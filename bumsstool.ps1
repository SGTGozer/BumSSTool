[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$appRoot = $PSScriptRoot
$startupLog = Join-Path ([IO.Path]::GetTempPath()) 'bumsstool-startup.log'
try {
    if ($env:OS -ne 'Windows_NT') { throw 'bumsstool requires Windows 10 or Windows 11 (x64).' }
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Launch bumsstool.exe or Start-bumsstool.cmd to run the interface in STA mode.' }
    if (-not [Environment]::Is64BitProcess) { throw 'Please launch with 64-bit Windows PowerShell.' }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    . (Join-Path $appRoot 'src\Core.ps1')
    . (Join-Path $appRoot 'src\ViewModel.ps1')
    $script:CacheRoot = Join-Path $env:LOCALAPPDATA 'bumsstool'
    $null = New-Item -ItemType Directory -Path $script:CacheRoot -Force
    $script:PreferencesPath = Join-Path $script:CacheRoot 'preferences.json'
    $script:Favorites = @()
    if (Test-Path -LiteralPath $script:PreferencesPath) {
        try {
            $preferences = Get-Content -LiteralPath $script:PreferencesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:Favorites = @(Get-BumValue $preferences 'Favorites' @())
        } catch { $script:Favorites = @() }
    }
    $script:Catalog = Get-BumCatalog (Join-Path $appRoot 'tools.json')
    $reader = New-Object Xml.XmlNodeReader([xml](Get-Content -LiteralPath (Join-Path $appRoot 'src\Main.xaml') -Raw -Encoding UTF8))
    $script:Window = [Windows.Markup.XamlReader]::Load($reader)
    $reader.Close()
    $script:UI = @{}
    foreach ($name in @('CarSymbols','CarHeadlights','HeaderCarImage','TitleBar','MinimizeButton','MaximizeButton','CloseWindowButton','DetailsPanel','CloseDetailsButton','AllToolsButton','FavoritesButton','DownloadedButton','InstallPathText','StatusHeading','StatusBadge','TotalBadge','HelpButton','Categories','CacheFolderButton','ConsoleButton','RefreshButton','ClearDownloadsButton','SearchBox','ClearSearchButton','SectionTitle','ResultsText','ToolGrid','EmptyText','DetailName','DetailCategory','DetailDescription','DetailNotes','DownloadButton','RunButton','SourceButton','ToolFolderButton','FavoriteButton','LaunchFile','ArgumentsBox','AdminBox','ConsoleBox','InstallDetails','StatusText','CancelButton','ExportButton','DownloadProgress','LogBox')) {
        $script:UI[$name] = $script:Window.FindName($name)
        if ($null -eq $script:UI[$name]) { throw "Missing interface control: $name" }
    }
    $icon = Join-Path $appRoot 'assets\car.ico'
    if (Test-Path -LiteralPath $icon) { $script:Window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$icon) }
    $script:UI.CarSymbols.Text = [IO.File]::ReadAllText((Join-Path $appRoot 'assets\car.txt')).TrimEnd()
    $script:UI.CarHeadlights.Text = Get-BumCarLightMask $script:UI.CarSymbols.Text
    $script:UI.HeaderCarImage.Source = [Windows.Media.Imaging.BitmapImage]::new([Uri](Join-Path $appRoot 'assets\car.png'))
    $script:UI.InstallPathText.Text = "Install path:`n$script:CacheRoot"
    $area = [Windows.SystemParameters]::WorkArea
    $script:Window.Width = [Math]::Min(1320, [Math]::Max(1060, $area.Width - 45))
    $script:Window.Height = [Math]::Min(800, [Math]::Max(680, $area.Height - 35))
    $script:Category = 'Orbdiff'
    $script:SelectedTool = $null
    $script:CurrentState = $null
    $script:Busy = $false
    $script:Rebuilding = $false
    $script:Worker = $null
    $script:Launches = New-Object 'System.Collections.Generic.List[object]'
    $script:LastLaunchPoll = [DateTime]::MinValue
    $script:PendingClose = $false
    $script:ActionQueue = New-BumActionQueue
    $script:RowsById = @{}
    $script:AppliedSearch = ''
    $script:ToolView = $null
    $script:IgnoreCardMouseUp = $false
    $script:SessionLines = New-Object 'System.Collections.Generic.List[string]'
    $script:SessionPath = Join-Path $script:CacheRoot ('session-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.log')

    function Write-AppLog {
        param([string]$Message)
        $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message
        $script:SessionLines.Add($line)
        Add-Content -LiteralPath $script:SessionPath -Value $line -Encoding UTF8
        $script:UI.LogBox.AppendText($line + [Environment]::NewLine)
        $script:UI.LogBox.ScrollToEnd()
    }

    function Show-AppError {
        param([string]$Message)
        Set-AppStatus $Message 'Error'
        Write-AppLog ('Error: ' + $Message)
    }

    function Set-AppStatus {
        param([string]$Message, [string]$State = 'Ready')
        $script:UI.StatusText.Text = $Message
        $script:UI.StatusHeading.Text = $State
        if ($script:Busy) { $script:UI.StatusBadge.Text = 'BUSY' }
        elseif ($State -eq 'Error') { $script:UI.StatusBadge.Text = 'ERROR' }
        else { $script:UI.StatusBadge.Text = 'IDLE' }
    }

    function Select-AppCollection {
        param([string]$Name)
        $script:Category = $Name
        $script:UI.Categories.SelectedIndex = -1
        $script:UI.DetailsPanel.Visibility = 'Collapsed'
        Refresh-Tools
    }

    function Show-ToolControls {
        if ($null -eq $script:UI.ToolGrid.SelectedItem) { return }
        Update-ToolDetails
        $script:UI.DetailsPanel.Visibility = 'Visible'
        $null = $script:UI.CloseDetailsButton.Focus()
    }

    function Toggle-AppMaximize {
        if ($script:Window.WindowState -eq [Windows.WindowState]::Maximized) {
            $script:Window.WindowState = [Windows.WindowState]::Normal
        } else { $script:Window.WindowState = [Windows.WindowState]::Maximized }
    }

    function Get-SelectedRow {
        if ($null -eq $script:UI.ToolGrid.SelectedItem) { return $null }
        return $script:UI.ToolGrid.SelectedItem
    }

    function Update-ToolDetails {
        $row = Get-SelectedRow
        $previousId = ''
        if ($null -ne $script:SelectedTool) { $previousId = $script:SelectedTool.Id }
        $script:SelectedTool = $null
        $script:CurrentState = $null
        $script:UI.LaunchFile.ItemsSource = $null
        $script:UI.LaunchFile.IsEnabled = $false
        $script:UI.RunButton.IsEnabled = $false
        $script:UI.ToolFolderButton.IsEnabled = $false
        $script:UI.DownloadButton.IsEnabled = $false
        $script:UI.SourceButton.IsEnabled = $false
        $script:UI.FavoriteButton.IsEnabled = $false
        if ($null -eq $row) {
            $script:UI.DetailName.Text = 'Pick a tool'
            $script:UI.DetailCategory.Text = ''
            $script:UI.DetailDescription.Text = 'Select an entry to see its download and launch controls.'
            $script:UI.DetailNotes.Text = ''
            $script:UI.InstallDetails.Text = ''
            return
        }
        $tool = $row.Tool
        if ($tool.Id -ne $previousId) { $script:UI.ArgumentsBox.Text = '' }
        $script:SelectedTool = $tool
        $script:UI.DetailName.Text = $tool.Name
        $script:UI.DetailCategory.Text = $tool.Category + ' / ' + $tool.Kind
        $script:UI.DetailDescription.Text = $tool.Description
        $script:UI.DetailNotes.Text = [string](Get-BumValue $tool 'Notes' '')
        $script:UI.SourceButton.IsEnabled = $true
        $script:UI.FavoriteButton.IsEnabled = $true
        if ($tool.Id -in $script:Favorites) { $script:UI.FavoriteButton.Content = 'Remove from favorites' }
        else { $script:UI.FavoriteButton.Content = 'Add to favorites' }
        $script:UI.DownloadButton.IsEnabled = -not $script:Busy
        if ($tool.Kind -eq 'Website') { $script:UI.DownloadButton.Content = 'Open website' }
        else { $script:UI.DownloadButton.Content = 'Download' }
        try { $state = Get-BumInstalled $script:CacheRoot $tool }
        catch { Write-AppLog $_.Exception.Message; $state = $null }
        if ($null -eq $state) {
            $script:UI.InstallDetails.Text = 'Click the card to install and open this tool automatically. Download here installs it without opening it.'
            return
        }
        $script:CurrentState = $state
        $script:UI.DownloadButton.Content = 'Re-download'
        $script:UI.ToolFolderButton.IsEnabled = $true
        $launchables = @(Get-BumLaunchables $state.Payload $tool.Name)
        $choices = @(foreach ($file in $launchables) {
            [pscustomobject]@{ DisplayName = $file.FullName.Substring($state.Payload.Length).TrimStart('\','/'); Path = $file.FullName }
        })
        $script:UI.LaunchFile.ItemsSource = $choices
        if ($choices.Count -gt 0) {
            $script:UI.LaunchFile.SelectedIndex = 0
            try {
                $preferred = (Get-BumPreferredLaunchFile $state.Payload $tool).FullName
                for ($i=0; $i -lt $choices.Count; $i++) {
                    if ($choices[$i].Path -eq $preferred) { $script:UI.LaunchFile.SelectedIndex=$i; break }
                }
            } catch {}
            $script:UI.LaunchFile.IsEnabled = -not $script:Busy
            $script:UI.RunButton.IsEnabled = -not $script:Busy
        }
        $hashText = 'SHA-256: ' + $state.Sha256.Substring(0,16) + '...'
        if ($state.PublisherHashVerified) { $hashText += ' (publisher hash verified)' }
        $script:UI.InstallDetails.Text = "Downloaded version: $($state.Version)`n$hashText"
        if ($choices.Count -eq 0) { $script:UI.InstallDetails.Text += "`nNo launch file found. Open the tool folder or Source page." }
    }

    function Initialize-ToolRows {
        $script:Rebuilding = $true
        try {
            $script:ToolRows = New-BumToolRows $script:Catalog.Tools $script:CacheRoot $script:Favorites
            $script:RowsById = @{}
            foreach ($row in $script:ToolRows) { $script:RowsById[$row.Id] = $row }
            $script:ToolView = [Windows.Data.CollectionViewSource]::GetDefaultView($script:ToolRows)
            $script:ToolView.Filter = [Predicate[object]]{
                param($row)
                Test-BumRowVisible $row $script:Category $script:AppliedSearch
            }
            $script:UI.ToolGrid.ItemsSource = $script:ToolView
            $script:UI.TotalBadge.Text = "$($script:ToolRows.Count) catalog entries"
            if ($null -ne $script:Worker -and $script:RowsById.ContainsKey($script:Worker.Tool.Id)) {
                $script:RowsById[$script:Worker.Tool.Id].State = 'Preparing...'
            }
            foreach ($id in $script:ActionQueue.Ids.Keys) {
                if ($script:RowsById.ContainsKey($id)) { $script:RowsById[$id].State = 'Queued' }
            }
        } finally { $script:Rebuilding = $false }
    }

    function Refresh-Tools {
        param([string]$PreserveId = '')
        if ($null -eq $script:ToolView) { return }
        if ($script:Rebuilding) { return }
        if ($null -ne $script:SearchTimer) { $script:SearchTimer.Stop() }
        $script:Rebuilding = $true
        try {
            $selected = Get-SelectedRow
            if (-not $PreserveId -and $null -ne $selected) { $PreserveId = $selected.Id }
            $script:AppliedSearch = $script:UI.SearchBox.Text.Trim()
            $script:ToolView.Refresh()
            $script:UI.SectionTitle.Text = $script:Category
            $script:UI.ResultsText.Text = "$($script:ToolView.Count) entries"
            if ($script:ToolView.Count -eq 0) { $script:UI.EmptyText.Visibility = 'Visible' }
            else {
                $script:UI.EmptyText.Visibility = 'Collapsed'
                if ($PreserveId -and $script:RowsById.ContainsKey($PreserveId)) {
                    $match = $script:RowsById[$PreserveId]
                    if ($script:ToolView.Contains($match)) { $script:UI.ToolGrid.SelectedItem = $match }
                }
            }
        } finally { $script:Rebuilding = $false }
        if ($script:UI.DetailsPanel.Visibility -eq [Windows.Visibility]::Visible) { Update-ToolDetails }
    }

    function Start-InstalledTool {
        param($Tool, [string]$Arguments = '', [bool]$Admin = $false, [bool]$Console = $false, [string]$LaunchPath = '')
        $state = Get-BumInstalled $script:CacheRoot $Tool
        if ($null -eq $state) { throw "$($Tool.Name) is no longer installed. Click the card again to download it." }
        $path = $LaunchPath
        if (-not $path) { $path = (Get-BumPreferredLaunchFile $state.Payload $Tool).FullName }
        $process = Start-BumExecutable $path $Arguments $Admin $Console $Tool $script:CacheRoot
        $script:Launches.Add([pscustomobject]@{ Tool=$Tool; Process=$process; State='Starting'; Started=[DateTime]::UtcNow })
        Write-AppLog ('Starting ' + $Tool.Name + ': ' + [IO.Path]::GetFileName($path) + '. Log: ' + $process.LaunchLogPath)
        Set-AppStatus ($Tool.Name + ' is starting...') 'Starting'
    }

    function Update-LaunchStatuses {
        if (([DateTime]::UtcNow - $script:LastLaunchPoll).TotalMilliseconds -lt 1000) { return }
        $script:LastLaunchPoll = [DateTime]::UtcNow
        foreach ($launch in @($script:Launches.ToArray())) {
            $status = $null
            try {
                if (Test-Path -LiteralPath $launch.Process.LaunchStatusPath) {
                    $status = Get-Content -LiteralPath $launch.Process.LaunchStatusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                }
            } catch { continue }
            if ($null -ne $status -and $status.State -ne $launch.State) {
                $launch.State = $status.State
                if ($status.State -eq 'Running') {
                    Write-AppLog ($launch.Tool.Name + ' started.')
                    if (-not $script:Busy) { Set-AppStatus ($launch.Tool.Name + ' is running.') 'Running' }
                } elseif ($status.State -eq 'Failed') {
                    Show-AppError ($launch.Tool.Name + ': ' + $status.Message + ' Log: ' + $status.LogPath)
                    if ($script:RowsById.ContainsKey($launch.Tool.Id)) { $script:RowsById[$launch.Tool.Id].State = 'Launch failed' }
                } elseif ($status.State -eq 'Exited') { Write-AppLog ($launch.Tool.Name + ' exited with code 0.') }
            }
            if ($null -eq $status -and $launch.Process.HasExited) {
                Show-AppError ($launch.Tool.Name + ' launch supervisor exited before starting the tool. Log: ' + $launch.Process.LaunchLogPath)
                $launch.State = 'Failed'
            }
            if ($launch.State -in @('Failed','Exited')) {
                $launch.Process.Dispose()
                $null = $script:Launches.Remove($launch)
            }
        }
    }

    function Invoke-ToolCard {
        param($Row)
        if ($null -eq $Row -or $script:PendingClose) { return }
        $tool = $Row.Tool
        if ($tool.Kind -eq 'Website') {
            Start-BumWebsite $tool.Url
            Write-AppLog ('Opened website: ' + $tool.Name)
            return
        }
        if ($script:ActionQueue.Ids.ContainsKey($tool.Id) -or
            ($null -ne $script:Worker -and $script:Worker.Tool.Id -eq $tool.Id)) { return }
        $state = $null
        try { $state = Get-BumInstalled $script:CacheRoot $tool } catch {}
        $action = [pscustomobject]@{ Tool = $tool; AutoRun = $true; DownloadRequired = ($null -eq $state); LaunchPath = ''; Arguments = ''; Admin = $false; Console = $false }
        if ($script:Busy) {
            if (Add-BumQueuedAction $script:ActionQueue $action) {
                $Row.State = 'Queued'
                Write-AppLog ('Queued ' + $tool.Name + ' for preparation and launch.')
            }
        } else { Start-ToolDownload $action }
    }

    function Start-ToolDownload {
        param($Action = $null)
        if ($script:Busy) { return }
        if ($null -eq $Action) {
            if ($null -eq $script:SelectedTool) { return }
            $Action = [pscustomobject]@{ Tool = $script:SelectedTool; AutoRun = $false; Arguments = ''; Admin = $false; Console = $false }
        }
        $tool = $Action.Tool
        if ($tool.Kind -eq 'Website') {
            Start-BumWebsite $tool.Url
            Write-AppLog ('Opened website: ' + $tool.Name)
            return
        }
        $script:Busy = $true
        $script:UI.ClearDownloadsButton.IsEnabled = $false
        $script:UI.CancelButton.IsEnabled = $true
        $script:UI.DownloadProgress.IsIndeterminate = $true
        Set-AppStatus ('Preparing ' + $tool.Name + '...') 'Preparing'
        Write-AppLog ('Preparation requested: ' + $tool.Name)
        $runspace = $null; $ps = $null; $cancellation = $null
        try {
            $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
            $cancellation = New-Object Threading.CancellationTokenSource
            $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $runspace.ApartmentState = 'STA'
            $runspace.ThreadOptions = 'ReuseThread'
            $runspace.Open()
            $ps = [Management.Automation.PowerShell]::Create()
            $ps.Runspace = $runspace
            $code = {
                param($corePath, $action, $root, $queue, $cancellation)
                $ErrorActionPreference = 'Stop'
                . $corePath
                try {
                    $result = Prepare-BumToolAction $action $root $queue $cancellation
                    $queue.Enqueue([pscustomobject]@{ Type = 'Complete'; Message = "$($action.Tool.Name) is ready."; Percent = 100 })
                    return $result
                } catch {
                    $message = $_.Exception.Message
                    if ($cancellation.IsCancellationRequested) { $message = 'Preparation cancelled. The previous download is still available.' }
                    $queue.Enqueue([pscustomobject]@{ Type = 'Failure'; Message = $message; Percent = -1 })
                    throw
                }
            }
            $null = $ps.AddScript($code.ToString()).AddArgument((Join-Path $appRoot 'src\Core.ps1')).AddArgument($Action).AddArgument($script:CacheRoot).AddArgument($queue).AddArgument($cancellation)
            $script:Worker = [pscustomobject]@{ PowerShell = $ps; Runspace = $runspace; Queue = $queue; Cancellation = $cancellation; Handle = $ps.BeginInvoke(); Tool = $tool; AutoRun = $Action.AutoRun; Arguments = $Action.Arguments; Admin = $Action.Admin; Console = $Action.Console }
            if ($script:RowsById.ContainsKey($tool.Id)) { $script:RowsById[$tool.Id].State = 'Preparing...' }
        } catch {
            if ($null -ne $ps) { $ps.Dispose() }
            if ($null -ne $runspace) { $runspace.Dispose() }
            if ($null -ne $cancellation) { $cancellation.Dispose() }
            $script:Busy = $false
            $script:UI.ClearDownloadsButton.IsEnabled = $true
            $script:UI.CancelButton.IsEnabled = $false
            $script:UI.DownloadProgress.IsIndeterminate = $false
            if ($script:RowsById.ContainsKey($tool.Id)) { $script:RowsById[$tool.Id].State = 'Retry install' }
            throw
        }
        if ($script:UI.DetailsPanel.Visibility -eq [Windows.Visibility]::Visible) { Update-ToolDetails }
    }

    function Clear-QueuedToolActions {
        foreach ($id in @($script:ActionQueue.Ids.Keys)) {
            if ($script:RowsById.ContainsKey($id)) { Update-BumRowInstallState $script:RowsById[$id] $script:CacheRoot }
        }
        Clear-BumActionQueue $script:ActionQueue
    }

    function Start-NextQueuedTool {
        if ($script:Busy -or $script:PendingClose) { return }
        while ($script:ActionQueue.Items.Count -gt 0) {
            $action = Get-BumQueuedAction $script:ActionQueue
            try {
                Start-ToolDownload $action; return
            } catch { Show-AppError $_.Exception.Message }
        }
    }

    function Finish-ToolDownload {
        $worker = $script:Worker
        $success = $false
        $launchPath = ''
        $cancelled = $worker.Cancellation.IsCancellationRequested
        try {
            $results = @($worker.PowerShell.EndInvoke($worker.Handle))
            foreach ($result in $results) {
                if (Get-BumValue $result 'Installed' $false) { $success = $true; $launchPath = [string](Get-BumValue $result 'LaunchPath' '') }
            }
        } catch {
            if (-not $cancelled) { Set-AppStatus $_.Exception.Message 'Error' }
            Write-AppLog ('Preparation failed: ' + $_.Exception.Message)
        } finally {
            $worker.PowerShell.Dispose()
            $worker.Runspace.Dispose()
            $worker.Cancellation.Dispose()
            $script:Worker = $null
            $script:Busy = $false
            $script:UI.CancelButton.IsEnabled = $false
            $script:UI.ClearDownloadsButton.IsEnabled = $true
            $script:UI.DownloadProgress.IsIndeterminate = $false
        }
        if ($script:RowsById.ContainsKey($worker.Tool.Id)) {
            $row = $script:RowsById[$worker.Tool.Id]
            Update-BumRowInstallState $row $script:CacheRoot
            if (-not $success -and -not $cancelled) { $row.State = 'Retry setup' }
        }
        if ($cancelled) { Set-AppStatus 'Preparation cancelled.' 'Cancelled' }
        elseif ($success) { $script:UI.DownloadProgress.Value = 100; Set-AppStatus ($worker.Tool.Name + ' is ready.') 'Ready' }
        elseif ($script:UI.StatusHeading.Text -eq 'Error') { $script:UI.StatusBadge.Text = 'ERROR' }
        else { $script:UI.StatusBadge.Text = 'IDLE' }
        Refresh-Tools
        if ($script:PendingClose) { $script:Window.Close(); return }
        if ($success -and -not $cancelled -and $worker.AutoRun) {
            try { Start-InstalledTool $worker.Tool $worker.Arguments $worker.Admin $worker.Console $launchPath }
            catch { Show-AppError $_.Exception.Message }
        }
        Start-NextQueuedTool
    }

    $script:SearchTimer = New-Object Windows.Threading.DispatcherTimer
    $script:SearchTimer.Interval = [TimeSpan]::FromMilliseconds(180)
    $script:SearchTimer.Add_Tick({
        $script:SearchTimer.Stop()
        if ($script:UI.SearchBox.Text.Trim().Length -gt 0 -and $script:Category -notin @('All tools','Favorites','Downloaded')) {
            $script:Category = 'All tools'
            $script:UI.Categories.SelectedIndex = -1
        }
        Refresh-Tools
    })
    Initialize-ToolRows
    $categoryNames = @('Orbdiff','Spokwn','Tonynoh','Praiselily','RedLotus','Zimmerman','NirSoft','Dependencies','Others')
    foreach ($category in $categoryNames) {
        $item = New-Object Windows.Controls.ListBoxItem
        $item.Content = $category
        $item.Tag = $category
        $null = $script:UI.Categories.Items.Add($item)
    }
    $script:UI.Categories.Add_SelectionChanged({
        if ($null -ne $script:UI.Categories.SelectedItem) {
            $script:Category = [string]$script:UI.Categories.SelectedItem.Tag
            $script:UI.DetailsPanel.Visibility = 'Collapsed'
            Refresh-Tools
        }
    })
    $script:UI.Categories.SelectedIndex = 0
    $script:UI.SearchBox.Add_TextChanged({
        $script:SearchTimer.Stop()
        $script:SearchTimer.Start()
    })
    $script:UI.ClearSearchButton.Add_Click({ $script:UI.SearchBox.Text = ''; Refresh-Tools })
    $script:UI.ToolGrid.Add_SelectionChanged({
        if (-not $script:Rebuilding) {
            $row = Get-SelectedRow
            if ($script:UI.DetailsPanel.Visibility -eq [Windows.Visibility]::Visible) { Update-ToolDetails }
            else {
                if ($null -ne $row) {
                    if ($null -eq $script:SelectedTool -or $script:SelectedTool.Id -ne $row.Id) { $script:UI.ArgumentsBox.Text = '' }
                    $script:SelectedTool = $row.Tool
                } else { $script:SelectedTool = $null }
            }
        }
    })
    $script:UI.ToolGrid.Add_PreviewMouseLeftButtonDown({ param($sender, $eventArgs)
        # WPF updates ClickCount on mouse-down; mouse-up does not carry that count.
        $script:IgnoreCardMouseUp = $eventArgs.ClickCount -gt 1
    })
    $script:UI.ToolGrid.Add_MouseLeftButtonUp({
        param($sender, $eventArgs)
        if ($script:IgnoreCardMouseUp) { $script:IgnoreCardMouseUp = $false; return }
        $item = [Windows.Controls.ItemsControl]::ContainerFromElement($script:UI.ToolGrid, $eventArgs.OriginalSource)
        if ($null -ne $item) {
            try { Invoke-ToolCard $item.Content } catch { Show-AppError $_.Exception.Message }
        }
    })
    $script:UI.ToolGrid.Add_PreviewMouseRightButtonUp({ param($sender, $eventArgs)
        $item = [Windows.Controls.ItemsControl]::ContainerFromElement($script:UI.ToolGrid, $eventArgs.OriginalSource)
        if ($null -ne $item) {
            $script:UI.ToolGrid.SelectedItem = $item.Content
            try { Show-ToolControls } catch { Show-AppError $_.Exception.Message }
            $eventArgs.Handled = $true
        }
    })
    $script:UI.ToolGrid.Add_KeyUp({ param($sender, $eventArgs)
        if ($eventArgs.Key -eq [Windows.Input.Key]::Enter) {
            try {
                if (([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift) -ne 0) { Show-ToolControls }
                else { Invoke-ToolCard (Get-SelectedRow) }
            } catch { Show-AppError $_.Exception.Message }
            $eventArgs.Handled = $true
        }
    })
    $script:UI.CloseDetailsButton.Add_Click({ $script:UI.DetailsPanel.Visibility = 'Collapsed'; $null = $script:UI.ToolGrid.Focus() })
    $script:UI.DetailsPanel.Add_MouseLeftButtonDown({ param($sender, $eventArgs)
        if ($eventArgs.OriginalSource -eq $script:UI.DetailsPanel) {
            $script:UI.DetailsPanel.Visibility = 'Collapsed'
            $null = $script:UI.ToolGrid.Focus()
        }
    })
    $script:UI.AllToolsButton.Add_Click({ Select-AppCollection 'All tools' })
    $script:UI.FavoritesButton.Add_Click({ Select-AppCollection 'Favorites' })
    $script:UI.DownloadedButton.Add_Click({ Select-AppCollection 'Downloaded' })
    $script:UI.MinimizeButton.Add_Click({ $script:Window.WindowState = [Windows.WindowState]::Minimized })
    $script:UI.MaximizeButton.Add_Click({ Toggle-AppMaximize })
    $script:UI.CloseWindowButton.Add_Click({ $script:Window.Close() })
    $script:UI.TitleBar.Add_MouseLeftButtonDown({ param($sender, $eventArgs)
        $source = $eventArgs.OriginalSource
        while ($null -ne $source -and $source -ne $script:UI.TitleBar) {
            if ($source -is [Windows.Controls.Primitives.ButtonBase]) { return }
            if ($source -is [Windows.FrameworkContentElement]) { $source = $source.Parent }
            else { $source = [Windows.Media.VisualTreeHelper]::GetParent($source) }
        }
        if ($eventArgs.ClickCount -eq 2) { Toggle-AppMaximize }
        else { try { $script:Window.DragMove() } catch {} }
    })
    $script:Window.Add_KeyDown({ param($sender, $eventArgs)
        if ($eventArgs.Key -eq [Windows.Input.Key]::Escape -and $script:UI.DetailsPanel.Visibility -eq [Windows.Visibility]::Visible) {
            $script:UI.DetailsPanel.Visibility = 'Collapsed'
            $null = $script:UI.ToolGrid.Focus()
            $eventArgs.Handled = $true
        }
    })
    $script:UI.DownloadButton.Add_Click({ try { Start-ToolDownload } catch { Show-AppError $_.Exception.Message } })
    $script:UI.RunButton.Add_Click({
        try {
            if ($script:Busy -or $null -eq $script:UI.LaunchFile.SelectedItem) { return }
            $path = $script:UI.LaunchFile.SelectedItem.Path
            Start-ToolDownload ([pscustomobject]@{ Tool=$script:SelectedTool;AutoRun=$true;DownloadRequired=$false;LaunchPath=$path;Arguments=$script:UI.ArgumentsBox.Text;Admin=[bool]$script:UI.AdminBox.IsChecked;Console=[bool]$script:UI.ConsoleBox.IsChecked })
        } catch { Show-AppError $_.Exception.Message }
    })
    $script:UI.SourceButton.Add_Click({ try { if ($script:SelectedTool) { Start-BumWebsite $script:SelectedTool.SourceUrl } } catch { Show-AppError $_.Exception.Message } })
    $script:UI.ToolFolderButton.Add_Click({ try { if ($script:CurrentState) { Start-Process explorer.exe -ArgumentList ('"' + $script:CurrentState.Payload + '"') } } catch { Show-AppError $_.Exception.Message } })
    $script:UI.CacheFolderButton.Add_Click({ try { Start-Process explorer.exe -ArgumentList ('"' + $script:CacheRoot + '"') } catch { Show-AppError $_.Exception.Message } })
    $script:UI.ConsoleButton.Add_Click({
        try {
            $console = Join-Path $env:SystemRoot 'System32\cmd.exe'
            Start-Process $console -ArgumentList '/d /k' -WorkingDirectory $script:CacheRoot
            Write-AppLog 'Opened CMD in the tools folder.'
        } catch { Show-AppError $_.Exception.Message }
    })
    $script:UI.FavoriteButton.Add_Click({
        try {
            if ($null -eq $script:SelectedTool) { return }
            $id = $script:SelectedTool.Id
            if ($id -in $script:Favorites) { $script:Favorites = @($script:Favorites | Where-Object { $_ -ne $id }) }
            else { $script:Favorites = @($script:Favorites) + $id }
            Write-BumJsonAtomic $script:PreferencesPath ([pscustomobject]@{ Favorites = @($script:Favorites) })
            if ($script:RowsById.ContainsKey($id)) { $script:RowsById[$id].IsFavorite = $id -in $script:Favorites }
            Refresh-Tools $id
        } catch { Show-AppError $_.Exception.Message }
    })
    $script:UI.RefreshButton.Add_Click({
        try { $script:Catalog = Get-BumCatalog (Join-Path $appRoot 'tools.json'); Initialize-ToolRows; Refresh-Tools; Write-AppLog 'Reloaded the tool catalog and local download records.' }
        catch { Show-AppError $_.Exception.Message }
    })
    $script:UI.ClearDownloadsButton.Add_Click({
        try {
            if ($script:Busy) { return }
            $answer = [Windows.MessageBox]::Show($script:Window,
                'Remove all tools downloaded by bumsstool? This keeps the app, favorites and session logs. Close running tools before clearing.',
                'Clear bumsstool downloads', [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Question)
            if ($answer -ne [Windows.MessageBoxResult]::Yes) { return }
            foreach ($folderName in @('tools','staging')) {
                $folderPath = Join-Path $script:CacheRoot $folderName
                if (Test-Path -LiteralPath $folderPath) { Remove-Item -LiteralPath $folderPath -Recurse -Force -ErrorAction Stop }
            }
            Initialize-ToolRows
            Refresh-Tools
            Write-AppLog 'Cleared tools downloaded by bumsstool.'
            Set-AppStatus 'Downloaded tools cleared.'
        } catch { Refresh-Tools; Show-AppError $_.Exception.Message }
    })
    $script:UI.CancelButton.Add_Click({
        Clear-QueuedToolActions
        if ($null -ne $script:Worker) {
            $script:Worker.Cancellation.Cancel()
            Set-AppStatus 'Cancelling download...' 'Cancelling'
            $script:UI.CancelButton.IsEnabled = $false
        }
    })
    $script:UI.HelpButton.Add_Click({ try { Start-Process notepad.exe -ArgumentList ('"' + (Join-Path $appRoot 'README.txt') + '"') } catch { Show-AppError $_.Exception.Message } })
    $script:UI.ExportButton.Add_Click({
        try {
            $dialog = New-Object Microsoft.Win32.SaveFileDialog
            $dialog.Filter = 'Text log (*.txt)|*.txt|All files (*.*)|*.*'
            $dialog.FileName = 'bumsstool-session-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt'
            if ($dialog.ShowDialog($script:Window)) {
                @('bumsstool session log', 'Exported: ' + [DateTime]::Now.ToString('o'), '') + @($script:SessionLines) | Set-Content -LiteralPath $dialog.FileName -Encoding UTF8
                Write-AppLog 'Exported session log. Tool findings remain in their own windows and output files.'
            }
        } catch { Show-AppError $_.Exception.Message }
    })

    $script:Timer = New-Object Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $script:Timer.Add_Tick({
        Update-LaunchStatuses
        if ($null -eq $script:Worker) { return }
        $entry = $null
        while ($script:Worker.Queue.TryDequeue([ref]$entry)) {
            switch ($entry.Type) {
                'Log' { Write-AppLog $entry.Message }
                'Progress' {
                    Set-AppStatus ($script:Worker.Tool.Name + ': ' + $entry.Message) 'Downloading'
                    $script:UI.DownloadProgress.IsIndeterminate = $entry.Percent -lt 0
                    if ($entry.Percent -ge 0) { $script:UI.DownloadProgress.Value = $entry.Percent }
                }
                'Failure' { Set-AppStatus $entry.Message 'Error'; Write-AppLog ('Preparation failed: ' + $entry.Message) }
                'Complete' { Set-AppStatus $entry.Message 'Ready' }
                default { Set-AppStatus $entry.Message 'Preparing' }
            }
        }
        if ($script:Worker.Handle.IsCompleted) {
            Finish-ToolDownload
        }
    })
    $script:Window.Add_Closing({
        param($sender, $eventArgs)
        Clear-QueuedToolActions
        if ($script:Busy -and $null -ne $script:Worker) {
            $eventArgs.Cancel = $true
            $script:PendingClose = $true
            $script:Worker.Cancellation.Cancel()
            Set-AppStatus 'Finishing download cancellation before closing...' 'Closing'
        }
    })
    $script:Window.Add_Closed({
        $script:Timer.Stop(); $script:SearchTimer.Stop()
        foreach ($launch in $script:Launches) { $launch.Process.Dispose() }
    })
    Write-AppLog "bumsstool by SGTGozer ready. $($script:Catalog.Tools.Count) catalog entries loaded."
    Write-AppLog 'Click a card to install and open it. Right-click for launch options.'
    Refresh-Tools
    $script:Timer.Start()
    $null = $script:Window.ShowDialog()
} catch {
    ($_ | Out-String) + [Environment]::NewLine + $_.ScriptStackTrace | Set-Content -LiteralPath $startupLog -Encoding UTF8
    try {
        Add-Type -AssemblyName PresentationFramework
        $null = [Windows.MessageBox]::Show("bumsstool could not start.`n`n$($_.Exception.Message)`n`nDetails: $startupLog", 'bumsstool startup error')
    } catch { Write-Error "bumsstool startup failed. Details: $startupLog" -ErrorAction Continue }
    exit 1
}
