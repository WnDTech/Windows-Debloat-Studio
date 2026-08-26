<#
    Build-Exe.ps1
    -------------
    Produces dist\WindowsDebloatStudio.exe - the single file a customer
    downloads.

    Needs nothing installed. The C# compiler used here ships with the .NET
    Framework that is already part of Windows, which is the same compiler the
    app itself uses at runtime to build its view-models. So this build runs on
    a stock Windows 11 box with no SDK, no MSBuild and no package restore.

        .\tools\Build-Exe.ps1
        .\tools\Build-Exe.ps1 -Sign          # once a certificate exists

    What the exe contains is every file the app needs to run and nothing else:
    no tests, no website, no screenshots, and none of the state a previous run
    left behind. The payload is compressed but deliberately not obfuscated or
    packed - the whole selling point is that the PowerShell inside is readable,
    and packers are what makes a scanner assume the worst.
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
    # Sign the finished exe. Off by default because there is no certificate yet.
    [switch]$Sign,

    # Where the exe goes.
    [string]$OutDir,

    # Skip rebuilding the icon.
    [switch]$NoIcon
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$Tools = Split-Path -Parent $PSCommandPath
$Root = Split-Path -Parent $Tools
if (-not $OutDir) { $OutDir = Join-Path $Root 'dist' }

function Say { param([string]$M, [string]$C = 'Gray') Write-Host "  $M" -ForegroundColor $C }
function Head { param([string]$M) Write-Host ''; Write-Host "  $M" -ForegroundColor Cyan }

<#
    The one place that needs editing once a certificate exists.

    There is no free certificate that Windows trusts. A self-signed one does
    nothing for SmartScreen - it only helps if every user installs the root,
    which nobody should do. The realistic routes are:

      SignPath Foundation   free, but only for open-source projects
      Certum open source     about EUR 25/year, also open source only
      Azure Trusted Signing  about USD 10/month, needs a verified legal entity
      OV certificate         a few hundred a year, reputation still builds slowly
      EV certificate         dearer, but SmartScreen trusts it immediately

    Whichever is used, the call ends up being signtool with a timestamp URL.
    Timestamping is not optional: without it every signature stops validating
    the day the certificate expires, including on copies already downloaded.
#>
function Invoke-SignExe {
    param([Parameter(Mandatory)][string]$Path)

    $signtool = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if (-not $signtool) {
        Say 'signtool.exe is not on PATH - it comes with the Windows SDK.' 'Red'
        throw 'Cannot sign: signtool.exe not found.'
    }

    # Fill in one of these. Left empty on purpose so a build cannot silently
    # produce something that claims to be signed and is not.
    $thumbprint = ''      # certificate in the current user's store
    $pfxPath = ''         # or a .pfx on disk
    $timestampUrl = 'http://timestamp.digicert.com'

    if (-not $thumbprint -and -not $pfxPath) {
        Say 'No certificate is configured yet.' 'Red'
        Say 'Set $thumbprint or $pfxPath in Invoke-SignExe (tools\Build-Exe.ps1).' 'Red'
        throw 'Cannot sign: no certificate configured.'
    }

    $signArgs = @('sign', '/fd', 'SHA256', '/tr', $timestampUrl, '/td', 'SHA256')
    if ($thumbprint) { $signArgs += @('/sha1', $thumbprint) }
    else {
        $pw = Read-Host -AsSecureString 'Certificate password'
        $plainPw = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw))
        $signArgs += @('/f', $pfxPath, '/p', $plainPw)
    }
    $signArgs += $Path

    & $signtool.Source @signArgs
    if ($LASTEXITCODE -ne 0) { throw "signtool failed (exit $LASTEXITCODE)." }

    # Never trust the exit code alone; confirm the signature reads back.
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ($sig.Status -ne 'Valid') { throw "The signature did not verify: $($sig.Status)" }
    Say ("signed by {0}" -f $sig.SignerCertificate.Subject) 'Green'
}

# ---------------------------------------------------------------- version
Head 'version'
$coreText = Get-Content (Join-Path $Root 'src\Modules\Core.ps1') -Raw
if ($coreText -notmatch "\`$script:AppVersion\s*=\s*'([^']+)'") {
    throw 'Could not read $script:AppVersion out of Core.ps1.'
}
$version = $Matches[1]
# A Win32 version resource wants four parts.
$quad = $version
while (($quad -split '\.').Count -lt 4) { $quad += '.0' }
Say "app version $version  (file version $quad)" 'Green'

