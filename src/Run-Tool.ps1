[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PlanPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Core.ps1')
$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($plan.SchemaVersion -ne 1) { throw 'Unsupported tool-launch plan.' }
function Save-LaunchStatus {
    param([string]$State, [int]$ExitCode=0, [string]$Message='')
    Write-BumJsonAtomic $plan.StatusPath ([pscustomobject]@{ Name=$plan.Name;State=$State;ExitCode=$ExitCode;Message=$Message;LogPath=$plan.LogPath;UpdatedUtc=[DateTime]::UtcNow.ToString('o') })
}
$lines = @('bumsstool launch log', 'Tool: '+$plan.Name, 'Executable: '+$plan.Executable, 'Working directory: '+$plan.WorkingDirectory, 'Started: '+[DateTime]::Now.ToString('o'), '')
$lines | Set-Content -LiteralPath $plan.LogPath -Encoding UTF8
$process = $null
try {
    if ($plan.Console) {
        # Windows native utilities inherit these console code pages. Setting
        # them before process start prevents UTF-8 banners becoming mojibake.
        try {
            [Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
            [Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
            $OutputEncoding=[Console]::OutputEncoding
        } catch { ('Console encoding setup: '+$_.Exception.Message) | Add-Content -LiteralPath $plan.LogPath -Encoding UTF8 }
        try { $Host.UI.RawUI.WindowTitle='bumsstool - '+$plan.Name } catch {}
        Write-Host ('Starting '+$plan.Name+'...') -ForegroundColor Magenta
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$plan.Executable
    $info.Arguments=$plan.Arguments
    $info.WorkingDirectory=$plan.WorkingDirectory
    $info.UseShellExecute=$false
    $info.WindowStyle='Normal'
    $info.CreateNoWindow=-not $plan.Console
    # Drain both redirected streams concurrently without PowerShell event handlers.
    # Console utilities inherit the visible console so prompts remain interactive.
    if (-not $plan.Console) { $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true }
    $process=[Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw 'The operating system did not start the tool.' }
    if (-not $plan.Console) {
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
    }
    Save-LaunchStatus 'Running'
    $process.WaitForExit()
    if (-not $plan.Console) {
        $stdout.GetAwaiter().GetResult() | Add-Content -LiteralPath $plan.LogPath -Encoding UTF8
        $stderr.GetAwaiter().GetResult() | Add-Content -LiteralPath $plan.LogPath -Encoding UTF8
    }
    $code=$process.ExitCode
    ('Exit code: '+$code) | Add-Content -LiteralPath $plan.LogPath -Encoding UTF8
    if ($code -ne 0) {
        $message=$plan.Name+' exited with code '+$code+'. Details: '+$plan.LogPath
        Save-LaunchStatus 'Failed' $code $message
        if ($plan.Console) { Write-Host $message -ForegroundColor Red }
    } else { Save-LaunchStatus 'Exited' }
    if ($plan.Console) {
        Write-Host ('Exit code: '+$code)
        Write-Host 'This console stays open. For tools that need input files or flags, right-click the card and add arguments.' -ForegroundColor DarkGray
    }
} catch {
    $message=$_.Exception.Message
    ($_ | Out-String) | Add-Content -LiteralPath $plan.LogPath -Encoding UTF8
    Save-LaunchStatus 'Failed' -1 $message
    if ($plan.Console) { Write-Host $message -ForegroundColor Red }
} finally { if ($null -ne $process) { $process.Dispose() } }
