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

param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'screens'),
    [int]$W = 1500,
    [int]$H = 950
)
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
. (Join-Path $Root 'src\Modules\Ui.ps1')

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

Initialize-Interop
$app = [Windows.Application]::Current
if ($null -eq $app) { $app = New-Object Windows.Application }
$theme = Import-XamlFile (Join-Path $Root 'src\Gui\Theme.xaml')
$app.Resources.MergedDictionaries.Add($theme)

$win = Import-XamlFile (Join-Path $Root 'src\Gui\MainWindow.xaml')
$script:Ui = @{ Win = $win }
$script:Shell = New-Object Debloat.ShellVM
$script:Shell.AdminText = 'Administrator'
$win.DataContext = $script:Shell
$script:LogItems = New-Object Collections.ObjectModel.ObservableCollection[object]
$win.FindName('LstLog').ItemsSource = $script:LogItems

Import-Catalog | Out-Null
Refresh-PresetList
Build-Help

$topItems = New-Object Collections.ObjectModel.ObservableCollection[object]
$ov = New-Object Debloat.CategoryVM; $ov.Key = 'overview'; $ov.Name = 'Start here'; $ov.Glyph = [string][char]0xE946
$topItems.Add($ov)
$pr = New-Object Debloat.CategoryVM; $pr.Key = 'presets'; $pr.Name = 'Presets'; $pr.Glyph = [string][char]0xE8FD
$topItems.Add($pr)
$win.FindName('RailTop').ItemsSource = $topItems
$win.FindName('RailCats').ItemsSource = @($script:Categories | ForEach-Object { $_.Vm })
$script:ActiveCategory = $script:Categories[0]

# Fake live states for the screenshots. Deterministic, but varied per category,
# so the readiness chart shows a real spread instead of 15 identical bars.
$catSeed = @{}
$k = 0
foreach ($c in $script:Categories) { $catSeed[$c.Key] = (2 + ($k * 7) % 9); $k++ }
$i = 0
foreach ($vm in $script:AllTweaks) {
    $seed = $catSeed[$vm.Category]
    $r = ($i * 31 + $seed * 17) % 12
    if ($r -lt $seed) { $vm.CurrentState = 'Disabled' }
    elseif ($r -lt 9) { $vm.CurrentState = 'Enabled' }
    elseif ($r -eq 9) { $vm.CurrentState = 'Mixed' }
    else { $vm.CurrentState = 'Unknown' }
    $i++
}

# Show the window well off-screen: an unrealised visual tree renders blank.
$win.WindowStartupLocation = 'Manual'
$win.Left = -20000
$win.Top = -20000
$win.Width = $W
$win.Height = $H
$win.ShowInTaskbar = $false
$win.Show()
$app.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::SystemIdle, [action] {}) | Out-Null

function Snap {
    param([string]$Name)
    $win.UpdateLayout()
    # let any expand/fade storyboard finish before capturing
    $deadline = [DateTime]::UtcNow.AddMilliseconds(450)
    while ([DateTime]::UtcNow -lt $deadline) {
        $app.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::SystemIdle, [action] {}) | Out-Null
    }
    $src = $win.Content
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($W, $H, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($src)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $path = Join-Path $OutDir ($Name + '.png')
    $fs = [IO.File]::Create($path)
    $enc.Save($fs); $fs.Close()
    Write-Output "  $Name.png"
}

# 1. options view, first category, one card expanded
Set-View 'options'
$script:Shell.SectionTitle = $script:ActiveCategory.Name
$script:Shell.SectionBlurb = $script:ActiveCategory.Blurb
Update-Filter
$list = @($win.FindName('LstTweaks').ItemsSource)
$list[1].State = 'Disable'
$list[3].State = 'Enable'
$list[4].State = 'Revert'
$list[2].IsExpanded = $true
Update-Counts
Snap '01-options'

