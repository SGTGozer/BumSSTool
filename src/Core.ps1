# bumsstool - independent tool-catalog and download implementation.
# Compatible with Windows PowerShell 5.1. This file does not load the GUI.
Set-StrictMode -Version 2.0

function Get-BumValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-BumCatalog {
    param([Parameter(Mandatory = $true)][string]$Path)
    $catalog = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($catalog.SchemaVersion -ne 1) { throw 'Unsupported catalog version.' }
    $ids = @{}
    foreach ($tool in $catalog.Tools) {
        if ($tool.Id -notmatch '^[a-z0-9][a-z0-9-]*$') { throw "Invalid tool ID: $($tool.Id)" }
        if ($ids.ContainsKey($tool.Id)) { throw "Duplicate tool ID: $($tool.Id)" }
        $ids[$tool.Id] = $true
        if ($tool.Kind -notin @('GitHub', 'Direct', 'Script', 'Website', 'DotNet')) {
            throw "Invalid tool kind: $($tool.Kind)"
        }
        foreach ($url in @($tool.Url, $tool.SourceUrl)) {
            Assert-BumHttps $url
        }
    }
    return $catalog
}

function Assert-BumHttps {
    param([string]$Url)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.UserInfo) {
        throw "An HTTPS address is required: $Url"
    }
}

function Write-BumEvent {
    param($Queue, [string]$Type, [string]$Message, [double]$Percent = -1)
    if ($null -ne $Queue) {
        $Queue.Enqueue([pscustomobject]@{ Type = $Type; Message = $Message; Percent = $Percent })
    }
}

function Test-BumCancelled {
    param($Cancellation)
    if ($null -ne $Cancellation) { $Cancellation.Token.ThrowIfCancellationRequested() }
}

function Invoke-BumJson {
    param([string]$Url)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Assert-BumHttps $Url
    $headers = @{ 'User-Agent' = 'bumsstool/1.3'; 'Accept' = 'application/json' }
    try {
        # Assign before returning so REST JSON arrays become individual pipeline items.
        $data = Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec 35 -ErrorAction Stop
        return $data
    } catch {
        $status = 0
        $response = Get-BumValue $_.Exception 'Response'
        if ($null -ne $response) { $status = [int]$response.StatusCode }
        if ($status -eq 403 -or $status -eq 429) {
            throw 'The download provider is limiting requests. Wait a while or use the Source button.'
        }
        throw
    }
}

function Get-BumAssetScore {
    param([string]$Name)
    $nameLower = $Name.ToLowerInvariant()
    if ($nameLower -match '(linux|(?:^|[-_.])lin[-_.]|macos|(?:^|[-_.])mac[-_.]|osx|darwin|android|\.app\.|\.dmg$|\.deb$|\.rpm$|\.tar\.|\.tgz$)') { return -1 }
    if ($nameLower -match '(arm64|aarch64|arm32|armv7|win-arm|winarm)') { return -1 }
    if ($nameLower -match '(checksum|sha256|sha512|symbols|\.pdb\.|source|sources|\.sig$|\.asc$)') { return -1 }
    if ($nameLower -notmatch '\.(exe|zip|ps1|cmd|bat|msi|jar)$' -and $nameLower -notmatch '\.exe\.gz$') { return -1 }
    $score = 10
    if ($nameLower -match '(windows|win32|win64|win-x|win_x|win\.x|win-amd)') { $score += 25 }
    if ($nameLower -match '(x64|amd64|x86_64|64bit|64-bit)') { $score += 20 }
    if ($nameLower -match '(x86(?!_64)|32bit|32-bit|i386|i686)') { $score -= 5 }
    if ($nameLower -match '(portable|standalone)') { $score += 12 }
    if ($nameLower -match '(installer|setup|install\.)') { $score -= 8 }
    if ($nameLower -match '(debug|\.dbg\.|live-response|legacy)') { $score -= 15 }
    if ($nameLower -match '\.exe\.gz$') { $score += 8 }
    switch ([IO.Path]::GetExtension($nameLower)) {
        '.zip' { $score += 8 }
        '.exe' { $score += 7 }
        '.ps1' { $score += 4 }
        '.jar' { $score += 3 }
    }
    return $score
}

