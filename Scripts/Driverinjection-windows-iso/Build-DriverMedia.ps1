#Requires -Version 7.2
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Injects harvested RAID and Wi-Fi drivers into a Windows 11 ISO and repackages it as a bootable ISO.

.DESCRIPTION
    Runs on the technician workstation. Driver scope is decided by folder:

        <DriverRoot>\RAID\**  -> boot.wim (all indexes), winre.wim (inside each install index), install.wim
        <DriverRoot>\WiFi\**  -> install.wim only

    Stages: Preflight -> Expand -> Stage drivers -> Normalize (select editions, ESD->WIM)
            -> WinPE (boot.wim) -> OS + WinRE (install.wim) -> Optimize (re-export) -> Repack (oscdimg)

    Every injected image is verified with /Get-Drivers; a missing driver fails the build.
    winre.wim is serviced once per unique source hash and reused across editions.
    On failure the work folder is kept for inspection and any mount is discarded.

    Requires: elevated PowerShell 7, dism.exe (host should be same or newer build than the image),
    Windows ADK Deployment Tools (oscdimg.exe).

.PARAMETER IsoPath
    Source Windows 11 ISO (e.g. downloaded with Fido or the Microsoft site).

.PARAMETER DriverRoot
    Folder produced by Export-DeviceDrivers.ps1. Must contain RAID\; WiFi\ is optional.

.PARAMETER WorkDir
    Scratch folder (needs ~30 GB). Must not contain spaces.

.PARAMETER Editions
    Image names to keep in install.wim. Matched exactly against the ISO's image names.

.PARAMETER NoPrompt
    Use efisys_noprompt.bin so UEFI boot doesn't wait for "Press any key".

.PARAMETER Force
    Wipe an existing WorkDir and overwrite an existing output ISO.

