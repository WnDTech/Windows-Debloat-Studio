# Windows Debloat Studio - review, apply and reverse what Windows 11 ships with.
# Copyright (C) 2026 WndTech
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program. If not, see <https://www.gnu.org/licenses/>.

# =====================================================================
#  Engine.ps1 - reads, applies and restores every kind of action.
#
#  Action kinds: reg, service, appx, task, feature, capability, command
#
#  Three operations exist for every kind:
#    Get-ActionState     -> Enabled / Disabled / Mixed / Unknown  (what is true now)
#    Get-ActionCapture   -> an object that can put the system back exactly
#    Set-ActionState     -> move to Enabled or Disabled
#    Restore-ActionCapture -> replay a capture
# =====================================================================

$script:Cache = @{
    Services = $null
    Appx     = $null
    AppxProv = $null
    Tasks    = $null
    Features = $null
    Caps     = $null
}

$script:DeleteToken = '@delete'

# --------------------------------------------------------------- caches

function Reset-EngineCache {
    param([switch]$IncludeSlow)
    $script:Cache.Services = $null
    $script:Cache.Appx     = $null
    $script:Cache.AppxProv = $null
    $script:Cache.Tasks    = $null
    if ($IncludeSlow) {
        $script:Cache.Features = $null
        $script:Cache.Caps     = $null
    }
}

function Get-ServiceCache {
    if ($null -eq $script:Cache.Services) {
        $h = @{}
        # The registry is the authority and is far quicker than Get-Service for
        # start type, and it also sees services Get-Service refuses to open.
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Services'
        foreach ($k in (Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
            $start = $null
            try { $start = (Get-ItemProperty -LiteralPath $k.PSPath -Name 'Start' -ErrorAction Stop).Start } catch { }
            if ($null -ne $start) { $h[$k.PSChildName.ToLower()] = [int]$start }
        }
        $script:Cache.Services = $h
    }
    return $script:Cache.Services
}

function Get-AppxCache {
    if ($null -eq $script:Cache.Appx) {
        $h = @{}
        foreach ($p in (Get-AppxPackage -ErrorAction SilentlyContinue)) {
            $key = $p.Name.ToLower()
            if (-not $h.ContainsKey($key)) { $h[$key] = @() }
            $h[$key] += $p
        }
        $script:Cache.Appx = $h
    }
    return $script:Cache.Appx
}

function Get-AppxProvisionedCache {
    if ($null -eq $script:Cache.AppxProv) {
        $h = @{}
        try {
            foreach ($p in (Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)) {
                $h[$p.DisplayName.ToLower()] = $p
            }
        } catch { }
        $script:Cache.AppxProv = $h
    }
    return $script:Cache.AppxProv
}

function Get-TaskCache {
    if ($null -eq $script:Cache.Tasks) {
        $h = @{}
        try {
            foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
                $full = ($t.TaskPath + $t.TaskName)
                $h[$full.ToLower()] = $t
            }
        } catch { }
        $script:Cache.Tasks = $h
    }
    return $script:Cache.Tasks
}

function Get-FeatureCache {
    if ($null -eq $script:Cache.Features) {
        $h = @{}
        try {
            foreach ($f in (Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue)) {
                $h[$f.FeatureName.ToLower()] = "$($f.State)"
            }
        } catch { }
        $script:Cache.Features = $h
    }
    return $script:Cache.Features
}

function Get-CapabilityCache {
    if ($null -eq $script:Cache.Caps) {
        $h = @{}
        try {
            foreach ($c in (Get-WindowsCapability -Online -ErrorAction SilentlyContinue)) {
                $h[$c.Name.ToLower()] = "$($c.State)"
            }
        } catch { }
        $script:Cache.Caps = $h
    }
    return $script:Cache.Caps
}

# Whether a category needs the slow DISM queries before its states mean anything.
function Test-NeedsSlowScan {
    param($Tweaks)
    foreach ($t in $Tweaks) {
        foreach ($a in $t.Actions) {
            if ($a.kind -eq 'feature' -or $a.kind -eq 'capability') { return $true }
        }
    }
    return $false
}

# --------------------------------------------------------------- registry

function Convert-HiveToPath {
    param([string]$Hive, [string]$Path)
    # Never guess a hive. Silently falling back to HKLM would send a write
    # somewhere the caller did not ask for.
    switch ($Hive) {
        'HKLM'  { return "HKLM:\$Path" }
        'HKCU'  { return "HKCU:\$Path" }
        'HKCR'  { return "Registry::HKEY_CLASSES_ROOT\$Path" }
        'HKU'   { return "Registry::HKEY_USERS\$Path" }
        default { throw "Unknown registry hive '$Hive' for path '$Path'." }
    }
}

# --------------------------------------------------------------- user hives
#
#  HKCU only ever means the account running this app. To make a per-user option
#  stick for everybody, the same value has to be written into each profile's
#  NTUSER.DAT, plus the default profile so future accounts inherit it.
#
#  Mounting a hive is expensive, so an apply opens one session up front, writes
#  every option through it, then unmounts. A capture records which profiles it
#  touched so a later undo can find them again even after a reboot.

$script:HiveSession = $null
$script:MountSeq = 0

function Get-UserProfileList {
    $out = New-Object Collections.ArrayList
    $meSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value

    [void]$out.Add([pscustomobject]@{
            Sid = 'current'; Label = "$env:USERNAME (you)"; NtUser = $null; IsCurrent = $true
        })

    $base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($k in (Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
        $sid = $k.PSChildName
        # Skip the built-in system accounts and this account, which is handled above.
        if ($sid -notlike 'S-1-5-21-*') { continue }
        if ($sid -eq $meSid) { continue }
        $path = $null
        try { $path = (Get-ItemProperty -LiteralPath $k.PSPath -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath } catch { }
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $dat = Join-Path $path 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $dat)) { continue }
        [void]$out.Add([pscustomobject]@{
                Sid = $sid; Label = (Split-Path $path -Leaf); NtUser = $dat; IsCurrent = $false
            })
    }

    $def = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (Test-Path -LiteralPath $def) {
        [void]$out.Add([pscustomobject]@{
                Sid = 'default'; Label = 'default profile (new accounts)'; NtUser = $def; IsCurrent = $false
            })
    }
    return $out.ToArray()
}

