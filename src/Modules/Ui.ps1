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
#  Ui.ps1 - builds the window, wires every control, runs the apply and
#  undo flows. All UI work happens on the single WPF thread; long jobs
#  pump the dispatcher between steps so the progress panel keeps drawing.
# =====================================================================

$script:Ui = @{}
$script:Shell = $null
$script:LogItems = $null
$script:ActiveCategory = $null
$script:View = 'options'
$script:SlowScanned = @{}
$script:Cancel = $false

# --------------------------------------------------------------- bootstrap

# Compiles the view-models to a DLL with a fixed assembly name, because the
# XAML refers to them as assembly=DebloatInterop.
function Initialize-Interop {
    $cs = Join-Path $script:Paths.Interop 'Interop.cs'
    $refs = @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml')

    # The XAML names these types as assembly=DebloatInterop, so the compiled
    # file has to keep exactly that name - Add-Type takes the assembly name
    # from the output file name.
    #
    # That rules out the obvious fallback for a locked file. Compiling into
    # memory with "Add-Type -Path Interop.cs" produces an assembly with a
    # generated name, which XAML cannot resolve, and the window then fails with
    # "Cannot create unknown type StateEqualsConverter" - a message that says
    # nothing about the real cause. So when the shared copy is locked by another
    # running instance, compile into a private folder under the same file name
    # instead, and keep the assembly identity intact.
    $shared = Join-Path $script:Paths.Bin 'DebloatInterop.dll'
    $private = Join-Path (Join-Path $script:Paths.Bin ('pid-' + $PID)) 'DebloatInterop.dll'

    Remove-DeadInteropCopies

    $problems = New-Object Collections.Generic.List[string]
    foreach ($dll in @($shared, $private)) {

        # An existing build is reusable only if it is newer than the source.
        if (Test-Path -LiteralPath $dll) {
            if ((Get-Item $cs).LastWriteTimeUtc -le (Get-Item $dll).LastWriteTimeUtc) {
                try { Add-Type -Path $dll -ErrorAction Stop; return }
                catch { $problems.Add("could not load $dll : $($_.Exception.Message)") }
            }
        }

        Write-Host '  compiling view-models...' -ForegroundColor DarkGray
        try {
            $dir = Split-Path -Parent $dll
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            if (Test-Path -LiteralPath $dll) { Remove-Item -LiteralPath $dll -Force -ErrorAction Stop }
            Add-Type -Path $cs -OutputAssembly $dll -OutputType Library -ReferencedAssemblies $refs -ErrorAction Stop
            Add-Type -Path $dll -ErrorAction Stop
            return
        } catch {
            $problems.Add("could not build $dll : $($_.Exception.Message)")
            if ($dll -eq $shared) {
                Write-Host '  shared copy is in use, building a private one...' -ForegroundColor DarkGray
            }
        }
    }

    foreach ($p in $problems) { Write-AppLog $p 'error' }
    throw ('The view-models could not be compiled. ' + [string]::Join(' | ', $problems))
}

# Private copies are named after the process that built them. Anything left by
# a process that is no longer running is dead weight, so clear it out.
function Remove-DeadInteropCopies {
    foreach ($d in @(Get-ChildItem -LiteralPath $script:Paths.Bin -Directory -Filter 'pid-*' -ErrorAction SilentlyContinue)) {
        $pidText = $d.Name.Substring(4)
        $n = 0
        if (-not [int]::TryParse($pidText, [ref]$n)) { continue }
        if ($n -eq $PID) { continue }
        if (Get-Process -Id $n -ErrorAction SilentlyContinue) { continue }
        try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop }
        catch { }
    }
}

