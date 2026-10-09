# Launch metadata and command construction; no external process is started here.
function Get-BumPeInfo {
    param([string]$Path)
    $result = [pscustomobject]@{ Machine=0; Subsystem=0; Architecture='x64'; Imports=@(); RequiresAdmin=$false }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 96 -or [BitConverter]::ToUInt16($bytes,0) -ne 0x5A4D) { return $result }
    $pe = [BitConverter]::ToInt32($bytes,60)
    if ($pe -lt 64 -or $pe + 94 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550) { return $result }
    $result.Machine = [BitConverter]::ToUInt16($bytes,$pe+4)
    if ($result.Machine -eq 0x14c) { $result.Architecture = 'x86' }
    elseif ($result.Machine -ne 0x8664) { $result.Architecture = 'unsupported' }
    $result.Subsystem = [BitConverter]::ToUInt16($bytes,$pe+92)
    $optional = $pe+24
    $magic = [BitConverter]::ToUInt16($bytes,$optional)
    $directoryOffset = 96
    if ($magic -eq 0x20b) { $directoryOffset = 112 }
    $sectionOffset = $optional + [BitConverter]::ToUInt16($bytes,$pe+20)
    $sections = @()
    for ($i=0; $i -lt [BitConverter]::ToUInt16($bytes,$pe+6); $i++) {
        $offset = $sectionOffset+40*$i
        if ($offset+40 -gt $bytes.Length) { break }
        $sections += [pscustomobject]@{ Size=[Math]::Max([BitConverter]::ToUInt32($bytes,$offset+8),[BitConverter]::ToUInt32($bytes,$offset+16)); Rva=[BitConverter]::ToUInt32($bytes,$offset+12); Raw=[BitConverter]::ToUInt32($bytes,$offset+20) }
    }
    $toOffset = {
        param([uint32]$Rva)
        foreach ($section in $sections) {
            if ($Rva -ge $section.Rva -and $Rva -lt $section.Rva+$section.Size) { return [int]($section.Raw+$Rva-$section.Rva) }
        }
        return -1
    }
    if ($optional+$directoryOffset+16 -le $bytes.Length) {
        $importRva = [BitConverter]::ToUInt32($bytes,$optional+$directoryOffset+8)
        if ($importRva -gt 0) {
            $descriptor = & $toOffset $importRva
            $imports = @()
            for ($i=0; $i -lt 512 -and $descriptor -ge 0 -and $descriptor+20 -le $bytes.Length; $i++) {
                $nameRva = [BitConverter]::ToUInt32($bytes,$descriptor+12)
                if ($nameRva -eq 0) { break }
                $nameOffset = & $toOffset $nameRva
                if ($nameOffset -ge 0 -and $nameOffset -lt $bytes.Length) {
                    $end = $nameOffset
                    while ($end -lt $bytes.Length -and $bytes[$end] -ne 0 -and $end-$nameOffset -lt 260) { $end++ }
                    $imports += [Text.Encoding]::ASCII.GetString($bytes,$nameOffset,$end-$nameOffset)
                }
                $descriptor += 20
            }
            $result.Imports = $imports
        }
    }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $wide = [Text.Encoding]::Unicode.GetString($bytes)
    $result.RequiresAdmin = $text -match '(?i)requestedExecutionLevel\s+[^>]*level\s*=\s*["'']requireAdministrator' -or
        $wide -match '(?i)requestedExecutionLevel\s+[^>]*level\s*=\s*["'']requireAdministrator'
    return $result
}

function Get-BumPreferredLaunchFile {
    param([string]$Directory, $Tool)
    $files = @(Get-BumLaunchables $Directory $Tool.Name)
    $pattern = Get-BumValue $Tool 'LaunchPattern' ''
    if ($pattern) {
        $preferred = @($files | Where-Object { $_.Name -match $pattern })
        if ($preferred.Count -gt 0) { return $preferred[0] }
        if ([bool](Get-BumValue $Tool 'RequireLaunchPattern' $false)) { throw "$($Tool.Name) needs an updated download with its correct launch file." }
    }
    if ($files.Count -eq 0) { throw "$($Tool.Name) has no runnable file. It may have been removed or quarantined; use Re-download in the tool options." }
    return $files[0]
}