function Select-BumGitHubAsset {
    param($Assets)
    $scored = @(foreach ($asset in $Assets) {
        $score = Get-BumAssetScore $asset.name
        if ($score -ge 0) { [pscustomobject]@{ Score = $score; Name = $asset.name; Asset = $asset } }
    })
    if ($scored.Count -eq 0) { return $null }
    return ($scored | Sort-Object @{ Expression = 'Score'; Descending = $true }, Name | Select-Object -First 1).Asset
}

function Resolve-BumDownload {
    param($Tool, $Queue, $Cancellation)
    Test-BumCancelled $Cancellation
    Write-BumEvent $Queue 'Status' "Looking up $($Tool.Name)..."
    switch ($Tool.Kind) {
        'Website' { return [pscustomobject]@{ Browser = $true; Url = $Tool.Url } }
        'GitHub' {
            if ($Tool.Url -notmatch '^https://github\.com/([^/]+)/([^/]+)(?:/|$)') { throw 'Invalid GitHub repository address.' }
            $owner = $Matches[1]; $repo = $Matches[2]
            $releases = @()
            $listLoaded = $false
            try {
                $releases = @(Invoke-BumJson "https://api.github.com/repos/$owner/$repo/releases/latest")
            } catch {
                $response = Get-BumValue $_.Exception 'Response'
                if ($null -eq $response -or [int]$response.StatusCode -ne 404) { throw }
                $releases = @(Invoke-BumJson "https://api.github.com/repos/$owner/$repo/releases?per_page=10")
                $listLoaded = $true
            }
            if ($releases.Count -eq 0) { throw 'This repository has no published releases. Open its Source page for installation instructions.' }
            $preferred = Get-BumValue $Tool 'AssetPattern' ''
            $asset = $null; $release = $null
            for ($pass = 0; $pass -lt 2; $pass++) {
                foreach ($candidate in $releases) {
                    if ($candidate.draft) { continue }
                    $assets = @($candidate.assets)
                    if ($preferred) { $assets = @($assets | Where-Object { $_.name -match $preferred }) }
                    $asset = Select-BumGitHubAsset $assets
                    if ($null -ne $asset) { $release = $candidate; break }
                }
                if ($null -ne $asset -or $listLoaded) { break }
                $releases = @(Invoke-BumJson "https://api.github.com/repos/$owner/$repo/releases?per_page=10")
                $listLoaded = $true
            }
            if ($null -eq $asset) { throw 'No compatible Windows .exe, .zip, .ps1 or .jar release was found. Use the Source page.' }
            $sha = ''
            $digest = Get-BumValue $asset 'digest' ''
            if ($digest -match '^sha256:([a-fA-F0-9]{64})$') { $sha = $Matches[1] }
            return [pscustomobject]@{ Browser = $false; Url = $asset.browser_download_url; FileName = $asset.name; Version = $release.tag_name; Sha256 = $sha }
        }
        'DotNet' {
            $metadata = Invoke-BumJson $Tool.Url
            $latest = $metadata.releases | Where-Object { $null -ne (Get-BumValue $_ $Tool.Product) } | Select-Object -First 1
            if ($null -eq $latest) { throw 'No Microsoft runtime release was found.' }
            $product = Get-BumValue $latest $Tool.Product
            $file = $product.files | Where-Object { $_.rid -eq 'win-x64' -and $_.name -match '\.exe$' } | Select-Object -First 1
            if ($null -eq $file) { throw 'No x64 Windows installer was found in Microsoft release metadata.' }
            return [pscustomobject]@{ Browser = $false; Url = $file.url; FileName = ([Uri]$file.url).Segments[-1]; Version = $product.version; Sha256 = ''; Sha512 = (Get-BumValue $file 'hash' '') }
        }
        default {
            $fileName = [Uri]::UnescapeDataString(([Uri]$Tool.Url).Segments[-1])
            if ($Tool.Kind -eq 'Script') { $fileName = "$($Tool.Id).ps1" }
            if ($Tool.Name -eq 'VSRedist') { $fileName = 'vc_redist.x64.exe' }
            return [pscustomobject]@{ Browser = $false; Url = $Tool.Url; FileName = $fileName; Version = 'current'; Sha256 = '' }
        }
    }
}