# The icon is generated rather than committed, and it is needed twice over:
# as the exe's Win32 resource and as a file inside the payload, so the window
# can set its own taskbar icon. Build it before the payload is assembled or a
# clean checkout fails with "these payload files are missing".
# ---------------------------------------------------------------- icon
if (-not $NoIcon) {
    Head 'icon'
    & (Join-Path $Tools 'New-AppIcon.ps1')
}
$icon = Join-Path $Root 'assets\app.ico'
if (-not (Test-Path -LiteralPath $icon)) { throw "The icon is missing: $icon" }

# ---------------------------------------------------------------- payload list
Head 'payload'

# Everything the app opens at runtime. Listed explicitly rather than swept up
# from the folder, so a stray file in the working tree can never end up inside
# a customer's download.
$include = @(
    'Debloat.ps1'
    'src\Modules\Core.ps1'
    'src\Modules\Engine.ps1'
    'src\Modules\Journal.ps1'
    'src\Modules\Catalog.ps1'
    'src\Modules\Presets.ps1'
    'src\Modules\License.ps1'
    'src\Modules\Ui.ps1'
    'src\Gui\MainWindow.xaml'
    'src\Gui\Theme.xaml'
    'src\Interop\Interop.cs'
    'data\licensing.json'
    'data\presets.json'
    # The window loads this at runtime for its taskbar and Alt-Tab icon. The
    # exe's own Win32 icon resource cannot serve: the window belongs to the
    # powershell.exe child process, which would otherwise show PowerShell's icon.
    'assets\app.ico'
)
foreach ($f in (Get-ChildItem (Join-Path $Root 'data\catalog') -Filter '*.json' | Sort-Object Name)) {
    $include += ('data\catalog\' + $f.Name)
}

$missing = @($include | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Root $_)) })
if ($missing.Count) { throw ("These payload files are missing: " + ($missing -join ', ')) }

# The app decides whether to recompile Interop.cs by comparing its write time
# against the compiled assembly's. Carrying the real write times across means
# an unchanged app does not rebuild its view-models on every single launch.
$entries = @()
foreach ($rel in $include) {
    $full = Join-Path $Root $rel
    $entries += , [pscustomobject]@{
        Rel   = $rel
        Bytes = [IO.File]::ReadAllBytes($full)
        Ticks = (Get-Item -LiteralPath $full).LastWriteTimeUtc.Ticks
    }
}
# Measure-Object on this PowerShell version will not take a script block for
# -Property, so total it by hand.
$rawTotal = 0
foreach ($e in $entries) { $rawTotal += $e.Bytes.Length }
Say ("{0} files, {1:N0} KB before compression" -f $entries.Count, ($rawTotal / 1KB))

# Container format, matching the reader in Bootstrap.cs:
#   int32 count, then per file: int32 pathLen, path, int64 ticks, int32 len, data
$ms = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter($ms)
$bw.Write([int32]$entries.Count)
foreach ($e in $entries) {
    $pathBytes = [Text.Encoding]::UTF8.GetBytes($e.Rel)
    $bw.Write([int32]$pathBytes.Length)
    $bw.Write([byte[]]$pathBytes)
    $bw.Write([int64]$e.Ticks)
    $bw.Write([int32]$e.Bytes.Length)
    $bw.Write([byte[]]$e.Bytes)
}
$bw.Flush()
$plain = $ms.ToArray()
$bw.Dispose(); $ms.Dispose()

$cms = New-Object IO.MemoryStream
$dz = New-Object IO.Compression.DeflateStream($cms, [IO.Compression.CompressionMode]::Compress, $true)
$dz.Write($plain, 0, $plain.Length)
$dz.Dispose()
$payload = $cms.ToArray()
$cms.Dispose()
Say ("compressed to {0:N0} KB  ({1:P0} of original)" -f ($payload.Length / 1KB), ($payload.Length / $plain.Length)) 'Green'

$obj = Join-Path $OutDir 'obj'
foreach ($d in @($OutDir, $obj)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$payloadFile = Join-Path $obj 'payload.bin'
[IO.File]::WriteAllBytes($payloadFile, $payload)

# ---------------------------------------------------------------- version attrs
# Kept in a generated file rather than hard-coded in Bootstrap.cs, so the exe's
# version always follows Core.ps1 and can never drift from the app's own.
$versionCs = Join-Path $obj 'Version.cs'
@"
// Generated by tools\Build-Exe.ps1. Do not edit.
using System.Reflection;

[assembly: AssemblyVersion("$quad")]
[assembly: AssemblyFileVersion("$quad")]
[assembly: AssemblyInformationalVersion("$version")]
"@ | Set-Content -LiteralPath $versionCs -Encoding UTF8

# ---------------------------------------------------------------- compile
Head 'compile'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) {
    throw 'The in-box C# compiler was not found. .NET Framework 4.x should be present on Windows 11.'
}
Say "using $csc"