function Mount-UserHive {
    param([Parameter(Mandatory)][string]$NtUser)
    $script:MountSeq++
    $name = "DebloatStudio_$($PID)_$($script:MountSeq)"
    & reg.exe load "HKU\$name" "$NtUser" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $name
}

function Dismount-UserHive {
    param([Parameter(Mandatory)][string]$MountName)
    # The provider keeps handles open; without this the unload fails.
    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()
    & reg.exe unload "HKU\$MountName" 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Resolve one capture/apply target to a live registry root, mounting if needed.
# Returns $null when the profile cannot be reached.
function Resolve-HiveRoot {
    param([string]$Sid, [string]$NtUser, [switch]$AllowMount)

    if ($Sid -eq 'current') { return [pscustomobject]@{ Root = 'HKCU:'; Mounted = $null } }

    if ($Sid -ne 'default') {
        $loaded = "Registry::HKEY_USERS\$Sid"
        if (Test-Path -LiteralPath $loaded) {
            return [pscustomobject]@{ Root = $loaded; Mounted = $null }
        }
    }
    if (-not $AllowMount -or [string]::IsNullOrWhiteSpace($NtUser)) { return $null }
    if (-not (Test-Path -LiteralPath $NtUser)) { return $null }

    $name = Mount-UserHive -NtUser $NtUser
    if (-not $name) { return $null }
    return [pscustomobject]@{ Root = "Registry::HKEY_USERS\$name"; Mounted = $name }
}

function Open-UserHiveSession {
    # -NoMount lists the profiles that would be written to without loading any
    # hive, which is what a dry run needs: mounting is itself a change.
    param([switch]$NoMount)

    $profiles = Get-UserProfileList
    $targets = New-Object Collections.ArrayList
    $mounted = New-Object Collections.ArrayList
    $notes = New-Object Collections.ArrayList

    if ($NoMount) {
        foreach ($p in $profiles) {
            [void]$targets.Add([pscustomobject]@{
                    Sid = $p.Sid; Label = $p.Label; NtUser = $p.NtUser; Root = $null
                })
        }
        $script:HiveSession = [pscustomobject]@{
            Targets = $targets; Mounted = $mounted; Notes = $notes
        }
        return $script:HiveSession
    }

    foreach ($p in $profiles) {
        $r = Resolve-HiveRoot -Sid $p.Sid -NtUser $p.NtUser -AllowMount
        if ($null -eq $r) {
            [void]$notes.Add("could not open the registry for $($p.Label) - skipped")
            continue
        }
        if ($r.Mounted) { [void]$mounted.Add($r.Mounted) }
        [void]$targets.Add([pscustomobject]@{
                Sid = $p.Sid; Label = $p.Label; NtUser = $p.NtUser; Root = $r.Root
            })
    }

    $script:HiveSession = [pscustomobject]@{
        Targets = $targets; Mounted = $mounted; Notes = $notes
    }
    return $script:HiveSession
}

function Close-UserHiveSession {
    if ($null -eq $script:HiveSession) { return @() }
    $notes = New-Object Collections.ArrayList
    foreach ($m in $script:HiveSession.Mounted) {
        if (Dismount-UserHive -MountName $m) { [void]$notes.Add("unmounted $m") }
        else { [void]$notes.Add("WARNING: could not unmount $m - it will release at the next restart") }
    }
    $script:HiveSession = $null
    return $notes.ToArray()
}

# The targets one reg action should be written to right now.
function Get-RegActionTargets {
    param($Action)

    if ($Action.hive -ne 'HKCU' -or $null -eq $script:HiveSession) {
        return @([pscustomobject]@{
                Sid = 'current'; Label = 'this account'; NtUser = $null
                Root = (Convert-HiveToPath $Action.hive '').TrimEnd('\')
            })
    }
    $out = New-Object Collections.ArrayList
    foreach ($t in $script:HiveSession.Targets) {
        [void]$out.Add([pscustomobject]@{
                Sid = $t.Sid; Label = $t.Label; NtUser = $t.NtUser; Root = $t.Root
            })
    }
    return $out.ToArray()
}

function Join-RegPath {
    param([string]$Root, [string]$Path)
    $r = "$Root".TrimEnd('\')
    if ($r -eq 'HKCU:' -or $r -eq 'HKLM:') { return "$r\$Path" }
    return "$r\$Path"
}

function Get-RegValue {
    param([string]$FullPath, [string]$Name)
    if (-not (Test-Path -LiteralPath $FullPath)) {
        return [pscustomobject]@{ KeyExists = $false; Exists = $false; Value = $null; Kind = $null }
    }
    try {
        $item = Get-Item -LiteralPath $FullPath -ErrorAction Stop
        $names = $item.GetValueNames()
        if ($names -notcontains $Name) {
            return [pscustomobject]@{ KeyExists = $true; Exists = $false; Value = $null; Kind = $null }
        }
        $val = $item.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        $kind = "$($item.GetValueKind($Name))"
        return [pscustomobject]@{ KeyExists = $true; Exists = $true; Value = $val; Kind = $kind }
    } catch {
        return [pscustomobject]@{ KeyExists = $true; Exists = $false; Value = $null; Kind = $null }
    }
}

# A REG_DWORD is 32 unsigned bits, but .NET wants a signed Int32. Catalog values
# such as 4294967295 (0xFFFFFFFF) have to be reinterpreted rather than cast.
function Convert-ToDwordInt {
    param($Value)
    $d = [double]$Value
    if ($d -gt 2147483647 -or $d -lt -2147483648) {
        return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$d), 0)
    }
    return [int]$d
}

function Set-RegValue {
    param([string]$FullPath, [string]$Name, $Value, [string]$Type)
    if ($null -eq $Value -or "$Value" -eq $script:DeleteToken) {
        if (Test-Path -LiteralPath $FullPath) {
            Remove-ItemProperty -LiteralPath $FullPath -Name $Name -Force -ErrorAction Stop
        }
        return
    }
    if (-not (Test-Path -LiteralPath $FullPath)) {
        New-Item -Path $FullPath -Force -ErrorAction Stop | Out-Null
    }
    $t = if ($Type) { $Type } else { 'DWord' }
    $v = $Value
    switch ($t) {
        'DWord'  { $v = Convert-ToDwordInt $Value }
        'QWord'  { $v = [int64]$Value }
        'String' { $v = [string]$Value }
        'ExpandString' { $v = [string]$Value }
        'MultiString'  { $v = @($Value) }
        'Binary' {
            if ($Value -is [string]) { $v = [byte[]]([Convert]::FromBase64String($Value)) }
            else { $v = [byte[]]$Value }
        }
    }
    New-ItemProperty -LiteralPath $FullPath -Name $Name -Value $v -PropertyType $t -Force -ErrorAction Stop | Out-Null
}

function Test-RegValueMatch {
    param($Current, $Target, [string]$Type)
    if ("$Target" -eq $script:DeleteToken) { return (-not $Current.Exists) }
    if (-not $Current.Exists) { return $false }
    switch ($Type) {
        'DWord' { return ([int]$Current.Value -eq (Convert-ToDwordInt $Target)) }
        'QWord' { return ([int64]$Current.Value -eq [int64]$Target) }
        'Binary' {
            $t = if ($Target -is [string]) { [Convert]::FromBase64String($Target) } else { [byte[]]$Target }
            $c = [byte[]]$Current.Value
            if ($c.Length -ne $t.Length) { return $false }
            for ($i = 0; $i -lt $c.Length; $i++) { if ($c[$i] -ne $t[$i]) { return $false } }
            return $true
        }
        default { return ("$($Current.Value)" -eq "$Target") }
    }
}

# --------------------------------------------------------------- winget
#
#  Re-registering a removed app only works while its payload is still in
#  WindowsApps. Once Windows has cleaned that up, the Store is the only way
#  back, and winget can drive it.
#
#  A catalogue entry may carry a Store product id. Those ids are data and could
#  be wrong, so nothing is ever installed on the strength of one: winget is
#  asked to describe the package first and the install only proceeds if the
#  name it reports matches what the catalogue expected. A bad id therefore
#  fails safely instead of installing something else.

$script:WingetPath = 'unchecked'

function Get-WingetPath {
    if ($script:WingetPath -eq 'unchecked') {
        $c = Get-Command winget.exe -ErrorAction SilentlyContinue
        $script:WingetPath = if ($c) { $c.Source } else { $null }
    }
    return $script:WingetPath
}

function Test-StoreIdMatches {
    param([string]$Id, [string]$Expect)

    $wg = Get-WingetPath
    if (-not $wg) { return [pscustomobject]@{ Ok = $false; Reason = 'winget is not available on this PC' } }
    if ([string]::IsNullOrWhiteSpace($Id)) { return [pscustomobject]@{ Ok = $false; Reason = 'no Store id recorded' } }

    try {
        $out = & $wg show --id $Id --source msstore --accept-source-agreements --disable-interactivity 2>&1 |
        Out-String
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = "winget show failed: $($_.Exception.Message)" }
    }

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($out)) {
        return [pscustomobject]@{ Ok = $false; Reason = "winget could not find $Id in the Store" }
    }
    if ([string]::IsNullOrWhiteSpace($Expect)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'no expected name recorded, refusing to install blind' }
    }

    # Compare on letters and digits only, so punctuation and spacing differences
    # between the catalogue and the Store listing do not cause a false refusal.
    $norm = { param($t) (($t -replace '[^a-zA-Z0-9]', '')).ToLower() }
    if ((& $norm $out) -like ('*' + (& $norm $Expect) + '*')) {
        return [pscustomobject]@{ Ok = $true; Reason = "matched '$Expect'" }
    }
    $first = ($out -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1).Trim()
    return [pscustomobject]@{
        Ok = $false
        Reason = "REFUSED: id $Id does not look like '$Expect' (winget reported: $first)"
    }
}

