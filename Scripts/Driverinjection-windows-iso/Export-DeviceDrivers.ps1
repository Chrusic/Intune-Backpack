#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Exports the third-party RAID/VMD storage and Wi-Fi drivers in use on this device.

.DESCRIPTION
    Runs on a reference endpoint (Windows PowerShell 5.1 compatible). Finds the drivers actually
    bound to the storage controller(s) and the Wi-Fi adapter, and exports them with pnputil into
    the layout consumed by Build-DriverMedia.ps1:

        <Destination>\RAID\<Make>\<Model>\<inf>_<version>\...
        <Destination>\WiFi\<Make>\<Model>\<inf>_<version>\...
        <Destination>\<Category>\<Make>\<Model>\manifest.json

    Inbox drivers (anything not oemNN.inf) are reported and skipped: they already ship in the image.
    Only each device's primary driver package is exported; optional extension/software-component
    packages are left to Windows Update after install.

    The storage controller must be in RAID/VMD mode in firmware. In AHCI mode the VMD driver is
    not loaded and there is nothing to export.

.PARAMETER Destination
    Root folder for the export, e.g. a USB stick or network share. Re-running on more models
    into the same root builds up the driver library.

.EXAMPLE
    .\Export-DeviceDrivers.ps1 -Destination E:\Drivers
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Destination
)

$ErrorActionPreference = 'Stop'

function Get-SafeName {
    param([string] $Name)
    $clean = ($Name -replace '[\\/:*?"<>|]', '').Trim()
    if ($clean) { $clean } else { 'Unknown' }
}

function Get-DeviceIdentity {
    $system = Get-CimInstance -ClassName Win32_ComputerSystem
    $product = Get-CimInstance -ClassName Win32_ComputerSystemProduct

    $make = switch -Regex ($system.Manufacturer) {
        '^Dell'   { 'Dell' }
        '^Lenovo' { 'Lenovo' }
        default   { Get-SafeName $system.Manufacturer }
    }
    # Lenovo puts the machine type code in Model; the friendly name ("ThinkPad T14 Gen 5") is in Version.
    $model = if ($make -eq 'Lenovo' -and $product.Version) { $product.Version } else { $system.Model }

    [pscustomobject]@{
        Make         = $make
        Model        = Get-SafeName $model
        MachineType  = $system.Model
        ComputerName = $env:COMPUTERNAME
    }
}

function Get-TargetDevice {
    Get-PnpDevice -Class SCSIAdapter, HDC -PresentOnly -ErrorAction SilentlyContinue |
        ForEach-Object { [pscustomobject]@{ Category = 'RAID'; InstanceId = $_.InstanceId; FriendlyName = $_.FriendlyName } }

    $wifiIds = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object PhysicalMediaType -eq 'Native 802.11' |
        Select-Object -ExpandProperty PnPDeviceID)

    if ($wifiIds) {
        foreach ($id in $wifiIds) {
            $pnp = Get-PnpDevice -InstanceId $id
            [pscustomobject]@{ Category = 'WiFi'; InstanceId = $pnp.InstanceId; FriendlyName = $pnp.FriendlyName }
        }
    }
    else {
        # Fallback for adapters NetAdapter doesn't report (e.g. disabled in a way that hides media type).
        Get-PnpDevice -Class Net -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object FriendlyName -match 'Wi-?Fi|Wireless|802\.11|WLAN' |
            ForEach-Object { [pscustomobject]@{ Category = 'WiFi'; InstanceId = $_.InstanceId; FriendlyName = $_.FriendlyName } }
    }
}

function Get-DriverProperty {
    param([string] $InstanceId)
    $keys = 'DEVPKEY_Device_DriverInfPath', 'DEVPKEY_Device_DriverVersion',
            'DEVPKEY_Device_DriverProvider', 'DEVPKEY_Device_HardwareIds'
    $props = @{}
    Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $keys -ErrorAction SilentlyContinue |
        ForEach-Object { $props[$_.KeyName] = $_.Data }
    $props
}

$identity = Get-DeviceIdentity
$exported = @{}
$manifests = @{}

$results = foreach ($device in Get-TargetDevice) {
    $props = Get-DriverProperty -InstanceId $device.InstanceId
    $oemInf = $props['DEVPKEY_Device_DriverInfPath']

    $result = [ordered]@{
        Category = $device.Category
        Make     = $identity.Make
        Model    = $identity.Model
        Device   = $device.FriendlyName
        Inf      = $oemInf
        OemInf   = $oemInf
        Version  = $props['DEVPKEY_Device_DriverVersion']
        Provider = $props['DEVPKEY_Device_DriverProvider']
        Status   = $null
        Path     = $null
    }

    if (-not $oemInf) {
        $result.Status = 'NoDriver'
        [pscustomobject]$result
        continue
    }
    if ($oemInf -notmatch '^oem\d+\.inf$') {
        $result.Status = 'InboxSkipped'
        [pscustomobject]$result
        continue
    }

    $modelDir = Join-Path $Destination "$($device.Category)\$($identity.Make)\$($identity.Model)"
    $key = "$modelDir|$oemInf"
    if ($exported.ContainsKey($key)) { continue }   # two controllers sharing one driver
    $exported[$key] = $true

    $staging = Join-Path $modelDir ('_export_' + [IO.Path]::GetFileNameWithoutExtension($oemInf))
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    $null = & pnputil.exe /export-driver $oemInf $staging
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $staging -Recurse -Force
        $result.Status = "ExportFailed ($LASTEXITCODE)"
        [pscustomobject]$result
        continue
    }

    $inf = Get-ChildItem -LiteralPath $staging -Filter *.inf -File | Select-Object -First 1
    $result.Inf = $inf.Name.ToLowerInvariant()
    $folderName = '{0}_{1}' -f [IO.Path]::GetFileNameWithoutExtension($inf.Name), $result.Version
    $final = Join-Path $modelDir $folderName

    if (Test-Path -LiteralPath $final) {
        Remove-Item -LiteralPath $staging -Recurse -Force
        $result.Status = 'AlreadyPresent'
    }
    else {
        Rename-Item -LiteralPath $staging -NewName $folderName
        $result.Status = 'Exported'
    }
    $result.Path = $final

    if (-not $manifests.ContainsKey($modelDir)) { $manifests[$modelDir] = [System.Collections.Generic.List[object]]::new() }
    $manifests[$modelDir].Add([ordered]@{
        Category    = $result.Category
        Device      = $result.Device
        Inf         = $result.Inf
        OemInf      = $oemInf
        Version     = $result.Version
        Provider    = $result.Provider
        HardwareIds = @($props['DEVPKEY_Device_HardwareIds'])
        Folder      = $folderName
    })

    [pscustomobject]$result
}

foreach ($dir in $manifests.Keys) {
    [ordered]@{
        Make           = $identity.Make
        Model          = $identity.Model
        MachineType    = $identity.MachineType
        SourceComputer = $identity.ComputerName
        ExportedAt     = (Get-Date).ToString('s')
        Drivers        = $manifests[$dir]
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dir 'manifest.json') -Encoding UTF8
}

$ok = 'Exported', 'AlreadyPresent'
if (-not ($results | Where-Object { $_.Category -eq 'RAID' -and $_.Status -in $ok })) {
    Write-Warning 'No third-party storage driver exported. If this model uses Intel VMD/RST, check that firmware storage mode is RAID/VMD, not AHCI.'
}
if (-not ($results | Where-Object { $_.Category -eq 'WiFi' -and $_.Status -in $ok })) {
    Write-Warning 'No third-party Wi-Fi driver exported (none found, or the adapter uses an inbox driver).'
}

$results