$exe = Join-Path $OutDir 'WindowsDebloatStudio.exe'
if (Test-Path -LiteralPath $exe) { Remove-Item -LiteralPath $exe -Force }

$manifest = Join-Path $Root 'src\Bootstrap\app.manifest'
$cscArgs = @(
    '/nologo'
    '/target:winexe'          # no console window
    '/platform:anycpu'
    '/optimize+'
    '/warnaserror-'
    "/out:$exe"
    "/win32icon:$icon"
    "/win32manifest:$manifest"
    "/resource:$payloadFile,payload.bin"
    '/reference:System.dll'
    (Join-Path $Root 'src\Bootstrap\Bootstrap.cs')
    $versionCs
)
$out = & $csc @cscArgs 2>&1
$code = $LASTEXITCODE
$out | Where-Object { $_ -match '\S' } | ForEach-Object { Say $_ 'DarkYellow' }
if ($code -ne 0 -or -not (Test-Path -LiteralPath $exe)) { throw "The compile failed (exit $code)." }

$item = Get-Item -LiteralPath $exe
Say ("built {0}  ({1:N0} KB)" -f $item.Name, ($item.Length / 1KB)) 'Green'

# Confirm the metadata Windows will actually show in the UAC prompt.
$vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
Say ("UAC will name it: `"{0}`"" -f $vi.FileDescription)
Say ("file version {0}, product {1}" -f $vi.FileVersion, $vi.ProductName)

# ---------------------------------------------------------------- sign
Head 'signing'
if ($Sign) {
    Invoke-SignExe -Path $exe
} else {
    Say 'skipped: pass -Sign once a certificate is available' 'DarkYellow'
    Say 'unsigned means SmartScreen shows "Windows protected your PC" on first run' 'DarkYellow'
}

# ---------------------------------------------------------------- checksum
Head 'checksum'
$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLower()
$sumFile = "$exe.sha256"
"$hash *$($item.Name)" | Set-Content -LiteralPath $sumFile -Encoding ASCII
Say "SHA-256  $hash" 'Green'
Say "written to $(Split-Path -Leaf $sumFile)"

# ---------------------------------------------------------------- the site
# The download page publishes this checksum, and the compiler stamps a fresh
# module id into every build - so a hand-copied hash is wrong the moment the exe
# is rebuilt. Rewrite it here instead, from the file that was actually produced.
Head 'download page'
$site = Join-Path $Root 'site\index.html'
if (Test-Path -LiteralPath $site) {
    $html = [IO.File]::ReadAllText($site, [Text.UTF8Encoding]::new($false))
    $before = $html

    $html = [Text.RegularExpressions.Regex]::Replace($html,
        '(?<=<p class="dl-sha"><span>SHA-256</span><code>)[0-9a-f]{64}(?=</code></p>)', $hash)

    $kb = [int][Math]::Round($item.Length / 1KB)
    $html = [Text.RegularExpressions.Regex]::Replace($html,
        '(?<=<p class="dl-meta">)\d+(?=&nbsp;KB)', "$kb")
    $html = [Text.RegularExpressions.Regex]::Replace($html,
        '(?<=<p class="dl-meta">[^<]*version )\d+\.\d+\.\d+', $version)
    $html = [Text.RegularExpressions.Regex]::Replace($html,
        '(?<=one file, about )\d+(?=&nbsp;KB)', "$kb")

    if ($html -ne $before) {
        [IO.File]::WriteAllText($site, $html, [Text.UTF8Encoding]::new($false))
        Say "updated the checksum and size on the download page" 'Green'
    } else {
        Say 'download page already matches'
    }

    # Never let the build claim success if the page and the exe disagree.
    $check = [IO.File]::ReadAllText($site, [Text.UTF8Encoding]::new($false))
    if ($check -notmatch [regex]::Escape($hash)) {
        throw 'The download page does not carry this build''s checksum. Check the dl-sha markup in site\index.html.'
    }
} else {
    Say 'no site\index.html to update' 'DarkYellow'
}

Head 'done'
Say "$exe" 'Green'
Say 'remember to republish the download page - its checksum changed' 'DarkYellow'
Write-Host ''
