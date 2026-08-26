<#
    Test-Package.ps1
    ----------------
    Checks the built exe before it goes anywhere near a customer.

    The interesting checks are the negative ones. A build script that quietly
    includes one extra file is how a dev machine's paths, a test harness, or a
    stale licence ends up inside a public download - and none of that shows up
    by running the app and finding that it works.

    Run tools\Build-Exe.ps1 first.
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

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSCommandPath
$Root = Split-Path -Parent $Root
if (-not $Exe) { $Exe = Join-Path $Root 'dist\WindowsDebloatStudio.exe' }

$pass = 0; $fail = 0
function Check {
    param([string]$What, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $What) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  FAIL  " + $What + "  " + $Detail) -ForegroundColor Red }
}
function Head { param([string]$M) Write-Host ''; Write-Host "  $M" -ForegroundColor Cyan }

if (-not (Test-Path -LiteralPath $Exe)) { throw "No exe at $Exe - run tools\Build-Exe.ps1 first." }

# ---------------------------------------------------------------- the file
Head 'A) the file itself'
$item = Get-Item -LiteralPath $Exe
Check 'the download is a single file' ($item.PSIsContainer -eq $false)
Check 'it is small enough to not look suspicious' ($item.Length -lt 5MB) ("{0:N0} KB" -f ($item.Length / 1KB))

$vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($Exe)
Check 'UAC will show the app name, not "Windows PowerShell"' `
    ($vi.FileDescription -eq 'Windows Debloat Studio') $vi.FileDescription
Check 'a product name is set' (-not [string]::IsNullOrWhiteSpace($vi.ProductName)) $vi.ProductName
Check 'a company is set' (-not [string]::IsNullOrWhiteSpace($vi.CompanyName)) $vi.CompanyName

$coreText = Get-Content (Join-Path $Root 'src\Modules\Core.ps1') -Raw
$null = $coreText -match "\`$script:AppVersion\s*=\s*'([^']+)'"
$appVersion = $Matches[1]
Check 'the exe version matches the app version' ($vi.FileVersion -like ($appVersion + '*')) `
    ("exe=" + $vi.FileVersion + " app=" + $appVersion)

# ---------------------------------------------------------------- resources
Head 'B) icon and manifest'
$bytes = [IO.File]::ReadAllBytes($Exe)
$text = [Text.Encoding]::ASCII.GetString($bytes)
Check 'the manifest asks for administrator' ($text -match 'requireAdministrator')
Check 'and does not ask for uiAccess' ($text -notmatch 'uiAccess="true"')
Check 'an icon is embedded' ($bytes.Length -gt 0 -and (Test-Path (Join-Path $Root 'assets\app.ico')))

