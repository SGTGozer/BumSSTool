# Prepare publisher-provided prerequisites before starting a downloaded tool.
function Get-BumDotNetRequirements {
    param([string]$Path)
    $config = Get-BumRuntimeConfig $Path
    $options = Get-BumValue $config 'runtimeOptions'
    $requirements = @()
    $framework = Get-BumValue $options 'framework'
    if ($framework) { $requirements += $framework }
    $requirements += @(Get-BumValue $options 'frameworks' @())
    # includedFrameworks describes a self-contained app; it needs no shared runtime.
    return @($requirements | Where-Object { $null -ne $_ })
}

function Test-BumDotNetFramework {
    param($Requirement, [string]$Architecture='x64')
    $roots = @()
    $programFiles = $env:ProgramFiles
    if ($Architecture -eq 'x86') { $programFiles=[Environment]::GetEnvironmentVariable('ProgramFiles(x86)') }
    if ($programFiles) { $roots += Join-Path $programFiles 'dotnet' }
    if ($env:OS -eq 'Windows_NT') {
        try {
            $key = Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\'+$Architecture) -ErrorAction Stop
            if ($key.InstallLocation) { $roots += $key.InstallLocation }
        } catch {}
    }
    $needed = [version]$Requirement.version
    foreach ($root in @($roots | Select-Object -Unique)) {
        $shared = Join-Path (Join-Path $root 'shared') $Requirement.name
        if (-not (Test-Path -LiteralPath $shared)) { continue }
        foreach ($dir in Get-ChildItem -LiteralPath $shared -Directory) {
            $version = $null
            if ([version]::TryParse($dir.Name,[ref]$version) -and $version.Major -eq $needed.Major -and $version.Minor -eq $needed.Minor -and $version -ge $needed) { return $true }
        }
    }
    return $false
}

function Resolve-BumDotNetPrerequisite {
    param($Requirement, [string]$Architecture)
    if ($Requirement.name -notin @('Microsoft.NETCore.App','Microsoft.WindowsDesktop.App')) { throw ('Automatic setup is not available for '+$Requirement.name+'. See the tool publisher prerequisites.') }
    $needed = [version]$Requirement.version
    $channel = [string]$needed.Major+'.'+$needed.Minor
    $metadata = Invoke-BumJson ('https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/'+$channel+'/releases.json')
    foreach ($release in $metadata.releases) {
        $desktop = Get-BumValue $release 'windowsdesktop'
        if (-not $desktop -or [version]$desktop.version -lt $needed) { continue }
        $asset = $desktop.files | Where-Object { $_.rid -eq ('win-'+$Architecture) -and $_.name.EndsWith('.exe') } | Select-Object -First 1
        if ($asset) {
            return [pscustomobject]@{ Url=$asset.url;FileName=('windowsdesktop-'+$desktop.version+'-'+$Architecture+'.exe');Sha512=$asset.hash;Version=$desktop.version }
        }
    }
    throw ('No compatible Microsoft Desktop Runtime installer was found for '+$channel+' '+$Architecture+'.')
}

