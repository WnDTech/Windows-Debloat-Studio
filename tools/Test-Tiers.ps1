<#
    Test-Tiers.ps1
    --------------
    Exercises the Pro/Technician separation and the two Technician features, on
    a redirected licence file so a developer's real one is untouched.

    The unattended apply is tested in dry-run mode. That is not a compromise for
    the sake of testing: a path that writes to the registry on machines a
    technician does not own needs a way to be rehearsed, so -DryRun is a real
    feature and testing through it exercises the same selection resolution,
    ordering and reporting as a live run.
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

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
. (Join-Path $Root 'src\Modules\Core.ps1'); Initialize-Paths -Root $Root
. (Join-Path $Root 'src\Modules\Engine.ps1')
. (Join-Path $Root 'src\Modules\Journal.ps1')
. (Join-Path $Root 'src\Modules\Catalog.ps1')
. (Join-Path $Root 'src\Modules\Presets.ps1')
. (Join-Path $Root 'src\Modules\License.ps1')
. (Join-Path $Root 'src\Modules\Report.ps1')
. (Join-Path $Root 'src\Modules\Unattended.ps1')
. (Join-Path $Root 'src\Modules\Ui.ps1')

$pass = 0; $fail = 0
function Check {
    param([string]$What, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $What) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  FAIL  " + $What + "  " + $Detail) -ForegroundColor Red }
}
function Head { param($m) Write-Host ''; Write-Host "  $m" -ForegroundColor Cyan }

