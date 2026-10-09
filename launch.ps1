# bumsstool - by SGTGozer
# Save this file as launch.ps1 in the root of SGTGozer/BumSSTool on GitHub.
# Works as a local script or through Invoke-RestMethod / Invoke-Expression.
& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) {
        throw 'bumsstool requires Windows 10 or Windows 11 (x64).'
    }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'The Windows LOCALAPPDATA folder could not be found.'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $archiveUri = 'https://github.com/SGTGozer/BumSSTool/archive/refs/heads/main.zip'
    $installRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'bumsstool/launcher') ([guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $installRoot 'package.zip'
    $payloadRoot = Join-Path $installRoot 'app'
    $created = $false
    $started = $false

    try {
        $null = New-Item -ItemType Directory -Path $installRoot -Force
        $created = $true
        Write-Host 'Downloading bumsstool...' -ForegroundColor Magenta
        Invoke-WebRequest -UseBasicParsing -UserAgent 'BumSSTool' -Uri $archiveUri -OutFile $archivePath
        Expand-Archive -LiteralPath $archivePath -DestinationPath $payloadRoot

        $application = Get-ChildItem -LiteralPath $payloadRoot -Filter 'bumsstool.exe' -File -Recurse |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.DirectoryName 'bumsstool.ps1') -PathType Leaf } |
            Select-Object -First 1
        if ($null -eq $application) {
            throw 'The GitHub download does not contain bumsstool.exe and bumsstool.ps1 together. Upload the complete app folder to the repository.'
        }
        $required = @(
            'bumsstool.ps1', 'tools.json', 'src/Core.ps1', 'src/Launch.ps1',
            'src/Prerequisites.ps1', 'src/Run-Tool.ps1', 'src/ViewModel.ps1',
            'src/Main.xaml', 'assets/car.png', 'assets/car.txt'
        )
        $missing = @(foreach ($relative in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $application.DirectoryName $relative) -PathType Leaf)) {
                $relative
            }
        })
        if ($missing.Count -gt 0) {
            throw ('The GitHub upload is missing required app files: ' + ($missing -join ', ') + '. Upload the complete app folder, including src and assets.')
        }

        Remove-Item -LiteralPath $archivePath -Force
        Write-Host 'Starting bumsstool...' -ForegroundColor Magenta
        Start-Process -FilePath $application.FullName -WorkingDirectory $application.DirectoryName -PassThru | Out-Null
        $started = $true
    } catch {
        # Delete only this attempt's unique folder when preparation/start fails.
        if ($created -and -not $started -and (Test-Path -LiteralPath $installRoot)) {
            Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}