function Save-BumDownload {
    param([string]$Url, [string]$Path, $Queue, $Cancellation)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Assert-BumHttps $Url
    $partial = "$Path.partial"
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.UserAgent = 'bumsstool/1.3'
    $request.Timeout = 35000
    $request.ReadWriteTimeout = 20000
    $request.AllowAutoRedirect = $true
    $response = $null; $inputStream = $null; $outputStream = $null
    try {
        Test-BumCancelled $Cancellation
        $response = $request.GetResponse()
        Assert-BumHttps $response.ResponseUri.AbsoluteUri
        $total = $response.ContentLength
        if ($total -gt 2147483648) { throw 'This asset is larger than the 2 GB download limit. Use the Source page.' }
        if ($response.ContentType -match '^text/html') { throw 'The provider returned a web page instead of a downloadable file. Use the Source page.' }
        $inputStream = $response.GetResponseStream()
        $outputStream = [IO.File]::Open($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 131072
        [long]$received = 0
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            Test-BumCancelled $Cancellation
            $outputStream.Write($buffer, 0, $count)
            $received += $count
            if ($received -gt 2147483648) { throw 'The download exceeded 2 GB. Use the Source page.' }
            if ($clock.ElapsedMilliseconds -gt 200) {
                $percent = -1
                if ($total -gt 0) { $percent = 100.0 * $received / $total }
                Write-BumEvent $Queue 'Progress' ("Downloaded {0:N1} MB" -f ($received / 1MB)) $percent
                $clock.Restart()
            }
        }
        if ($received -eq 0) { throw 'The downloaded file is empty.' }
        if ($total -ge 0 -and $received -ne $total) { throw 'The download was incomplete. Try downloading again.' }
        $outputStream.Dispose(); $outputStream = $null
        Move-Item -LiteralPath $partial -Destination $Path -ErrorAction Stop
        Write-BumEvent $Queue 'Progress' 'Download complete.' 100
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
    }
}

function Expand-BumArchive {
    param([string]$Path, [string]$Destination, $Cancellation)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $null = New-Item -ItemType Directory -Path $Destination -Force
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        [long]$size = 0
        if ($zip.Entries.Count -gt 100000) { throw 'The archive contains too many entries.' }
        foreach ($entry in $zip.Entries) {
            Test-BumCancelled $Cancellation
            $size += $entry.Length
            if ($size -gt 10737418240) { throw 'The expanded archive exceeds the 10 GB limit.' }
            $relative = $entry.FullName.Replace('\', '/').Replace('/', [IO.Path]::DirectorySeparatorChar)
            if ($relative.Contains(':') -or [IO.Path]::IsPathRooted($relative)) { throw 'The archive contains an unsafe path.' }
            $target = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $relative))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'The archive tries to write outside its tool folder.' }
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                $null = New-Item -ItemType Directory -Path $target -Force
            } else {
                $null = New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force
                $source = $entry.Open()
                $dest = $null
                try {
                    $dest = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    $buffer = New-Object byte[] 131072
                    while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        Test-BumCancelled $Cancellation
                        $dest.Write($buffer, 0, $count)
                    }
                } finally {
                    if ($null -ne $dest) { $dest.Dispose() }
                    $source.Dispose()
                }
            }
        }
    } finally { $zip.Dispose() }
}

function Expand-BumGzip {
    param([string]$Path, [string]$Destination, $Cancellation)
    $inputStream = [IO.File]::OpenRead($Path)
    $gzip = $null; $outputStream = $null
    try {
        $gzip = New-Object IO.Compression.GZipStream($inputStream, [IO.Compression.CompressionMode]::Decompress)
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        $buffer = New-Object byte[] 131072
        [long]$size = 0
        while (($count = $gzip.Read($buffer, 0, $buffer.Length)) -gt 0) {
            Test-BumCancelled $Cancellation
            $size += $count
            if ($size -gt 2147483648) { throw 'The expanded executable exceeded 2 GB.' }
            $outputStream.Write($buffer, 0, $count)
        }
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $gzip) { $gzip.Dispose() }
        $inputStream.Dispose()
    }
}

