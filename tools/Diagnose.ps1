<#
    Diagnose.ps1
    ------------
    Run this when the app will not start, and send the output.

    It checks the things that actually stop it, in the order they bite, and it
    changes nothing. Run it the ordinary way - no elevation needed:

        powershell -ExecutionPolicy Bypass -File tools\Diagnose.ps1
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
param([string]$Exe)

$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $Exe) { $Exe = Join-Path $Root 'dist\WindowsDebloatStudio.exe' }

function Head { param($m) Write-Host ''; Write-Host "  $m" -ForegroundColor Cyan }
function Ok { param($m) Write-Host "  ok    $m" -ForegroundColor Green }
function Bad { param($m) Write-Host "  BAD   $m" -ForegroundColor Red }
function Note { param($m) Write-Host "  note  $m" -ForegroundColor DarkYellow }
function Info { param($m) Write-Host "        $m" -ForegroundColor DarkGray }

Head 'this machine'
$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Info ("Windows build {0}.{1}, {2}" -f $os.CurrentBuild, $os.UBR, $os.DisplayVersion)
Info ("PowerShell {0}, apartment {1}" -f $PSVersionTable.PSVersion,
    [Threading.Thread]::CurrentThread.GetApartmentState())
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Info ("running as {0}, elevated={1}" -f $id.Name, $elevated)

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Bad 'Windows PowerShell 5.1 is required and this is older.'
}

Head 'the executable'
if (-not (Test-Path -LiteralPath $Exe)) {
    Bad "not found: $Exe"
    Info 'If it vanished after downloading, antivirus removed it - see the next section.'
} else {
    $i = Get-Item -LiteralPath $Exe
    Ok ("found, {0:N0} KB, written {1}" -f ($i.Length / 1KB), $i.LastWriteTime)
    Info ("SHA-256  " + (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash.ToLower())

    # Mark of the Web. A file downloaded from the internet carries this, and it
    # is what makes SmartScreen challenge it.
    $zone = Get-Content -LiteralPath $Exe -Stream Zone.Identifier -ErrorAction SilentlyContinue
    if ($zone) {
        Note 'this file is marked as downloaded from the internet'
        Info 'That is what triggers "Windows protected your PC". To clear it:'
        Info ("    Unblock-File '" + $Exe + "'")
    } else {
        Ok 'no download mark, so SmartScreen will not challenge it'
    }

    $sig = Get-AuthenticodeSignature -LiteralPath $Exe
    if ($sig.Status -eq 'Valid') { Ok ("signed: " + $sig.SignerCertificate.Subject) }
    else { Note ("not signed (" + $sig.Status + ") - expect a SmartScreen warning on first run") }
}

Head 'antivirus'
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Info ("Defender real-time protection: " + $mp.RealTimeProtectionEnabled)
    $threats = @(Get-MpThreatDetection -ErrorAction SilentlyContinue |
        Where-Object { ($_.Resources -join ' ') -match 'Debloat' })
    if ($threats.Count) {
        Bad ("Defender has acted on this app " + $threats.Count + " time(s):")
        foreach ($t in $threats) { Info ("  " + $t.InitialDetectionTime + "  " + ($t.Resources -join '; ')) }
        Info 'Restore it from Windows Security > Protection history, and add an exclusion.'
    } else {
        Ok 'Defender has no detections recorded against this app'
    }
} catch { Note 'could not query Defender; a third-party antivirus may be in charge' }

Head 'where the app keeps state'
$machine = Join-Path $env:ProgramData 'WindowsDebloatStudio'
$user = Join-Path $env:LOCALAPPDATA 'WindowsDebloatStudio'

foreach ($pair in @(@{ P = $machine; N = 'machine state (journal, licence, presets)'; NeedWrite = $elevated },
                    @{ P = $user; N = 'per-user state (compiled assembly, logs)'; NeedWrite = $true })) {
    $p = $pair.P
    if (-not (Test-Path -LiteralPath $p)) { Info ($pair.N + ": not created yet - " + $p); continue }
    Info ($pair.N + ": " + $p)
    try {
        $acl = Get-Acl -LiteralPath $p
        Info ("  owner " + $acl.Owner + ", inheritance dropped=" + $acl.AreAccessRulesProtected)
    } catch { Note '  could not read permissions' }

    $probe = Join-Path $p ('probe-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.tmp')
    $canWrite = $false
    try { [IO.File]::WriteAllText($probe, 'x'); $canWrite = $true; Remove-Item $probe -Force } catch { }

    if ($canWrite) { Ok ('  writable by this account') }
    elseif ($pair.NeedWrite) {
        Bad '  NOT writable, and it needs to be - this will stop the app starting'
        Info '  Fix: run these in an elevated PowerShell, then start the app again.'
        Info ("      takeown /f `"$p`" /r /d y")
        Info ("      icacls `"$p`" /reset /t")
    } else {
        Ok '  read-only for this account, which is expected when not elevated'
    }
}

Head 'the last few sessions'
$logs = @(Get-ChildItem (Join-Path $user 'logs') -Filter 'session-*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 3)
if (-not $logs.Count) {
    Note 'no session logs at all - the app has never got as far as starting up'
} else {
    foreach ($l in $logs) {
        Write-Host ''
        Info ($l.Name + "  (" + $l.Length + " bytes)")
        $text = @(Get-Content -LiteralPath $l.FullName -ErrorAction SilentlyContinue)
        if ($text.Count -eq 0) { Bad '  empty - it died before it could log anything' }
        foreach ($line in ($text | Select-Object -Last 12)) {
            $colour = if ($line -match '\[ERROR\]') { 'Red' } elseif ($line -match '\[WARN\]') { 'DarkYellow' } else { 'Gray' }
            Write-Host ("        " + $line) -ForegroundColor $colour
        }
    }
    $errors = @(Select-String -Path ($logs | ForEach-Object { $_.FullName }) -Pattern '\[ERROR\]' -ErrorAction SilentlyContinue)
    Write-Host ''
    if ($errors.Count) {
        Bad ($errors.Count.ToString() + ' error line(s) found:')
        foreach ($e in ($errors | Select-Object -Last 6)) { Info ('  ' + $e.Line) }
    } else { Ok 'no errors logged' }
}

Head 'starting it from source, with everything visible'
Info 'If the exe does nothing, this shows the real error instead of hiding it:'
Info ('    powershell -STA -NoProfile -ExecutionPolicy Bypass -File "' +
    (Join-Path $Root 'Debloat.ps1') + '"')
Info ''
Info 'And this checks the catalogue loads without opening a window:'
Info ('    powershell -NoProfile -ExecutionPolicy Bypass -File "' +
    (Join-Path $Root 'Debloat.ps1') + '" -Validate')
Write-Host ''
