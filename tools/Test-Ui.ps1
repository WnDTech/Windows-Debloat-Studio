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

# Smoke test: build interop, parse both XAML files, resolve every x:Name that
# Ui.ps1 asks for, and exercise the filter/preset logic without a message loop.
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

. (Join-Path $Root 'src\Modules\Core.ps1')
Initialize-Paths -Root $Root
. (Join-Path $Root 'src\Modules\Engine.ps1')
. (Join-Path $Root 'src\Modules\Journal.ps1')
. (Join-Path $Root 'src\Modules\Catalog.ps1')
. (Join-Path $Root 'src\Modules\Presets.ps1')
. (Join-Path $Root 'src\Modules\License.ps1')
. (Join-Path $Root 'src\Modules\Report.ps1')
. (Join-Path $Root 'src\Modules\Ui.ps1')

function Say { param($m, $c = 'Gray') Write-Host ("  " + $m) -ForegroundColor $c }

$fail = 0

Say 'interop...' 'Cyan'
Initialize-Interop
Say 'ok' 'Green'

Say 'application + theme...' 'Cyan'
$app = [Windows.Application]::Current
if ($null -eq $app) { $app = New-Object Windows.Application }
$theme = Import-XamlFile (Join-Path $Root 'src\Gui\Theme.xaml')
$app.Resources.MergedDictionaries.Add($theme)
Say ("theme keys: " + $theme.Keys.Count) 'Green'

Say 'main window...' 'Cyan'
$win = Import-XamlFile (Join-Path $Root 'src\Gui\MainWindow.xaml')
$script:Ui = @{ Win = $win }
Say 'ok' 'Green'

# every name Ui.ps1 resolves
$names = @(
    'BtnMin', 'BtnMax', 'BtnClose', 'BtnHelp', 'RailTop', 'RailCats',
    'TxtSearch', 'SearchHint', 'BtnSearchClear',
    'TglSafe', 'TglModerate', 'TglAggressive', 'ChkHideDone', 'TxtVisible', 'Toolbar',
    'BtnBulkEnable', 'BtnBulkDisable', 'BtnBulkRevert', 'BtnBulkClear',
    'LstTweaks', 'EmptyState', 'ViewPresets', 'ViewOverview', 'OverviewHost',
    'LstPresets', 'BtnPresetSaveCurrent', 'BtnPresetImport',
    'BtnClearAll', 'BtnSavePreset', 'BtnUndoAll', 'BtnApply',
    'OvConfirm', 'TxtConfirmTitle', 'TxtConfirmSummary', 'ConfirmWarn', 'TxtConfirmWarn',
    'LstChanges', 'ChkRestorePoint', 'TxtRestoreNote', 'ChkRestartExplorer', 'TxtExplorerNote',
    'BtnConfirmCancel', 'BtnConfirmApply',
    'ChkAllUsers', 'TxtAllUsersNote', 'ChkDryRun', 'BtnRescan', 'BtnRestartNow',
    'BtnTier', 'OvLicense', 'TxtLicDetail', 'TxtLicFeatures', 'TxtLicKey', 'TxtLicMachine',
    'LicKeyBlock', 'LicActiveBlock', 'BtnLicActivate', 'BtnLicRecheck', 'BtnLicRemove',
    'BtnLicBuy', 'BtnLicBuyTech', 'BtnLicPortal', 'BtnLicClose',
    'BtnLicSource', 'BtnLicTerms', 'LicHaveBlock', 'TxtLicHaveHead', 'TxtLicHave',
    'LicNextBlock', 'TxtLicNextHead', 'TxtLicNextWho', 'BtnReport',
    'OvBusy', 'PbProgress', 'LogScroll', 'LstLog', 'TxtBusyFoot', 'BtnBusySaveLog', 'BtnBusyClose',
    'OvSave', 'TxtSaveSummary', 'TxtPresetName', 'TxtPresetSummary', 'TxtPresetDetail',
    'BtnSaveCancel', 'BtnSaveOk',
    'OvHelp', 'HelpHost', 'BtnHelpClose',
    'Toast', 'ToastIcon', 'ToastText',
    'BtnRestorePoint', 'BtnOpenLogs', 'TxtJournal'
)
Say 'resolving named elements...' 'Cyan'
$missing = @()
foreach ($n in $names) { if ($null -eq $win.FindName($n)) { $missing += $n } }
if ($missing.Count) { Say ('MISSING: ' + ($missing -join ', ')) 'Red'; $fail++ }
else { Say ("all $($names.Count) elements found") 'Green' }

Say 'data templates...' 'Cyan'
foreach ($t in @('TweakTemplate', 'PresetTemplate', 'RailTemplate', 'ChangeTemplate', 'LogTemplate')) {
    if ($null -eq $win.TryFindResource($t)) { Say "MISSING template $t" 'Red'; $fail++ }
}
Say 'ok' 'Green'

Say 'catalogue + view models...' 'Cyan'
$script:Shell = New-Object Debloat.ShellVM
$win.DataContext = $script:Shell
$script:LogItems = New-Object Collections.ObjectModel.ObservableCollection[object]
$win.FindName('LstLog').ItemsSource = $script:LogItems
Import-Catalog | Out-Null
Say ("$($script:AllTweaks.Count) tweaks, $($script:Categories.Count) categories") 'Green'

