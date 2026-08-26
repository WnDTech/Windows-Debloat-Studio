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

# End-to-end test of capture -> apply -> revert -> global undo using only
# harmless per-user registry options, in an isolated journal.
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

# isolate the journal so the real one is untouched
$script:Paths.Journal = Join-Path $env:TEMP ('journal-test-' + [guid]::NewGuid().ToString('N') + '.jsonl')
$script:Journal = $null

$pass = 0; $fail = 0
function Check {
    param([string]$What, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $What) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  FAIL  " + $What + "  " + $Detail) -ForegroundColor Red }
}

function RegNow {
    param($Action)
    Get-RegValue (Convert-HiveToPath $Action.hive $Action.path) $Action.name
}

# ------------------------------------------------------------------ subject A
$idA = 'ui.taskbar.seconds'
$defA = Get-TweakDef $idA
$actA = $defA.Actions[0]
$origA = RegNow $actA
Write-Host ''
Write-Host "A) $($defA.Name)" -ForegroundColor Cyan
Write-Host ("   original: exists=$($origA.Exists) value=$($origA.Value)") -ForegroundColor DarkGray

# --- apply Disable
$cap = Get-ActionCapture $actA
Add-JournalEntry -TweakId $idA -TweakName $defA.Name -Direction 'Disable' -Index 0 -Capture $cap
$notes = Set-ActionState -Action $actA -Direction 'Disable'
$now = RegNow $actA
Check 'Disable writes the disable value' ($now.Exists -and [int]$now.Value -eq 0) "got exists=$($now.Exists) value=$($now.Value)"
Check 'state reads back as Disabled' ((Get-ActionState $actA) -eq 'Disabled') (Get-ActionState $actA)
Check 'journal recorded the option' (Test-TweakTouched $idA)
Check 'journal counts one option' ((Get-JournalTweakCount) -eq 1) (Get-JournalTweakCount)

# --- apply Enable on top, so the journal now has two entries for this option
$cap2 = Get-ActionCapture $actA
Add-JournalEntry -TweakId $idA -TweakName $defA.Name -Direction 'Enable' -Index 0 -Capture $cap2
Set-ActionState -Action $actA -Direction 'Enable' | Out-Null
$now = RegNow $actA
Check 'Enable writes the enable value' ($now.Exists -and [int]$now.Value -eq 1) "value=$($now.Value)"
Check 'state reads back as Enabled' ((Get-ActionState $actA) -eq 'Enabled') (Get-ActionState $actA)
Check 'journal still counts one option' ((Get-JournalTweakCount) -eq 1) (Get-JournalTweakCount)

