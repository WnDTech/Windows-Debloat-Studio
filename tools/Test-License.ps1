<#
    Test-License.ps1
    ----------------
    Exercises the entitlement logic without touching the real licence state
    or contacting Polar, then makes two live unauthenticated calls to confirm
    the endpoints still behave the way the implementation assumes.

    The important assertions are the ones about what must NEVER be gated, and
    about a paid licence surviving a loss of internet access.
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
. (Join-Path $Root 'src\Modules\Core.ps1'); Initialize-Paths -Root $Root
. (Join-Path $Root 'src\Modules\Engine.ps1')
. (Join-Path $Root 'src\Modules\Journal.ps1')
. (Join-Path $Root 'src\Modules\Catalog.ps1')
. (Join-Path $Root 'src\Modules\Presets.ps1')
. (Join-Path $Root 'src\Modules\License.ps1')

$pass = 0; $fail = 0
function Check {
    param([string]$What, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $What) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  FAIL  " + $What + "  " + $Detail) -ForegroundColor Red }
}

# Redirect state to a scratch file so a developer's real licence is untouched.
$tmp = Join-Path $env:TEMP ('lic-test-' + [guid]::NewGuid().ToString('N') + '.json')
function Get-LicenseStatePath { $tmp }

Import-LicenseConfig | Out-Null
Write-Host ''
Write-Host 'A) configuration' -ForegroundColor Cyan
Check 'licensing.json loads' ($null -ne $script:LicCfg)
Check 'four gated features are described' (@($script:LicCfg.features.PSObject.Properties).Count -eq 4) `
    ("count=" + @($script:LicCfg.features.PSObject.Properties).Count)
Check 'two paid tiers exist' (@($script:LicCfg.tiers).Count -eq 2)
$configured = Test-LicenseConfigured
Write-Host ("   organisation id set: $configured") -ForegroundColor DarkGray

# ---------------------------------------------------------------- free tier
Write-Host ''
Write-Host 'B) with no licence, the free tier is intact' -ForegroundColor Cyan
Clear-LicenseState
$e = Get-Entitlement -Refresh
Check 'tier is Free' ($e.TierId -eq 'free') $e.TierId
Check 'not marked paid' (-not $e.IsPaid)

foreach ($f in @('presets.advanced', 'presets.save', 'allusers', 'winget')) {
    Check "gated: $f" (-not (Test-Feature $f))
}

# The things that must never be gated are not features at all - there is no
# entitlement check anywhere near them. Assert that by scanning the source.
$ui = Get-Content (Join-Path $Root 'src\Modules\Ui.ps1') -Raw
$eng = Get-Content (Join-Path $Root 'src\Modules\Engine.ps1') -Raw
$jrn = Get-Content (Join-Path $Root 'src\Modules\Journal.ps1') -Raw
Check 'Journal.ps1 contains no entitlement check' (-not ($jrn -match 'Test-Feature'))
Check 'the undo handler contains no entitlement check' `
    (-not ((($ui -split 'function Invoke-GlobalUndo')[1] -split 'function ')[0] -match 'Test-Feature'))
Check 'the apply loop gates nothing but winget' `
    ((($ui -split 'function Invoke-Apply')[1] -split 'function ')[0] -notmatch 'Test-Feature')
Check 'Restore-ActionCapture contains no entitlement check' `
    (-not ((($eng -split 'function Restore-ActionCapture')[1] -split "`nfunction ")[0] -match 'Test-Feature'))
$cat = Get-Content (Join-Path $Root 'src\Modules\Catalog.ps1') -Raw
Check 'the catalogue loader gates nothing' (-not ($cat -match 'Test-Feature'))

# An ordered dictionary has no Clone(), so copy it explicitly.
function Copy-State {
    param($From)
    $o = [ordered]@{}
    foreach ($k in $From.Keys) { $o[$k] = $From[$k] }
    return $o
}

# ---------------------------------------------------------------- paid tier
Write-Host ''
Write-Host 'C) an activated licence unlocks exactly four things' -ForegroundColor Cyan
$fresh = [ordered]@{
    provider = 'polar'; key = 'TEST-KEY'; activationId = 'act-1'
    tierId = 'pro'; tierName = 'Pro'; benefitId = 'ben-1'
    label = 'TESTPC (abcd1234)'; limitActivations = 3; expiresUtc = $null
    activatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    lastValidatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    lastResult = 'valid'
}
Save-LicenseState $fresh
$e = Get-Entitlement -Refresh
Check 'tier is Pro' ($e.TierId -eq 'pro') $e.TierId
Check 'marked paid' ($e.IsPaid)
Check 'status is active' ($e.Status -eq 'active') $e.Status
$unlocked = @('presets.advanced', 'presets.save', 'allusers', 'winget') |
Where-Object { Test-Feature $_ }
Check 'all four features unlocked' (@($unlocked).Count -eq 4) ("unlocked=" + @($unlocked).Count)
Check 'an unknown feature name is still denied' (-not (Test-Feature 'something.else'))