function Install-StoreApp {
    param([string]$Id, [string]$Expect)

    # Store reinstall through winget is a Pro feature. Free still gets the
    # local re-register paths and a clickable Store link, so nothing a free
    # user removed is unrecoverable - it just takes one more click.
    if ((Get-Command Test-Feature -ErrorAction SilentlyContinue) -and -not (Test-Feature 'winget')) {
        return [pscustomobject]@{ Ok = $false
            Note = 'reinstalling from the Store through winget is included with Pro - use the Store link below' }
    }

    $check = Test-StoreIdMatches -Id $Id -Expect $Expect
    if (-not $check.Ok) { return [pscustomobject]@{ Ok = $false; Note = $check.Reason } }

    $wg = Get-WingetPath
    $out = & $wg install --id $Id --source msstore --accept-package-agreements `
        --accept-source-agreements --disable-interactivity 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        return [pscustomobject]@{ Ok = $true; Note = "installed $Expect from the Store with winget" }
    }
    $tail = (($out -replace '\s+', ' ').Trim())
    if ($tail.Length -gt 180) { $tail = $tail.Substring(0, 180) + '...' }
    return [pscustomobject]@{ Ok = $false; Note = "winget install of $Expect failed: $tail" }
}

# A catalogue appx action may carry  "store": { "<Package.Name>": { "id":..., "expect":... } }
function Get-AppxStoreId {
    param($Action, [string]$Package)
    if (-not $Action.store) { return $null }
    $e = $Action.store.PSObject.Properties | Where-Object { $_.Name -eq $Package }
    if (-not $e) { return $null }
    $v = $e.Value
    if ([string]::IsNullOrWhiteSpace("$($v.id)")) { return $null }
    return [pscustomobject]@{ id = "$($v.id)"; expect = "$($v.expect)" }
}

function Get-AppxStoreLink {
    param($Action, [string]$Package)
    $sid = Get-AppxStoreId -Action $Action -Package $Package
    if (-not $sid) { return $null }
    return Get-StoreLink $sid.id
}

# The Store link a person can click when winget cannot help.
function Get-StoreLink {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    return "ms-windows-store://pdp/?productid=$Id"
}

# --------------------------------------------------------------- state read

function Get-ActionState {
    param([Parameter(Mandatory)]$Action)

    try {
        switch ($Action.kind) {

            'reg' {
                $full = Convert-HiveToPath $Action.hive $Action.path
                $cur = Get-RegValue $full $Action.name
                if (Test-RegValueMatch $cur $Action.disable $Action.type) { return 'Disabled' }
                if (Test-RegValueMatch $cur $Action.enable  $Action.type) { return 'Enabled' }
                return 'Unknown'
            }

            'service' {
                $c = Get-ServiceCache
                $key = "$($Action.name)".ToLower()
                if (-not $c.ContainsKey($key)) { return 'Unknown' }
                $start = $c[$key]
                $want = Convert-StartTypeToInt $Action.disable
                if ($start -eq $want) { return 'Disabled' }
                $wantE = Convert-StartTypeToInt $Action.enable
                if ($start -eq $wantE) { return 'Enabled' }
                if ($start -eq 4) { return 'Disabled' }
                return 'Enabled'
            }

            'appx' {
                $inst = Get-AppxCache
                $prov = Get-AppxProvisionedCache
                $present = 0
                $total = 0
                foreach ($n in $Action.packages) {
                    $total++
                    $k = "$n".ToLower()
                    if ($inst.ContainsKey($k) -or $prov.ContainsKey($k)) { $present++ }
                }
                if ($present -eq 0) { return 'Disabled' }
                if ($present -eq $total) { return 'Enabled' }
                return 'Mixed'
            }

            'task' {
                $c = Get-TaskCache
                $on = 0; $off = 0; $seen = 0
                foreach ($p in $Action.tasks) {
                    $k = "$p".ToLower()
                    if (-not $c.ContainsKey($k)) { continue }
                    $seen++
                    if ("$($c[$k].State)" -eq 'Disabled') { $off++ } else { $on++ }
                }
                if ($seen -eq 0) { return 'Unknown' }
                if ($on -eq 0) { return 'Disabled' }
                if ($off -eq 0) { return 'Enabled' }
                return 'Mixed'
            }

            'feature' {
                $c = Get-FeatureCache
                $k = "$($Action.name)".ToLower()
                if (-not $c.ContainsKey($k)) { return 'Unknown' }
                if ($c[$k] -like 'Enabled*') { return 'Enabled' }
                return 'Disabled'
            }

            'capability' {
                $c = Get-CapabilityCache
                $k = "$($Action.name)".ToLower()
                if (-not $c.ContainsKey($k)) { return 'Unknown' }
                if ($c[$k] -eq 'Installed') { return 'Enabled' }
                return 'Disabled'
            }

            'command' {
                if (-not $Action.probe) { return 'Unknown' }
                $res = & ([scriptblock]::Create($Action.probe))
                $s = "$res"
                if ($s -eq 'Enabled' -or $s -eq 'Disabled' -or $s -eq 'Mixed') { return $s }
                return 'Unknown'
            }
        }
    } catch {
        return 'Unknown'
    }
    return 'Unknown'
}

function Convert-StartTypeToInt {
    param($Value)
    switch ("$Value") {
        'Boot'      { return 0 }
        'System'    { return 1 }
        'Automatic' { return 2 }
        'AutomaticDelayed' { return 2 }
        'Manual'    { return 3 }
        'Disabled'  { return 4 }
        default     { return 3 }
    }
}

function Get-TweakState {
    param([Parameter(Mandatory)]$Tweak)
    $states = @()
    foreach ($a in $Tweak.Actions) { $states += (Get-ActionState $a) }
    if ($states.Count -eq 0) { return 'Unknown' }
    $u = @($states | Sort-Object -Unique)
    if ($u.Count -eq 1) { return $u[0] }
    if ($u -contains 'Enabled' -and $u -contains 'Disabled') { return 'Mixed' }
    if ($u -contains 'Mixed') { return 'Mixed' }
    $known = @($states | Where-Object { $_ -ne 'Unknown' } | Sort-Object -Unique)
    if ($known.Count -eq 1) { return $known[0] }
    return 'Unknown'
}

# --------------------------------------------------------------- capture

function Get-ActionCapture {
    param([Parameter(Mandatory)]$Action)

    $cap = [ordered]@{ kind = $Action.kind }

    switch ($Action.kind) {
        'reg' {
            $cap.hive = $Action.hive
            $cap.path = $Action.path
            $cap.name = $Action.name

            # One entry per profile we are about to write to, so a later undo can
            # put each of them back independently.
            $targets = New-Object Collections.ArrayList
            foreach ($t in (Get-RegActionTargets $Action)) {
                $cur = Get-RegValue (Join-RegPath $t.Root $Action.path) $Action.name
                $val = $cur.Value
                if ($val -is [byte[]]) { $val = [Convert]::ToBase64String($val) }
                [void]$targets.Add([ordered]@{
                        sid        = $t.Sid
                        label      = $t.Label
                        ntuser     = $t.NtUser
                        keyExisted = $cur.KeyExists
                        existed    = $cur.Exists
                        value      = $val
                        type       = if ($cur.Kind) { $cur.Kind } else { $Action.type }
                    })
            }
            $cap.targets = $targets

            # Kept flat as well so journals written by earlier versions, and any
            # single-profile change, still read correctly.
            $first = $targets[0]
            $cap.keyExisted = $first.keyExisted
            $cap.existed = $first.existed
            $cap.value = $first.value
            $cap.type = $first.type
        }
        'service' {
            $c = Get-ServiceCache
            $key = "$($Action.name)".ToLower()
            $cap.name = $Action.name
            $cap.existed = $c.ContainsKey($key)
            $cap.start = if ($cap.existed) { $c[$key] } else { $null }
            $svc = Get-Service -Name $Action.name -ErrorAction SilentlyContinue
            $cap.status = if ($svc) { "$($svc.Status)" } else { $null }
        }
        'appx' {
            $inst = Get-AppxCache
            $prov = Get-AppxProvisionedCache
            $items = @()
            foreach ($n in $Action.packages) {
                $k = "$n".ToLower()
                $locs = @()
                if ($inst.ContainsKey($k)) {
                    foreach ($p in $inst[$k]) { $locs += "$($p.InstallLocation)" }
                }
                $sid = Get-AppxStoreId -Action $Action -Package $n
                $items += [ordered]@{
                    name        = $n
                    installed   = $inst.ContainsKey($k)
                    provisioned = $prov.ContainsKey($k)
                    locations   = $locs
                    storeId     = if ($sid) { $sid.id } else { $null }
                    storeExpect = if ($sid) { $sid.expect } else { $null }
                }
            }
            $cap.packages = $items
        }
        'task' {
            $c = Get-TaskCache
            $items = @()
            foreach ($p in $Action.tasks) {
                $k = "$p".ToLower()
                $items += [ordered]@{
                    path    = $p
                    exists  = $c.ContainsKey($k)
                    state   = if ($c.ContainsKey($k)) { "$($c[$k].State)" } else { $null }
                }
            }
            $cap.tasks = $items
        }
        'feature' {
            $cap.name = $Action.name
            $cap.state = (Get-FeatureCache)["$($Action.name)".ToLower()]
        }
        'capability' {
            $cap.name = $Action.name
            $cap.state = (Get-CapabilityCache)["$($Action.name)".ToLower()]
        }
        'command' {
            $cap.state = Get-ActionState $Action
            $cap.enable = $Action.enable
            $cap.disable = $Action.disable
        }
    }
    return $cap
}

# --------------------------------------------------------------- apply

# A dry run describes what would happen and deliberately contains no write of
# any kind, so there is no conditional inside the real apply code that could be
# got wrong and let a change slip through.
function Get-DryRunNotes {
    param(
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)][string]$Direction
    )
    $n = New-Object Collections.Generic.List[string]

    switch ($Action.kind) {
        'reg' {
            $want = if ($Direction -eq 'Enable') { $Action.enable } else { $Action.disable }
            foreach ($t in (Get-RegActionTargets $Action)) {
                $where = "  [$($t.Label)]"
                if ("$want" -eq $script:DeleteToken) {
                    $n.Add("would remove $($Action.hive)\$($Action.path)\$($Action.name)$where")
                } else {
                    $n.Add("would set $($Action.hive)\$($Action.path)\$($Action.name) = $want ($($Action.type))$where")
                }
            }
        }
        'service' {
            $want = if ($Direction -eq 'Enable') { $Action.enable } else { $Action.disable }
            $c = Get-ServiceCache
            if (-not $c.ContainsKey("$($Action.name)".ToLower())) {
                $n.Add("service $($Action.name) is not on this PC, would be skipped")
            } else {
                if ($Direction -eq 'Disable') { $n.Add("would stop $($Action.name) if it is running") }
                $n.Add("would set $($Action.name) start type to $want")
                if ($Direction -eq 'Enable') { $n.Add("would start $($Action.name)") }
            }
        }
        'appx' {
            $inst = Get-AppxCache
            $prov = Get-AppxProvisionedCache
            foreach ($p in $Action.packages) {
                $k = "$p".ToLower()
                $here = ($inst.ContainsKey($k) -or $prov.ContainsKey($k))
                if (-not $here) { $n.Add("$p is not installed, would be skipped"); continue }
                if ($Direction -eq 'Disable') {
                    if ($inst.ContainsKey($k)) { $n.Add("would remove $p for this account") }
                    if ($prov.ContainsKey($k)) { $n.Add("would deprovision $p for new accounts") }
                } else {
                    $n.Add("would re-register $p from its local payload if it is still there")
                }
            }
        }
        'task' {
            $c = Get-TaskCache
            foreach ($p in $Action.tasks) {
                if (-not $c.ContainsKey("$p".ToLower())) { $n.Add("task not present: $p"); continue }
                $n.Add("would $($Direction.ToLower()) task $p")
            }
        }
        'feature' {
            $verb = if ($Direction -eq 'Enable') { 'turn on' } else { 'turn off' }
            $n.Add("would $verb the Windows feature $($Action.name) via DISM")
        }
        'capability' {
            $verb = if ($Direction -eq 'Enable') { 'install' } else { 'remove' }
            $n.Add("would $verb the capability $($Action.name) via DISM")
        }
        'command' {
            $cmd = if ($Direction -eq 'Enable') { $Action.enable } else { $Action.disable }
            if ([string]::IsNullOrWhiteSpace($cmd)) { $n.Add("nothing to run for $Direction") }
            else { $n.Add("would run: " + (($cmd -replace '\s+', ' ').Trim())) }
        }
    }
    if ($n.Count -eq 0) { $n.Add('nothing to do') }
    return $n
}

function Get-DryRunRestoreNotes {
    param([Parameter(Mandatory)]$Capture)
    $n = New-Object Collections.Generic.List[string]
    switch ($Capture.kind) {
        'reg' {
            $targets = @($Capture.targets)
            if ($targets.Count -eq 0) { $targets = @($Capture) }
            foreach ($t in $targets) {
                $where = if (@($Capture.targets).Count -gt 1) { "  [$($t.label)]" } else { '' }
                if ($t.existed) { $n.Add("would restore $($Capture.path)\$($Capture.name) = $($t.value)$where") }
                else { $n.Add("would remove $($Capture.name) again, it did not exist before$where") }
            }
        }
        'service' {
            $map = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
            $n.Add("would set $($Capture.name) start type back to $($map[[int]$Capture.start])")
        }
        'appx' {
            foreach ($p in $Capture.packages) {
                if ($p.installed -or $p.provisioned) { $n.Add("would reinstall $($p.name) from its recorded folder") }
            }
        }
        'task' {
            foreach ($t in $Capture.tasks) { if ($t.exists) { $n.Add("would set task $($t.path) back to $($t.state)") } }
        }
        'feature' { $n.Add("would set the feature $($Capture.name) back to $($Capture.state)") }
        'capability' { $n.Add("would set the capability $($Capture.name) back to $($Capture.state)") }
        'command' { $n.Add("would re-run the $($Capture.state) command") }
    }
    if ($n.Count -eq 0) { $n.Add('nothing recorded to restore') }
    return $n
}

function Set-ActionState {
    param(
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)][ValidateSet('Enable','Disable')][string]$Direction,
        [switch]$DryRun
    )

    if ($DryRun) { return (Get-DryRunNotes -Action $Action -Direction $Direction) }

    $notes = New-Object Collections.Generic.List[string]

    switch ($Action.kind) {

        'reg' {
            $want = if ($Direction -eq 'Enable') { $Action.enable } else { $Action.disable }
            $tgts = @(Get-RegActionTargets $Action)
            foreach ($t in $tgts) {
                $full = Join-RegPath $t.Root $Action.path
                $where = if ($tgts.Count -gt 1) { "  [$($t.Label)]" } else { '' }
                try {
                    Set-RegValue -FullPath $full -Name $Action.name -Value $want -Type $Action.type
                    if ("$want" -eq $script:DeleteToken) {
                        $notes.Add("removed $($Action.path)\$($Action.name)$where")
                    } else {
                        $notes.Add("$($Action.path)\$($Action.name) = $want$where")
                    }
                } catch {
                    $notes.Add("could not write $($Action.name)$where : $($_.Exception.Message)")
                }
            }
        }

        'service' {
            $target = if ($Direction -eq 'Enable') { $Action.enable } else { $Action.disable }
            $svcName = $Action.name
            $c = Get-ServiceCache
            if (-not $c.ContainsKey($svcName.ToLower())) {
                $notes.Add("service $svcName is not present on this PC - skipped")
                break
            }
            if ($Direction -eq 'Disable') {
                $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    try { Stop-Service -Name $svcName -Force -ErrorAction Stop; $notes.Add("stopped $svcName") }
                    catch { $notes.Add("could not stop $svcName (it will stay stopped after a restart)") }
                }
            }
            $applied = $false
            try {
                Set-Service -Name $svcName -StartupType $target -ErrorAction Stop
                $applied = $true
            } catch {
                # Protected services refuse the service-control path; the registry
                # start value is honoured on the next boot either way.
                try {
                    $rk = "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName"
                    Set-RegValue -FullPath $rk -Name 'Start' -Value (Convert-StartTypeToInt $target) -Type 'DWord'
                    $applied = $true
                    $notes.Add("$svcName set through the registry (needs a restart)")
                } catch {
                    $notes.Add("ACCESS DENIED writing start type for $svcName")
                }
            }
            if ($applied) {
                $notes.Add("$svcName start type -> $target")
                (Get-ServiceCache)[$svcName.ToLower()] = (Convert-StartTypeToInt $target)
            }
            if ($Direction -eq 'Enable') {
                try { Start-Service -Name $svcName -ErrorAction Stop; $notes.Add("started $svcName") } catch { }
            }
        }

        'appx' {
            $inst = Get-AppxCache
            $prov = Get-AppxProvisionedCache
            foreach ($n in $Action.packages) {
                $k = "$n".ToLower()
                if ($Direction -eq 'Disable') {
                    if ($inst.ContainsKey($k)) {
                        foreach ($p in $inst[$k]) {
                            try {
                                Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
                                $notes.Add("removed $($p.Name) for the current user")
                            } catch {
                                $notes.Add("could not remove $($p.Name): $($_.Exception.Message)")
                            }
                        }
                        $inst.Remove($k)
                    }
                    if ($prov.ContainsKey($k)) {
                        try {
                            Remove-AppxProvisionedPackage -Online -PackageName $prov[$k].PackageName `
                                -ErrorAction Stop | Out-Null
                            $notes.Add("deprovisioned $n so new accounts do not get it")
                        } catch {
                            $notes.Add("could not deprovision $n")
                        }
                        $prov.Remove($k)
                    }
                } else {
                    # Re-registering only works while the payload is still on disk.
                    $done = $false
                    $glob = Join-Path $env:ProgramFiles "WindowsApps\$n*"
                    foreach ($dir in (Get-ChildItem -Path $glob -Directory -ErrorAction SilentlyContinue)) {
                        $mf = Join-Path $dir.FullName 'AppXManifest.xml'
                        if (Test-Path -LiteralPath $mf) {
                            try {
                                Add-AppxPackage -Register $mf -DisableDevelopmentMode -ErrorAction Stop
                                $notes.Add("re-registered $n from $($dir.Name)")
                                $done = $true
                                break
                            } catch { }
                        }
                    }
                    if (-not $done) {
                        $sid = Get-AppxStoreId -Action $Action -Package $n
                        if ($sid) {
                            $r = Install-StoreApp -Id $sid.id -Expect $sid.expect
                            $notes.Add("  " + $r.Note)
                            $done = $r.Ok
                        }
                    }
                    if (-not $done) {
                        $link = Get-AppxStoreLink -Action $Action -Package $n
                        if ($link) { $notes.Add("$n payload is gone - install it from $link") }
                        else { $notes.Add("$n payload is gone - reinstall it from the Microsoft Store") }
                    }
                }
            }
            $script:Cache.Appx = $null
            $script:Cache.AppxProv = $null
        }

        'task' {
            foreach ($p in $Action.tasks) {
                $leaf = Split-Path $p -Leaf
                $folder = Split-Path $p -Parent
                if (-not $folder.EndsWith('\')) { $folder = $folder + '\' }
                try {
                    if ($Direction -eq 'Disable') {
                        Disable-ScheduledTask -TaskName $leaf -TaskPath $folder -ErrorAction Stop | Out-Null
                        $notes.Add("disabled task $leaf")
                    } else {
                        Enable-ScheduledTask -TaskName $leaf -TaskPath $folder -ErrorAction Stop | Out-Null
                        $notes.Add("enabled task $leaf")
                    }
                } catch {
                    $notes.Add("task $leaf not present or not changeable")
                }
            }
            $script:Cache.Tasks = $null
        }

        'feature' {
            try {
                if ($Direction -eq 'Disable') {
                    Disable-WindowsOptionalFeature -Online -FeatureName $Action.name -NoRestart `
                        -ErrorAction Stop | Out-Null
                    $notes.Add("turned off Windows feature $($Action.name)")
                } else {
                    Enable-WindowsOptionalFeature -Online -FeatureName $Action.name -All -NoRestart `
                        -ErrorAction Stop | Out-Null
                    $notes.Add("turned on Windows feature $($Action.name)")
                }
                $script:Cache.Features = $null
            } catch {
                $notes.Add("feature $($Action.name): $($_.Exception.Message)")
            }
        }

        'capability' {
            try {
                if ($Direction -eq 'Disable') {
                    Remove-WindowsCapability -Online -Name $Action.name -ErrorAction Stop | Out-Null
                    $notes.Add("removed capability $($Action.name)")
                } else {
                    Add-WindowsCapability -Online -Name $Action.name -ErrorAction Stop | Out-Null
                    $notes.Add("added capability $($Action.name)")
                }
                $script:Cache.Caps = $null
            } catch {
                $notes.Add("capability $($Action.name): $($_.Exception.Message)")
            }
        }

        'command' {
            $cmdText = if ($Direction -eq 'Enable') { $Action.enable } else { $Action.disable }
            if ([string]::IsNullOrWhiteSpace($cmdText)) {
                $notes.Add("nothing to run for $Direction")
                break
            }
            $out = & ([scriptblock]::Create($cmdText)) 2>&1
            $notes.Add(("ran: " + ($cmdText -replace '\s+', ' ')).Trim())
            if ($out) {
                $txt = (($out | Out-String) -replace '\s+', ' ').Trim()
                if ($txt) { $notes.Add("  -> $txt") }
            }
        }
    }

    return $notes
}

