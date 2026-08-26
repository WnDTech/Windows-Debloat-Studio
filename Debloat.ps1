<#
    Windows Debloat Studio
    ----------------------
    A WPF front end for reviewing and reversing Windows 11's telemetry,
    advertising, preinstalled apps and shell behaviour.

    Run it with the launcher next to this file, or by hand:
        powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "Debloat.ps1"

    Nothing is selected when the window opens and nothing is applied until
    you press Review and apply and confirm.
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
    # Skip the automatic elevation prompt. Machine-wide options will fail.
    [switch]$NoElevate,
    # Report what the catalogue contains and exit, without opening a window.
    [switch]$Validate,
    # Apply a preset file with no window and no prompts, then exit. Technician.
    [string]$Apply,
    # Write a hand-over report of everything changed on this PC, then exit.
    [string]$Report,
    # With -Apply: walk the preset and report, changing nothing at all.
    [switch]$DryRun,
    # With -Apply: do not ask, do not summarise interactively. Implied.
    [switch]$Silent,
    # Print the switches and exit.
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------- elevation

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$headless = $Validate -or $Apply -or $Report -or $Help

if ($Help) {
    # A here-string, because the earlier version concatenated with + inside
    # Write-Host, which PowerShell reads as extra positional arguments and
    # prints them space-separated in the wrong order.
    @'

  Windows Debloat Studio

  Run it with no arguments to open the window.

    --validate             list the catalogue and presets, change nothing
    --apply <preset.json>  apply a preset with no window        [Technician]
    --dry-run              with --apply: report, change nothing
    --report <out.html>    write a hand-over report             [Technician]
    --noelevate            skip the elevation prompt
    --help                 this

  Exit codes:  0 done    2 not licensed    3 bad input    4 something failed

  Scripting it. This is a windowed program, so a shell does not wait for it
  and will not hand you the exit code. Wait for it explicitly:

    $p = Start-Process .\WindowsDebloatStudio.exe -Wait -PassThru -NoNewWindow `
            -ArgumentList '--apply', 'build.json'
    $p.ExitCode

  Add -RedirectStandardOutput log.txt to capture what it did. From cmd:

    start /wait "" WindowsDebloatStudio.exe --apply build.json

'@ | Write-Host
    exit 0
}
if (-not $headless -and -not $NoElevate -and -not (Test-Elevated)) {
    Write-Host ''
    Write-Host '  Windows Debloat Studio needs administrator rights to read and change' -ForegroundColor Yellow
    Write-Host '  machine-wide settings. Asking for elevation...' -ForegroundColor Yellow
    Write-Host ''
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = (Join-Path $PSHOME 'powershell.exe')
        $psi.Arguments = '-STA -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $MyInvocation.MyCommand.Path
        $psi.Verb = 'runas'
        $psi.UseShellExecute = $true
        [Diagnostics.Process]::Start($psi) | Out-Null
        exit 0
    } catch {
        Write-Host '  Elevation was declined. Continuing without it.' -ForegroundColor DarkYellow
        Write-Host '  Machine-wide options will report access denied.' -ForegroundColor DarkYellow
        Write-Host ''
    }
}

# ---------------------------------------------------------------- apartment state

# WPF needs a single-threaded apartment. Windows PowerShell is STA by default
# only when launched with -STA, so re-launch ourselves if we are not.
if (-not $headless -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host '  Restarting in a single-threaded apartment for WPF...' -ForegroundColor DarkGray
    $args2 = '-STA -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $MyInvocation.MyCommand.Path
    if ($NoElevate) { $args2 += ' -NoElevate' }
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $args2 -Wait
    exit 0
}

# ---------------------------------------------------------------- load

Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop
Add-Type -AssemblyName System.Xaml -ErrorAction Stop

. (Join-Path $Root 'src\Modules\Core.ps1')
Initialize-Paths -Root $Root

. (Join-Path $Root 'src\Modules\Engine.ps1')
. (Join-Path $Root 'src\Modules\Journal.ps1')
. (Join-Path $Root 'src\Modules\Catalog.ps1')
. (Join-Path $Root 'src\Modules\Presets.ps1')
. (Join-Path $Root 'src\Modules\License.ps1')
. (Join-Path $Root 'src\Modules\Report.ps1')
. (Join-Path $Root 'src\Modules\Unattended.ps1')
. (Join-Path $Root 'src\Modules\Ui.ps1')

Write-AppLog "session start, admin=$(Test-IsAdmin), pid=$PID" 'head'
foreach ($n in @($script:MigrationNotes)) { if ($n) { Write-AppLog $n 'ok' } }

# ---------------------------------------------------------------- validate mode

if ($Validate) {
    Initialize-Interop
    $cats = Import-Catalog
    $presets = Import-Presets

    Write-Host ''
    Write-Host ('  {0} options across {1} categories' -f $script:AllTweaks.Count, $cats.Count) -ForegroundColor Cyan
    foreach ($c in $cats) {
        $s = @($c.Tweaks | Where-Object { $_.Risk -eq 'safe' }).Count
        $m = @($c.Tweaks | Where-Object { $_.Risk -eq 'moderate' }).Count
        $a = @($c.Tweaks | Where-Object { $_.Risk -eq 'aggressive' }).Count
        Write-Host ('    {0,-38} {1,3} options   safe {2,3}  moderate {3,3}  aggressive {4,3}' -f $c.Name, $c.Tweaks.Count, $s, $m, $a)
    }
    Write-Host ''
    Write-Host ('  {0} presets' -f $presets.Count) -ForegroundColor Cyan
    foreach ($p in $presets) {
        Write-Host ('    {0,-26} {1,-11} {2}' -f $p.Name, $p.RiskLabel, $p.CountSummary)
    }
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------- unattended
#
# Applying a preset with no window, and writing the hand-over report, are both
# Technician features. Note what is *not* gated: the journal is still written,
# so an unattended apply is exactly as reversible as one done by clicking, and
# Undo everything works on it afterwards. The gate is on the convenience of
# doing it without a person present, never on the safety net.
#
# Exit codes, because the whole point is being scriptable:
#   0  applied, or nothing needed applying
#   2  not licensed for this
#   3  the preset file could not be read
#   4  one or more actions failed

if ($Apply -or $Report) {
    Initialize-Interop
    Import-Catalog | Out-Null
    Import-Presets | Out-Null
    $ent = Initialize-License

    $needed = if ($Apply) { 'cli' } else { 'report' }
    if (-not (Test-Feature $needed)) {
        $tier = Get-TierForFeature $needed
        $tierName = if ($tier) { "$($tier.name)" } else { 'Technician' }
        Write-Host ''
        Write-Host ("  " + (Get-FeatureDescription $needed) + " is part of $tierName.") -ForegroundColor Yellow
        Write-Host ("  This install is on $($ent.TierName). Everything else is unaffected:") -ForegroundColor DarkGray
        Write-Host '  every option, the journal, Revert and Undo everything are free.' -ForegroundColor DarkGray
        Write-Host ''
        Write-AppLog "unattended $needed refused: tier=$($ent.TierId)" 'warn'
        exit 2
    }

    if ($Report) {
        try {
            $r = Export-ChangeReport -Path ([IO.Path]::GetFullPath($Report))
            Write-Host ''
            Write-Host ("  Report written to $($r.Path)") -ForegroundColor Green
            Write-Host ("  $($r.Count) option(s) changed on this PC.") -ForegroundColor DarkGray
            Write-Host ''
            Write-AppLog "report written to $($r.Path), $($r.Count) options" 'ok'
            exit 0
        } catch {
            Write-Host ("  The report could not be written: $($_.Exception.Message)") -ForegroundColor Red
            Write-AppLog "report failed: $($_.Exception.Message)" 'error'
            exit 3
        }
    }

    # ---- unattended apply
    Write-Host ''
    Write-Host ("  Windows Debloat Studio $script:AppVersion  -  unattended") -ForegroundColor Cyan
    Write-Host ("  licence $($ent.TierName), administrator=$(Test-IsAdmin)") -ForegroundColor DarkGray

    $emit = { param($text, $colour) Write-Host $text -ForegroundColor $colour }
    $res = Invoke-UnattendedApply -PresetPath $Apply -DryRun:$DryRun -OnLine $emit

    Write-Host ''
    if ($res.Total -gt 0) {
        $tail = ''
        if ($res.Skipped) { $tail += ", $($res.Skipped) skipped" }
        if ($res.Restart) { $tail += ', a restart is needed' }
        $verb = if ($DryRun) { 'would be applied' } else { 'applied' }
        Write-Host ("  $($res.Applied) $verb, $($res.Failed) failed$tail") `
            -ForegroundColor $(if ($res.Failed) { 'Yellow' } else { 'Green' })
        if ($DryRun) {
            Write-Host '  Nothing was changed and nothing was journalled.' -ForegroundColor DarkGray
        } else {
            Write-Host ("  Every change is in $($script:Paths.Journal) and can be undone.") -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-AppLog ("unattended apply$(if ($DryRun) { ' (dry run)' }): $($res.Applied) applied, $($res.Failed) failed, restart=$($res.Restart)") `
        $(if ($res.Failed) { 'warn' } else { 'ok' })
    exit $res.Code
}

# ---------------------------------------------------------------- run

$os = Get-WindowsBuildInfo
Write-Host ''
Write-Host '  Windows Debloat Studio' -ForegroundColor Cyan
Write-Host ("  $($os.Product) $($os.Display), build $($os.Build)") -ForegroundColor DarkGray
if (-not $os.Is11) {
    Write-Host '  This catalogue targets Windows 11. Some options will read as Unknown.' -ForegroundColor Yellow
}
Write-Host '  Loading...' -ForegroundColor DarkGray

try {
    Start-DebloatUi
} catch {
    Write-Host ''
    Write-Host '  The window could not be opened.' -ForegroundColor Red
    Write-Host ("  $($_.Exception.Message)") -ForegroundColor Red
    if ($_.Exception.InnerException) {
        Write-Host ("  inner: $($_.Exception.InnerException.Message)") -ForegroundColor DarkRed
    }
    Write-Host ("  at: $($_.InvocationInfo.PositionMessage)") -ForegroundColor DarkGray
    Write-AppLog "startup failed: $($_.Exception.Message)" 'error'
    Write-AppLog ("stack: " + ($_.ScriptStackTrace -replace "`r?`n", ' | ')) 'error'
    Write-AppLog ("type: " + $_.Exception.GetType().FullName) 'error'
    # Launched from the packaged exe there is no console to read from: output is
    # piped back to the bootstrapper, which shows the tail of it in a dialog.
    # Only wait for a keypress when a person is actually looking at a terminal.
    if (-not [Console]::IsInputRedirected) {
        Write-Host ''
        Write-Host '  Press any key to close.' -ForegroundColor DarkGray
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
    }
    exit 1
}

Write-AppLog 'session end' 'head'