function Write-BumJsonAtomic {
    param([string]$Path, $Value)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backup = "$Path.bak"
    try {
        $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($temporary, $Path, $backup)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        } else { [IO.File]::Move($temporary, $Path) }
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-BumToolDirectory {
    param([string]$CacheRoot, $Tool)
    if ($Tool.Id -notmatch '^[a-z0-9][a-z0-9-]*$') { throw 'Invalid tool ID.' }
    return Join-Path (Join-Path $CacheRoot 'tools') $Tool.Id
}

function Get-BumInstalled {
    param([string]$CacheRoot, $Tool)
    $dir = Get-BumToolDirectory $CacheRoot $Tool
    $statePath = Join-Path $dir 'installed.json'
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.ToolId -ne $Tool.Id -or $state.Folder -notmatch '^[a-f0-9]{32}$') { throw 'The saved tool record is invalid.' }
    $versionDir = Join-Path (Join-Path $dir 'versions') $state.Folder
    if (-not (Test-Path -LiteralPath $versionDir -PathType Container)) { return $null }
    if (-not (Test-Path -LiteralPath (Join-Path $versionDir 'payload') -PathType Container)) { return $null }
    $state | Add-Member -NotePropertyName Directory -NotePropertyValue $versionDir -Force
    $state | Add-Member -NotePropertyName Payload -NotePropertyValue (Join-Path $versionDir 'payload') -Force
    return $state
}

