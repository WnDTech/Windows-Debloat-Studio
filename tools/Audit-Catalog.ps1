<#
    Audit-Catalog.ps1
    -----------------
    Cross-checks every identifier in the catalogue against this actual machine,
    to catch the failure mode a JSON schema check cannot see: a name that is
    simply spelled wrong. A misspelled service, task, feature or registry key
    makes an option quietly do nothing for ever, and it looks identical to an
    option that legitimately does not apply to this PC.

    What each result means:

      OK        the identifier was found on this machine
      ABSENT    not found, but that is expected for this kind of identifier
                (group policy keys do not exist until a policy is set)
      SUSPECT   not found where it really should exist - worth looking at

    Read the SUSPECT list. Everything else is noise.
#>
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

[CmdletBinding()]
param(
    # Also list every ABSENT identifier, not just the suspects.
    # (named ShowAll, not Full: a local $full would collide case-insensitively)
    [switch]$ShowAll
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

Add-Type -AssemblyName PresentationFramework
. (Join-Path $Root 'src\Modules\Core.ps1'); Initialize-Paths -Root $Root
. (Join-Path $Root 'src\Modules\Engine.ps1')
. (Join-Path $Root 'src\Modules\Journal.ps1')
. (Join-Path $Root 'src\Modules\Catalog.ps1')
. (Join-Path $Root 'src\Modules\Presets.ps1')
. (Join-Path $Root 'src\Modules\Ui.ps1')

Initialize-Interop
Import-Catalog | Out-Null

$elevated = Test-IsAdmin
Write-Host ''
Write-Host '  Catalogue audit against this machine' -ForegroundColor Cyan
$os = Get-WindowsBuildInfo
Write-Host ("  $($os.Product) $($os.Display), build $($os.Build)   elevated=$elevated") -ForegroundColor DarkGray
Write-Host ''

$suspect = New-Object Collections.ArrayList
$absent = New-Object Collections.ArrayList
$stats = @{}
$baselined = 0

# Registry paths that are documented and correct but that Windows does not
# create until the setting is changed, so the depth heuristic flags them every
# time. Recording them here keeps the suspect list meaningful: anything that
# turns up outside this baseline is worth actually investigating.
$KnownAbsent = @(
    'SOFTWARE\Microsoft\Windows\Shell\Copilot'
    'SOFTWARE\Microsoft\Speech_OneCore\Settings\VoiceActivation'
    'SOFTWARE\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'
    'SOFTWARE\Microsoft\Siuf\Rules'
    'SOFTWARE\Microsoft\Settings\FindMyDevice'
    'SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
    'SOFTWARE\Microsoft\Windows Script Host\Settings'
    'SOFTWARE\Microsoft\Windows\CurrentVersion\AIDataAnalysis'
    'SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement'
    'SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings'
    'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize'
    'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons'
    'SOFTWARE\Microsoft\Notepad'
    'SOFTWARE\Microsoft\PolicyManager\default\WiFi'
    'SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Wpad'
    'SYSTEM\CurrentControlSet\Services\USB'
    'SOFTWARE\Microsoft\Office'
    'SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense'
    'SOFTWARE\Microsoft\Input\Settings'
    'SOFTWARE\Microsoft\GameBar'
    'SOFTWARE\Policies'
    'SOFTWARE\CLASSES\CLSID'                     # blocking a shell extension means creating it
    'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop\NameSpace'
    'SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization'
)

function Test-KnownAbsent {
    param([string]$Path)
    foreach ($k in $KnownAbsent) {
        if ($Path -like ($k + '*')) { return $true }
    }
    return $false
}

# Services and tasks Microsoft has removed from current Windows 11 builds. The
# catalogue deliberately still names them, because the same option is correct on
# Windows 10 and on older 11 builds, and an absent one is skipped harmlessly.
# Listing them here stops them drowning out a genuine misspelling.
$RemovedServices = @(
    'p2psvc', 'PNRPsvc', 'PNRPAutoReg', 'p2pimsvc'   # peer networking, gone
    'AJRouter'                                        # AllJoyn, gone
    'Fax'                                             # fax service, gone from 11
    'Browser'                                         # Computer Browser, gone
    'spectrum', 'MixedRealityOpenXRSvc', 'SharedRealitySvc'  # WMR, removed
    'TabletInputService'                              # renamed TextInputManagementService in 11
    'dmwappushservice'                                # removed on newer builds
    'WMPNetworkSvc'                                   # goes with legacy WMP
    'RetailDemo'                                      # absent on some SKUs
    'DmEnrollmentSvc', 'PhoneSvc', 'WalletService', 'SEMgrSvc'
    'embeddedmode', 'UevAgentService', 'PeerDistSvc', 'SNMPTRAP', 'ALG'
)
$RemovedTaskFolders = @(
    '\Microsoft\Windows\Customer Experience Improvement Program\'  # trimmed to 2 tasks
    '\Microsoft\Windows\Application Experience\'                   # several removed
    '\Microsoft\Office\'                                           # only if Office installed
    '\Microsoft\Windows\Shell\FamilySafety'                        # trimmed
    '\Microsoft\Windows\PushToInstall\'
    '\Microsoft\Windows\Clip\'
    '\Microsoft\Windows\Subscription\'
    '\Microsoft\Windows\Maps\'
    '\Microsoft\Windows\Flighting\'
    '\Microsoft\Windows\SettingSync\'
    '\Microsoft\Windows\License Manager\'
    '\Microsoft\Windows\Windows Defender\'    # not visible without elevation
    '\Microsoft\Windows\AppID\'
    '\Microsoft\Windows\Sysmain\'
    '\Microsoft\Windows\DiskFootprint\'
    '\Microsoft\Windows\Speech\'
    '\Microsoft\Windows\RetailDemo\'
    '\Microsoft\XblGameSave\'
    # These exist but are ACL'd so tightly that Get-ScheduledTask returns nothing
    # for the folder at all, elevated or not. Verified: 0 visible tasks.
    '\Microsoft\Windows\UpdateOrchestrator\'
    '\Microsoft\Windows\WindowsUpdate\Refresh'
    '\Microsoft\Windows\WindowsUpdate\sih'                       # removed from current builds
    '\Microsoft\Windows\InstallService\SmartRetry'            # replaced by RestoreDevice
)

function Test-KnownRemovedService {
    param([string]$Name)
    foreach ($s in $RemovedServices) { if ($Name -ieq $s) { return $true } }
    return $false
}

function Test-KnownRemovedTask {
    param([string]$Path)
    foreach ($f in $RemovedTaskFolders) { if ($Path -like ($f + '*')) { return $true } }
    return $false
}

function Bump { param($k) if (-not $stats.ContainsKey($k)) { $stats[$k] = 0 }; $stats[$k]++ }
function Flag { param($Kind, $Id, $What, $Why)
    [void]$suspect.Add([pscustomobject]@{ Kind = $Kind; Id = $Id; What = $What; Why = $Why })
}
function Note { param($Kind, $Id, $What, $Why)
    [void]$absent.Add([pscustomobject]@{ Kind = $Kind; Id = $Id; What = $What; Why = $Why })
}

# ------------------------------------------------------------------ registry
Write-Host '  registry...' -ForegroundColor DarkGray
foreach ($vm in $script:AllTweaks) {
    foreach ($a in (Get-TweakDef $vm.Id).Actions) {
        if ($a.kind -ne 'reg') { continue }
        Bump 'reg'
        $regPath = Convert-HiveToPath $a.hive $a.path
        $cur = Get-RegValue $regPath $a.name

        if ($cur.Exists) { Bump 'reg.valuePresent'; continue }

        # A policy key legitimately does not exist until the policy is set, and
        # plenty of non-policy values are simply not present on a given build.
        $isPolicy = ($a.path -match '\\Policies\\|^SOFTWARE\\Policies|\\CurrentVersion\\Policies')
        if ($cur.KeyExists) {
            Bump 'reg.keyOnly'
            Note 'reg' $vm.Id "$($a.hive)\$($a.path) -> $($a.name)" 'key exists, value not set yet'
            continue
        }
        Bump 'reg.noKey'
        # Creating one new leaf key is completely normal: plenty of Windows
        # settings only materialise once you change them. What suggests a wrong
        # path is several levels missing at once, so measure how deep the
        # existing part of the path goes before deciding.
        $segs = @($a.path.Split([char]92) | Where-Object { $_ })
        $exists = 0
        $probe = (Convert-HiveToPath $a.hive '').TrimEnd([char]92)
        foreach ($seg in $segs) {
            $probe = "$probe\$seg"
            if (Test-Path -LiteralPath $probe) { $exists++ } else { break }
        }
        $missing = $segs.Count - $exists
        if (Test-KnownAbsent $a.path) {
            $script:baselined++
            Note 'reg' $vm.Id "$($a.hive)\$($a.path)" 'known correct, Windows creates it on demand'
        } elseif ($isPolicy -or $missing -le 1) {
            $why = if ($isPolicy) { 'policy key, absent until set' }
                   else { "leaf key not created yet ($exists of $($segs.Count) levels exist)" }
            Note 'reg' $vm.Id "$($a.hive)\$($a.path)" $why
        } else {
            Flag 'reg' $vm.Id "$($a.hive)\$($a.path)" `
                "$missing path levels missing - only $exists of $($segs.Count) exist, so this path may be wrong"
        }
    }
}

# ------------------------------------------------------------------ services
Write-Host '  services...' -ForegroundColor DarkGray
$svcCache = Get-ServiceCache
foreach ($vm in $script:AllTweaks) {
    foreach ($a in (Get-TweakDef $vm.Id).Actions) {
        if ($a.kind -ne 'service') { continue }
        Bump 'service'
        if ($svcCache.ContainsKey("$($a.name)".ToLower())) { Bump 'service.present'; continue }
        # Per-user services appear with a random suffix, so check the stem too.
        $stem = "$($a.name)".ToLower()
        $hit = $false
        foreach ($k in $svcCache.Keys) { if ($k -like ($stem + '_*')) { $hit = $true; break } }
        if ($hit) { Bump 'service.present'; continue }
        if (Test-KnownRemovedService $a.name) {
            Bump 'service.removedByMs'
            Note 'service' $vm.Id $a.name 'removed from current Windows builds, kept for older ones'
        } else {
            Flag 'service' $vm.Id $a.name 'no service with that name on this PC'
        }
    }
}

# ------------------------------------------------------------------ tasks
Write-Host '  scheduled tasks...' -ForegroundColor DarkGray
$taskCache = Get-TaskCache
foreach ($vm in $script:AllTweaks) {
    foreach ($a in (Get-TweakDef $vm.Id).Actions) {
        if ($a.kind -ne 'task') { continue }
        foreach ($t in $a.tasks) {
            Bump 'task'
            if ($taskCache.ContainsKey("$t".ToLower())) { Bump 'task.present'; continue }
            # Third-party tasks depend on software being installed.
            $thirdParty = ($t -notlike '\Microsoft\*')
            if ($thirdParty) {
                Note 'task' $vm.Id $t 'third-party task, software not installed'
            } elseif (Test-KnownRemovedTask $t) {
                Bump 'task.removedByMs'
                Note 'task' $vm.Id $t 'trimmed from current builds, or hidden without elevation'
            } else {
                Flag 'task' $vm.Id $t 'Microsoft task not present on this build'
            }
        }
    }
}

# ------------------------------------------------------------------ features
if ($elevated) {
    Write-Host '  windows features and capabilities (slow)...' -ForegroundColor DarkGray
    $featCache = Get-FeatureCache
    $capCache = Get-CapabilityCache
    foreach ($vm in $script:AllTweaks) {
        foreach ($a in (Get-TweakDef $vm.Id).Actions) {
            if ($a.kind -eq 'feature') {
                Bump 'feature'
                if ($featCache.ContainsKey("$($a.name)".ToLower())) { Bump 'feature.present'; continue }
                Flag 'feature' $vm.Id $a.name 'no optional feature with that name'
            } elseif ($a.kind -eq 'capability') {
                Bump 'capability'
                if ($capCache.ContainsKey("$($a.name)".ToLower())) { Bump 'capability.present'; continue }
                # Capability names carry a language tag that varies by install.
                $stem = ("$($a.name)" -split '~')[0].ToLower()
                $hit = $false
                foreach ($k in $capCache.Keys) { if ($k -like ($stem + '*')) { $hit = $true; break } }
                if ($hit) { Note 'capability' $vm.Id $a.name 'present with a different language tag' }
                else { Flag 'capability' $vm.Id $a.name 'no capability with that name' }
            }
        }
    }
} else {
    Write-Host '  windows features and capabilities: SKIPPED, needs elevation' -ForegroundColor Yellow
    Write-Host '  note: without elevation some scheduled tasks are also invisible, so task' -ForegroundColor Yellow
    Write-Host '        suspects may be a permissions artefact rather than a wrong name.' -ForegroundColor Yellow
}

# ------------------------------------------------------------------ appx
Write-Host '  app packages...' -ForegroundColor DarkGray
$inst = Get-AppxCache
$prov = Get-AppxProvisionedCache
$allNames = New-Object Collections.ArrayList
foreach ($k in $inst.Keys) { [void]$allNames.Add($k) }
foreach ($k in $prov.Keys) { if (-not $allNames.Contains($k)) { [void]$allNames.Add($k) } }
foreach ($vm in $script:AllTweaks) {
    foreach ($a in (Get-TweakDef $vm.Id).Actions) {
        if ($a.kind -ne 'appx') { continue }
        foreach ($pkg in $a.packages) {
            Bump 'appx'
            if ($allNames.Contains("$pkg".ToLower())) { Bump 'appx.present'; continue }
            Note 'appx' $vm.Id $pkg 'not installed on this PC'
        }
    }
}

# ------------------------------------------------------------------ option states
Write-Host '  option states...' -ForegroundColor DarkGray
$byState = @{}
$unknown = New-Object Collections.ArrayList
foreach ($vm in $script:AllTweaks) {
    $st = Get-TweakState (Get-TweakDef $vm.Id)
    if (-not $byState.ContainsKey($st)) { $byState[$st] = 0 }
    $byState[$st]++
    if ($st -eq 'Unknown') { [void]$unknown.Add($vm.Id) }
}

# ------------------------------------------------------------------ report
Write-Host ''
Write-Host '  identifiers checked' -ForegroundColor Cyan
foreach ($k in ($stats.Keys | Sort-Object)) {
    Write-Host ('    {0,-22} {1}' -f $k, $stats[$k])
}

Write-Host ''
Write-Host '  option state on this PC' -ForegroundColor Cyan
foreach ($k in ($byState.Keys | Sort-Object)) {
    Write-Host ('    {0,-22} {1}' -f $k, $byState[$k])
}

Write-Host ''
if ($suspect.Count -eq 0) {
    Write-Host '  NO SUSPECT IDENTIFIERS' -ForegroundColor Green
} else {
    Write-Host ("  {0} SUSPECT identifiers - check these" -f $suspect.Count) -ForegroundColor Red
    foreach ($g in ($suspect | Group-Object Kind | Sort-Object Name)) {
        Write-Host ''
        Write-Host ("    == {0} ({1})" -f $g.Name, $g.Count) -ForegroundColor Yellow
        foreach ($x in ($g.Group | Sort-Object Id)) {
            Write-Host ('      {0,-34} {1}' -f $x.Id, $x.What)
            Write-Host ('      {0,-34} {1}' -f '', $x.Why) -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
Write-Host ("  {0} identifiers absent for expected reasons" -f $absent.Count) -ForegroundColor DarkGray
Write-Host ("  {0} of those are baselined registry paths known to be correct" -f $baselined) -ForegroundColor DarkGray
if ($ShowAll) {
    foreach ($g in ($absent | Group-Object Kind | Sort-Object Name)) {
        Write-Host ''
        Write-Host ("    == {0} ({1})" -f $g.Name, $g.Count) -ForegroundColor DarkGray
        foreach ($x in ($g.Group | Sort-Object Id)) {
            Write-Host ('      {0,-34} {1}  ({2})' -f $x.Id, $x.What, $x.Why) -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
if ($unknown.Count -gt 0) {
    Write-Host ("  {0} options read Unknown, meaning their state could not be determined:" -f $unknown.Count) -ForegroundColor Yellow
    foreach ($u in $unknown) { Write-Host ("      $u") -ForegroundColor DarkGray }
    Write-Host '  Unknown is expected for command-probe options and for anything not present on this build.' -ForegroundColor DarkGray
}
Write-Host ''
exit ([math]::Min($suspect.Count, 250))