# Redirect licence state and the journal so nothing real is touched.
$tmp = Join-Path $env:TEMP ('tier-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
function Get-LicenseStatePath { Join-Path $tmp 'license.json' }
$script:Paths.Journal = Join-Path $tmp 'journal.jsonl'

Initialize-Interop
Import-LicenseConfig | Out-Null
Import-Catalog | Out-Null
Import-Presets | Out-Null

function Set-Tier {
    param([string]$Id)
    if ($Id -eq 'free') { Clear-LicenseState; Get-Entitlement -Refresh | Out-Null; return }
    $t = Get-Tier $Id
    Save-LicenseState ([ordered]@{
            provider = 'polar'; key = 'TEST'; activationId = 'act'
            tierId = $Id; tierName = "$($t.name)"; benefitId = 'ben'
            label = 'TESTPC (abcd1234)'; limitActivations = 3; expiresUtc = $null
            activatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            lastValidatedUtc = (Get-Date).ToUniversalTime().ToString('o')
            lastResult = 'valid'
        })
    Get-Entitlement -Refresh | Out-Null
}

# A preset touching one safe per-user option, used only in dry run.
$presetPath = Join-Path $tmp 'one.json'
$firstSafe = @($script:AllTweaks | Where-Object { $_.Risk -eq 'safe' })[0]
@{
    schema = 'debloat-preset/1'
    name = 'Tier test'
    selections = @{ "$($firstSafe.Id)" = 'Disable' }
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $presetPath -Encoding UTF8

# ---------------------------------------------------------------- separation
Head 'A) the tiers are actually different'
$pro = Get-Tier 'pro'; $tech = Get-Tier 'technician'
$techOnly = @($tech.features | Where-Object { @($pro.features) -notcontains $_ })
Check 'Technician grants strictly more than Pro' ($techOnly.Count -gt 0) ("adds " + ($techOnly -join ', '))
Check 'and includes all of Pro' (@($pro.features | Where-Object { @($tech.features) -notcontains $_ }).Count -eq 0)

# ---------------------------------------------------------------- gating
Head 'B) the two Technician features are gated'
foreach ($tier in @('free', 'pro')) {
    Set-Tier $tier
    Check "$tier cannot use the command line" (-not (Test-Feature 'cli'))
    Check "$tier cannot export a report" (-not (Test-Feature 'report'))
    Check "$tier cannot use technician presets" (-not (Test-PresetAllowed 'technician'))
}
Set-Tier 'technician'
Check 'Technician can use the command line' (Test-Feature 'cli')
Check 'Technician can export a report' (Test-Feature 'report')
Check 'Technician can use technician presets' (Test-PresetAllowed 'technician')

# ---------------------------------------------------------------- unattended
Head 'C) unattended apply, dry run'
$lines = New-Object Collections.Generic.List[string]
$res = Invoke-UnattendedApply -PresetPath $presetPath -DryRun -OnLine {
    param($t, $c) $lines.Add("$t")
}
Check 'it resolved the preset' ($res.Total -eq 1) ("total=" + $res.Total)
Check 'it reported the option as handled' ($res.Applied -eq 1) ("applied=" + $res.Applied + " failed=" + $res.Failed)
Check 'it exited clean' ($res.Code -eq 0) ("code=" + $res.Code)
Check 'it said it was a dry run' (@($lines | Where-Object { $_ -match 'DRY RUN' }).Count -eq 1)
Check 'a dry run writes no journal' (-not (Test-Path -LiteralPath $script:Paths.Journal))

Head 'D) unattended apply refuses bad input'
$missing = Invoke-UnattendedApply -PresetPath (Join-Path $tmp 'nope.json') -DryRun
Check 'a missing file is exit 3' ($missing.Code -eq 3) ("code=" + $missing.Code)

$notPreset = Join-Path $tmp 'notpreset.json'
'{ "hello": "world" }' | Set-Content -LiteralPath $notPreset -Encoding UTF8
$bad = Invoke-UnattendedApply -PresetPath $notPreset -DryRun
Check 'a file with no selections is exit 3' ($bad.Code -eq 3) ("code=" + $bad.Code)

$empty = Join-Path $tmp 'empty.json'
'{ "selections": { "no.such.option": "Disable" } }' | Set-Content -LiteralPath $empty -Encoding UTF8
$none = Invoke-UnattendedApply -PresetPath $empty -DryRun
Check 'a preset matching nothing is exit 0, not an error' ($none.Code -eq 0) ("code=" + $none.Code)

# ---------------------------------------------------------------- report
Head 'E) the hand-over report'
$out = Join-Path $tmp 'report.html'
$r = Export-ChangeReport -Path $out
Check 'it writes a file' (Test-Path -LiteralPath $out)
$html = Get-Content -LiteralPath $out -Raw
Check 'with an empty journal it says nothing was changed' ($html -match 'Nothing has been changed')
Check 'it is a complete HTML document' ($html -match '(?s)<!doctype html>.*</html>')
Check 'it names this machine' ($html -match [regex]::Escape($env:COMPUTERNAME))
Check 'an empty report says there is nothing to reverse, rather than how to' `
    (-not ($html -match 'Undo everything'))

# Now with something in the journal.
Add-JournalEntry -TweakId $firstSafe.Id -TweakName $firstSafe.Name -Direction 'Disable' -Index 0 `
    -Capture ([ordered]@{ kind = 'reg'; existed = $true; path = 'HKCU\Software\Test'; name = 'Sample'; value = 1; type = 'DWord' })
$script:Journal = $null
$r2 = Export-ChangeReport -Path $out
$html2 = Get-Content -LiteralPath $out -Raw
Check 'a journalled change appears in the report' ($r2.Count -eq 1) ("count=" + $r2.Count)
Check 'the report names the option' ($html2 -match [regex]::Escape($firstSafe.Name))
Check 'and states what the value was before' ($html2 -match 'Sample was 1')
Check 'and leads with how to reverse it' ($html2 -match 'Undo everything')
Check 'naming where the record lives, so it survives the app going away' `
    ($html2 -match 'journal\.jsonl')
Check 'HTML in a value is escaped, not injected' `
    (-not ($html2 -match '<script'))

# ---------------------------------------------------------------- safety
Head 'F) the safety net is still not gated by any of this'
$src = Get-Content (Join-Path $Root 'src\Modules\Unattended.ps1') -Raw
Check 'the unattended path contains no entitlement check' (-not ($src -match 'Test-Feature'))
Check 'and it still journals every action' ($src -match 'Add-JournalEntry')
$rep = Get-Content (Join-Path $Root 'src\Modules\Report.ps1') -Raw
Check 'the report contains no entitlement check' (-not ($rep -match 'Test-Feature'))

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fail -eq 0) { Write-Host "  TIER TEST PASSED  ($pass checks)" -ForegroundColor Green }
else { Write-Host "  TIER TEST: $fail failed, $pass passed" -ForegroundColor Red }
exit $fail