function Install-BumMicrosoftPrerequisite {
    param($Asset, [string]$CacheRoot, $Queue, $Cancellation, [string]$Name)
    if ($env:OS -ne 'Windows_NT') { throw 'Microsoft runtime installation requires Windows.' }
    $folder = Join-Path $CacheRoot 'runtimes\installers'
    $null = New-Item -ItemType Directory -Path $folder -Force
    $path = Join-Path $folder $Asset.FileName
    if (-not (Test-Path -LiteralPath $path)) {
        Write-BumEvent $Queue 'Status' ('Downloading '+$Name+'...')
        Save-BumDownload $Asset.Url $path $Queue $Cancellation
    }
    $sha512 = Get-BumValue $Asset 'Sha512' ''
    if ($sha512 -and (Get-FileHash -LiteralPath $path -Algorithm SHA512).Hash -ne $sha512) {
        Remove-Item -LiteralPath $path -Force
        throw ($Name+' publisher hash verification failed; click again to retry the download.')
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
        Remove-Item -LiteralPath $path -Force
        throw ($Name+' did not pass Microsoft signature verification. Click again to retry the publisher download.')
    }
    Test-BumCancelled $Cancellation
    Write-BumEvent $Queue 'Status' ('Installing '+$Name+'; approve the Windows UAC prompt if shown...')
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$path; $info.Arguments='/install /quiet /norestart'; $info.UseShellExecute=$true; $info.Verb='runas'
    $process=[Diagnostics.Process]::Start($info)
    if ($null -eq $process) { throw ('Windows did not start '+$Name+' setup.') }
    try {
        # Do not interrupt an in-progress system installer. Cancellation prevents
        # the tool launch as soon as the installer has finished.
        while (-not $process.WaitForExit(250)) {}
        if ($process.ExitCode -notin @(0,3010,1641)) { throw ($Name+' setup exited with code '+$process.ExitCode+'.') }
    } finally { $process.Dispose() }
    Test-BumCancelled $Cancellation
    Write-BumEvent $Queue 'Log' ($Name+' installed.')
}