# Every icon entry has to be readable by the shell, or Explorer falls back to
# the generic exe icon at whichever size is broken.
Add-Type -AssemblyName PresentationCore
$icoPath = Join-Path $Root 'assets\app.ico'
$dec = New-Object Windows.Media.Imaging.IconBitmapDecoder(
    (New-Object Uri((Resolve-Path $icoPath).Path)),
    [Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
    [Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
$frames = @($dec.Frames).Count
Check 'every icon size decodes' ($frames -ge 5) ("$frames frames")
$has16 = @($dec.Frames | Where-Object { $_.PixelWidth -eq 16 }).Count -eq 1
Check 'there is a 16px icon for the taskbar and title bar' $has16

# ---------------------------------------------------------------- the payload
Head 'C) what is actually inside'

# Read the embedded payload back out the same way the bootstrapper does.
$asm = [Reflection.Assembly]::LoadFile($Exe)
$stream = $asm.GetManifestResourceStream('payload.bin')
Check 'the payload resource is present' ($null -ne $stream)

$inflate = New-Object IO.Compression.DeflateStream($stream, [IO.Compression.CompressionMode]::Decompress)
$buf = New-Object IO.MemoryStream
$inflate.CopyTo($buf)
$inflate.Dispose()
$buf.Position = 0
$r = New-Object IO.BinaryReader($buf)

$count = $r.ReadInt32()
$files = [ordered]@{}
for ($i = 0; $i -lt $count; $i++) {
    $rel = [Text.Encoding]::UTF8.GetString($r.ReadBytes($r.ReadInt32()))
    $ticks = $r.ReadInt64()
    $data = $r.ReadBytes($r.ReadInt32())
    $files[$rel] = [pscustomobject]@{ Bytes = $data; Ticks = $ticks }
}
$r.Dispose(); $buf.Dispose()
Write-Host ("   $count files unpacked from the exe") -ForegroundColor DarkGray

Check 'the entry script is there' ($files.Contains('Debloat.ps1'))
Check 'all seven modules are there' (@($files.Keys | Where-Object { $_ -like 'src\Modules\*.ps1' }).Count -eq 7) `
    ("found " + @($files.Keys | Where-Object { $_ -like 'src\Modules\*.ps1' }).Count)
Check 'both XAML files are there' (@($files.Keys | Where-Object { $_ -like 'src\Gui\*.xaml' }).Count -eq 2)
Check 'the view-model source is there' ($files.Contains('src\Interop\Interop.cs'))
Check 'all fifteen catalogue files are there' (@($files.Keys | Where-Object { $_ -like 'data\catalog\*' }).Count -eq 15) `
    ("found " + @($files.Keys | Where-Object { $_ -like 'data\catalog\*' }).Count)

# The negative checks: nothing that belongs only on a development machine.
foreach ($unwanted in @('tools\', 'site\', 'logs\', 'presets\', 'dist\', 'assets\', 'src\Bootstrap\', '.git')) {
    $hit = @($files.Keys | Where-Object { $_ -like ($unwanted + '*') })
    Check "no $unwanted in the download" ($hit.Count -eq 0) ($hit -join ', ')
}
$compiled = @($files.Keys | Where-Object { $_ -like '*.dll' -or $_ -like '*.exe' })
Check 'no compiled binaries are shipped inside the payload' ($compiled.Count -eq 0) ($compiled -join ', ')

# ---------------------------------------------------------------- leakage
Head 'D) nothing from this machine leaks out'

# A path or a user name baked into a public download is both an information
# leak and a support problem, because it will not exist on the customer's PC.
$leaks = @{
    'this developer user name' = $env:USERNAME
    'this machine name'        = $env:COMPUTERNAME
    'the build folder path'    = $Root
}
foreach ($k in $leaks.Keys) {
    $needle = $leaks[$k]
    if ([string]::IsNullOrWhiteSpace($needle)) { continue }
    $found = New-Object Collections.Generic.List[string]
    foreach ($rel in $files.Keys) {
        $t = [Text.Encoding]::UTF8.GetString($files[$rel].Bytes)
        if ($t -like ('*' + $needle + '*')) { $found.Add($rel) }
    }
    Check "no $k in the payload" ($found.Count -eq 0) ([string]::Join(', ', $found))
}

# The licence config must ship unactivated: no key, no activation id.
$licRel = 'data\licensing.json'
if ($files.Contains($licRel)) {
    $lic = [Text.Encoding]::UTF8.GetString($files[$licRel].Bytes) | ConvertFrom-Json
    Check 'the shipped licence config carries no licence key' `
        (-not ($lic.PSObject.Properties.Name -contains 'key'))
    Check 'the shipped licence config carries no activation' `
        (-not ($lic.PSObject.Properties.Name -contains 'activationId'))
}

# ---------------------------------------------------------------- timestamps
Head 'E) timestamps are carried across'
# Without this the app rebuilds its view-models on every single launch, because
# a freshly unpacked Interop.cs always looks newer than the cached assembly.
$interop = $files['src\Interop\Interop.cs']
$onDisk = (Get-Item (Join-Path $Root 'src\Interop\Interop.cs')).LastWriteTimeUtc.Ticks
Check 'Interop.cs keeps its real write time' ($interop.Ticks -eq $onDisk) `
    ("payload=" + $interop.Ticks + " disk=" + $onDisk)
$anyZero = @($files.Keys | Where-Object { $files[$_].Ticks -le 0 })
Check 'no file has a missing timestamp' ($anyZero.Count -eq 0) ($anyZero -join ', ')

# ---------------------------------------------------------------- checksum
Head 'F) the published checksum'
$sumFile = "$Exe.sha256"
Check 'a checksum file was written' (Test-Path -LiteralPath $sumFile)
if (Test-Path -LiteralPath $sumFile) {
    $published = (Get-Content $sumFile -Raw).Trim().Split(' ')[0].ToLower()
    $actual = (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash.ToLower()
    Check 'the checksum matches the exe' ($published -eq $actual) ("published=" + $published.Substring(0, 16))
}

# ---------------------------------------------------------------- signature
Head 'G) the download page matches this build'
# The page publishes the checksum people are told to verify against. The
# compiler stamps a new module id into every build, so a page that was right
# yesterday is wrong today - which would teach users to ignore the mismatch.
$site = Join-Path $Root 'site\index.html'
if (Test-Path -LiteralPath $site) {
    $html = [IO.File]::ReadAllText($site, [Text.UTF8Encoding]::new($false))
    $actual = (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash.ToLower()
    Check 'the page publishes this exe''s checksum' ($html -match [regex]::Escape($actual))

    $kb = [int][Math]::Round($item.Length / 1KB)
    $shown = [regex]::Match($html, '(?<=<p class="dl-meta">)(\d+)(?=&nbsp;KB)')
    Check 'the page shows the right file size' ($shown.Success -and [int]$shown.Value -eq $kb) `
        ("page=" + $shown.Value + "KB exe=" + $kb + "KB")
    Check 'the page shows the right version' ($html -match ('version ' + [regex]::Escape($appVersion)))

    # A stale hash from an earlier build must not still be sitting on the page.
    $allHashes = @([regex]::Matches($html, '\b[0-9a-f]{64}\b') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $stale = @($allHashes | Where-Object { $_ -ne $actual })
    Check 'no leftover checksum from a previous build' ($stale.Count -eq 0) ($stale -join ', ')
} else {
    Write-Host '  NOTE  no site\index.html to check' -ForegroundColor DarkYellow
}

Head 'H) signature'
$sig = Get-AuthenticodeSignature -LiteralPath $Exe
if ($sig.Status -eq 'Valid') {
    Check 'signed and valid' $true $sig.SignerCertificate.Subject
} else {
    Write-Host ("  NOTE  not signed yet (" + $sig.Status + ")") -ForegroundColor DarkYellow
    Write-Host '        SmartScreen will show "Windows protected your PC" on first run.' -ForegroundColor DarkYellow
}

Write-Host ''
if ($fail -eq 0) { Write-Host "  PACKAGE TEST PASSED  ($pass checks)" -ForegroundColor Green }
else { Write-Host "  PACKAGE TEST: $fail failed, $pass passed" -ForegroundColor Red }
exit $fail