# The window is owned by the powershell.exe process that hosts it, so without
# this the taskbar, Alt-Tab and the window's own thumbnail all show PowerShell's
# icon - regardless of the icon on the exe the user actually double-clicked,
# because that exe is only the parent process.
#
# The .ico carries seven sizes; the frame closest to 32px is picked rather than
# handing WPF the 256px one, which Windows would then downscale to 16px and turn
# to mush in the title bar.
function Set-WindowIcon {
    param([Parameter(Mandatory)]$Window)

    $path = Join-Path $script:Paths.Root 'assets\app.ico'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-AppLog "no app icon at $path, the window will show the host icon" 'warn'
        return
    }
    try {
        $dec = New-Object Windows.Media.Imaging.IconBitmapDecoder(
            (New-Object Uri((Resolve-Path -LiteralPath $path).Path)),
            [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
            [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)

        $best = $null
        foreach ($f in $dec.Frames) {
            if ($null -eq $best) { $best = $f; continue }
            if ([Math]::Abs($f.PixelWidth - 32) -lt [Math]::Abs($best.PixelWidth - 32)) { $best = $f }
        }
        if ($best) { $Window.Icon = $best }
    } catch {
        Write-AppLog "could not load the app icon: $($_.Exception.Message)" 'warn'
    }
}

function Import-XamlFile {
    param([Parameter(Mandatory)][string]$Path)
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $ms = New-Object IO.MemoryStream($bytes, $false)
    try { return [Windows.Markup.XamlReader]::Load($ms) }
    finally { $ms.Dispose() }
}

# Lets the window repaint in the middle of a long loop.
function Sync-Ui {
    if ($script:Ui.Win) {
        $script:Ui.Win.Dispatcher.Invoke([Windows.Threading.DispatcherPriority]::Background, [action] { }) | Out-Null
    }
}

function Get-El {
    param([string]$Name)
    return $script:Ui.Win.FindName($Name)
}

# --------------------------------------------------------------- log panel

function Add-UiLog {
    param(
        [string]$Text,
        [ValidateSet('info', 'ok', 'warn', 'error', 'head')][string]$Level = 'info'
    )
    $vm = New-Object Debloat.LogVM
    $vm.Time = (Get-Date).ToString('HH:mm:ss')
    $vm.Level = $Level
    $vm.Text = $Text
    $script:LogItems.Add($vm)
    # Write-AppLog takes a mandatory string, so blank spacer lines stay UI-only.
    if (-not [string]::IsNullOrEmpty($Text)) { Write-AppLog $Text $Level }
    if ($script:LogItems.Count -gt 4000) { $script:LogItems.RemoveAt(0) }
    $sv = Get-El 'LogScroll'
    if ($sv) { $sv.ScrollToEnd() }
}

function Show-Toast {
    param([string]$Text, [ValidateSet('ok', 'warn', 'error')][string]$Kind = 'ok')

    $t = Get-El 'Toast'
    $icon = Get-El 'ToastIcon'
    $txt = Get-El 'ToastText'

    $txt.Text = $Text
    switch ($Kind) {
        'ok' { $icon.Text = [char]0xE73E; $icon.Foreground = $script:Ui.Win.FindResource('Green') }
        'warn' { $icon.Text = [char]0xE7BA; $icon.Foreground = $script:Ui.Win.FindResource('Amber') }
        'error' { $icon.Text = [char]0xEA39; $icon.Foreground = $script:Ui.Win.FindResource('Red') }
    }
    $t.Visibility = 'Visible'

    if ($script:Ui.ToastTimer) { $script:Ui.ToastTimer.Stop() }
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(4)
    $timer.Add_Tick({
            $script:Ui.ToastTimer.Stop()
            (Get-El 'Toast').Visibility = 'Collapsed'
        })
    $script:Ui.ToastTimer = $timer
    $timer.Start()
}

# --------------------------------------------------------------- views

function Set-View {
    param([ValidateSet('options', 'presets', 'overview')][string]$Name)

    $script:View = $Name
    (Get-El 'LstTweaks').Visibility = if ($Name -eq 'options') { 'Visible' } else { 'Collapsed' }
    (Get-El 'Toolbar').Visibility = if ($Name -eq 'options') { 'Visible' } else { 'Collapsed' }
    (Get-El 'ViewPresets').Visibility = if ($Name -eq 'presets') { 'Visible' } else { 'Collapsed' }
    (Get-El 'ViewOverview').Visibility = if ($Name -eq 'overview') { 'Visible' } else { 'Collapsed' }
    if ($Name -ne 'options') { (Get-El 'EmptyState').Visibility = 'Collapsed' }

    # A view always opens at its top; inheriting the last scroll offset makes
    # the page look like it started half way down.
    switch ($Name) {
        'overview' { (Get-El 'ViewOverview').ScrollToTop() }
        'presets' { (Get-El 'ViewPresets').ScrollToTop() }
    }
}

function Select-Category {
    param([string]$Key)

    $cat = Get-CategoryByKey $Key
    if ($null -eq $cat) { return }

    $script:ActiveCategory = $cat
    $script:Shell.SectionTitle = $cat.Name
    $script:Shell.SectionBlurb = $cat.Blurb
    Set-View 'options'

    # Anything skipped at launch - the DISM feature and capability queries, and
    # the command probes - is read the first time its category is opened.
    #
    # Tracked per category, not with a single flag. The feature and capability
    # caches are global, so one flag was survivable while those were the only
    # deferred things: the first slow category built the caches and later ones
    # read from them. Command probes are per option and run right here, so a
    # single flag would have left every category after the first showing Unknown
    # for ever.
    if ($null -eq $script:SlowScanned) { $script:SlowScanned = @{} }
    if (-not $script:SlowScanned.ContainsKey($cat.Key) -and (Test-NeedsSlowScan $cat.Tweaks)) {
        $script:Shell.Status = 'Reading the slower settings for this section...'
        Sync-Ui
        Get-FeatureCache | Out-Null
        Get-CapabilityCache | Out-Null
        $script:SlowScanned[$cat.Key] = $true
        Update-TweakStates $cat.Tweaks
        Update-Coverage
        $script:Shell.Status = 'Ready'
    }

    Update-Filter
}

# --------------------------------------------------------------- filtering

function Update-Filter {
    if ($script:View -ne 'options' -or $null -eq $script:ActiveCategory) { return }

    $q = (Get-El 'TxtSearch').Text
    $searching = -not [string]::IsNullOrWhiteSpace($q)
    $needle = if ($searching) { $q.Trim().ToLower() } else { '' }

    $risks = New-Object Collections.Generic.List[string]
    if ((Get-El 'TglSafe').IsChecked) { $risks.Add('safe') }
    if ((Get-El 'TglModerate').IsChecked) { $risks.Add('moderate') }
    if ((Get-El 'TglAggressive').IsChecked) { $risks.Add('aggressive') }

    $hideDone = [bool](Get-El 'ChkHideDone').IsChecked

    # A search looks across the whole catalogue, not just the open category.
    $pool = if ($searching) { $script:AllTweaks } else { $script:ActiveCategory.Tweaks }

    $shown = New-Object Collections.ObjectModel.ObservableCollection[object]
    foreach ($vm in $pool) {
        if (-not $risks.Contains($vm.Risk)) { continue }
        if ($searching -and $vm.SearchBlob.IndexOf($needle) -lt 0) { continue }
        if ($hideDone -and $vm.CurrentState -eq 'Disabled' -and -not $vm.HasSelection) { continue }
        $shown.Add($vm)
    }

    $lst = Get-El 'LstTweaks'
    $lst.ItemsSource = $shown
    if ($shown.Count -gt 0) { $lst.ScrollIntoView($shown[0]) }
    (Get-El 'EmptyState').Visibility = if ($shown.Count -eq 0) { 'Visible' } else { 'Collapsed' }

    if ($searching) {
        $script:Shell.SectionTitle = 'Search results'
        $script:Shell.SectionBlurb = "Matching '$($q.Trim())' across all $($script:AllTweaks.Count) options in every category. Clear the box to go back to browsing."
    } elseif ($script:ActiveCategory) {
        $script:Shell.SectionTitle = $script:ActiveCategory.Name
        $script:Shell.SectionBlurb = $script:ActiveCategory.Blurb
    }

    $total = @($pool).Count
    (Get-El 'TxtVisible').Text = "showing $($shown.Count) of $total"
}

function Update-Counts {
    $total = 0
    foreach ($c in $script:Categories) {
        $n = 0
        foreach ($vm in $c.Tweaks) { if ($vm.HasSelection) { $n++ } }
        $c.Vm.Pending = $n
        $total += $n
    }
    $script:Shell.PendingTotal = $total
}

function Get-StagedTweaks {
    $out = New-Object Collections.ObjectModel.ObservableCollection[object]
    foreach ($vm in $script:AllTweaks) { if ($vm.HasSelection) { $out.Add($vm) } }
    return $out
}

function Clear-AllSelections {
    foreach ($vm in $script:AllTweaks) { $vm.State = '' }
    Update-Counts
    Update-Filter
}

# =====================================================================
#  Dashboard builders for the Start here page.
#
#  Chart decisions, made in this order: form first, colour last.
#
#  * Headline numbers are stat tiles, not one-bar charts. One hero figure.
#  * Risk is an ordered status scale (safe -> moderate -> aggressive), so it
#    wears reserved status steps, never series colours, and every segment
#    carries a label. Measured under simulated protanopia the safe/moderate
#    pair separates by dE 11.3, so it survives red-green colour blindness.
#  * Category readiness is nominal - the bar length already encodes the value,
#    so every bar takes the same series hue rather than being coloured by its
#    own value. One series means no legend; the panel title names it.
#  * Bars are two star-width grid columns, so they stay true at any window
#    size without a single line of layout code.
# =====================================================================

function Th { param([double]$l, [double]$t, [double]$r, [double]$b) [Windows.Thickness]::new($l, $t, $r, $b) }
function Res { param([string]$k) $script:Ui.Win.FindResource($k) }

function New-Tb {
    param(
        [string]$Text,
        [string]$StyleKey,
        [double]$Size = 0,
        [string]$Brush,
        $Margin,
        [string]$Weight,
        [switch]$Wrap
    )
    $t = New-Object Windows.Controls.TextBlock
    if ($StyleKey) { $t.Style = Res $StyleKey }
    $t.Text = $Text
    if ($Size -gt 0) { $t.FontSize = $Size }
    if ($Brush) { $t.Foreground = Res $Brush }
    if ($Margin) { $t.Margin = $Margin }
    if ($Weight) { $t.FontWeight = $Weight }
    if ($Wrap) { $t.TextWrapping = 'Wrap' }
    return $t
}

function New-Dot {
    param([string]$Brush, [double]$Size = 8)
    $e = New-Object Windows.Shapes.Ellipse
    $e.Width = $Size; $e.Height = $Size
    $e.Fill = Res $Brush
    $e.VerticalAlignment = 'Center'
    $e.Margin = Th 0 0 7 0
    return $e
}

# A panel is the surface a chart sits on: title, optional subtitle, body.
function New-Panel {
    param([string]$Title, [string]$Sub, [double]$BottomMargin = 12)

    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = [Windows.CornerRadius]::new(11)
    $b.Background = Res 'Card'
    $b.BorderBrush = Res 'BorderSoft'
    $b.BorderThickness = [Windows.Thickness]::new(1)
    $b.Padding = Th 20 17 20 18
    $b.Margin = Th 0 0 0 $BottomMargin

    $sp = New-Object Windows.Controls.StackPanel
    if ($Title) {
        $sp.Children.Add((New-Tb -Text $Title -StyleKey 'H2' -Size 14.5)) | Out-Null
    }
    if ($Sub) {
        $sp.Children.Add((New-Tb -Text $Sub -StyleKey 'Caption' -Margin (Th 0 4 0 0) -Wrap)) | Out-Null
    }
    $body = New-Object Windows.Controls.StackPanel
    $body.Margin = Th 0 14 0 0
    $sp.Children.Add($body) | Out-Null
    $b.Child = $sp

    return [pscustomobject]@{ Root = $b; Body = $body }
}

# ---------------------------------------------------------------- stat tiles

function New-StatTile {
    param(
        [string]$Label,
        [string]$Value,
        [string]$Sub,
        [switch]$Hero,
        [string]$ValueBrush = 'Text'
    )
    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = [Windows.CornerRadius]::new(11)
    $b.Background = Res 'Card'
    $b.BorderBrush = Res 'BorderSoft'
    $b.BorderThickness = [Windows.Thickness]::new(1)
    $b.Padding = Th 18 15 18 16

    $sp = New-Object Windows.Controls.StackPanel

    # label above value: the label is the question, the number is the answer
    $sp.Children.Add((New-Tb -Text $Label.ToUpper() -StyleKey 'Overline' -Wrap)) | Out-Null

    $size = if ($Hero) { 50 } else { 30 }
    $v = New-Tb -Text $Value -Size $size -Brush $ValueBrush -Weight 'SemiBold' -Margin (Th 0 6 0 0)
    # Same sans as the rest of the app: a display face on a hero figure reads as
    # decoration. Proportional figures, so 355 does not sit loose at 50px.
    $v.FontFamily = Res 'UiFont'
    $v.LineHeight = $size * 1.06
    $v.LineStackingStrategy = 'BlockLineHeight'
    $sp.Children.Add($v) | Out-Null

    if ($Sub) {
        $sp.Children.Add((New-Tb -Text $Sub -StyleKey 'Caption' -Margin (Th 0 5 0 0) -Wrap)) | Out-Null
    }
    $b.Child = $sp
    return $b
}

function New-StatRow {
    param($Tiles)
    $g = New-Object Windows.Controls.Grid
    $g.Margin = Th 0 0 0 12
    $i = 0
    foreach ($t in $Tiles) {
        if ($i -gt 0) {
            $gap = New-Object Windows.Controls.ColumnDefinition
            $gap.Width = [Windows.GridLength]::new(12)
            $g.ColumnDefinitions.Add($gap)
        }
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = [Windows.GridLength]::new(1, 'Star')
        $g.ColumnDefinitions.Add($cd)
        [Windows.Controls.Grid]::SetColumn($t, $g.ColumnDefinitions.Count - 1)
        $g.Children.Add($t) | Out-Null
        $i++
    }
    return $g
}

# ---------------------------------------------------------------- stacked status bar

# Segments separated by a 2px gap in the surface colour rather than a stroke:
# the gap is the separator, so no non-data ink is added.
# 14px, not a full-height block: saturated fills belong on thin marks and
# accents, never on large slabs.
function New-StackedBar {
    param($Segments, [double]$Height = 14)

    $g = New-Object Windows.Controls.Grid
    $g.Height = $Height
    $live = @($Segments | Where-Object { $_.Value -gt 0 })
    $n = $live.Count
    $idx = 0

    foreach ($seg in $live) {
        if ($idx -gt 0) {
            $gap = New-Object Windows.Controls.ColumnDefinition
            $gap.Width = [Windows.GridLength]::new(2)
            $g.ColumnDefinitions.Add($gap)
        }
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = [Windows.GridLength]::new([double]$seg.Value, 'Star')
        $g.ColumnDefinitions.Add($cd)
        $col = $g.ColumnDefinitions.Count - 1

        # 4px rounded outer ends, square where segments meet
        $tl = 0; $bl = 0; $tr = 0; $br = 0
        if ($idx -eq 0) { $tl = 4; $bl = 4 }
        if ($idx -eq ($n - 1)) { $tr = 4; $br = 4 }

        $b = New-Object Windows.Controls.Border
        $b.Background = Res $seg.Brush
        $b.CornerRadius = [Windows.CornerRadius]::new($tl, $tr, $br, $bl)
        $b.ToolTip = "$($seg.Label): $($seg.Value)"
        [Windows.Controls.Grid]::SetColumn($b, $col)
        $g.Children.Add($b) | Out-Null
        $idx++
    }
    return $g
}

# Legend is always present for two or more series. Identity comes from the dot,
# never from colouring the text.
function New-Legend {
    param($Segments)
    $wrap = New-Object Windows.Controls.WrapPanel
    $wrap.Margin = Th 0 11 0 0
    foreach ($seg in $Segments) {
        $sp = New-Object Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $sp.Margin = Th 0 0 22 0
        $sp.Children.Add((New-Dot $seg.Brush)) | Out-Null
        $sp.Children.Add((New-Tb -Text $seg.Label -StyleKey 'Caption' -Size 12 -Brush 'TextDim')) | Out-Null
        $sp.Children.Add((New-Tb -Text ([string]$seg.Value) -Size 12 -Brush 'Text' `
                    -Weight 'SemiBold' -Margin (Th 7 0 0 0))) | Out-Null
        $wrap.Children.Add($sp) | Out-Null
    }
    return $wrap
}

# ---------------------------------------------------------------- category meters

# Nominal categories: bar length carries the value, so every bar is the same
# hue. Value rides the tip of the bar; no legend, no gridlines needed.
function New-MeterRow {
    param([string]$Label, [double]$Fraction, [string]$Value, [string]$Tip, [string]$Key)

    $outer = New-Object Windows.Controls.Border
    $outer.CornerRadius = [Windows.CornerRadius]::new(6)
    $outer.Background = [Windows.Media.Brushes]::Transparent
    $outer.Padding = Th 8 5 8 5
    $outer.Margin = Th -8 0 -8 2
    if ($Key) {
        $outer.Cursor = 'Hand'
        $outer.Tag = $Key
        $outer.ToolTip = "$Tip - click to open this category"
        $outer.Add_MouseEnter({ param($sender, $e) $sender.Background = (Res 'CardHover') })
        $outer.Add_MouseLeave({ param($sender, $e) $sender.Background = [Windows.Media.Brushes]::Transparent })
        $outer.Add_MouseLeftButtonUp({ param($sender, $e) Select-RailCategory $sender.Tag })
    } else {
        $outer.ToolTip = $Tip
    }

    $g = New-Object Windows.Controls.Grid
    foreach ($w in @(174, 0, 96)) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        if ($w -gt 0) { $cd.Width = [Windows.GridLength]::new($w) }
        else { $cd.Width = [Windows.GridLength]::new(1, 'Star') }
        $g.ColumnDefinitions.Add($cd)
    }

    $name = New-Tb -Text $Label -Size 12.5 -Brush 'TextDim'
    $name.VerticalAlignment = 'Center'
    $name.TextTrimming = 'CharacterEllipsis'
    $name.Margin = Th 0 0 12 0
    [Windows.Controls.Grid]::SetColumn($name, 0)
    $g.Children.Add($name) | Out-Null

    # blue-on-blue: the track is a darker step of the same ramp, so the state
    # reads across the whole width rather than only where the fill is
    $bar = New-Object Windows.Controls.Grid
    $bar.Height = 10
    $bar.VerticalAlignment = 'Center'
    $c1 = New-Object Windows.Controls.ColumnDefinition
    $c1.Width = [Windows.GridLength]::new([math]::Max($Fraction, 0.0), 'Star')
    $c2 = New-Object Windows.Controls.ColumnDefinition
    $c2.Width = [Windows.GridLength]::new([math]::Max(1.0 - $Fraction, 0.0), 'Star')
    $bar.ColumnDefinitions.Add($c1); $bar.ColumnDefinitions.Add($c2)

    $track = New-Object Windows.Controls.Border
    $track.Background = Res 'SeriesTrack'
    $track.Opacity = 0.45
    $track.CornerRadius = [Windows.CornerRadius]::new(5)
    [Windows.Controls.Grid]::SetColumn($track, 0)
    [Windows.Controls.Grid]::SetColumnSpan($track, 2)
    $bar.Children.Add($track) | Out-Null

    if ($Fraction -gt 0) {
        $fill = New-Object Windows.Controls.Border
        $fill.Background = Res 'Series1'
        $fill.CornerRadius = [Windows.CornerRadius]::new(5)
        $fill.MinWidth = 6
        [Windows.Controls.Grid]::SetColumn($fill, 0)
        $bar.Children.Add($fill) | Out-Null
    }
    [Windows.Controls.Grid]::SetColumn($bar, 1)
    $g.Children.Add($bar) | Out-Null

    $val = New-Tb -Text $Value -Size 11.5 -Brush 'TextDim'
    $val.VerticalAlignment = 'Center'
    $val.Margin = Th 12 0 0 0
    $val.TextAlignment = 'Right'
    [Windows.Controls.Grid]::SetColumn($val, 2)
    $g.Children.Add($val) | Out-Null

    $outer.Child = $g
    return $outer
}

# Drives the rail selection, which already does the rest of the work.
function Select-RailCategory {
    param([string]$Key)
    if (-not $Key) { return }
    $cats = Get-El 'RailCats'
    for ($i = 0; $i -lt $cats.Items.Count; $i++) {
        if ($cats.Items[$i].Key -eq $Key) { $cats.SelectedIndex = $i; return }
    }
}

# ---------------------------------------------------------------- prose card

function New-NoteCard {
    param([string]$Glyph, [string]$Title, [string]$Body, [string]$Accent = 'Accent')

    $b = New-Object Windows.Controls.Border
    $b.CornerRadius = [Windows.CornerRadius]::new(11)
    $b.Background = Res 'Card'
    $b.BorderBrush = Res 'BorderSoft'
    $b.BorderThickness = [Windows.Thickness]::new(1)
    $b.Padding = Th 20 16 20 17
    $b.Margin = Th 0 0 0 12

    $g = New-Object Windows.Controls.Grid
    foreach ($w in @(0, 1)) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        if ($w -eq 0) { $cd.Width = [Windows.GridLength]::new(34) }
        else { $cd.Width = [Windows.GridLength]::new(1, 'Star') }
        $g.ColumnDefinitions.Add($cd)
    }
    $ic = New-Tb -Text $Glyph -Size 17 -Brush $Accent
    $ic.FontFamily = Res 'IconFont'
    $ic.VerticalAlignment = 'Top'
    $ic.Margin = Th 0 1 0 0
    [Windows.Controls.Grid]::SetColumn($ic, 0)
    $g.Children.Add($ic) | Out-Null

    $sp = New-Object Windows.Controls.StackPanel
    [Windows.Controls.Grid]::SetColumn($sp, 1)
    $sp.Children.Add((New-Tb -Text $Title -StyleKey 'H2' -Size 14.5 -Margin (Th 0 0 0 6))) | Out-Null
    $sp.Children.Add((New-Tb -Text $Body -StyleKey 'Body' -Wrap)) | Out-Null
    $g.Children.Add($sp) | Out-Null

    $b.Child = $g
    return $b
}

# ---------------------------------------------------------------- coverage maths

# Options whose live state could not be read are excluded from both halves, so
# the figure never claims to know more than it does.
function Update-Coverage {
    foreach ($c in $script:Categories) {
        $off = 0; $known = 0
        foreach ($vm in $c.Tweaks) {
            switch ($vm.CurrentState) {
                'Disabled' { $off++; $known++ }
                'Enabled' { $known++ }
                'Mixed' { $known++ }
            }
        }
        $c.Vm.OffCount = $off
        $c.Vm.KnownCount = $known
    }
}

# ---------------------------------------------------------------- the dashboard

function Build-Overview {
    $host_ = Get-El 'OverviewHost'
    $host_.Children.Clear()
    Update-Coverage

    $os = Get-WindowsBuildInfo
    $safe = 0; $mod = 0; $agg = 0
    $off = 0; $known = 0; $unknown = 0
    foreach ($vm in $script:AllTweaks) {
        switch ($vm.Risk) { 'safe' { $safe++ } 'moderate' { $mod++ } 'aggressive' { $agg++ } }
        switch ($vm.CurrentState) {
            'Disabled' { $off++; $known++ }
            'Enabled' { $known++ }
            'Mixed' { $known++ }
            default { $unknown++ }
        }
    }
    $touched = Get-JournalTweakCount

    # --- headline row. One hero figure; the rest are ordinary stat tiles.
    $tiles = @(
        (New-StatTile -Hero -Label 'Options you can review' -Value ([string]$script:AllTweaks.Count) `
                -Sub "across $($script:Categories.Count) categories, nothing selected until you choose"),
        (New-StatTile -Label 'Already switched off' -Value ([string]$off) `
                -Sub "of $known whose state could be read" -ValueBrush 'Series1'),
        (New-StatTile -Label 'Changed by this app' -Value ([string]$touched) `
                -Sub $(if ($touched -eq 0) { 'nothing has been changed on this PC' } else { 'every one of them still undoable' }) `
                -ValueBrush $(if ($touched -eq 0) { 'TextDim' } else { 'Violet' })),
        (New-StatTile -Label 'State not readable' -Value ([string]$unknown) `
                -Sub 'probed options, or features not present on this build' -ValueBrush 'TextDim')
    )
    $host_.Children.Add((New-StatRow $tiles)) | Out-Null

    # --- risk mix: ordered status scale, part-to-whole, direct-labelled
    $segs = @(
        [pscustomobject]@{ Label = 'Safe'; Value = $safe; Brush = 'RiskSafe' }
        [pscustomobject]@{ Label = 'Moderate'; Value = $mod; Brush = 'RiskModerate' }
        [pscustomobject]@{ Label = 'Aggressive'; Value = $agg; Brush = 'RiskAggressive' }
    )
    $p = New-Panel -Title 'Risk mix across the catalogue' `
        -Sub 'Safe is reversible with no functional loss. Moderate changes a real feature and says which. Aggressive can break updates, security or app installs, and each card explains the specific danger.'
    $p.Body.Children.Add((New-StackedBar $segs)) | Out-Null
    $p.Body.Children.Add((New-Legend $segs)) | Out-Null
    $host_.Children.Add($p.Root) | Out-Null

    # --- per-category readiness, largest share first
    $p2 = New-Panel -Title 'How much of each category is already switched off' `
        -Sub 'Counted against the options whose live state could be read, so categories that rely on slower checks look emptier than they are until you open them. Click any row to jump to that category.'
    $rows = @()
    foreach ($c in $script:Categories) {
        $rows += [pscustomobject]@{
            Name = $c.Name; Key = $c.Key; Off = $c.Vm.OffCount; Known = $c.Vm.KnownCount
            Frac = $(if ($c.Vm.KnownCount -gt 0) { [double]$c.Vm.OffCount / $c.Vm.KnownCount } else { 0.0 })
        }
    }
    foreach ($r in ($rows | Sort-Object -Property Frac -Descending)) {
        $val = if ($r.Known -gt 0) { "$($r.Off) of $($r.Known)" } else { 'not read yet' }
        $tip = "$($r.Name): $val options already in the off state"
        $p2.Body.Children.Add((New-MeterRow -Label $r.Name -Fraction $r.Frac -Value $val `
                    -Tip $tip -Key $r.Key)) | Out-Null
    }
    $host_.Children.Add($p2.Root) | Out-Null

    # --- the two things worth reading in prose
    $elev = if (Test-IsAdmin) { 'Running elevated, so every option can be applied.' }
    else { 'NOT elevated - machine-wide options will fail until you restart this app as administrator.' }
    $host_.Children.Add((New-NoteCard ([char]0xE770) 'This PC' (
                "$($os.Product) $($os.Display), build $($os.Build)" + [char]10 +
                "Signed in as $env:USERNAME on $env:COMPUTERNAME" + [char]10 + $elev
            ) 'Accent')) | Out-Null

    $jn = if ($touched -eq 0) { 'This app has not changed anything on this PC yet.' }
    else { "$touched options have been changed and every one can be put back." }
    $host_.Children.Add((New-NoteCard ([char]0xE777) 'Your safety net' (
                $jn + [char]10 +
                'Before each change the previous state is written to logs\journal.jsonl. That one file backs both Revert on a single option and Undo everything in the footer, and it survives closing the app.' + [char]10 +
                'The confirmation screen also offers a dry run, which logs exactly what would happen and touches nothing.'
            ) 'Green')) | Out-Null

    $host_.Children.Add((New-NoteCard ([char]0xE8FB) 'Suggested order of work' (
                '1. Create a restore point from the sidebar.' + [char]10 +
                '2. Open Presets and stage one that matches how you use this machine. Nothing is applied yet.' + [char]10 +
                '3. Walk the categories and change your mind on anything you disagree with.' + [char]10 +
                '4. Press Review and apply, tick Dry run to rehearse it, then apply for real.' + [char]10 +
                '5. Save your choices as a preset to repeat them on another PC.'
            ) 'Violet')) | Out-Null
}

function Build-Help {
    $host_ = Get-El 'HelpHost'
    $host_.Children.Clear()

    $t = New-Object Windows.Controls.TextBlock
    $t.Text = 'How this app works'
    $t.Style = $script:Ui.Win.FindResource('H1')
    $t.Margin = [Windows.Thickness]::new(0, 0, 0, 16)
    $host_.Children.Add($t) | Out-Null

    $pairs = @(
        @('Nothing is selected by default',
            'Every one of the ' + $script:AllTweaks.Count + ' options starts with no choice made. The app cannot change anything until you pick Enable, Disable or Revert on something and then press Review and apply.'),
        @('Enable, Disable, Revert',
            'The three buttons describe the Windows feature, not the tweak. Enable means the feature is on; Disable means it is off. For most options Disable is the debloating direction, but some options are features Windows ships off that you may want on, and the card says which. Revert reads the journal and puts the option back to the value it had before this app first changed it.'),
        @('Staging, then applying',
            'Choices accumulate as you browse. The footer counts them and each sidebar category shows its own count. Review and apply shows you the exact list before anything happens, and you can go back from there.'),
        @('The journal and global undo',
            'Before each individual change, the current state is captured and appended to logs\journal.jsonl. Undo everything replays that file backwards, oldest capture first, so the machine returns to how it was before you started. The journal survives closing the app, so you can undo tomorrow.'),
        @('Presets',
            'A preset is a list of option ids and the word Enable, Disable or Revert. It cannot contain a registry path or a command, so importing one from someone else can only ever set choices you could have set by hand. Presets stage; they never apply on their own.'),
        @('Sharing presets',
            'Save current selection writes a .json file into the presets folder beside the app. Send that file to someone and they import it and get exactly your choices. Export from any preset card writes the same format.'),
        @('What needs a restart',
            'Options tagged Restart only take full effect after a reboot. Shell changes usually need File Explorer restarted, which the confirmation screen offers to do for you. Service and driver level changes need a real restart.'),
        @('Reading the risk labels',
            'Safe means reversible with no functional loss for most people. Moderate means a real feature changes or disappears, and the card tells you which. Aggressive means it can break updates, security or app installation, and those cards explain the specific danger.'),
        @('Dry run',
            'The confirmation screen has a Dry run box. With it ticked, the app walks your whole selection and writes the complete log of what it would do, without touching a single registry value, service, app or task. It also writes nothing to the journal, and your selections stay staged so you can then apply for real. The dry run is a separate code path that contains no write of any kind, rather than the real apply with the writes skipped.'),
        @('Applying to every account',
            'HKCU options only ever affect the account running the app. Tick "Apply per-user options to all accounts" and the app also loads each other profile registry hive from its NTUSER.DAT, plus the default profile so accounts created later inherit the settings too. Each profile is captured separately, so Undo can put them back one by one, and it can find them again later even after a reboot. This needs administrator rights.'),
        @('Rescanning',
            'The refresh button in the title bar throws away everything the app has cached and re-reads the live state of all options. Use it if you changed something in Settings while the app was open, or if a state chip looks wrong. Your staged selections are kept.'),
        @('When something goes wrong',
            'Use Undo everything first. If the machine will not start properly, use the System Restore point. Every session writes a timestamped log next to the journal, which the Open log folder button in the sidebar takes you to.')
    )

    foreach ($p in $pairs) {
        $h = New-Object Windows.Controls.TextBlock
        $h.Text = $p[0]
        $h.Style = $script:Ui.Win.FindResource('H2')
        $h.FontSize = 14
        $h.Margin = [Windows.Thickness]::new(0, 0, 0, 5)
        $host_.Children.Add($h) | Out-Null

        $b = New-Object Windows.Controls.TextBlock
        $b.Text = $p[1]
        $b.Style = $script:Ui.Win.FindResource('Body')
        $b.Margin = [Windows.Thickness]::new(0, 0, 0, 17)
        $host_.Children.Add($b) | Out-Null
    }
}

# --------------------------------------------------------------- licence

function Sync-LicenseUi {
    $e = Get-Entitlement -Refresh
    $script:Shell.TierName = $e.TierName
    $script:Shell.IsPaid = [bool]$e.IsPaid
    $script:Shell.LicenceDetail = $e.Detail

    (Get-El 'TxtLicDetail').Text = $e.Detail

    # What this licence already includes. Read from the entitlement, not a
    # hard-coded list, so it is true for whichever tier was actually bought.
    $have = @($e.Features)
    (Get-El 'LicHaveBlock').Visibility = if ($have.Count -gt 0) { 'Visible' } else { 'Collapsed' }
    if ($have.Count -gt 0) {
        $lines = @($have | ForEach-Object { [char]0x2022 + ' ' + (Get-FeatureDescription $_) })
        (Get-El 'TxtLicHaveHead').Text = ("INCLUDED WITH " + "$($e.TierName)".ToUpper())
        (Get-El 'TxtLicHave').Text = [string]::Join("`n", $lines)
    }

    # And what the next tier up would add. Nothing shown once the top tier is
    # held - an upsell block for something already owned is just confusing.
    $next = Get-UpgradeOffer
    (Get-El 'LicNextBlock').Visibility = if ($next) { 'Visible' } else { 'Collapsed' }
    if ($next) {
        (Get-El 'TxtLicNextHead').Text = ("WHAT " + "$($next.TierName)".ToUpper() + " ADDS")
        $adds = @($next.Adds | ForEach-Object { [char]0x2022 + ' ' + (Get-FeatureDescription $_) })
        (Get-El 'TxtLicFeatures').Text = [string]::Join("`n", $adds)
        (Get-El 'TxtLicNextWho').Text = "$($next.Blurb) $($next.Machines) Every option and the whole safety net stay free either way."
    }

    # The two buy buttons only make sense while there is something to buy.
    $bp = Get-El 'BtnLicBuy'
    if ($bp) { $bp.Visibility = if ($e.TierId -eq 'free') { 'Visible' } else { 'Collapsed' } }
    $bt = Get-El 'BtnLicBuyTech'
    if ($bt) { $bt.Visibility = if ($e.TierId -eq 'technician') { 'Collapsed' } else { 'Visible' } }

    $st = Get-LicenseState
    $hasKey = ($null -ne $st -and $st.key)
    (Get-El 'LicActiveBlock').Visibility = if ($hasKey) { 'Visible' } else { 'Collapsed' }
    if ($hasKey) {
        $lim = if ($st.limitActivations) { "$($st.limitActivations) PCs allowed" } else { 'no PC limit' }
        (Get-El 'TxtLicMachine').Text = "$($st.label)`n$lim"
        (Get-El 'TxtLicKey').Text = "$($st.key)"
    }

    # A locked preset still shows everything it would do; only the action
    # changes. Each preset is judged against the feature its own tier needs,
    # rather than everything non-free being compared against the literal string
    # 'pro' - which meant a technician preset could never lock, and a locked one
    # told the buyer to buy Pro even when Pro was what they already had.
    foreach ($pv in @($script:Presets)) {
        $pv.IsLocked = -not (Test-PresetAllowed $pv.Tier)
        $name = Get-PresetTierName $pv.Tier
        if ($name) { $pv.LockTierName = $name }
    }

    # Paid controls explain themselves rather than vanishing, and name the tier
    # they belong to so the message is actionable.
    $save = Test-Feature 'presets.save'
    $saveTier = Get-TierForFeature 'presets.save'
    $saveName = if ($saveTier) { "$($saveTier.name)" } else { 'Pro' }
    foreach ($n in @('BtnPresetSaveCurrent', 'BtnSavePreset', 'BtnPresetImport')) {
        $b = Get-El $n
        if ($b) {
            $b.IsEnabled = $save
            if (-not $save) {
                $b.ToolTip = "Included with $saveName. Free covers every option and the whole safety net."
            }
        }
    }

    # The hand-over report is Technician only.
    $rep = Test-Feature 'report'
    $repTier = Get-TierForFeature 'report'
    $repName = if ($repTier) { "$($repTier.name)" } else { 'Technician' }
    $rb = Get-El 'BtnReport'
    if ($rb) {
        $rb.IsEnabled = $rep
        if (-not $rep) {
            $rb.ToolTip = "Included with $repName, for handing a machine back to someone else."
        } else {
            $rb.ToolTip = 'Save a report of every change made to this PC, and how to reverse it.'
        }
    }

    Update-Filter
}

function Show-LicensePanel {
    param([string]$Because)
    Sync-LicenseUi
    if ($Because) {
        (Get-El 'TxtLicDetail').Text = $Because + '  ' + (Get-Entitlement).Detail
    }
    (Get-El 'OvLicense').Visibility = 'Visible'
    if (-not (Get-Entitlement).IsPaid) { (Get-El 'TxtLicKey').Focus() | Out-Null }
}

# Reached for a paid feature without a licence: say so once, here, and offer
# the way forward. Never a startup nag, never a modal on launch.
function Deny-Feature {
    param([string]$Feature)
    $what = Get-FeatureDescription $Feature
    $tier = Get-TierForFeature $Feature
    $name = if ($tier) { "$($tier.name)" } else { 'Pro' }
    Show-Toast "$what is included with $name." 'warn'
    Show-LicensePanel -Because "You reached for $($what.ToLower()), which is part of $name."
}

function Open-Url {
    param([string]$Url, [string]$Missing)
    if ([string]::IsNullOrWhiteSpace($Url)) {
        Show-Toast $Missing 'warn'
        return
    }
    try { Start-Process $Url } catch { Show-Toast "Could not open the link: $($_.Exception.Message)" 'error' }
}

# --------------------------------------------------------------- presets

function Refresh-PresetList {
    $list = @(Import-Presets)
    (Get-El 'LstPresets').ItemsSource = $list
}

function Set-PresetSelections {
    param([string]$PresetId, [switch]$Additive)

    $sel = Get-PresetSelections $PresetId
    if ($sel.Count -eq 0) {
        Show-Toast 'That preset does not match any option in this catalogue.' 'warn'
        return 0
    }

    if (-not $Additive) { foreach ($vm in $script:AllTweaks) { $vm.State = '' } }

    $n = 0
    $skipped = 0
    foreach ($id in $sel.Keys) {
        $vm = Get-TweakVm $id
        if ($null -eq $vm) { continue }
        if ($sel[$id] -eq 'Revert' -and -not (Test-TweakTouched $id)) { $skipped++; continue }
        $vm.State = $sel[$id]
        $n++
    }

    Update-Counts
    Update-Filter
    if ($skipped -gt 0) {
        Show-Toast "Staged $n options. $skipped Revert entries were skipped because this app never changed them."
    } else {
        Show-Toast "Staged $n options. Nothing has been applied yet - review and apply when you are ready."
    }
    return $n
}

function Show-SavePresetDialog {
    if (-not (Test-Feature 'presets.save')) { Deny-Feature 'presets.save'; return }
    $staged = @(Get-StagedTweaks)
    if ($staged.Count -eq 0) {
        Show-Toast 'Choose Enable, Disable or Revert on at least one option first.' 'warn'
        return
    }

    $e = 0; $d = 0; $r = 0
    foreach ($vm in $staged) {
        switch ($vm.State) { 'Enable' { $e++ } 'Disable' { $d++ } 'Revert' { $r++ } }
    }
    (Get-El 'TxtSaveSummary').Text =
    "$($staged.Count) options are staged: $d to disable, $e to enable, $r to revert. The preset stores only option names and your choice, so it is safe to share."
    (Get-El 'TxtPresetName').Text = ''
    (Get-El 'TxtPresetSummary').Text = ''
    (Get-El 'TxtPresetDetail').Text = ''
    (Get-El 'OvSave').Visibility = 'Visible'
    (Get-El 'TxtPresetName').Focus() | Out-Null
}

# --------------------------------------------------------------- confirm sheet

function Show-ConfirmSheet {
    $staged = @(Get-StagedTweaks)
    if ($staged.Count -eq 0) { return }

    $rows = New-Object Collections.ObjectModel.ObservableCollection[object]
    $agg = 0; $restart = 0; $explorer = $noJournal = 0; $irrev = 0

    foreach ($vm in ($staged | Sort-Object CategoryName, Name)) {
        $def = Get-TweakDef $vm.Id
        $detail = switch ($vm.State) {
            'Enable' { $vm.EnableMeans }
            'Disable' { $vm.DisableMeans }
            'Revert' {
                if (Test-TweakTouched $vm.Id) { 'Restores the value recorded before this app first changed it.' }
                else { 'SKIPPED - this app has never changed this option, so there is nothing recorded to go back to.' }
            }
        }
        if ($vm.State -eq 'Revert' -and -not (Test-TweakTouched $vm.Id)) { $noJournal++ }
        if ($vm.Risk -eq 'aggressive') { $agg++ }
        if ($vm.RequiresRestart) { $restart++ }
        if ($def.Explorer) { $explorer++ }
        if ($vm.Category -eq 'cleanup') { $irrev++ }

        $r = New-Object Debloat.ChangeVM
        $r.Name = $vm.Name
        $r.Action = $vm.State
        $r.Category = $vm.CategoryName
        $r.Risk = $vm.Risk
        $r.Detail = $detail
        $r.RequiresRestart = $vm.RequiresRestart
        $rows.Add($r)
    }

    (Get-El 'LstChanges').ItemsSource = $rows

    $bits = @("$($staged.Count) options will be changed")
    if ($restart -gt 0) { $bits += "$restart need a restart before they fully take effect" }
    if ($explorer -gt 0) { $bits += "$explorer change the Windows shell" }
    if ($noJournal -gt 0) { $bits += "$noJournal Revert entries will be skipped" }
    (Get-El 'TxtConfirmSummary').Text = ([string]::Join('. ', $bits) +
        '. The previous state of each one is recorded first, so all of this can be undone afterwards.')

    $warn = Get-El 'ConfirmWarn'
    if ($agg -gt 0 -or $irrev -gt 0) {
        $parts = @()
        if ($irrev -gt 0) { $parts += "$irrev of these options permanently delete files — temporary files, old updates, caches, or the previous Windows installation. Unlike every other option in this app, Revert cannot undo them because the data is gone." }
        if ($agg -gt 0) { $parts += "$agg of these options are marked Aggressive. Those can break Windows Update, remove security protections, or delete something that cannot be restored." }
        (Get-El 'TxtConfirmWarn').Text = [string]::Join(' ', $parts)
        $warn.Visibility = 'Visible'
    } else {
        $warn.Visibility = 'Collapsed'
    }

    (Get-El 'ChkRestartExplorer').IsChecked = ($explorer -gt 0)
    (Get-El 'ChkRestorePoint').IsChecked = ($agg -gt 0 -or $staged.Count -ge 20)
    (Get-El 'ChkDryRun').IsChecked = $false

    # Offer the all-accounts option only when there is another account to reach
    # and we are elevated enough to load its hive.
    $chkAll = Get-El 'ChkAllUsers'
    $note = Get-El 'TxtAllUsersNote'
    $others = @(Get-UserProfileList | Where-Object { -not $_.IsCurrent })
    $perUser = 0
    foreach ($vm in $staged) {
        foreach ($a in (Get-TweakDef $vm.Id).Actions) {
            if ($a.kind -eq 'reg' -and $a.hive -eq 'HKCU') { $perUser++; break }
        }
    }

    if (-not (Test-Feature 'allusers')) {
        $chkAll.IsChecked = $false
        $chkAll.IsEnabled = $false
        $note.Text = 'Included with Pro. Per-user options still apply to your own account on the free version.'
    } elseif (-not (Test-IsAdmin)) {
        $chkAll.IsChecked = $false
        $chkAll.IsEnabled = $false
        $note.Text = 'Needs administrator rights. Restart the app elevated to use this.'
    } elseif ($others.Count -eq 0) {
        $chkAll.IsChecked = $false
        $chkAll.IsEnabled = $false
        $note.Text = 'No other profiles found on this PC, so there is nothing extra to write.'
    } elseif ($perUser -eq 0) {
        $chkAll.IsChecked = $false
        $chkAll.IsEnabled = $false
        $note.Text = 'None of the staged options are per-user, so this would change nothing.'
    } else {
        $chkAll.IsEnabled = $true
        $names = ($others | Select-Object -First 3 | ForEach-Object { $_.Label }) -join ', '
        $extra = if ($others.Count -gt 3) { " and $($others.Count - 3) more" } else { '' }
        $note.Text = "$perUser of these are per-user. Also writes them to: $names$extra."
    }

    (Get-El 'OvConfirm').Visibility = 'Visible'
}

# --------------------------------------------------------------- apply

function Open-BusyPanel {
    param([string]$Title, [string]$Detail, [switch]$Cancellable)
    $script:LogItems.Clear()
    $script:Shell.BusyTitle = $Title
    $script:Shell.BusyDetail = $Detail
    $script:Shell.Progress = 0
    $script:Shell.IsBusy = $true
    (Get-El 'BtnBusyClose').IsEnabled = $false
    (Get-El 'BtnBusySaveLog').Visibility = 'Collapsed'
    (Get-El 'BtnRestartNow').Visibility = 'Collapsed'
    (Get-El 'BtnBusyCancel').Visibility = if ($Cancellable) { 'Visible' } else { 'Collapsed' }
    (Get-El 'BtnBusyCancel').IsEnabled = $true
    $script:Cancel = $false
    (Get-El 'TxtBusyFoot').Text = 'Working. Please do not close the window.'
    (Get-El 'OvBusy').Visibility = 'Visible'
    Sync-Ui
}

function Close-BusyPanel {
    param([string]$Footer)
    $script:Shell.IsBusy = $false
    $script:Shell.Progress = 100
    (Get-El 'BtnBusyClose').IsEnabled = $true
    (Get-El 'BtnBusyCancel').Visibility = 'Collapsed'
    (Get-El 'BtnBusySaveLog').Visibility = 'Visible'
    (Get-El 'TxtBusyFoot').Text = $Footer
    Sync-Ui
}

function Invoke-Apply {
    $staged = @(Get-StagedTweaks | Sort-Object CategoryName, Name)
    if ($staged.Count -eq 0) { return }

    $makeRestore = [bool](Get-El 'ChkRestorePoint').IsChecked
    $restartExplorer = [bool](Get-El 'ChkRestartExplorer').IsChecked
    $allUsers = [bool](Get-El 'ChkAllUsers').IsChecked
    $dryRun = [bool](Get-El 'ChkDryRun').IsChecked
    (Get-El 'OvConfirm').Visibility = 'Collapsed'

    if ($dryRun) {
        # A dry run must not create a restore point or bounce Explorer either.
        $makeRestore = $false
        $restartExplorer = $false
        Open-BusyPanel 'Dry run - nothing will be changed' "Walking through $($staged.Count) options and logging exactly what would happen. No registry value, service, app or task is touched." -Cancellable
        Add-UiLog 'DRY RUN. Nothing below is actually being changed.' 'warn'
        Add-UiLog ''
    } else {
        Open-BusyPanel 'Applying your changes' "Working through $($staged.Count) options. The previous state of each one is recorded before it is touched." -Cancellable
    }

    # Load the other profiles' registry hives once, rather than per option.
    if ($allUsers -and -not $dryRun) {
        Add-UiLog 'Opening the registry for every account on this PC.' 'head'
        Sync-Ui
        $sess = Open-UserHiveSession
        foreach ($n in $sess.Notes) { Add-UiLog "  $n" 'warn' }
        foreach ($t in $sess.Targets) { Add-UiLog "  ready: $($t.Label)" }
        Sync-Ui
    } elseif ($allUsers -and $dryRun) {
        # -NoMount: listing the profiles must not load a hive during a dry run.
        $sess = Open-UserHiveSession -NoMount
        foreach ($t in $sess.Targets) { Add-UiLog "would also write to: $($t.Label)" }
        Add-UiLog ''
    }

    if ($makeRestore) {
        Add-UiLog 'Creating a System Restore point. This can take a minute or two.' 'head'
        Sync-Ui
        $rp = New-SystemRestorePoint -Description ('Debloat Studio - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
        if ($rp.Ok) { Add-UiLog 'Restore point created.' 'ok' }
        else { Add-UiLog "Restore point failed: $($rp.Message)" 'warn' }
    }

    $done = 0; $failed = 0; $skipped = 0; $needRestart = $false
    $i = 0

    $stopped = $false
    foreach ($vm in $staged) {
        # Checked here and nowhere else: an option is always finished in full, so
        # the journal never ends up describing a half-applied change.
        if ($script:Cancel) {
            $stopped = $true
            Add-UiLog ''
            Add-UiLog "STOPPED at your request. $($staged.Count - $i) options were not started." 'warn'
            break
        }
        $i++
        $script:Shell.Progress = [math]::Round(($i / $staged.Count) * 100, 1)
        $script:Shell.BusyDetail = "[$i of $($staged.Count)]  $($vm.Name)"

        $def = Get-TweakDef $vm.Id
        if ($null -eq $def) { continue }

        Add-UiLog "$($vm.State.ToUpper())  -  $($vm.Name)  ($($vm.CategoryName))" 'head'
        Sync-Ui

        try {
            if ($vm.State -eq 'Revert') {
                $caps = @(Get-TweakOriginalCaptures $vm.Id)
                if ($caps.Count -eq 0) {
                    Add-UiLog '  skipped: this app has never changed this option, so nothing was recorded to go back to' 'warn'
                    $skipped++
                    continue
                }
                foreach ($c in $caps) {
                    foreach ($note in (Restore-ActionCapture -Capture $c.Capture -DryRun:$dryRun)) {
                        Add-UiLog "  $note"
                    }
                }
                if (-not $dryRun) {
                    Remove-JournalTweak $vm.Id
                    $vm.IsTouched = $false
                }
                $done++
            } else {
                $idx = 0
                foreach ($a in $def.Actions) {
                    if (-not $dryRun) {
                        $cap = Get-ActionCapture $a
                        Add-JournalEntry -TweakId $vm.Id -TweakName $vm.Name -Direction $vm.State `
                            -Index $idx -Capture $cap
                    }
                    foreach ($note in (Set-ActionState -Action $a -Direction $vm.State -DryRun:$dryRun)) {
                        $lvl = if ($note -match 'ACCESS DENIED|could not|cannot') { 'warn' } else { 'info' }
                        Add-UiLog "  $note" $lvl
                    }
                    $idx++
                }
                if (-not $dryRun) { $vm.IsTouched = $true }
                $done++
            }

            if ($vm.RequiresRestart) { $needRestart = $true }
            if (-not $dryRun) {
                $vm.CurrentState = Get-TweakState $def
                $vm.State = ''
            }
        } catch {
            Add-UiLog "  FAILED: $($_.Exception.Message)" 'error'
            $failed++
        }
        Sync-Ui
    }

    if ($allUsers) {
        foreach ($n in (Close-UserHiveSession)) {
            $lvl = if ($n -like 'WARNING*') { 'warn' } else { 'info' }
            Add-UiLog $n $lvl
        }
    }

    Add-UiLog ''
    if ($dryRun) {
        Add-UiLog "Dry run complete. $done options walked, $skipped skipped, $failed errored." 'ok'
        Add-UiLog 'Nothing on this PC was changed. Your selections are still staged, so you can apply for real from the footer.' 'warn'
    } elseif ($stopped) {
        Add-UiLog "Stopped early. $done applied, $skipped skipped, $failed failed." 'warn'
        Add-UiLog 'Everything that was applied is in the journal, so Undo everything still puts it all back. The options that were not started are still staged.' 'info'
    } else {
        Add-UiLog "Finished. $done applied, $skipped skipped, $failed failed." 'ok'
    }

    if ($restartExplorer) {
        Add-UiLog 'Restarting File Explorer so shell changes appear.' 'head'
        Sync-Ui
        if (Restart-ExplorerShell) { Add-UiLog 'File Explorer restarted.' 'ok' }
        else { Add-UiLog 'Could not restart File Explorer. Sign out and in instead.' 'warn' }
    }

    if ($needRestart -and -not $dryRun) {
        $script:Shell.RestartPending = $true
        Add-UiLog 'Some of these changes only take full effect after you restart Windows.' 'warn'
        (Get-El 'BtnRestartNow').Visibility = 'Visible'
    }

    if (-not $dryRun) {
        Reset-EngineCache
        $script:Shell.JournalCount = Get-JournalTweakCount
        Update-Counts
        Update-Coverage
    }
    Update-Filter

    if ($dryRun) {
        $foot = "Dry run: $done options walked, nothing changed"
    } else {
        $foot = if ($stopped) { "Stopped early after $done applied" } else { "$done applied" }
        if ($skipped) { $foot += ", $skipped skipped" }
        if ($failed) { $foot += ", $failed failed - see the log above" }
    }
    Close-BusyPanel $foot
}

function Invoke-Rescan {
    Open-BusyPanel 'Re-reading this PC' "Discarding what was cached and checking the live state of all $($script:AllTweaks.Count) options again."
    Add-UiLog 'Clearing cached state...' 'head'
    Sync-Ui
    Reset-EngineCache -IncludeSlow
    $script:SlowScanned = @{}

    Add-UiLog 'Reading services, apps and scheduled tasks...' 'head'
    Sync-Ui
    Get-ServiceCache | Out-Null
    Get-AppxCache | Out-Null
    Get-AppxProvisionedCache | Out-Null
    Get-TaskCache | Out-Null

    Add-UiLog 'Checking each option...' 'head'
    Sync-Ui
    # Pumping the dispatcher forces a full layout and render pass over the whole
    # visual tree, which on this window costs far more than the option probe it
    # is reporting on. Measured: the same Update-TweakStates loop takes about
    # 2.7 seconds with no UI attached and around 11 with a pump every twelfth
    # option - the progress display was four times the cost of the actual work.
    #
    # Repainting about five times a second is more than enough for a progress
    # bar, so the properties update every time and only the repaint is throttled.
    $script:LastPump = [Diagnostics.Stopwatch]::StartNew()
    $prog = {
        param($i, $n)
        $script:Shell.Progress = [math]::Round(($i / $n) * 100, 1)
        $script:Shell.BusyDetail = "Checked $i of $n options."
        if ($script:LastPump.ElapsedMilliseconds -ge 200) {
            Sync-Ui
            $script:LastPump.Restart()
        }
    }
    $script:DeferSlowProbes = $true
    try { Update-TweakStates $script:AllTweaks $prog }
    finally { $script:DeferSlowProbes = $false }
    Update-Coverage

    $script:Shell.JournalCount = Get-JournalTweakCount
    Add-UiLog 'Done. Windows features are read again when you next open that category.' 'ok'
    Update-Filter
    Close-BusyPanel 'State refreshed. Your staged selections were kept.'
}

function Invoke-GlobalUndo {
    $plan = Get-JournalUndoPlan
    if ($plan.Count -eq 0) {
        Show-Toast 'There is nothing recorded to undo.' 'warn'
        return
    }

    (Get-El 'OvConfirm').Visibility = 'Collapsed'
    Open-BusyPanel 'Undoing everything' "Replaying $($plan.Count) recorded changes in reverse, putting each option back to the value it had before this app first touched it." -Cancellable

    $ok = 0; $bad = 0
    $i = 0
    $lastTweak = ''

    $stopped = $false
    foreach ($e in $plan) {
        if ($script:Cancel) {
            $stopped = $true
            Add-UiLog ''
            Add-UiLog "STOPPED at your request. $($plan.Count - $i) recorded changes were left in place." 'warn'
            break
        }
        $i++
        $script:Shell.Progress = [math]::Round(($i / $plan.Count) * 100, 1)
        $script:Shell.BusyDetail = "[$i of $($plan.Count)]  $($e.tweakName)"
        if ($e.tweakName -ne $lastTweak) {
            Add-UiLog "RESTORE  -  $($e.tweakName)" 'head'
            $lastTweak = $e.tweakName
        }
        try {
            foreach ($note in (Restore-ActionCapture $e.capture)) { Add-UiLog "  $note" }
            $ok++
        } catch {
            Add-UiLog "  FAILED: $($_.Exception.Message)" 'error'
            $bad++
        }
        Sync-Ui
    }

    Reset-EngineCache -IncludeSlow
    $script:SlowScanned = @{}

    Add-UiLog ''
    if ($stopped) {
        Add-UiLog "Undo stopped early. $ok restored, $bad failed." 'warn'
        # The journal is kept whole rather than trimmed. Restoring an already
        # restored value again is harmless, so a second Undo simply finishes
        # the job instead of leaving the rest stranded.
        Add-UiLog 'The journal has been kept, so you can press Undo everything again to finish the rest.' 'info'
        $script:Shell.JournalCount = Get-JournalTweakCount
    } else {
        Clear-Journal -Archive
        Add-UiLog "Undo complete. $ok restored, $bad failed." 'ok'
        Add-UiLog 'The journal has been archived in the logs folder, so this app now considers the machine untouched.' 'info'
        foreach ($vm in $script:AllTweaks) { $vm.IsTouched = $false }
        $script:Shell.JournalCount = 0
    }
    Add-UiLog 'Restart Windows to be certain every service and policy change has settled.' 'warn'

    foreach ($vm in $script:AllTweaks) { $vm.State = '' }
    $script:Shell.RestartPending = $true
    Update-Counts

    $script:Shell.Status = 'Re-reading the machine state...'
    Sync-Ui
    Update-TweakStates $script:AllTweaks
    Update-Coverage
    $script:Shell.Status = 'Ready'
    Update-Filter

    $foot = if ($stopped) { "Stopped early: $ok restored, $bad failed" } else { "$ok restored, $bad failed" }
    Close-BusyPanel $foot
}

# --------------------------------------------------------------- wiring

function Register-Handlers {

    $win = $script:Ui.Win

    # --- window chrome
    (Get-El 'BtnMin').Add_Click({ $script:Ui.Win.WindowState = 'Minimized' })
    (Get-El 'BtnMax').Add_Click({
            $w = $script:Ui.Win
            $w.WindowState = if ($w.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }
        })
    (Get-El 'BtnClose').Add_Click({
            if ($script:Shell.IsBusy) { return }
            if ($script:Shell.HasPending) {
                $r = [Windows.MessageBox]::Show(
                    "You have $($script:Shell.PendingTotal) changes staged that have not been applied. Close anyway?",
                    'Windows Debloat Studio', 'YesNo', 'Warning')
                if ($r -ne 'Yes') { return }
            }
            $script:Ui.Win.Close()
        })

    # --- navigation rail
    $railTop = Get-El 'RailTop'
    $railTop.Add_SelectionChanged({
            $sel = $args[0].SelectedItem
            if ($null -eq $sel) { return }
            (Get-El 'RailCats').SelectedIndex = -1
            (Get-El 'TxtSearch').Text = ''
            switch ($sel.Key) {
                'overview' {
                    $script:Shell.SectionTitle = 'Windows Debloat Studio'
                    $script:Shell.SectionBlurb = 'Read this page once before you change anything. It explains how the three choices work, what the journal does for you, and the order of work that goes wrong least often.'
                    Set-View 'overview'
                }
                'presets' {
                    $script:Shell.SectionTitle = 'Presets'
                    $script:Shell.SectionBlurb = 'A preset is a named set of choices. Staging one ticks its options for you and leaves the rest alone; nothing is applied until you review and confirm. Save your own to repeat them on another PC or to share.'
                    Set-View 'presets'
                }
            }
        })

    $railCats = Get-El 'RailCats'
    $railCats.Add_SelectionChanged({
            $sel = $args[0].SelectedItem
            if ($null -eq $sel) { return }
            (Get-El 'RailTop').SelectedIndex = -1
            Select-Category $sel.Key
        })

    # --- search and filters
    (Get-El 'TxtSearch').Add_TextChanged({
            if ($script:View -ne 'options' -and -not [string]::IsNullOrWhiteSpace((Get-El 'TxtSearch').Text)) {
                Set-View 'options'
            }
            Update-Filter
        })
    (Get-El 'BtnSearchClear').Add_Click({ (Get-El 'TxtSearch').Text = '' })

    foreach ($n in @('TglSafe', 'TglModerate', 'TglAggressive')) {
        (Get-El $n).Add_Click({ Update-Filter })
    }
    (Get-El 'ChkHideDone').Add_Click({ Update-Filter })

    # --- bulk actions across whatever is currently listed
    $bulk = {
        param($state, $label)
        $items = @((Get-El 'LstTweaks').ItemsSource)
        if ($items.Count -eq 0) { return }
        $n = 0
        foreach ($vm in $items) {
            if ($state -eq 'Revert' -and -not (Test-TweakTouched $vm.Id)) { continue }
            $vm.State = $state
            $n++
        }
        Update-Counts
        if ($state -eq '') { Show-Toast "Cleared the selection on $($items.Count) options." }
        else { Show-Toast "Set $n of $($items.Count) shown options to $label." }
    }
    (Get-El 'BtnBulkEnable').Add_Click({ & $script:Ui.Bulk 'Enable' 'Enable' })
    (Get-El 'BtnBulkDisable').Add_Click({ & $script:Ui.Bulk 'Disable' 'Disable' })
    (Get-El 'BtnBulkRevert').Add_Click({ & $script:Ui.Bulk 'Revert' 'Revert' })
    (Get-El 'BtnBulkClear').Add_Click({ & $script:Ui.Bulk '' 'no choice' })
    $script:Ui.Bulk = $bulk

    # --- card buttons, caught as they bubble out of the item templates
    $lst = Get-El 'LstTweaks'
    $lst.AddHandler(
        [Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [Windows.RoutedEventHandler] {
            param($s, $e)
            $btn = $e.OriginalSource -as [Windows.Controls.Button]
            if ($null -eq $btn) { return }
            $vm = $btn.DataContext -as [Debloat.TweakVM]
            if ($null -eq $vm) { return }
            switch ($btn.Name) {
                'BtnCardClear' { $vm.State = ''; Update-Counts }
                'BtnCardExpand' { $vm.IsExpanded = -not $vm.IsExpanded }
            }
        })
    $lst.AddHandler(
        [Windows.Controls.Primitives.ToggleButton]::CheckedEvent,
        [Windows.RoutedEventHandler] {
            param($s, $e)
            $rb = $e.OriginalSource -as [Windows.Controls.RadioButton]
            if ($null -eq $rb) { return }
            $vm = $rb.DataContext -as [Debloat.TweakVM]
            if ($null -eq $vm) { return }
            if ($vm.State -eq 'Revert' -and -not (Test-TweakTouched $vm.Id)) {
                Show-Toast 'This app has never changed that option, so there is nothing to revert to. The change will be skipped.' 'warn'
            }
            Update-Counts
        })

    # --- preset cards
    $presetHost = Get-El 'LstPresets'
    $presetHost.AddHandler(
        [Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [Windows.RoutedEventHandler] {
            param($s, $e)
            $btn = $e.OriginalSource -as [Windows.Controls.Button]
            if ($null -eq $btn) { return }
            $p = $btn.DataContext -as [Debloat.PresetVM]
            if ($null -eq $p) { return }

            switch ($btn.Name) {
                'BtnPresetStage' {
                    if ($p.IsLocked) { Deny-Feature 'presets.advanced'; return }
                    Set-PresetSelections $p.Id | Out-Null
                }
                'BtnPresetInspect' {
                    if ($p.IsLocked) { Deny-Feature 'presets.advanced'; return }
                    Set-PresetSelections $p.Id | Out-Null
                    $sel = Get-PresetSelections $p.Id
                    $first = $null
                    foreach ($c in $script:Categories) {
                        foreach ($vm in $c.Tweaks) { if ($sel.ContainsKey($vm.Id)) { $first = $c; break } }
                        if ($first) { break }
                    }
                    if ($first) {
                        $cats = Get-El 'RailCats'
                        for ($i = 0; $i -lt $cats.Items.Count; $i++) {
                            if ($cats.Items[$i].Key -eq $first.Key) { $cats.SelectedIndex = $i; break }
                        }
                    }
                }
                'BtnPresetExport' {
                    if (-not (Test-Feature 'presets.save')) { Deny-Feature 'presets.save'; return }
                    $dlg = New-Object Microsoft.Win32.SaveFileDialog
                    $dlg.Filter = 'Debloat preset (*.json)|*.json'
                    $dlg.FileName = (Get-SafeFileName $p.Name) + '.json'
                    $dlg.Title = 'Export preset'
                    if ($dlg.ShowDialog()) {
                        try {
                            Export-PresetOut -PresetId $p.Id -DestPath $dlg.FileName | Out-Null
                            Show-Toast "Exported to $([IO.Path]::GetFileName($dlg.FileName))."
                        } catch { Show-Toast "Export failed: $($_.Exception.Message)" 'error' }
                    }
                }
                'BtnPresetDelete' {
                    $r = [Windows.MessageBox]::Show(
                        "Delete the preset '$($p.Name)'? The file will be removed from the presets folder. Nothing on your PC changes.",
                        'Delete preset', 'YesNo', 'Warning')
                    if ($r -eq 'Yes') {
                        Remove-UserPreset -Path $p.Path
                        Refresh-PresetList
                        Show-Toast 'Preset deleted.'
                    }
                }
            }
        })

    (Get-El 'BtnPresetImport').Add_Click({
            if (-not (Test-Feature 'presets.save')) { Deny-Feature 'presets.save'; return }
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Filter = 'Debloat preset (*.json)|*.json|All files (*.*)|*.*'
            $dlg.Title = 'Import a preset file'
            if ($dlg.ShowDialog()) {
                try {
                    $dest = Copy-PresetIn -SourcePath $dlg.FileName
                    Refresh-PresetList
                    Show-Toast "Imported $([IO.Path]::GetFileName($dest)). It is now in the list below."
                } catch { Show-Toast "Import failed: $($_.Exception.Message)" 'error' }
            }
        })
    (Get-El 'BtnPresetSaveCurrent').Add_Click({ Show-SavePresetDialog })
    (Get-El 'BtnSavePreset').Add_Click({ Show-SavePresetDialog })

    # --- save preset dialog
    (Get-El 'BtnSaveCancel').Add_Click({ (Get-El 'OvSave').Visibility = 'Collapsed' })
    (Get-El 'BtnSaveOk').Add_Click({
            $name = (Get-El 'TxtPresetName').Text.Trim()
            if ([string]::IsNullOrWhiteSpace($name)) {
                Show-Toast 'Give the preset a name first.' 'warn'
                return
            }
            $sel = @{}
            foreach ($vm in (Get-StagedTweaks)) { $sel[$vm.Id] = $vm.State }
            try {
                $f = Save-UserPreset -Name $name -Summary (Get-El 'TxtPresetSummary').Text.Trim() `
                    -Detail (Get-El 'TxtPresetDetail').Text.Trim() -Selections $sel
                (Get-El 'OvSave').Visibility = 'Collapsed'
                Refresh-PresetList
                Show-Toast "Saved as $([IO.Path]::GetFileName($f)). Share that file to share these choices."
            } catch { Show-Toast "Could not save: $($_.Exception.Message)" 'error' }
        })

    # --- footer
    (Get-El 'BtnClearAll').Add_Click({
            Clear-AllSelections
            Show-Toast 'All selections cleared.'
        })
    (Get-El 'BtnApply').Add_Click({ Show-ConfirmSheet })
    (Get-El 'BtnConfirmCancel').Add_Click({ (Get-El 'OvConfirm').Visibility = 'Collapsed' })
    (Get-El 'BtnConfirmApply').Add_Click({ Invoke-Apply })

    (Get-El 'BtnUndoAll').Add_Click({
            $n = Get-JournalTweakCount
            if ($n -eq 0) {
                Show-Toast 'This app has not changed anything on this PC yet.' 'warn'
                return
            }
            $r = [Windows.MessageBox]::Show(
                "Put back every change this app has made on this PC?`n`n$n options were changed. Each one goes back to the exact value recorded before the app first touched it, oldest first.`n`nApps that were removed are reinstalled where their files are still on disk. The cleanup options in Advanced deleted data and cannot be undone.`n`nContinue?",
                'Undo everything', 'YesNo', 'Warning')
            if ($r -eq 'Yes') { Invoke-GlobalUndo }
        })

    # --- busy panel
    (Get-El 'BtnBusyCancel').Add_Click({
            $script:Cancel = $true
            (Get-El 'BtnBusyCancel').IsEnabled = $false
            $script:Shell.BusyTitle = 'Stopping...'
            Add-UiLog 'Stop requested. Finishing the option that is running, then stopping.' 'warn'
        })
    (Get-El 'BtnBusyClose').Add_Click({ (Get-El 'OvBusy').Visibility = 'Collapsed' })
    (Get-El 'BtnBusySaveLog').Add_Click({
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.Filter = 'Text file (*.txt)|*.txt'
            $dlg.FileName = 'debloat-log-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt'
            $dlg.InitialDirectory = $script:Paths.Logs
            if ($dlg.ShowDialog()) {
                $lines = foreach ($l in $script:LogItems) { '{0}  {1}' -f $l.Time, $l.Text }
                [IO.File]::WriteAllLines($dlg.FileName, $lines)
                Show-Toast 'Log saved.'
            }
        })

    # --- sidebar safety block
    (Get-El 'BtnRestorePoint').Add_Click({
            Open-BusyPanel 'Creating a restore point' 'Asking Windows for a System Restore point. This usually takes under a minute.'
            Add-UiLog 'Requesting a restore point...' 'head'
            Sync-Ui
            $rp = New-SystemRestorePoint -Description ('Debloat Studio manual - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
            if ($rp.Ok) {
                Add-UiLog 'Restore point created. You can find it under System Restore in Control Panel.' 'ok'
                Close-BusyPanel 'Restore point created.'
            } else {
                Add-UiLog $rp.Message 'error'
                Add-UiLog 'The usual cause is System Protection being turned off for the system drive. Turn it on under System Properties, Protection settings.' 'warn'
                Close-BusyPanel 'Could not create a restore point.'
            }
        })
    (Get-El 'BtnOpenLogs').Add_Click({ Start-Process explorer.exe $script:Paths.Logs })

    # The hand-over report. Technician: it exists for giving a machine back to
    # somebody else, which is not something you do to your own PC.
    (Get-El 'BtnReport').Add_Click({
            if (-not (Test-Feature 'report')) {
                Deny-Feature 'report'
                return
            }
            $dlg = New-Object Microsoft.Win32.SaveFileDialog
            $dlg.Title = 'Save the hand-over report'
            $dlg.Filter = 'Web page (*.html)|*.html'
            $dlg.FileName = ('Changes to ' + $env:COMPUTERNAME + ' ' + (Get-Date -Format 'yyyy-MM-dd') + '.html')
            $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
            if (-not $dlg.ShowDialog()) { return }
            try {
                $r = Export-ChangeReport -Path $dlg.FileName
                Add-UiLog "hand-over report written to $($r.Path) covering $($r.Count) changed option(s)" 'ok'
                Show-Toast ("Report saved. $($r.Count) changed option(s).") 'ok'
                Start-Process $r.Path
            } catch {
                Add-UiLog "the report could not be written: $($_.Exception.Message)" 'error'
                Show-Toast 'The report could not be written. See the log.' 'warn'
            }
        })

    # --- licence
    (Get-El 'BtnTier').Add_Click({ Show-LicensePanel })
    (Get-El 'BtnLicClose').Add_Click({ (Get-El 'OvLicense').Visibility = 'Collapsed' })

    (Get-El 'BtnLicActivate').Add_Click({
            $key = (Get-El 'TxtLicKey').Text
            if ([string]::IsNullOrWhiteSpace($key)) { Show-Toast 'Paste your licence key first.' 'warn'; return }
            $script:Shell.Status = 'Checking your key with Polar...'
            Sync-Ui
            $r = Register-License -Key $key
            $script:Shell.Status = 'Ready'
            if ($r.Ok) {
                Sync-LicenseUi
                Refresh-PresetList
                Sync-LicenseUi
                Show-Toast $r.Message
            } else {
                Show-Toast $r.Message 'error'
                (Get-El 'TxtLicDetail').Text = $r.Message
            }
        })

    (Get-El 'BtnLicRecheck').Add_Click({
            $script:Shell.Status = 'Checking with Polar...'
            Sync-Ui
            Update-LicenseValidation -Force | Out-Null
            $script:Shell.Status = 'Ready'
            Sync-LicenseUi
            Show-Toast (Get-Entitlement).Detail
        })

    (Get-El 'BtnLicRemove').Add_Click({
            $r = [Windows.MessageBox]::Show(
                "Remove this licence from this PC?`n`nThe Pro features lock again here, and the activation slot is released so you can use it on another machine.",
                'Remove licence', 'YesNo', 'Question')
            if ($r -ne 'Yes') { return }
            $res = Unregister-License
            Sync-LicenseUi
            Refresh-PresetList
            Sync-LicenseUi
            Show-Toast $res.Message
        })

    (Get-El 'BtnLicBuy').Add_Click({
            Open-Url (Get-CheckoutUrl 'pro') 'No Pro checkout link is set in data\licensing.json yet.'
        })
    (Get-El 'BtnLicBuyTech').Add_Click({
            Open-Url (Get-CheckoutUrl 'technician') 'No Technician checkout link is set in data\licensing.json yet.'
        })
    (Get-El 'BtnLicPortal').Add_Click({
            Open-Url (Get-CheckoutUrl 'portal') 'No purchases page link is set in data\licensing.json yet.'
        })

    # The GPL asks that an interactive program tell the user where the source is
    # and how to read the terms. For this app that is not a formality: being able
    # to read what it does before letting it change your PC is the point.
    (Get-El 'BtnLicSource').Add_Click({
            Open-Url $script:SourceUrl 'No source URL is set in data\licensing.json yet.'
        })
    (Get-El 'BtnLicTerms').Add_Click({
            # The licence ships beside the app, but in the packaged build that
            # folder is temporary - so fall back to the canonical copy.
            $local = Join-Path $script:Paths.Root 'LICENSE'
            if (Test-Path -LiteralPath $local) { Start-Process -FilePath $local }
            else { Open-Url 'https://www.gnu.org/licenses/gpl-3.0.html' }
        })

    # --- rescan the live state
    (Get-El 'BtnRescan').Add_Click({
            if ($script:Shell.IsBusy) { return }
            Invoke-Rescan
        })

    # --- restart Windows, offered only after changes that need one
    (Get-El 'BtnRestartNow').Add_Click({
            $r = [Windows.MessageBox]::Show(
                "Restart Windows now?`n`nSave your work in other programs first. Windows will restart in ten seconds and you can cancel it from a command prompt with 'shutdown /a' if you change your mind.",
                'Restart Windows', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
            Add-UiLog 'Restarting Windows in ten seconds.' 'warn'
            & shutdown.exe /r /t 10 /c 'Windows Debloat Studio: finishing pending changes' | Out-Null
        })

    # --- help
    (Get-El 'BtnHelp').Add_Click({ (Get-El 'OvHelp').Visibility = 'Visible' })
    (Get-El 'BtnHelpClose').Add_Click({ (Get-El 'OvHelp').Visibility = 'Collapsed' })

    # --- keyboard
    $win.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq 'Escape') {
                foreach ($n in @('OvLicense', 'OvHelp', 'OvSave', 'OvConfirm')) {
                    $o = Get-El $n
                    if ($o.Visibility -eq 'Visible') { $o.Visibility = 'Collapsed'; $e.Handled = $true; return }
                }
                if ((Get-El 'OvBusy').Visibility -eq 'Visible' -and -not $script:Shell.IsBusy) {
                    (Get-El 'OvBusy').Visibility = 'Collapsed'; $e.Handled = $true; return
                }
            }
            if ($e.Key -eq 'F' -and $e.KeyboardDevice.Modifiers -eq 'Control') {
                (Get-El 'TxtSearch').Focus() | Out-Null
                $e.Handled = $true
            }
        })
}

# --------------------------------------------------------------- entry

function Start-DebloatUi {

    Initialize-Interop

    # Claim a taskbar identity of our own, before any window exists. Without
    # this the taskbar button inherits the host process - powershell.exe - and
    # shows PowerShell's icon and groups with PowerShell windows, whatever icon
    # the window itself carries.
    if (-not [Debloat.Shell]::SetAppId('WndTech.WindowsDebloatStudio')) {
        Write-AppLog 'could not set the taskbar identity; the window may show the host icon' 'warn'
    }

    $app = [Windows.Application]::Current
    if ($null -eq $app) { $app = New-Object Windows.Application }
    $app.ShutdownMode = 'OnMainWindowClose'

    $theme = Import-XamlFile (Join-Path $script:Paths.Gui 'Theme.xaml')
    $app.Resources.MergedDictionaries.Add($theme)

    $win = Import-XamlFile (Join-Path $script:Paths.Gui 'MainWindow.xaml')
    $script:Ui.Win = $win
    Set-WindowIcon $win

    $script:Shell = New-Object Debloat.ShellVM
    $script:Shell.AdminText = if (Test-IsAdmin) { 'Administrator' } else { 'NOT elevated' }
    $win.DataContext = $script:Shell

    $script:LogItems = New-Object Collections.ObjectModel.ObservableCollection[object]
    (Get-El 'LstLog').ItemsSource = $script:LogItems

    # catalogue and rail
    Import-Catalog | Out-Null

    $topItems = New-Object Collections.ObjectModel.ObservableCollection[object]
    $ov = New-Object Debloat.CategoryVM
    $ov.Key = 'overview'; $ov.Name = 'Start here'; $ov.Glyph = [string][char]0xE946
    $ov.Total = 0
    $topItems.Add($ov)
    $pr = New-Object Debloat.CategoryVM
    $pr.Key = 'presets'; $pr.Name = 'Presets'; $pr.Glyph = [string][char]0xE8FD
    $pr.Total = 0
    $topItems.Add($pr)
    (Get-El 'RailTop').ItemsSource = $topItems

    (Get-El 'RailCats').ItemsSource = @($script:Categories | ForEach-Object { $_.Vm })

    # A search made from the overview page needs somewhere to fall back to.
    $script:ActiveCategory = $script:Categories[0]

    Register-Handlers
    Build-Help

    # Licence first, so presets know whether they are locked as they are built.
    # A free install makes no network call here at all.
    $ent = Initialize-License
    Write-AppLog "licence tier=$($ent.TierId) status=$($ent.Status)" 'info'

    Refresh-PresetList
    Sync-LicenseUi

    # Show the busy panel now so it is already on screen the moment the window
    # paints, rather than appearing a beat later.
    Open-BusyPanel 'Reading your current configuration' "Checking the live state of $($script:AllTweaks.Count) options: registry values, services, installed apps and scheduled tasks."
    (Get-El 'RailTop').SelectedIndex = 0

    # The state scan reads every service, package and scheduled task on the
    # machine and then probes all 355 options. That takes ten seconds or more,
    # and it used to run here - before Application.Run had shown the window. So
    # the user double-clicked and watched nothing at all for the whole scan,
    # while the busy panel and progress bar it faithfully updated were being
    # drawn to a window that was not on screen yet.
    #
    # ContentRendered fires once the window has actually painted, so the scan
    # now runs behind a visible progress bar. It can fire again on later
    # re-renders, hence the guard.
    $script:StartupScanDone = $false
    $win.Add_ContentRendered({
            if ($script:StartupScanDone) { return }
            $script:StartupScanDone = $true
            Start-InitialScan
        })

    $app.Run($win) | Out-Null
}

# The first read of the live machine state. Split out of Start-DebloatUi so it
# can be run after the window is visible.
function Start-InitialScan {
    Add-UiLog 'Reading services...' 'head'
    Sync-Ui
    Get-ServiceCache | Out-Null
    Add-UiLog 'Reading installed apps...' 'head'
    Sync-Ui
    Get-AppxCache | Out-Null
    Get-AppxProvisionedCache | Out-Null
    Add-UiLog 'Reading scheduled tasks...' 'head'
    Sync-Ui
    Get-TaskCache | Out-Null
    Add-UiLog 'Checking each option...' 'head'
    Sync-Ui

    $prog = {
        param($i, $n)
        $script:Shell.Progress = [math]::Round(($i / $n) * 100, 1)
        $script:Shell.BusyDetail = "Checked $i of $n options."
        Sync-Ui
    }
    Update-TweakStates $script:AllTweaks $prog

    $script:Shell.JournalCount = Get-JournalTweakCount
    Add-UiLog "Ready. $($script:AllTweaks.Count) options loaded across $($script:Categories.Count) categories." 'ok'
    Add-UiLog 'Windows features, optional capabilities and the options that have to run a query are read when you first open their category, because those are slow.' 'info'
    Close-BusyPanel 'Nothing has been changed. Nothing is selected.'
    (Get-El 'OvBusy').Visibility = 'Collapsed'

    Build-Overview
}