function Get-BumRuntimeConfig {
    param([string]$Path)
    $sidecar = [IO.Path]::ChangeExtension($Path,'.runtimeconfig.json')
    if (Test-Path -LiteralPath $sidecar) { return Get-Content -LiteralPath $sidecar -Raw -Encoding UTF8 | ConvertFrom-Json }
    if ([IO.Path]::GetExtension($Path) -ne '.exe') { return $null }
    # Single-file, framework-dependent apphosts embed the runtime configuration.
    $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path))
    $match = [regex]::Match($text,'\{\s*"runtimeOptions"\s*:')
    if (-not $match.Success) { return $null }
    $depth=0; $quoted=$false; $escaped=$false
    for ($i=$match.Index; $i -lt [Math]::Min($text.Length,$match.Index+65536); $i++) {
        $char = $text[$i]
        if ($quoted) {
            if ($escaped) { $escaped=$false }
            elseif ($char -eq '\') { $escaped=$true }
            elseif ($char -eq '"') { $quoted=$false }
        } elseif ($char -eq '"') { $quoted=$true }
        elseif ($char -eq '{') { $depth++ }
        elseif ($char -eq '}') {
            $depth--
            if ($depth -eq 0) {
                try { return $text.Substring($match.Index,$i-$match.Index+1) | ConvertFrom-Json }
                catch { return $null }
            }
        }
    }
    return $null
}

function Get-BumJavaPath {
    param([string]$CacheRoot)
    $private = Join-Path $CacheRoot 'runtimes\java'
    if (Test-Path -LiteralPath $private) {
        $java = Get-ChildItem -LiteralPath $private -Filter java.exe -Recurse -File | Where-Object { $_.Directory.Name -eq 'bin' } | Select-Object -First 1
        if ($java) { return $java.FullName }
    }
    if ($env:JAVA_HOME) {
        $java = Join-Path $env:JAVA_HOME 'bin\java.exe'
        if (Test-Path -LiteralPath $java) { return $java }
    }
    $command = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Repair-BumPowerShellEncoding {
    param([string]$Path, $Queue=$null)
    if ([IO.Path]::GetExtension($Path) -notin @('.ps1','.psm1','.psd1')) { return $false }
    $bytes=[IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return $false }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) { return $false }
    # Keep UTF-16/UTF-32 and signed scripts byte-for-byte unchanged.
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xff -and $bytes[1] -eq 0xfe) -or ($bytes[0] -eq 0xfe -and $bytes[1] -eq 0xff))) { return $false }
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xfe -and $bytes[3] -eq 0xff) { return $false }
    $utf8=New-Object Text.UTF8Encoding($false,$true)
    try { $text=$utf8.GetString($bytes) } catch [Text.DecoderFallbackException] { return $false }
    if ($text -match '(?m)^\s*# SIG # Begin signature block') { return $false }
    $temporary=$Path+'.encoding-'+[guid]::NewGuid().ToString('N')+'.tmp'
    $backup=$temporary+'.bak'
    try {
        # Add only the encoding marker; preserve every publisher byte after it.
        $marked=New-Object byte[] ($bytes.Length+3)
        $marked[0]=0xef; $marked[1]=0xbb; $marked[2]=0xbf
        [Array]::Copy($bytes,0,$marked,3,$bytes.Length)
        [IO.File]::WriteAllBytes($temporary,$marked)
        [IO.File]::Replace($temporary,$Path,$backup)
        Write-BumEvent $Queue 'Log' ('Prepared UTF-8 script encoding: '+[IO.Path]::GetFileName($Path))
        return $true
    } finally {
        foreach($leftover in @($temporary,$backup)) {
            if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Repair-BumPayloadScripts {
    param([string]$Directory, $Queue=$null, $Cancellation=$null)
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1','.psd1') }) {
        Test-BumCancelled $Cancellation
        $null=Repair-BumPowerShellEncoding $file.FullName $Queue
    }
}

function Test-BumPowerShellLaunchFile {
    param([string]$Path)
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) {
        $first=$errors[0]
        throw ('PowerShell script preflight failed in '+[IO.Path]::GetFileName($Path)+' at line '+$first.Extent.StartLineNumber+': '+$first.Message+' Re-download the tool or check its Source page for the required PowerShell version.')
    }
}