function Install-BumJavaPrerequisite {
    param([string]$CacheRoot, $Queue, $Cancellation)
    if (Get-BumJavaPath $CacheRoot) { return }
    Write-BumEvent $Queue 'Status' 'Preparing Java for this tool...'
    $assets = @(Invoke-BumJson 'https://api.adoptium.net/v3/assets/latest/17/hotspot?architecture=x64&image_type=jre&jvm_impl=hotspot&os=windows&vendor=eclipse')
    if ($assets.Count -eq 0) { throw 'The official Java provider returned no Windows x64 runtime.' }
    $package = $assets[0].binary.package
    Assert-BumHttps $package.link
    if ($package.checksum -notmatch '^[a-fA-F0-9]{64}$') { throw 'The Java provider did not supply a valid SHA-256 hash.' }
    $stage = Join-Path (Join-Path $CacheRoot 'staging') ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $stage -Force
    try {
        $zip = Join-Path $stage 'java.zip'
        Save-BumDownload $package.link $zip $Queue $Cancellation
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $package.checksum) { throw 'Java publisher hash verification failed.' }
        $payload = Join-Path $stage 'payload'
        Expand-BumArchive $zip $payload $Cancellation
        $java = Get-ChildItem -LiteralPath $payload -Filter java.exe -Recurse -File | Where-Object { $_.Directory.Name -eq 'bin' } | Select-Object -First 1
        if (-not $java) { throw 'The Java archive contains no Windows launcher.' }
        Test-BumCancelled $Cancellation
        $root = Join-Path $CacheRoot 'runtimes\java'
        $null = New-Item -ItemType Directory -Path $root -Force
        $destination = Join-Path $root ([guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $payload -Destination $destination
        Write-BumEvent $Queue 'Log' 'Java prepared for bumsstool; the system Java installation was unchanged.'
    } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
}

function Get-BumMissingVcLibraries {
    param([string]$Path, $Pe)
    $missing = @()
    foreach ($name in $Pe.Imports) {
        if ($name -notmatch '(?i)^(vcruntime|msvcp|concrt|mfc)140(?:_\d+)?\.dll$') { continue }
        $local = Join-Path (Split-Path -Parent $Path) $name
        $system = 'System32'
        if ($Pe.Architecture -eq 'x86') { $system='SysWOW64' }
        $global = Join-Path (Join-Path $env:SystemRoot $system) $name
        if (-not (Test-Path -LiteralPath $local) -and -not (Test-Path -LiteralPath $global)) { $missing += $name }
    }
    return $missing
}

function Ensure-BumLaunchPrerequisites {
    param([string]$Path, $Tool, [string]$CacheRoot, $Queue, $Cancellation)
    Test-BumCancelled $Cancellation
    $architecture='x64'
    $pe=$null
    if ([IO.Path]::GetExtension($Path) -eq '.exe') {
        $pe=Get-BumPeInfo $Path
        if ($pe.Machine -eq 0) { throw 'The downloaded file is not a Windows EXE. Re-download the tool.' }
        if ($pe.Architecture -eq 'unsupported') { throw 'This download is not compatible with Windows x64. Use the x64 or x86 release.' }
        $architecture=$pe.Architecture
    }
    foreach ($requirement in @(Get-BumDotNetRequirements $Path)) {
        if (-not (Test-BumDotNetFramework $requirement $architecture)) {
            $asset = Resolve-BumDotNetPrerequisite $requirement $architecture
            Install-BumMicrosoftPrerequisite $asset $CacheRoot $Queue $Cancellation ('.NET '+$asset.Version+' Desktop Runtime ('+$architecture+')')
            if (-not (Test-BumDotNetFramework $requirement $architecture)) { throw 'Runtime setup finished, but the required framework is unavailable. A Windows restart may be required.' }
        }
    }
    if ([IO.Path]::GetExtension($Path) -eq '.jar' -or [bool](Get-BumValue $Tool 'RequiresJava' $false)) { Install-BumJavaPrerequisite $CacheRoot $Queue $Cancellation }
    if ($null -ne $pe -and @(Get-BumMissingVcLibraries $Path $pe).Count -gt 0) {
        $asset = [pscustomobject]@{ Url=('https://aka.ms/vs/17/release/vc_redist.'+$architecture+'.exe');FileName=('vc_redist.'+$architecture+'.exe');Sha512='' }
        Install-BumMicrosoftPrerequisite $asset $CacheRoot $Queue $Cancellation ('Visual C++ Runtime ('+$architecture+')')
        if (@(Get-BumMissingVcLibraries $Path $pe).Count -gt 0) { throw 'Visual C++ setup finished, but required libraries remain missing. Restart Windows and retry.' }
    }
    Test-BumCancelled $Cancellation
}

function Prepare-BumToolAction {
    param($Action, [string]$CacheRoot, $Queue, $Cancellation)
    $tool = $Action.Tool
    $download = [bool](Get-BumValue $Action 'DownloadRequired' $true)
    $autoRun = [bool](Get-BumValue $Action 'AutoRun' $false)
    $path = [string](Get-BumValue $Action 'LaunchPath' '')
    $state = $null
    if (-not $download) { $state = Get-BumInstalled $CacheRoot $tool }
    if ($null -eq $state) { $download = $true }
    if (-not $download -and $autoRun -and -not $path) {
        try { $path = (Get-BumPreferredLaunchFile $state.Payload $tool).FullName }
        catch { $download = $true; Write-BumEvent $Queue 'Log' ('Refreshing the launch files for '+$tool.Name+'.') }
    }
    if ($download) {
        $result = Install-BumTool $tool $CacheRoot $Queue $Cancellation
        if (-not [bool](Get-BumValue $result 'Installed' $false)) { throw 'This entry has no automatic download. Open its Source page.' }
        $state = Get-BumInstalled $CacheRoot $tool
        if ($null -eq $state) { throw 'The download finished without a usable install record.' }
        $path = ''
    }
    if ($autoRun) {
        if (-not $path) { $path = (Get-BumPreferredLaunchFile $state.Payload $tool).FullName }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'The selected launch file is missing. Re-download the tool.' }
        Repair-BumPayloadScripts $state.Payload $Queue $Cancellation
        if ([IO.Path]::GetExtension($path) -eq '.ps1') { Test-BumPowerShellLaunchFile $path }
        Write-BumEvent $Queue 'Status' ('Checking prerequisites for '+$tool.Name+'...')
        Ensure-BumLaunchPrerequisites $path $tool $CacheRoot $Queue $Cancellation
    }
    Test-BumCancelled $Cancellation
    return [pscustomobject]@{ Installed=$true; LaunchPath=$path }
}