function Install-BumTool {
    param($Tool, [string]$CacheRoot, $Queue, $Cancellation)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $resolved = Resolve-BumDownload $Tool $Queue $Cancellation
    if ($resolved.Browser) { return $resolved }
    $fileName = $resolved.FileName
    if ($fileName -notmatch '^[^\\/:*?"<>|]+\.(exe|zip|ps1|cmd|bat|msi|jar|exe\.gz)$' -or $fileName -match '^\.') {
        throw 'The provider supplied an unsupported or invalid filename. Use the Source page.'
    }
    $toolDir = Get-BumToolDirectory $CacheRoot $Tool
    $null = New-Item -ItemType Directory -Path $toolDir -Force
    $folder = [guid]::NewGuid().ToString('N')
    $staging = Join-Path (Join-Path $CacheRoot 'staging') $folder
    $payload = Join-Path $staging 'payload'
    $null = New-Item -ItemType Directory -Path $payload -Force
    $assetPath = Join-Path $staging $fileName
    try {
        Write-BumEvent $Queue 'Log' "Downloading $fileName from $(([Uri]$resolved.Url).Host)."
        Save-BumDownload $resolved.Url $assetPath $Queue $Cancellation
        $hash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($resolved.Sha256 -and $hash -ne $resolved.Sha256.ToLowerInvariant()) { throw 'SHA-256 verification failed. The file will not be installed.' }
        $sha512 = Get-BumValue $resolved 'Sha512' ''
        if ($sha512 -and (Get-FileHash -LiteralPath $assetPath -Algorithm SHA512).Hash -ne $sha512) { throw 'Microsoft SHA-512 verification failed.' }
        if ($fileName -match '\.zip$') {
            Write-BumEvent $Queue 'Status' 'Extracting the tool...'
            Expand-BumArchive $assetPath $payload $Cancellation
        } elseif ($fileName -match '\.exe\.gz$') {
            Write-BumEvent $Queue 'Status' 'Decompressing the Windows executable...'
            Expand-BumGzip $assetPath (Join-Path $payload ($fileName -replace '\.gz$', '')) $Cancellation
        } else {
            Move-Item -LiteralPath $assetPath -Destination (Join-Path $payload $fileName) -ErrorAction Stop
        }
        Repair-BumPayloadScripts $payload $Queue $Cancellation
        Test-BumCancelled $Cancellation
        $versions = Join-Path $toolDir 'versions'
        $null = New-Item -ItemType Directory -Path $versions -Force
        $destination = Join-Path $versions $folder
        Move-Item -LiteralPath $staging -Destination $destination -ErrorAction Stop
        $record = [pscustomobject]@{
            ToolId = $Tool.Id; Name = $Tool.Name; Folder = $folder; Version = $resolved.Version
            Asset = $fileName; DownloadUrl = $resolved.Url; Sha256 = $hash
            PublisherHashVerified = [bool]($resolved.Sha256 -or $sha512)
            ScriptEncodingPreparation = 'UTF-8 BOM added to unsigned UTF-8 PowerShell files; hash records the original download'
            InstalledUtc = [DateTime]::UtcNow.ToString('o')
        }
        try { Write-BumJsonAtomic (Join-Path $toolDir 'installed.json') $record }
        catch {
            Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
            throw
        }
        Write-BumEvent $Queue 'Log' "Installed $($Tool.Name) $($resolved.Version). SHA-256: $hash"
        return [pscustomobject]@{ Browser = $false; Installed = $true }
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-BumLaunchables {
    param([string]$Directory, [string]$Name)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return @() }
    $normalized = ($Name -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    $items = @(Get-ChildItem -LiteralPath $Directory -Recurse -File -ErrorAction Stop | Where-Object {
        $_.Extension -in @('.exe', '.ps1', '.jar', '.cmd', '.bat', '.msi') -and
        $_.BaseName -notmatch '(?i)^(unins|uninstall|updat|crash|createdump|vshost|testhost|helper|reporter)' -and
        $_.FullName -notmatch '(?i)[\\/](runtimes|ref|obj|\.git)[\\/]'
    })
    return @($items | Sort-Object @{ Expression = {
        $base = ($_.BaseName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
        if ($base -eq $normalized) { 0 } elseif ($base.Contains($normalized)) { 1 } elseif ($_.Extension -eq '.exe') { 2 } else { 3 }
    } }, @{ Expression = { $_.FullName.Length } }, Name)
}

function Get-BumExecutableSubsystem {
    param([string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { return 0 }
        $stream.Position = 0x3C; $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset + 94 -gt $stream.Length) { return 0 }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { return 0 }
        $stream.Position = $offset + 24 + 68
        return $reader.ReadUInt16()
    } finally { $reader.Dispose() }
}

function ConvertTo-BumPsLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Start-BumExecutable {
    param([string]$Path, [string]$Arguments = '', [bool]$Admin = $false, [bool]$ForceConsole = $false, $Tool=$null, [string]$CacheRoot)
    $plan = New-BumLaunchPlan $Path $Arguments $Admin $ForceConsole $Tool $CacheRoot
    $planPath = [IO.Path]::ChangeExtension($plan.StatusPath,'.plan.json')
    Write-BumJsonAtomic $planPath $plan
    $info = New-BumSupervisorStartInfo $plan $planPath (Join-Path $PSScriptRoot 'Run-Tool.ps1')
    $process = [Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw 'Windows did not start the launch supervisor.' }
    $process | Add-Member -NotePropertyName LaunchStatusPath -NotePropertyValue $plan.StatusPath
    $process | Add-Member -NotePropertyName LaunchLogPath -NotePropertyValue $plan.LogPath
    return $process
}

function Start-BumWebsite {
    param([string]$Url)
    Assert-BumHttps $Url
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Url; $info.UseShellExecute = $true
    $null = [Diagnostics.Process]::Start($info)
}

function Get-BumFilteredTools {
    param($Tools, [string]$Category = 'All tools', [string]$Search = '', $Favorites = @(), [string]$CacheRoot)
    return @($Tools | Where-Object {
        $categoryMatch = $Category -eq 'All tools' -or $_.Category -eq $Category -or
            ($Category -eq 'Favorites' -and $_.Id -in $Favorites) -or
            ($Category -eq 'Downloaded' -and (Test-Path -LiteralPath (Join-Path (Get-BumToolDirectory $CacheRoot $_) 'installed.json')))
        $haystack = "$($_.Name) $($_.Description) $($_.Category)"
        $categoryMatch -and ([string]::IsNullOrWhiteSpace($Search) -or $haystack.IndexOf($Search.Trim(), [StringComparison]::OrdinalIgnoreCase) -ge 0)
    } | Sort-Object Category, Name)
}

. (Join-Path $PSScriptRoot 'Launch.ps1')
. (Join-Path $PSScriptRoot 'Prerequisites.ps1')