# --- Revert must use the OLDEST capture, i.e. the pre-app state
$caps = @(Get-TweakOriginalCaptures $idA)
Check 'revert plan has one action' ($caps.Count -eq 1) "count=$($caps.Count)"
Check 'revert uses the pre-app capture' ([bool]$caps[0].Capture.existed -eq [bool]$origA.Exists) `
    "capture.existed=$($caps[0].Capture.existed) orig.Exists=$($origA.Exists)"
Restore-ActionCapture $caps[0].Capture | Out-Null
$now = RegNow $actA
Check 'revert restored the original existence' ($now.Exists -eq $origA.Exists) "exists=$($now.Exists)"
if ($origA.Exists) {
    Check 'revert restored the original value' ("$($now.Value)" -eq "$($origA.Value)") "now=$($now.Value) orig=$($origA.Value)"
}
Remove-JournalTweak $idA
Check 'journal entry removed after revert' (-not (Test-TweakTouched $idA))
Check 'journal now empty' ((Get-JournalTweakCount) -eq 0) (Get-JournalTweakCount)

# ------------------------------------------------------------------ global undo
Write-Host ''
Write-Host 'B) global undo across three options' -ForegroundColor Cyan
$ids = @('ui.taskbar.seconds', 'ui.explorer.fullpath', 'priv.clipboardhistory')
$before = @{}
foreach ($id in $ids) {
    $d = Get-TweakDef $id
    $before[$id] = @()
    $k = 0
    foreach ($a in $d.Actions) {
        $before[$id] += (RegNow $a)
        $c = Get-ActionCapture $a
        Add-JournalEntry -TweakId $id -TweakName $d.Name -Direction 'Disable' -Index $k -Capture $c
        Set-ActionState -Action $a -Direction 'Disable' | Out-Null
        $k++
    }
}
Check 'journal counts three options' ((Get-JournalTweakCount) -eq 3) (Get-JournalTweakCount)

$changed = 0
foreach ($id in $ids) {
    foreach ($a in (Get-TweakDef $id).Actions) {
        if ((Get-ActionState $a) -eq 'Disabled') { $changed++ }
    }
}
Check 'all three now read Disabled' ($changed -ge 3) "disabled actions=$changed"

# reload the journal from disk to prove the capture survives JSON round-tripping
$script:Journal = $null
$plan = Get-JournalUndoPlan
Check 'undo plan rebuilt from the file on disk' ($plan.Count -ge 3) "plan=$($plan.Count)"
foreach ($e in $plan) { Restore-ActionCapture $e.capture | Out-Null }

$restored = 0; $wrong = @()
foreach ($id in $ids) {
    $d = Get-TweakDef $id
    for ($k = 0; $k -lt $d.Actions.Count; $k++) {
        $a = $d.Actions[$k]
        $now = RegNow $a
        $orig = $before[$id][$k]
        if ($now.Exists -eq $orig.Exists -and "$($now.Value)" -eq "$($orig.Value)") { $restored++ }
        else { $wrong += "$id[$k]: now(exists=$($now.Exists),v=$($now.Value)) orig(exists=$($orig.Exists),v=$($orig.Value))" }
    }
}
Check 'every value restored exactly' ($wrong.Count -eq 0) ($wrong -join ' ; ')
Write-Host ("   restored $restored action values") -ForegroundColor DarkGray

Clear-Journal
Check 'journal cleared' ((Get-JournalTweakCount) -eq 0)

# ------------------------------------------------------------------ command probes
Write-Host ''
Write-Host 'C) command-kind probes return a usable state' -ForegroundColor Cyan
$bad = @()
foreach ($vm in $script:AllTweaks) {
    foreach ($a in (Get-TweakDef $vm.Id).Actions) {
        if ($a.kind -ne 'command') { continue }
        $s = Get-ActionState $a
        if ($s -notin @('Enabled', 'Disabled', 'Mixed', 'Unknown')) { $bad += "$($vm.Id) -> '$s'" }
    }
}
Check 'all command probes return a valid state' ($bad.Count -eq 0) ($bad -join ' ; ')

# ------------------------------------------------------------------ capture every action kind
Write-Host ''
Write-Host 'D) capture works for every action in the catalogue' -ForegroundColor Cyan
$capFail = @()
$kinds = @{}
foreach ($vm in $script:AllTweaks) {
    foreach ($a in (Get-TweakDef $vm.Id).Actions) {
        $kinds[$a.kind] = 1 + [int]$kinds[$a.kind]
        try {
            $c = Get-ActionCapture $a
            $json = $c | ConvertTo-Json -Depth 12 -Compress
            $rt = $json | ConvertFrom-Json
            if ($rt.kind -ne $a.kind) { $capFail += "$($vm.Id): kind lost in round trip" }
        } catch {
            $capFail += "$($vm.Id) [$($a.kind)]: $($_.Exception.Message)"
        }
    }
}
Check 'every action captures and round-trips through JSON' ($capFail.Count -eq 0) (@($capFail)[0..2] -join ' ; ')
Write-Host ('   action kinds: ' + (($kinds.GetEnumerator() | Sort-Object Name |
            ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '  ')) -ForegroundColor DarkGray

# ------------------------------------------------------------------ dry run
Write-Host ''
Write-Host 'E) dry run describes without writing' -ForegroundColor Cyan
$idE = 'ui.taskbar.seconds'
$defE = Get-TweakDef $idE
$actE = $defE.Actions[0]
$beforeE = RegNow $actE

$dryNotes = @(Set-ActionState -Action $actE -Direction 'Disable' -DryRun)
$afterE = RegNow $actE
Check 'dry run produced notes' ($dryNotes.Count -gt 0) "notes=$($dryNotes.Count)"
Check 'dry run notes say "would"' ([bool]($dryNotes -match 'would')) ($dryNotes -join ' ; ')
Check 'dry run changed nothing' (($afterE.Exists -eq $beforeE.Exists) -and
    ("$($afterE.Value)" -eq "$($beforeE.Value)")) `
    "before(exists=$($beforeE.Exists),v=$($beforeE.Value)) after(exists=$($afterE.Exists),v=$($afterE.Value))"