# ---------------------------------------------------------------- offline
Write-Host ''
Write-Host 'D) losing internet access does not take away what was paid for' -ForegroundColor Cyan
$off = (Copy-State $fresh)
$off.lastValidatedUtc = (Get-Date).ToUniversalTime().AddDays(-30).ToString('o')
Save-LicenseState $off
$e = Get-Entitlement -Refresh
Check '30 days offline keeps Pro' ($e.IsPaid) $e.Status
Check 'status says offline' ($e.Status -eq 'offline') $e.Status
Check 'the panel says how long ago it was checked' ($e.Detail -match '30 days ago') $e.Detail

$stale = (Copy-State $fresh)
$stale.lastValidatedUtc = (Get-Date).ToUniversalTime().AddDays(-90).ToString('o')
Save-LicenseState $stale
$e = Get-Entitlement -Refresh
Check '90 days offline falls back to Free' (-not $e.IsPaid) $e.Status
Check 'and explains why, with the allowance' ($e.Detail -match '60 day') $e.Detail

# ---------------------------------------------------------------- revoked / expired
Write-Host ''
Write-Host 'E) only a definite answer from Polar removes a licence' -ForegroundColor Cyan
$rev = (Copy-State $fresh); $rev.lastResult = 'revoked'
Save-LicenseState $rev
$e = Get-Entitlement -Refresh
Check 'a revoked key drops to Free' (-not $e.IsPaid)
Check 'and says so' ($e.Status -eq 'revoked') $e.Status

$exp = (Copy-State $fresh); $exp.expiresUtc = (Get-Date).ToUniversalTime().AddDays(-1).ToString('o')
Save-LicenseState $exp
$e = Get-Entitlement -Refresh
Check 'an expired key drops to Free' (-not $e.IsPaid)
Check 'and says so' ($e.Status -eq 'expired') $e.Status

$future = (Copy-State $fresh); $future.expiresUtc = (Get-Date).ToUniversalTime().AddDays(200).ToString('o')
Save-LicenseState $future
Check 'a key expiring in future stays Pro' ((Get-Entitlement -Refresh).IsPaid)

# ---------------------------------------------------------------- presets split
Write-Host ''
Write-Host 'F) the preset split' -ForegroundColor Cyan
$doc = Read-JsonFile (Join-Path $Root 'data\presets.json')
$free = @($doc.presets | Where-Object { $_.tier -eq 'free' })
$pro = @($doc.presets | Where-Object { $_.tier -eq 'pro' })
Check 'every preset declares a tier' ((@($free).Count + @($pro).Count) -eq @($doc.presets).Count)
Check 'three presets are free' (@($free).Count -eq 3) ("free=" + @($free).Count)
Check 'the safety escape hatch is free' `
    (@($free | Where-Object { $_.id -eq 'builtin.revert-all' }).Count -eq 1)
Check 'the starter privacy preset is free' `
    (@($free | Where-Object { $_.id -eq 'builtin.privacy-essentials' }).Count -eq 1)
Write-Host ("   free: " + (($free | ForEach-Object { $_.name }) -join ', ')) -ForegroundColor DarkGray

# ---------------------------------------------------------------- machine label
Write-Host ''
Write-Host 'G) machine label' -ForegroundColor Cyan
$lbl = Get-MachineLabel
Check 'label names this PC and a short stable hash' ($lbl -match '^\S.*\([0-9a-f]{8}\)$') $lbl
Check 'label is stable across calls' ($lbl -eq (Get-MachineLabel))

# ---------------------------------------------------------------- live endpoints
Write-Host ''
Write-Host 'H) the Polar endpoints still behave as assumed' -ForegroundColor Cyan
$saved = $script:LicCfg.organizationId
$script:LicCfg.organizationId = 'fda84e25-7b55-4d67-916d-60ead04ff61f'   # docs sample org
$r = Invoke-PolarCall -Action 'validate' -Body @{ key = 'WDS-NOT-A-REAL-KEY' }
Check 'an unknown key is a definite rejection, not a network error' ($r.Kind -eq 'rejected') `
    ("kind=" + $r.Kind + " msg=" + $r.Message)
$r2 = Invoke-PolarCall -Action 'validate' -Body @{ key = '' }
Check 'a malformed request is also a rejection' ($r2.Kind -eq 'rejected') ("kind=" + $r2.Kind)
$script:LicCfg.organizationId = $saved

$script:LicCfg.organizationId = ''
$r3 = Invoke-PolarCall -Action 'validate' -Body @{ key = 'x' }
Check 'an unconfigured build says so rather than calling out' ($r3.Kind -eq 'notconfigured') $r3.Kind
$script:LicCfg.organizationId = $saved

if (Test-Path $tmp) { Remove-Item $tmp -Force }
Write-Host ''
if ($fail -eq 0) { Write-Host "  LICENCE TEST PASSED  ($pass checks)" -ForegroundColor Green }
else { Write-Host "  LICENCE TEST: $fail failed, $pass passed" -ForegroundColor Red }
exit $fail