Say 'presets...' 'Cyan'
$p = Import-Presets
Say ("$($p.Count) presets") 'Green'

Say 'rail + filter...' 'Cyan'
$win.FindName('RailCats').ItemsSource = @($script:Categories | ForEach-Object { $_.Vm })
$script:ActiveCategory = $script:Categories[0]
$script:View = 'options'
Update-Filter
Say ("filter shows " + @($win.FindName('LstTweaks').ItemsSource).Count + " items") 'Green'

Say 'search across all categories...' 'Cyan'
$win.FindName('TxtSearch').Text = 'copilot'
Update-Filter
Say ("search 'copilot' -> " + @($win.FindName('LstTweaks').ItemsSource).Count + " items") 'Green'
$win.FindName('TxtSearch').Text = ''
Update-Filter

Say 'staging a preset...' 'Cyan'
$rec = $p | Where-Object { $_.Id -eq 'builtin.recommended' }
Set-PresetSelections $rec.Id | Out-Null
Update-Counts
Say ("staged: " + $script:Shell.PendingTotal + " (" + $script:Shell.PendingText + ")") 'Green'
if ($script:Shell.PendingTotal -lt 50) { Say 'expected many more staged' 'Red'; $fail++ }

Say 'confirm sheet...' 'Cyan'
Show-ConfirmSheet
$rows = @($win.FindName('LstChanges').ItemsSource)
Say ("confirm rows: " + $rows.Count) 'Green'
Say ("summary: " + $win.FindName('TxtConfirmSummary').Text.Substring(0, 90) + '...') 'DarkGray'
if ($rows.Count -ne $script:Shell.PendingTotal) { Say 'row count mismatch' 'Red'; $fail++ }

Say 'overview + help pages...' 'Cyan'
Build-Overview
Build-Help
Say ("overview cards: " + $win.FindName('OverviewHost').Children.Count +
    ", help blocks: " + $win.FindName('HelpHost').Children.Count) 'Green'

Say 'save + reload a user preset...' 'Cyan'
$sel = @{}
foreach ($vm in (Get-StagedTweaks)) { $sel[$vm.Id] = $vm.State }
$f = Save-UserPreset -Name 'ZZ Smoke Test' -Summary 'temporary' -Detail '' -Selections $sel
$p2 = Import-Presets
$mine = $p2 | Where-Object { $_.Name -eq 'ZZ Smoke Test' }
if ($null -eq $mine) { Say 'saved preset did not reload' 'Red'; $fail++ }
else {
    $back = Get-PresetSelections $mine.Id
    Say ("round-tripped " + $back.Count + " selections, origin=" + $mine.Origin) 'Green'
    if ($back.Count -ne $sel.Count) { Say 'selection count changed on round trip' 'Red'; $fail++ }
}
Remove-UserPreset -Path $f

Say 'licence gating on a free install...' 'Cyan'
Import-LicenseConfig | Out-Null
$ent = Get-Entitlement -Refresh
Say ("tier=" + $ent.TierId + "  paid=" + $ent.IsPaid) 'Green'
$locked = @($p2 | Where-Object { $_.Tier -eq 'pro' })
Say ("presets marked pro: " + $locked.Count) 'Green'
if ($ent.IsPaid) {
    Say 'this machine has a licence, so lock state is not asserted' 'Yellow'
} else {
    if ($locked.Count -ne 8) { Say "expected 8 pro presets, found $($locked.Count)" 'Red'; $fail++ }
    $tech = @($p2 | Where-Object { $_.Tier -eq 'technician' })
    Say ("presets marked technician: " + $tech.Count) 'Green'
    if ($tech.Count -ne 3) { Say "expected 3 technician presets, found $($tech.Count)" 'Red'; $fail++ }

    # Every gated feature, not just the original four.
    $all = @($script:LicCfg.features.PSObject.Properties.Name)
    foreach ($f in $all) {
        if (Test-Feature $f) { Say "feature $f should be locked on free" 'Red'; $fail++ }
    }
    Say ("all $($all.Count) paid features correctly locked") 'Green'

    # A locked preset must point at the tier that actually unlocks it.
    Sync-LicenseUi
    foreach ($pv in $p2) {
        if (-not $pv.IsLocked) { continue }
        $want = if ($pv.Tier -eq 'technician') { 'Technician' } else { 'Pro' }
        if ($pv.LockTierName -ne $want) {
            Say "preset '$($pv.Name)' is $($pv.Tier) but offers $($pv.LockTierName)" 'Red'; $fail++
        }
    }
    Say 'every locked preset names the tier that unlocks it' 'Green'
}

Say 'clearing selections...' 'Cyan'
Clear-AllSelections
Say ("pending now: " + $script:Shell.PendingTotal) 'Green'

Write-Host ''
if ($fail -eq 0) { Write-Host '  SMOKE TEST PASSED' -ForegroundColor Green }
else { Write-Host "  SMOKE TEST: $fail problem(s)" -ForegroundColor Red }
exit $fail