$jBefore = Get-JournalTweakCount
Check 'dry run wrote no journal entry' ((Get-JournalTweakCount) -eq $jBefore)

$dryAll = 0; $dryBad = @()
foreach ($vm in $script:AllTweaks) {
    foreach ($a in (Get-TweakDef $vm.Id).Actions) {
        foreach ($d in @('Enable', 'Disable')) {
            try { $n = @(Set-ActionState -Action $a -Direction $d -DryRun); $dryAll += $n.Count }
            catch { $dryBad += "$($vm.Id) [$($a.kind)] $d : $($_.Exception.Message)" }
        }
    }
}
Check 'dry run works for every action and direction' ($dryBad.Count -eq 0) (@($dryBad)[0..2] -join ' ; ')
Write-Host ("   described $dryAll planned changes across the whole catalogue") -ForegroundColor DarkGray

# ------------------------------------------------------------------ all users
Write-Host ''
Write-Host 'F) all-accounts registry targeting' -ForegroundColor Cyan
$profiles = @(Get-UserProfileList)
$others = @($profiles | Where-Object { -not $_.IsCurrent })
Write-Host ("   profiles found: " + (($profiles | ForEach-Object { $_.Label }) -join ', ')) -ForegroundColor DarkGray

Check 'profile list always contains the current account' `
    (@($profiles | Where-Object { $_.IsCurrent }).Count -eq 1)

if (-not (Test-IsAdmin)) {
    Write-Host '   SKIP: needs elevation to load another profile hive' -ForegroundColor Yellow
} elseif ($others.Count -eq 0) {
    Write-Host '   SKIP: no other profiles on this PC' -ForegroundColor Yellow
} else {
    $sess = Open-UserHiveSession
    Check 'hive session opened at least one extra profile' ($sess.Targets.Count -ge 2) `
        "targets=$($sess.Targets.Count)"

    $tg = @(Get-RegActionTargets $actE)
    Check 'a HKCU action now targets every profile' ($tg.Count -eq $sess.Targets.Count) `
        "action targets=$($tg.Count) session targets=$($sess.Targets.Count)"

    $hklm = $null
    foreach ($vm in $script:AllTweaks) {
        foreach ($a in (Get-TweakDef $vm.Id).Actions) {
            if ($a.kind -eq 'reg' -and $a.hive -eq 'HKLM') { $hklm = $a; break }
        }
        if ($hklm) { break }
    }
    Check 'a HKLM action still targets one place only' (@(Get-RegActionTargets $hklm).Count -eq 1)

    $capMulti = Get-ActionCapture $actE
    Check 'capture records one entry per profile' (@($capMulti.targets).Count -eq $tg.Count) `
        "capture targets=$(@($capMulti.targets).Count)"
    Check 'each capture entry names its profile' `
        (@($capMulti.targets | Where-Object { $_.sid }).Count -eq @($capMulti.targets).Count)

    # write to every profile, then put them all back
    $pre = @{}
    foreach ($t in $tg) { $pre[$t.Sid] = (Get-RegValue (Join-RegPath $t.Root $actE.path) $actE.name) }
    Set-ActionState -Action $actE -Direction 'Disable' | Out-Null
    $wrote = 0
    foreach ($t in $tg) {
        $v = Get-RegValue (Join-RegPath $t.Root $actE.path) $actE.name
        if ($v.Exists -and [int]$v.Value -eq 0) { $wrote++ }
    }
    Check 'the value landed in every profile' ($wrote -eq $tg.Count) "wrote=$wrote of $($tg.Count)"

    $json = $capMulti | ConvertTo-Json -Depth 12 -Compress
    Close-UserHiveSession | Out-Null
    # restore from the JSON form, with the session closed, exactly as an undo would
    Restore-ActionCapture ($json | ConvertFrom-Json) | Out-Null

    $sess2 = Open-UserHiveSession
    $ok = 0
    foreach ($t in (Get-RegActionTargets $actE)) {
        $v = Get-RegValue (Join-RegPath $t.Root $actE.path) $actE.name
        $o = $pre[$t.Sid]
        if ($null -eq $o) { continue }
        if ($v.Exists -eq $o.Exists -and "$($v.Value)" -eq "$($o.Value)") { $ok++ }
    }
    Close-UserHiveSession | Out-Null
    Check 'undo restored every profile from the JSON capture' ($ok -eq $tg.Count) "restored=$ok of $($tg.Count)"
}

# ------------------------------------------------------------------ multi-target without elevation
# reg.exe load/unload needs admin, but everything built on top of it does not.
# The per-user Classes hive is a genuinely separate, writable store already
# mounted under HKEY_USERS, so it stands in for a second profile here.
Write-Host ''
Write-Host 'G) multi-target write and restore (synthetic second hive)' -ForegroundColor Cyan
$mySid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
$classesSid = "$mySid" + '_Classes'
if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$classesSid")) {
    Write-Host '   SKIP: the per-user Classes hive is not mounted' -ForegroundColor Yellow
} else {
    $r = Resolve-HiveRoot -Sid $classesSid -NtUser $null
    Check 'Resolve-HiveRoot finds an already-mounted hive' ($null -ne $r -and -not $r.Mounted) "root=$($r.Root)"

    # stand up a synthetic two-profile session
    $script:HiveSession = [pscustomobject]@{
        Targets = @(
            [pscustomobject]@{ Sid = 'current'; Label = 'this account'; NtUser = $null; Root = 'HKCU:' },
            [pscustomobject]@{ Sid = $classesSid; Label = 'second hive'; NtUser = $null; Root = $r.Root }
        )
        Mounted = @(); Notes = @()
    }

    $actG = (Get-TweakDef 'ui.taskbar.seconds').Actions[0]
    $tg = @(Get-RegActionTargets $actG)
    Check 'action fans out to both targets' ($tg.Count -eq 2) "targets=$($tg.Count)"

    $pre = @{}
    foreach ($t in $tg) { $pre[$t.Sid] = (Get-RegValue (Join-RegPath $t.Root $actG.path) $actG.name) }
    Check 'second hive starts without the value' (-not $pre[$classesSid].Exists)

    $capG = Get-ActionCapture $actG
    Check 'capture holds both targets' (@($capG.targets).Count -eq 2)

    Set-ActionState -Action $actG -Direction 'Disable' | Out-Null
    $hit = 0
    foreach ($t in $tg) {
        $v = Get-RegValue (Join-RegPath $t.Root $actG.path) $actG.name
        if ($v.Exists -and [int]$v.Value -eq 0) { $hit++ }
    }
    Check 'the value landed in both hives' ($hit -eq 2) "wrote=$hit of 2"

    # restore from JSON with the session torn down, exactly as an undo would
    $jsonG = $capG | ConvertTo-Json -Depth 12 -Compress
    $script:HiveSession = $null
    Restore-ActionCapture ($jsonG | ConvertFrom-Json) | Out-Null

    $back = 0
    $rootMap = @{ 'current' = 'HKCU:'; $classesSid = $r.Root }
    foreach ($sid in $rootMap.Keys) {
        $v = Get-RegValue (Join-RegPath $rootMap[$sid] $actG.path) $actG.name
        $o = $pre[$sid]
        if ($v.Exists -eq $o.Exists -and "$($v.Value)" -eq "$($o.Value)") { $back++ }
    }
    Check 'undo put both hives back exactly' ($back -eq 2) "restored=$back of 2"

    # the key the test created in the second hive should be gone again
    $leftover = Get-RegValue (Join-RegPath $r.Root $actG.path) $actG.name
    Check 'nothing left behind in the second hive' (-not $leftover.Exists)
}

# ------------------------------------------------------------------ winget guard
Write-Host ''
Write-Host 'H) Store reinstall refuses a mismatched id' -ForegroundColor Cyan
$wg = Get-WingetPath
if (-not $wg) {
    Write-Host '   SKIP: winget is not installed on this PC' -ForegroundColor Yellow
} else {
    Write-Host ("   winget: $wg") -ForegroundColor DarkGray
    $good = Test-StoreIdMatches -Id '9WZDNCRFHVN5' -Expect 'Windows Calculator'
    Check 'a correct id and name is accepted' ($good.Ok) $good.Reason

    $wrongName = Test-StoreIdMatches -Id '9WZDNCRFHVN5' -Expect 'Adobe Photoshop'
    Check 'a real id with the wrong expected name is REFUSED' (-not $wrongName.Ok) $wrongName.Reason

    $wrongId = Test-StoreIdMatches -Id '000NOTAREALID' -Expect 'Windows Calculator'
    Check 'an unknown id is REFUSED' (-not $wrongId.Ok) $wrongId.Reason

    $blind = Test-StoreIdMatches -Id '9WZDNCRFHVN5' -Expect ''
    Check 'an id with no expected name is REFUSED' (-not $blind.Ok) $blind.Reason
}

# every store id in the catalogue must be well formed and carry an expected name
$badStore = @()
$storeCount = 0
foreach ($vm in $script:AllTweaks) {
    foreach ($a in (Get-TweakDef $vm.Id).Actions) {
        if ($a.kind -ne 'appx' -or -not $a.store) { continue }
        foreach ($e in $a.store.PSObject.Properties) {
            $storeCount++
            if (@($a.packages) -notcontains $e.Name) { $badStore += "$($vm.Id): store names $($e.Name) which is not in packages" }
            if ("$($e.Value.id)" -notmatch '^[0-9A-Z]{12}$') { $badStore += "$($vm.Id)/$($e.Name): id '$($e.Value.id)' is not a 12-character Store id" }
            if ([string]::IsNullOrWhiteSpace("$($e.Value.expect)")) { $badStore += "$($vm.Id)/$($e.Name): no expected name" }
        }
    }
}
Check 'every catalogue Store id is well formed' ($badStore.Count -eq 0) (@($badStore)[0..2] -join ' ; ')
Write-Host ("   $storeCount packages carry a Store id") -ForegroundColor DarkGray

$linkA = (Get-TweakDef 'app.bing.news').Actions[0]
Check 'a Store link is built for a known package' `
    ((Get-AppxStoreLink -Action $linkA -Package 'Microsoft.BingNews') -like 'ms-windows-store://pdp/?productid=*')
Check 'an unknown package has no Store id' ($null -eq (Get-AppxStoreId -Action $linkA -Package 'Not.A.Package'))

if (Test-Path $script:Paths.Journal) { Remove-Item $script:Paths.Journal -Force }

Write-Host ''
if ($fail -eq 0) { Write-Host "  ENGINE TEST PASSED  ($pass checks)" -ForegroundColor Green }
else { Write-Host "  ENGINE TEST: $fail failed, $pass passed" -ForegroundColor Red }
exit $fail
