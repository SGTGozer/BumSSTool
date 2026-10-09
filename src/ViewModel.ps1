# Cached card data. Filtering never reads tool records or scans payload folders.
if (-not ('BumToolRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
public sealed class BumToolRow : INotifyPropertyChanged
{
    public object Tool { get; set; }
    public string Id { get; set; }
    public string Name { get; set; }
    public string Category { get; set; }
    public string Description { get; set; }
    public string SearchText { get; set; }
    public bool IsInstalled { get; set; }
    private string state;
    private bool favorite;
    public string State {
        get { return state; }
        set { if (state != value) { state = value; Changed("State"); } }
    }
    public bool IsFavorite {
        get { return favorite; }
        set { if (favorite != value) { favorite = value; Changed("IsFavorite"); Changed("Star"); } }
    }
    public string Star { get { return favorite ? "\u2605" : ""; } }
    public event PropertyChangedEventHandler PropertyChanged;
    private void Changed(string name) {
        PropertyChangedEventHandler handler = PropertyChanged;
        if (handler != null) handler(this, new PropertyChangedEventArgs(name));
    }
}
'@
}

function Get-BumCarLightMask {
    param([string]$Symbols)
    # Build the text overlay once; the WPF storyboard only animates opacity.
    $lines = foreach ($line in [regex]::Split($Symbols, '\r\n|\n|\r')) {
        $mask = (' ' * $line.Length).ToCharArray()
        foreach ($light in [regex]::Matches($line, '\[=+\]')) {
            $light.Value.CopyTo(0, $mask, $light.Index, $light.Length)
        }
        -join $mask
    }
    return $lines -join [Environment]::NewLine
}

function Update-BumRowInstallState {
    param($Row, [string]$CacheRoot)
    $Row.IsInstalled = $false
    $Row.State = 'Install and open'
    if ($Row.Tool.Kind -eq 'Website') { $Row.State = 'Open website' }
    if (Get-BumValue $Row.Tool 'UnavailableAtBuild' $false) { $Row.State = 'Check source' }
    try {
        if ($null -ne (Get-BumInstalled $CacheRoot $Row.Tool)) {
            $Row.IsInstalled = $true
            $Row.State = 'Downloaded'
        }
    } catch { $Row.State = 'Repair' }
}

function New-BumToolRows {
    param($Tools, [string]$CacheRoot, $Favorites = @())
    $rows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    foreach ($tool in $Tools) {
        $row = New-Object BumToolRow
        $row.Tool = $tool
        $row.Id = $tool.Id
        $row.Name = $tool.Name
        $row.Category = $tool.Category
        $row.Description = $tool.Description
        $row.SearchText = "$($tool.Name) $($tool.Description) $($tool.Category)"
        $row.IsFavorite = $tool.Id -in $Favorites
        Update-BumRowInstallState $row $CacheRoot
        $rows.Add($row)
    }
    return ,$rows
}

function Test-BumRowVisible {
    param($Row, [string]$Category, [string]$Search)
    $categoryMatch = $Category -eq 'All tools' -or $Row.Category -eq $Category -or
        ($Category -eq 'Favorites' -and $Row.IsFavorite) -or
        ($Category -eq 'Downloaded' -and $Row.IsInstalled)
    return $categoryMatch -and ([string]::IsNullOrWhiteSpace($Search) -or
        $Row.SearchText.IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function New-BumActionQueue {
    return [pscustomobject]@{ Items = (New-Object 'System.Collections.Generic.Queue[object]'); Ids = @{} }
}

function Add-BumQueuedAction {
    param($Queue, $Action)
    if ($Queue.Ids.ContainsKey($Action.Tool.Id)) { return $false }
    $Queue.Items.Enqueue($Action)
    $Queue.Ids[$Action.Tool.Id] = $true
    return $true
}

function Get-BumQueuedAction {
    param($Queue)
    if ($Queue.Items.Count -eq 0) { return $null }
    $action = $Queue.Items.Dequeue()
    $Queue.Ids.Remove($action.Tool.Id)
    return $action
}

function Clear-BumActionQueue {
    param($Queue)
    $Queue.Items.Clear()
    $Queue.Ids.Clear()
}