function New-BumLaunchPlan {
    param([string]$Path, [string]$Arguments='', [bool]$Admin=$false, [bool]$ForceConsole=$false, $Tool=$null, [string]$CacheRoot)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Launch file not found: $Path. Use Re-download in the tool options." }
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -notin @('.exe','.ps1','.cmd','.bat','.jar','.msi')) { throw 'Unsupported launch-file type.' }
    if ([string]::IsNullOrWhiteSpace($CacheRoot)) { $CacheRoot = Join-Path $env:LOCALAPPDATA 'bumsstool' }
    if ([string]::IsNullOrWhiteSpace($Arguments)) { $Arguments = [string](Get-BumValue $Tool 'DefaultArguments' '') }
    $console = $ForceConsole -or $extension -in @('.ps1','.cmd','.bat') -or [bool](Get-BumValue $Tool 'KeepConsole' $false)
    $Admin = $Admin -or [bool](Get-BumValue $Tool 'RequiresAdmin' $false)
    $executable = $Path; $nativeArguments = $Arguments
    switch ($extension) {
        '.exe' {
            $pe = Get-BumPeInfo $Path
            if ($pe.Machine -eq 0) { throw 'The downloaded EXE is not a valid Windows executable. Re-download it from the Source page.' }
            if ($pe.Architecture -eq 'unsupported') { throw 'This download has an unsupported CPU architecture. Use the Windows x64 or x86 release.' }
            if ($pe.Subsystem -eq 3) { $console=$true }
            $Admin = $Admin -or $pe.RequiresAdmin
        }
        '.jar' {
            $executable = Get-BumJavaPath $CacheRoot
            if (-not $executable) { throw 'Java setup has not completed. Click the tool card to prepare Java, then retry.' }
            $nativeArguments = '-jar "' + $Path + '" ' + $Arguments
        }
        '.ps1' {
            $null=Repair-BumPowerShellEncoding $Path
            Test-BumPowerShellLaunchFile $Path
            $executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $nativeArguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "' + $Path + '" ' + $Arguments
        }
        { $_ -in @('.cmd','.bat') } {
            $executable = Join-Path $env:SystemRoot 'System32\cmd.exe'
            $nativeArguments = '/d /s /c ""' + $Path + '" ' + $Arguments + '"'
        }
        '.msi' {
            $executable = Join-Path $env:SystemRoot 'System32\msiexec.exe'
            $nativeArguments = '/i "' + $Path + '" ' + $Arguments
        }
    }
    $logs = Join-Path $CacheRoot 'launch-logs'
    $null = New-Item -ItemType Directory -Path $logs -Force
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    return [pscustomobject]@{
        SchemaVersion=1; Name=[string](Get-BumValue $Tool 'Name' ([IO.Path]::GetFileName($Path)))
        Executable=$executable; Arguments=$nativeArguments; WorkingDirectory=(Split-Path -Parent $Path)
        Console=[bool]$console; Admin=[bool]$Admin; Target=$Path
        StatusPath=(Join-Path $logs ($id+'.json')); LogPath=(Join-Path $logs ($id+'.txt'))
    }
}

function New-BumSupervisorStartInfo {
    param($Plan, [string]$PlanPath, [string]$SupervisorPath)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $hold = ''; $style = 'Hidden'
    if ($Plan.Console) { $hold='-NoExit '; $style='Normal' }
    $info.Arguments = '-NoLogo -NoProfile -STA '+$hold+'-ExecutionPolicy Bypass -WindowStyle '+$style+' -File "'+$SupervisorPath+'" -PlanPath "'+$PlanPath+'"'
    $info.WorkingDirectory = $Plan.WorkingDirectory
    $info.UseShellExecute = $true
    $info.WindowStyle = $style
    if ($Plan.Admin) { $info.Verb='runas' }
    return $info
}