# --------------------------------------------------------------- restore

function Restore-ActionCapture {
    param(
        [Parameter(Mandatory)]$Capture,
        [switch]$DryRun
    )

    if ($DryRun) { return (Get-DryRunRestoreNotes -Capture $Capture) }

    if ($Capture -is [Array] -or $Capture -is [Collections.IList]) {
        throw 'Restore-ActionCapture expects a single capture, not a collection.'
    }
    if ([string]::IsNullOrWhiteSpace("$($Capture.kind)")) {
        throw 'Capture has no kind, so it cannot be restored.'
    }

    $notes = New-Object Collections.Generic.List[string]

    switch ($Capture.kind) {

        'reg' {
            # Newer captures carry one entry per profile; older ones are flat.
            $targets = @($Capture.targets)
            if ($targets.Count -eq 0) {
                $targets = @([pscustomobject]@{
                        sid = 'current'; label = 'this account'; ntuser = $null
                        keyExisted = $Capture.keyExisted; existed = $Capture.existed
                        value = $Capture.value; type = $Capture.type
                    })
            }

            foreach ($t in $targets) {
                $sid = if ($t.sid) { "$($t.sid)" } else { 'current' }
                $r = Resolve-HiveRoot -Sid $sid -NtUser $t.ntuser -AllowMount
                if ($null -eq $r) {
                    $notes.Add("could not reach the registry for $($t.label) - left as it is")
                    continue
                }
                $where = if ($targets.Count -gt 1) { "  [$($t.label)]" } else { '' }
                $full = Join-RegPath $r.Root $Capture.path
                try {
                    if ($t.existed) {
                        Set-RegValue -FullPath $full -Name $Capture.name -Value $t.value -Type $t.type
                        $notes.Add("restored $($Capture.path)\$($Capture.name) = $($t.value)$where")
                    } else {
                        if (Test-Path -LiteralPath $full) {
                            Remove-ItemProperty -LiteralPath $full -Name $Capture.name -Force -ErrorAction SilentlyContinue
                        }
                        $notes.Add("removed $($Capture.name) again, it did not exist before$where")
                        # If we created the key ourselves and it is now empty, take it away too.
                        if (-not $t.keyExisted -and (Test-Path -LiteralPath $full)) {
                            try {
                                $item = Get-Item -LiteralPath $full -ErrorAction Stop
                                if ($item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) {
                                    Remove-Item -LiteralPath $full -Force -ErrorAction Stop
                                    $notes.Add("removed the key we created$where")
                                }
                            } catch { }
                        }
                    }
                } catch {
                    $notes.Add("could not restore $($Capture.name)$where : $($_.Exception.Message)")
                } finally {
                    if ($r.Mounted) { [void](Dismount-UserHive -MountName $r.Mounted) }
                }
            }
        }

        'service' {
            if (-not $Capture.existed) { $notes.Add("service $($Capture.name) was not present - nothing to do"); break }
            $map = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
            $target = $map[[int]$Capture.start]
            if (-not $target) { $target = 'Manual' }
            try {
                Set-Service -Name $Capture.name -StartupType $target -ErrorAction Stop
            } catch {
                try {
                    Set-RegValue -FullPath "HKLM:\SYSTEM\CurrentControlSet\Services\$($Capture.name)" `
                        -Name 'Start' -Value ([int]$Capture.start) -Type 'DWord'
                } catch { $notes.Add("could not restore start type for $($Capture.name)") }
            }
            $notes.Add("$($Capture.name) start type back to $target")
            if ($Capture.status -eq 'Running') {
                try { Start-Service -Name $Capture.name -ErrorAction Stop; $notes.Add("restarted $($Capture.name)") } catch { }
            }
            (Get-ServiceCache)["$($Capture.name)".ToLower()] = [int]$Capture.start
        }

        'appx' {
            foreach ($p in $Capture.packages) {
                if (-not $p.installed -and -not $p.provisioned) { continue }
                $done = $false
                foreach ($loc in @($p.locations)) {
                    if ([string]::IsNullOrWhiteSpace($loc)) { continue }
                    $mf = Join-Path $loc 'AppXManifest.xml'
                    if (Test-Path -LiteralPath $mf) {
                        try {
                            Add-AppxPackage -Register $mf -DisableDevelopmentMode -ErrorAction Stop
                            $notes.Add("reinstalled $($p.name) from its original folder")
                            $done = $true
                            break
                        } catch { }
                    }
                }
                if (-not $done) {
                    foreach ($dir in (Get-ChildItem -Path (Join-Path $env:ProgramFiles "WindowsApps\$($p.name)*") `
                                      -Directory -ErrorAction SilentlyContinue)) {
                        $mf = Join-Path $dir.FullName 'AppXManifest.xml'
                        if (Test-Path -LiteralPath $mf) {
                            try {
                                Add-AppxPackage -Register $mf -DisableDevelopmentMode -ErrorAction Stop
                                $notes.Add("reinstalled $($p.name)")
                                $done = $true
                                break
                            } catch { }
                        }
                    }
                }
                if (-not $done -and $p.storeId) {
                    $r = Install-StoreApp -Id $p.storeId -Expect $p.storeExpect
                    $notes.Add("  " + $r.Note)
                    $done = $r.Ok
                }
                if (-not $done) {
                    $link = Get-StoreLink $p.storeId
                    if ($link) { $notes.Add("$($p.name) cannot be put back locally - install it from $link") }
                    else { $notes.Add("$($p.name) cannot be put back locally - get it from the Microsoft Store") }
                }
            }
            $script:Cache.Appx = $null
            $script:Cache.AppxProv = $null
        }

        'task' {
            foreach ($t in $Capture.tasks) {
                if (-not $t.exists) { continue }
                $leaf = Split-Path $t.path -Leaf
                $folder = Split-Path $t.path -Parent
                if (-not $folder.EndsWith('\')) { $folder = $folder + '\' }
                try {
                    if ($t.state -eq 'Disabled') {
                        Disable-ScheduledTask -TaskName $leaf -TaskPath $folder -ErrorAction Stop | Out-Null
                    } else {
                        Enable-ScheduledTask -TaskName $leaf -TaskPath $folder -ErrorAction Stop | Out-Null
                    }
                    $notes.Add("task $leaf back to $($t.state)")
                } catch {
                    $notes.Add("could not restore task $leaf")
                }
            }
            $script:Cache.Tasks = $null
        }

        'feature' {
            try {
                if ("$($Capture.state)" -like 'Enabled*') {
                    Enable-WindowsOptionalFeature -Online -FeatureName $Capture.name -All -NoRestart `
                        -ErrorAction Stop | Out-Null
                    $notes.Add("feature $($Capture.name) turned back on")
                } else {
                    Disable-WindowsOptionalFeature -Online -FeatureName $Capture.name -NoRestart `
                        -ErrorAction Stop | Out-Null
                    $notes.Add("feature $($Capture.name) turned back off")
                }
                $script:Cache.Features = $null
            } catch {
                $notes.Add("feature $($Capture.name): $($_.Exception.Message)")
            }
        }

        'capability' {
            try {
                if ("$($Capture.state)" -eq 'Installed') {
                    Add-WindowsCapability -Online -Name $Capture.name -ErrorAction Stop | Out-Null
                    $notes.Add("capability $($Capture.name) reinstalled")
                } else {
                    Remove-WindowsCapability -Online -Name $Capture.name -ErrorAction Stop | Out-Null
                    $notes.Add("capability $($Capture.name) removed again")
                }
                $script:Cache.Caps = $null
            } catch {
                $notes.Add("capability $($Capture.name): $($_.Exception.Message)")
            }
        }

        'command' {
            $cmdText = $null
            if ("$($Capture.state)" -eq 'Enabled') { $cmdText = $Capture.enable }
            elseif ("$($Capture.state)" -eq 'Disabled') { $cmdText = $Capture.disable }
            if ([string]::IsNullOrWhiteSpace($cmdText)) {
                $notes.Add("the previous state was not known, so nothing was re-run")
                break
            }
            $out = & ([scriptblock]::Create($cmdText)) 2>&1
            $notes.Add("re-ran the $($Capture.state) command")
            if ($out) {
                $txt = (($out | Out-String) -replace '\s+', ' ').Trim()
                if ($txt) { $notes.Add("  -> $txt") }
            }
        }
    }

    return $notes
}

# --------------------------------------------------------------- Explorer refresh

function Restart-ExplorerShell {
    try {
        Stop-Process -Name explorer -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}