# 2. presets view
$win.FindName('RailTop').SelectedIndex = 1
$script:Shell.SectionTitle = 'Presets'
$script:Shell.SectionBlurb = 'A preset is a named set of choices. Staging one ticks its options for you and leaves the rest alone; nothing is applied until you review and confirm.'
Set-View 'presets'
Snap '02-presets'

# 3. overview
Update-Coverage
Build-Overview
$script:Shell.SectionTitle = 'Windows Debloat Studio'
$script:Shell.SectionBlurb = 'Read this page once before you change anything.'
Set-View 'overview'
Snap '03-overview'

# 4. confirm sheet, staged from a preset
Set-View 'options'
$rec = $script:Presets | Where-Object { $_.Id -eq 'builtin.recommended' }
Set-PresetSelections $rec.Id | Out-Null
Show-ConfirmSheet
Snap '04-confirm'
$win.FindName('OvConfirm').Visibility = 'Collapsed'

# 5. busy panel with log
Open-BusyPanel -Cancellable 'Applying your changes' 'Working through 160 options. The previous state of each one is recorded before it is touched.'
$script:Shell.Progress = 42
Add-UiLog 'DISABLE  -  Connected User Experiences and Telemetry service  (Privacy & Telemetry)' 'head'
Add-UiLog '  stopped DiagTrack'
Add-UiLog '  DiagTrack start type -> Disabled'
Add-UiLog 'DISABLE  -  Widgets board and the MSN news feed  (Ads, Tips & Suggestions)' 'head'
Add-UiLog '  HKLM\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests = 0'
Add-UiLog '  could not remove Microsoft.BingNews: package is in use' 'warn'
Add-UiLog 'DISABLE  -  Compatibility Appraiser tasks  (Scheduled Tasks)' 'head'
Add-UiLog '  disabled task Microsoft Compatibility Appraiser' 'ok'
Snap '05-applying'
$win.FindName('OvBusy').Visibility = 'Collapsed'

# 5b. dry-run panel
Open-BusyPanel 'Dry run - nothing will be changed' 'Walking through 134 options and logging exactly what would happen. No registry value, service, app or task is touched.'
$script:Shell.Progress = 68
Add-UiLog 'DRY RUN. Nothing below is actually being changed.' 'warn'
Add-UiLog ''
Add-UiLog 'would also write to: this account' 
Add-UiLog 'would also write to: default profile (new accounts)'
Add-UiLog ''
Add-UiLog 'DISABLE  -  Advertising ID for personalised ads  (Privacy & Telemetry)' 'head'
Add-UiLog '  would set HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo\Enabled = 0 (DWord)  [this account]'
Add-UiLog '  would set HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo\Enabled = 0 (DWord)  [default profile (new accounts)]'
Add-UiLog '  would set HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo\DisabledByGroupPolicy = 1 (DWord)  [this account]'
Add-UiLog 'DISABLE  -  Microsoft News  (Preinstalled Apps)' 'head'
Add-UiLog '  would remove Microsoft.BingNews for this account'
Add-UiLog '  would deprovision Microsoft.BingNews for new accounts'
Add-UiLog 'DISABLE  -  Fax service  (Background Services)' 'head'
Add-UiLog '  service Fax is not on this PC, would be skipped' 'warn'
Snap '05b-dryrun'
$win.FindName('OvBusy').Visibility = 'Collapsed'

# 6. save preset dialog
Show-SavePresetDialog
$win.FindName('TxtPresetName').Text = 'My office build'
$win.FindName('TxtPresetSummary').Text = 'What we run on the shared machines in the studio'
Snap '06-savepreset'
$win.FindName('OvSave').Visibility = 'Collapsed'

# 7. help
$win.FindName('OvHelp').Visibility = 'Visible'
Snap '07-help'
$win.FindName('OvHelp').Visibility = 'Collapsed'

# 8. search results, aggressive-only filter
Clear-AllSelections
Set-View 'options'
$win.FindName('TglSafe').IsChecked = $false
$win.FindName('TglModerate').IsChecked = $false
$win.FindName('TxtSearch').Text = 'defender'
Update-Filter
Snap '08-search'

Write-Output 'done'
$win.Close()