.EXAMPLE
    .\Build-DriverMedia.ps1 -IsoPath D:\ISO\Win11_25H2_Norwegian_x64.iso -DriverRoot D:\Drivers -NoPrompt -Verbose
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $IsoPath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string] $DriverRoot,

    [ValidatePattern('^[^ ]+$', ErrorMessage = 'WorkDir must not contain spaces (oscdimg boot-file arguments break on them).')]
    [string] $WorkDir = 'C:\DriverMediaWork',

    [string] $OutputDirectory,

    [string[]] $Editions = @('Windows 11 Pro'),

    [switch] $NoPrompt,
    [switch] $Force,
    [switch] $KeepWorkDir,

    [string] $OscdimgPath = (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'),

    [int] $MinFreeSpaceGB = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

#region Helpers

$script:DismCallCount = 0
$script:Report = [System.Collections.Generic.List[object]]::new()

function Write-Stage {
    param([string] $Text)
    Write-Progress -Activity 'Build-DriverMedia' -Status $Text
    Write-Verbose $Text
}

function Add-Report {
    param(
        [string] $Stage,
        [string] $Image,
        [object] $Index,
        [string] $Name,
        [object] $Drivers,
        [string] $Status = 'OK',
        [string] $Detail,
        [Diagnostics.Stopwatch] $Timer
    )
    $script:Report.Add([pscustomobject]@{
        Stage    = $Stage
        Image    = $Image
        Index    = $Index
        Name     = $Name
        Drivers  = $Drivers
        Status   = $Status
        Detail   = $Detail
        Duration = if ($Timer) { $Timer.Elapsed.ToString('hh\:mm\:ss') } else { $null }
    })
}

function Invoke-Dism {
    param(
        [Parameter(Mandatory)] [string] $Stage,
        [Parameter(Mandatory)] [string[]] $Arguments
    )
    $script:DismCallCount++
    $log = Join-Path $script:LogDir ('{0:d3}_{1}.log' -f $script:DismCallCount, ($Stage -replace '[^\w-]', '_'))
    $output = & dism.exe @Arguments /English "/LogPath:$log" 2>&1
    $code = $LASTEXITCODE
    if ($code -notin 0, 3010) {
        $tail = ($output | Select-Object -Last 15) -join [Environment]::NewLine
        throw "DISM failed at stage '$Stage' (exit $code). Log: $log$([Environment]::NewLine)$tail"
    }
    $output | ForEach-Object { "$_" }
}

function Get-MountedImageDir {
    & dism.exe /Get-MountedImageInfo /English 2>&1 |
        Select-String '^\s*Mount Dir\s*:\s*(.+?)\s*$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value }
}

function Get-WimIndex {
    param([string] $ImageFile)
    $current = $null
    foreach ($line in Invoke-Dism -Stage 'GetImageInfo' -Arguments '/Get-ImageInfo', "/ImageFile:$ImageFile") {
        if ($line -match '^\s*Index\s*:\s*(\d+)') {
            if ($current) { [pscustomobject]$current }
            $current = [ordered]@{ Index = [int]$Matches[1]; Name = $null }
        }
        elseif ($current -and $line -match '^\s*Name\s*:\s*(.+?)\s*$') {
            $current.Name = $Matches[1]
        }
    }
    if ($current) { [pscustomobject]$current }
}

function Get-WimBuild {
    param([string] $ImageFile, [int] $Index)
    $match = Invoke-Dism -Stage 'GetImageInfo' -Arguments '/Get-ImageInfo', "/ImageFile:$ImageFile", "/Index:$Index" |
        Select-String '^\s*Version\s*:\s*\d+\.\d+\.(\d+)' |
        Select-Object -First 1
    if ($match) { [int]$match.Matches[0].Groups[1].Value }
}

function Mount-Wim {
    param([string] $ImageFile, [int] $Index, [string] $MountDir, [string] $Label)
    New-Item -ItemType Directory -Path $MountDir -Force | Out-Null
    $null = Invoke-Dism -Stage "$Label-Mount" -Arguments '/Mount-Image', "/ImageFile:$ImageFile", "/Index:$Index", "/MountDir:$MountDir"
}

function Dismount-Wim {
    param([string] $MountDir, [string] $Label, [switch] $Commit)
    if ($Commit) {
        try {
            $null = Invoke-Dism -Stage "$Label-Commit" -Arguments '/Unmount-Image', "/MountDir:$MountDir", '/Commit'
        }
        catch {
            Dismount-Wim -MountDir $MountDir -Label $Label
            throw
        }
    }
    else {
        try {
            $null = Invoke-Dism -Stage "$Label-Discard" -Arguments '/Unmount-Image', "/MountDir:$MountDir", '/Discard'
        }
        catch {
            # Don't throw from here: we're usually inside a finally and must not mask the original error.
            Write-Warning "Could not discard mount at '$MountDir'. Check 'dism /Get-MountedImageInfo', then 'dism /Cleanup-Mountpoints' before re-running. $_"
            return
        }
    }
    # Only remove the mount dir once DISM confirms it's unmounted, and only if it's empty.
    if (-not (Get-ChildItem -LiteralPath $MountDir -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $MountDir -Force
    }
}

function Export-WimIndex {
    param([string] $Source, [int] $Index, [string] $Destination, [string] $Label)
    $null = Invoke-Dism -Stage "$Label-Export" -Arguments '/Export-Image', "/SourceImageFile:$Source", "/SourceIndex:$Index",
        "/DestinationImageFile:$Destination", '/Compress:max'
}

function Copy-UniqueDriverPackage {
    # Copies each driver package (folder containing .inf files) once, deduplicated by INF content,
    # so the same driver harvested from ten models is injected once. Returns expected INF names.
    param([string] $SourceRoot, [string] $Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $seen = @{}
    $expected = [System.Collections.Generic.List[string]]::new()
    $packages = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Filter *.inf -File | Group-Object DirectoryName
    foreach ($package in $packages) {
        $key = ($package.Group | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ''
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $target = Join-Path $Destination ('{0}_{1}' -f (Split-Path $package.Name -Leaf), $seen.Count)
        Copy-Item -LiteralPath $package.Name -Destination $target -Recurse
        $package.Group | ForEach-Object { $expected.Add($_.Name.ToLowerInvariant()) }
    }
    @($expected | Sort-Object -Unique)
}

function Add-ImageDriver {
    param([string] $MountDir, [string[]] $DriverPaths, [string[]] $ExpectedInfs, [string] $Label)
    foreach ($path in $DriverPaths) {
        $null = Invoke-Dism -Stage "$Label-AddDriver" -Arguments "/Image:$MountDir", '/Add-Driver', "/Driver:$path", '/Recurse'
    }
    $found = @(Invoke-Dism -Stage "$Label-GetDrivers" -Arguments "/Image:$MountDir", '/Get-Drivers' |
        Select-String '^\s*Original File Name\s*:\s*(.+?)\s*$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value.ToLowerInvariant() } |
        Sort-Object -Unique)
    $missing = @($ExpectedInfs | Where-Object { $_ -notin $found })
    if ($missing) { throw "${Label}: drivers missing after injection: $($missing -join ', ')" }
    $ExpectedInfs.Count
}

function Update-WinRE {
    # Services the winre.wim nested inside a mounted OS image. Identical winre.wim files (the norm
    # across editions on Microsoft media) are serviced once and reused via $Cache.
    param([string] $OsMountDir, [hashtable] $Cache, [string] $Label)
    $winre = Join-Path $OsMountDir 'Windows\System32\Recovery\winre.wim'
    if (-not (Test-Path -LiteralPath $winre)) {
        Write-Warning "${Label}: no winre.wim in image; skipping WinRE."
        return 'NotPresent'
    }

    $hash = (Get-FileHash -LiteralPath $winre).Hash
    $status = 'Reused'
    if (-not $Cache.ContainsKey($hash)) {
        $status = 'Serviced'
        $source = Join-Path $imagesDir "winre-$hash-src.wim"
        $final = Join-Path $imagesDir "winre-$hash.wim"
        Copy-Item -LiteralPath $winre -Destination $source -Force
        (Get-Item -LiteralPath $source -Force).Attributes = 'Normal'

        Mount-Wim -ImageFile $source -Index 1 -MountDir $winreMount -Label "$Label-winre"
        $commit = $false
        try {
            $null = Add-ImageDriver -MountDir $winreMount -DriverPaths $raidStage -ExpectedInfs $raidExpected -Label "$Label-winre"
            $commit = $true
        }
        finally {
            Dismount-Wim -MountDir $winreMount -Label "$Label-winre" -Commit:$commit
        }

        # Re-export to drop commit slack; winre.wim size matters for the recovery partition.
        Export-WimIndex -Source $source -Index 1 -Destination $final -Label "$Label-winre"
        Remove-Item -LiteralPath $source -Force
        $Cache[$hash] = $final
    }

    # winre.wim is Hidden+System in the image; CopyFile refuses to overwrite such files, so clear and restore.
    $attributes = (Get-Item -LiteralPath $winre -Force).Attributes
    (Get-Item -LiteralPath $winre -Force).Attributes = 'Normal'
    Copy-Item -LiteralPath $Cache[$hash] -Destination $winre -Force
    (Get-Item -LiteralPath $winre -Force).Attributes = $attributes
    $status
}

#endregion

#region Preflight

$IsoPath = (Resolve-Path -LiteralPath $IsoPath).ProviderPath
$DriverRoot = (Resolve-Path -LiteralPath $DriverRoot).ProviderPath
$WorkDir = [IO.Path]::GetFullPath($WorkDir)
if (-not $OutputDirectory) { $OutputDirectory = Split-Path -Parent $IsoPath }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath

$isoBaseName = [IO.Path]::GetFileNameWithoutExtension($IsoPath)
$outputIso = Join-Path $OutputDirectory ('{0}_Drivers_{1:yyyyMMdd}.iso' -f $isoBaseName, (Get-Date))
$script:LogDir = Join-Path $OutputDirectory ('{0}_Drivers_{1:yyyyMMdd-HHmmss}_logs' -f $isoBaseName, (Get-Date))
New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null

$mediaDir   = Join-Path $WorkDir 'media'
$sourcesDir = Join-Path $mediaDir 'sources'
$driversDir = Join-Path $WorkDir 'drivers'
$imagesDir  = Join-Path $WorkDir 'images'
$mountRoot  = Join-Path $WorkDir 'mount'
$bootMount  = Join-Path $mountRoot 'boot'
$osMount    = Join-Path $mountRoot 'os'
$winreMount = Join-Path $mountRoot 'winre'

Write-Stage 'Preflight'
$timer = [Diagnostics.Stopwatch]::StartNew()

if (-not (Test-Path -LiteralPath $OscdimgPath)) {
    throw "oscdimg.exe not found at '$OscdimgPath'. Install the Windows ADK 'Deployment Tools' feature or pass -OscdimgPath."
}

$mounted = @(Get-MountedImageDir)
if ($mounted) {
    throw "Existing DISM mounts found: $($mounted -join ', '). Resolve them (dism /Get-MountedImageInfo, /Unmount-Image, /Cleanup-Mountpoints) before building."
}

if ((Test-Path -LiteralPath $outputIso) -and -not $Force) {
    throw "Output ISO already exists: '$outputIso'. Use -Force to overwrite."
}

if (Test-Path -LiteralPath $WorkDir) {
    if (Get-ChildItem -LiteralPath $WorkDir -Force | Select-Object -First 1) {
        if (-not $Force) { throw "WorkDir '$WorkDir' is not empty. Use -Force to wipe it." }
        Remove-Item -LiteralPath $WorkDir -Recurse -Force
    }
}
New-Item -ItemType Directory -Path $WorkDir, $driversDir, $imagesDir, $mountRoot -Force | Out-Null

$freeGB = [math]::Round((Get-PSDrive -Name $WorkDir.Substring(0, 1)).Free / 1GB, 1)
if ($freeGB -lt $MinFreeSpaceGB) {
    throw "Only $freeGB GB free on the WorkDir drive; need at least $MinFreeSpaceGB GB."
}

try {
    $exclusions = @((Get-MpPreference).ExclusionPath)
    if (-not ($exclusions | Where-Object { $_ -and $WorkDir.StartsWith($_.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) })) {
        Write-Warning "WorkDir '$WorkDir' is not excluded from Defender real-time scanning; WIM mounts will be much slower. (Add-MpPreference -ExclusionPath '$WorkDir')"
    }
}
catch { Write-Verbose "Could not read Defender exclusions: $_" }

$raidSource = Join-Path $DriverRoot 'RAID'
$wifiSource = Join-Path $DriverRoot 'WiFi'
if (-not (Get-ChildItem -LiteralPath $raidSource -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    throw "No RAID drivers (*.inf) found under '$raidSource'."
}

Add-Report -Stage 'Preflight' -Detail "Free: $freeGB GB; logs: $script:LogDir" -Timer $timer

#endregion

$succeeded = $false
try {
    #region Expand

    Write-Stage 'Expand: copying ISO contents'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $null = Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -PassThru
    try {
        $volume = Get-DiskImage -ImagePath $IsoPath | Get-Volume
        $volumeLabel = $volume.FileSystemLabel
        $null = & robocopy.exe "$($volume.DriveLetter):\" $mediaDir /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed copying ISO contents (exit $LASTEXITCODE)." }
    }
    finally {
        $null = Dismount-DiskImage -ImagePath $IsoPath
    }
    Get-ChildItem -LiteralPath $mediaDir -Recurse -File -Force |
        Where-Object IsReadOnly |
        ForEach-Object { $_.IsReadOnly = $false }
    Add-Report -Stage 'Expand' -Image $IsoPath -Detail "Volume label: $volumeLabel" -Timer $timer

    #endregion

    #region Stage drivers

    Write-Stage 'Staging drivers'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $raidStage = Join-Path $driversDir 'RAID'
    $raidExpected = Copy-UniqueDriverPackage -SourceRoot $raidSource -Destination $raidStage

    $osDriverPaths = @($raidStage)
    $osExpected = $raidExpected
    $wifiExpected = @()
    if (Get-ChildItem -LiteralPath $wifiSource -Recurse -Filter *.inf -File -ErrorAction SilentlyContinue | Select-Object -First 1) {
        $wifiStage = Join-Path $driversDir 'WiFi'
        $wifiExpected = Copy-UniqueDriverPackage -SourceRoot $wifiSource -Destination $wifiStage
        $osDriverPaths += $wifiStage
        $osExpected = @($raidExpected + $wifiExpected | Sort-Object -Unique)
    }
    else {
        Write-Warning "No Wi-Fi drivers found under '$wifiSource'; install.wim gets RAID only."
    }
    Add-Report -Stage 'StageDrivers' -Drivers $osExpected.Count -Timer $timer `
        -Detail "RAID: $($raidExpected -join ', ') | WiFi: $($wifiExpected -join ', ')"

    #endregion

    #region Normalize

    Write-Stage 'Normalize: selecting editions'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $sourceInstall = 'install.wim', 'install.esd' |
        ForEach-Object { Join-Path $sourcesDir $_ } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not $sourceInstall) { throw "No install.wim or install.esd in '$sourcesDir' (split .swm media is not supported)." }

    $available = @(Get-WimIndex -ImageFile $sourceInstall)
    $workInstall = Join-Path $imagesDir 'install.wim'
    foreach ($edition in $Editions) {
        $match = $available | Where-Object Name -eq $edition
        if (-not $match) {
            throw "Edition '$edition' not found in $(Split-Path $sourceInstall -Leaf). Available: $($available.Name -join '; ')"
        }
        Write-Stage "Normalize: exporting '$edition' (index $($match.Index))"
        Export-WimIndex -Source $sourceInstall -Index $match.Index -Destination $workInstall -Label 'normalize'
    }

    $imageBuild = Get-WimBuild -ImageFile $workInstall -Index 1
    $hostBuild = [Environment]::OSVersion.Version.Build
    if ($imageBuild -and $hostBuild -lt $imageBuild) {
        Write-Warning "Host build $hostBuild is older than image build $imageBuild. Servicing may fail; use a newer host or the ADK's DISM."
    }
    Add-Report -Stage 'Normalize' -Image (Split-Path $sourceInstall -Leaf) -Name ($Editions -join '; ') `
        -Detail "Image build $imageBuild" -Timer $timer

    #endregion

    #region WinPE (boot.wim)

    $bootWim = Join-Path $sourcesDir 'boot.wim'
    $bootIndexes = @(Get-WimIndex -ImageFile $bootWim)
    foreach ($image in $bootIndexes) {
        $label = "boot$($image.Index)"
        Write-Stage "WinPE: boot.wim index $($image.Index) ($($image.Name))"
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Mount-Wim -ImageFile $bootWim -Index $image.Index -MountDir $bootMount -Label $label
        $commit = $false
        try {
            $count = Add-ImageDriver -MountDir $bootMount -DriverPaths $raidStage -ExpectedInfs $raidExpected -Label $label
            $commit = $true
        }
        finally {
            Dismount-Wim -MountDir $bootMount -Label $label -Commit:$commit
        }
        Add-Report -Stage 'WinPE' -Image 'boot.wim' -Index $image.Index -Name $image.Name -Drivers $count -Timer $timer
    }

    #endregion

    #region OS + WinRE (install.wim)

    $winreCache = @{}
    foreach ($image in Get-WimIndex -ImageFile $workInstall) {
        $label = "install$($image.Index)"
        Write-Stage "OS: install.wim index $($image.Index) ($($image.Name))"
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Mount-Wim -ImageFile $workInstall -Index $image.Index -MountDir $osMount -Label $label
        $commit = $false
        try {
            $count = Add-ImageDriver -MountDir $osMount -DriverPaths $osDriverPaths -ExpectedInfs $osExpected -Label $label
            Add-Report -Stage 'OS' -Image 'install.wim' -Index $image.Index -Name $image.Name -Drivers $count

            Write-Stage "WinRE: install.wim index $($image.Index) ($($image.Name))"
            $winreStatus = Update-WinRE -OsMountDir $osMount -Cache $winreCache -Label $label
            Add-Report -Stage 'WinRE' -Image 'winre.wim' -Index $image.Index -Name $image.Name `
                -Drivers $raidExpected.Count -Status $winreStatus
            $commit = $true
        }
        finally {
            Dismount-Wim -MountDir $osMount -Label $label -Commit:$commit
        }
        Add-Report -Stage 'OS+WinRE committed' -Image 'install.wim' -Index $image.Index -Name $image.Name -Timer $timer
    }

    #endregion

    #region Optimize (re-export to reclaim commit slack)

    Write-Stage 'Optimize: re-exporting boot.wim and install.wim'
    $timer = [Diagnostics.Stopwatch]::StartNew()

    $bootFinal = Join-Path $imagesDir 'boot-final.wim'
    foreach ($image in $bootIndexes) {
        Export-WimIndex -Source $bootWim -Index $image.Index -Destination $bootFinal -Label "boot$($image.Index)"
    }
    Move-Item -LiteralPath $bootFinal -Destination $bootWim -Force

    $installFinal = Join-Path $imagesDir 'install-final.wim'
    foreach ($image in Get-WimIndex -ImageFile $workInstall) {
        Export-WimIndex -Source $workInstall -Index $image.Index -Destination $installFinal -Label "install$($image.Index)"
    }
    Remove-Item -LiteralPath $sourceInstall -Force
    Move-Item -LiteralPath $installFinal -Destination (Join-Path $sourcesDir 'install.wim') -Force

    $installSizeGB = [math]::Round((Get-Item -LiteralPath (Join-Path $sourcesDir 'install.wim')).Length / 1GB, 2)
    Add-Report -Stage 'Optimize' -Detail "install.wim: $installSizeGB GB" -Timer $timer

    #endregion

    #region Repack

    Write-Stage 'Repack: building ISO with oscdimg'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $efiName = if ($NoPrompt) { 'efisys_noprompt.bin' } else { 'efisys.bin' }
    $etfsboot = Join-Path $mediaDir 'boot\etfsboot.com'
    $efisys = Join-Path $mediaDir "efi\microsoft\boot\$efiName"
    if (-not (Test-Path -LiteralPath $efisys)) {
        # Fall back to the ADK copy, staged into WorkDir because -bootdata can't take paths with spaces.
        $efisys = Join-Path $WorkDir $efiName
        Copy-Item -LiteralPath (Join-Path (Split-Path $OscdimgPath) $efiName) -Destination $efisys -Force
    }

    $isoLabel = if ($volumeLabel) { $volumeLabel } else { 'WIN11_DRIVERS' }
    $isoLabel = ($isoLabel -replace '[^\w-]', '_')
    $isoLabel = $isoLabel.Substring(0, [math]::Min(32, $isoLabel.Length))

    if (Test-Path -LiteralPath $outputIso) { Remove-Item -LiteralPath $outputIso -Force }
    $bootData = '2#p0,e,b{0}#pEF,e,b{1}' -f $etfsboot, $efisys
    & $OscdimgPath -m -o -u2 -udfver102 "-l$isoLabel" "-bootdata:$bootData" $mediaDir $outputIso *> (Join-Path $script:LogDir 'oscdimg.log')
    if ($LASTEXITCODE -ne 0) { throw "oscdimg failed (exit $LASTEXITCODE). Log: $(Join-Path $script:LogDir 'oscdimg.log')" }
    Add-Report -Stage 'Repack' -Image $outputIso -Detail "Label $isoLabel; $efiName" -Timer $timer

    #endregion

    $succeeded = $true
}
catch {
    Add-Report -Stage 'Failed' -Status 'Error' -Detail $_.Exception.Message
    throw
}
finally {
    Write-Progress -Activity 'Build-DriverMedia' -Completed
    $script:Report | Export-Csv -LiteralPath (Join-Path $script:LogDir 'report.csv') -NoTypeInformation -Encoding utf8

    if ($succeeded -and -not $KeepWorkDir) {
        if (Get-MountedImageDir | Where-Object { $_.StartsWith($WorkDir, [StringComparison]::OrdinalIgnoreCase) }) {
            Write-Warning "Mounts still present under '$WorkDir'; leaving it in place."
        }
        else {
            Remove-Item -LiteralPath $WorkDir -Recurse -Force
        }
    }
    elseif (-not $succeeded) {
        Write-Warning "Build failed. WorkDir '$WorkDir' kept for inspection; DISM logs in '$script:LogDir'."
    }
}

$script:Report
