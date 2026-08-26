<#
    New-AppIcon.ps1
    ---------------
    Draws assets\app.ico: the same mark the window and the website use, a
    rounded square in the app's accent blue with a white corner bracket.

    Written by hand rather than exported from a design tool so the icon is
    reproducible from source, and so the build needs nothing installed.
    ICO files are a directory of images; Windows Vista onwards reads PNG
    entries at every size, which keeps the large sizes small.
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
    [string]$OutFile
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $OutFile) {
    $toolsDir = Split-Path -Parent $PSCommandPath
    $OutFile = Join-Path (Split-Path -Parent $toolsDir) 'assets\app.ico'
}

$Accent = [Drawing.Color]::FromArgb(0xFF, 0x4C, 0x8D, 0xFF)   # C.Accent in Theme.xaml
$Ink = [Drawing.Color]::White
$Sizes = @(256, 128, 64, 48, 32, 24, 16)

function New-Mark {
    param([int]$Size)

    $bmp = New-Object Drawing.Bitmap($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.Clear([Drawing.Color]::Transparent)

        # A rounded square, inset slightly so the corners are not clipped.
        $pad = [double]$Size * 0.055
        $side = [double]$Size - (2 * $pad)
        $r = [double]$Size * 0.22          # matches border-radius .36rem on 1.3rem

        $path = New-Object Drawing.Drawing2D.GraphicsPath
        $d = $r * 2
        $x = $pad; $y = $pad; $w = $side; $h = $side
        $path.AddArc($x, $y, $d, $d, 180, 90)
        $path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
        $path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
        $path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
        $path.CloseFigure()

        $fill = New-Object Drawing.SolidBrush($Accent)
        $g.FillPath($fill, $path)
        $fill.Dispose()

        # The corner bracket: left and bottom strokes, open to the top right.
        # It reads as a baseline being swept clean, and as an L for "left as
        # you found it". Same geometry as the .mark i::after rule on the site.
        $inX = $pad + ($side * 0.26)
        $inTop = $pad + ($side * 0.24)
        $inBot = $pad + ($side * 0.74)
        $inRight = $pad + ($side * 0.76)

        $stroke = [Math]::Max(1.0, [double]$Size * 0.075)
        $pen = New-Object Drawing.Pen($Ink, $stroke)
        $pen.StartCap = 'Square'; $pen.EndCap = 'Square'
        $g.DrawLine($pen, $inX, $inTop, $inX, $inBot)
        $g.DrawLine($pen, $inX, $inBot, $inRight, $inBot)
        $pen.Dispose()

        $path.Dispose()
    } finally { $g.Dispose() }
    return $bmp
}

# ---------------------------------------------------------------- write the ico
$dir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# Encodes one image the way the ICO format's original entry type wants it: a
# BITMAPINFOHEADER whose height is doubled to cover the colour bitmap and the
# mask that follows it, then 32bpp BGRA rows stored bottom-up, then a 1bpp
# mask. The mask is left all-zero because the alpha channel already carries
# transparency, but the format still requires the bytes to be there.
#
# This matters for compatibility. PNG-compressed entries are smaller and the
# Windows shell reads them, but plenty of consumers do not - System.Drawing
# among them - so anything at or below 64px is written as a plain DIB and only
# the large sizes are PNG.
function ConvertTo-IcoDib {
    param([Drawing.Bitmap]$Bitmap)

    $w = $Bitmap.Width; $h = $Bitmap.Height
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)

    $bw.Write([uint32]40)          # biSize
    $bw.Write([int32]$w)           # biWidth
    $bw.Write([int32]($h * 2))     # biHeight, colour bitmap plus mask
    $bw.Write([uint16]1)           # biPlanes
    $bw.Write([uint16]32)          # biBitCount
    $bw.Write([uint32]0)           # biCompression, BI_RGB
    $bw.Write([uint32]($w * $h * 4))
    $bw.Write([int32]0); $bw.Write([int32]0)      # pixels per metre
    $bw.Write([uint32]0); $bw.Write([uint32]0)    # palette counts

    # Bottom-up BGRA.
    for ($y = $h - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $w; $x++) {
            $c = $Bitmap.GetPixel($x, $y)
            $bw.Write([byte]$c.B); $bw.Write([byte]$c.G)
            $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
        }
    }

    # The AND mask: one bit per pixel, each row padded to a 4-byte boundary.
    $rowBytes = [Math]::Ceiling($w / 8.0)
    $stride = [int]([Math]::Ceiling($rowBytes / 4.0) * 4)
    $blank = New-Object byte[] ($stride * $h)
    $bw.Write($blank)

    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()

    # The comma matters. A bare "return $bytes" unrolls the array into the
    # pipeline, and the caller collects it back as object[] - whose Length is
    # still right, so the header looks correct, but BinaryWriter no longer
    # matches its byte[] overload and writes nothing at all.
    return , $bytes
}

$pngs = @()
foreach ($s in $Sizes) {
    $bmp = New-Mark -Size $s
    if ($s -le 64) {
        $bytes = ConvertTo-IcoDib -Bitmap $bmp
    } else {
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
        $ms.Dispose()
    }
    $pngs += , @{ Size = $s; Bytes = $bytes }
    $bmp.Dispose()
}

$out = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter($out)

# ICONDIR: reserved, type 1 (icon), image count
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$pngs.Count)

# Directory entries come first, so every image offset is known up front.
$offset = 6 + (16 * $pngs.Count)
foreach ($p in $pngs) {
    $dim = if ($p.Size -ge 256) { 0 } else { $p.Size }   # 0 means 256 in this format
    $w.Write([byte]$dim); $w.Write([byte]$dim)
    $w.Write([byte]0)                 # palette count, 0 for truecolour
    $w.Write([byte]0)                 # reserved
    $w.Write([uint16]1)               # colour planes
    $w.Write([uint16]32)              # bits per pixel
    $w.Write([uint32]([byte[]]$p.Bytes).Length)
    $w.Write([uint32]$offset)
    $offset += $p.Bytes.Length
}
foreach ($p in $pngs) { $w.Write([byte[]]$p.Bytes) }

$w.Flush()
[IO.File]::WriteAllBytes($OutFile, $out.ToArray())
$w.Dispose(); $out.Dispose()

$kb = [Math]::Round((Get-Item $OutFile).Length / 1KB, 1)
Write-Host ("  wrote {0}  ({1} sizes, {2} KB)" -f $OutFile, $pngs.Count, $kb) -ForegroundColor Green
