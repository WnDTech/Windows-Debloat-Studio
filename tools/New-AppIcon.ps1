<#
    New-AppIcon.ps1
    ---------------
    Draws assets\app.ico: the app mark, in every size Windows asks for.

    The mark is four window panes with one taken away. It says the one thing
    this app does - Windows, with the excess removed - and the asymmetry is what
    makes it recognisable at 16 pixels, where a symmetrical 2x2 grid would just
    read as the generic "all apps" button.

    Two things were tried and rejected, both by rendering them and looking:

      A corner bracket. It was an accident of two CSS borders that happened to
      look like a letter L, and there is no L in Windows Debloat Studio. When
      the first person to see it asked what the L meant, that settled it.

      A ghost pane in the empty slot, to say the removed thing can come back.
      Lovely at 128px. At 16 and 24 the ghost sits too close in value to read as
      absent, so the mark collapsed into a plain 2x2 grid - losing the idea at
      exactly the sizes that matter most.

    Drawn from code rather than exported from a design tool, so the icon is
    reproducible from source and the build needs nothing installed.
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

# Deep indigo, one hue from light to dark. Deliberately not the app's accent
# blue: that is the same blue as every other utility in the tray, which was
# most of why the old icon did not stand out. Deliberately not a two-hue
# gradient either - purple-into-blue is the look that reads as generated.
$TileTop = [Drawing.Color]::FromArgb(0xFF, 0x63, 0x5B, 0xFF)
$TileBottom = [Drawing.Color]::FromArgb(0xFF, 0x43, 0x38, 0xCA)
$Ink = [Drawing.Color]::White

# Proportions, as fractions of the icon's side. Shared with the XAML title bar
# and the website's CSS so all three are the same mark.
$TilePad = 0.045     # inset of the tile, so the rounded corners are not clipped
$TileRadius = 0.235  # corner radius
$Cell = 0.235        # one pane
$Gap = 0.070         # between panes

$Sizes = @(256, 128, 64, 48, 32, 24, 16)

function New-Mark {
    param([int]$Size)

    $bmp = New-Object Drawing.Bitmap([int]$Size, [int]$Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([Drawing.Color]::Transparent)

        # ---- the tile
        $pad = [double]$Size * $TilePad
        $side = [double]$Size - (2 * $pad)
        $d = ([double]$Size * $TileRadius) * 2

        $path = New-Object Drawing.Drawing2D.GraphicsPath
        $path.AddArc($pad, $pad, $d, $d, 180, 90)
        $path.AddArc($pad + $side - $d, $pad, $d, $d, 270, 90)
        $path.AddArc($pad + $side - $d, $pad + $side - $d, $d, $d, 0, 90)
        $path.AddArc($pad, $pad + $side - $d, $d, $d, 90, 90)
        $path.CloseFigure()

        $rect = New-Object Drawing.RectangleF([single]$pad, [single]$pad, [single]$side, [single]$side)
        $brush = New-Object Drawing.Drawing2D.LinearGradientBrush($rect, $TileTop, $TileBottom, 90.0)
        $g.FillPath($brush, $path)
        $brush.Dispose(); $path.Dispose()

        # ---- the panes: top-left, top-right, bottom-left. Bottom-right is the
        #      one that was removed, and its absence is the whole mark.
        $cell = [double]$Size * $Cell
        $gap = [double]$Size * $Gap
        $block = (2 * $cell) + $gap
        $ox = ($Size - $block) / 2
        $oy = ($Size - $block) / 2

        # Under about 32px a fractional edge gets smeared across two pixel
        # columns and the panes lose their crispness, so those sizes are snapped
        # to whole pixels and drawn with antialiasing off.
        $small = ($Size -le 32)
        $g.SmoothingMode = if ($small) { 'None' } else { 'AntiAlias' }

        $solid = New-Object Drawing.SolidBrush($Ink)
        foreach ($p in @(@(0, 0), @(1, 0), @(0, 1))) {
            $x = $ox + ($p[0] * ($cell + $gap))
            $y = $oy + ($p[1] * ($cell + $gap))
            if ($small) {
                $w = [int][Math]::Max(3, [Math]::Round($cell))
                $g.FillRectangle($solid, [int][Math]::Round($x), [int][Math]::Round($y), $w, $w)
            } else {
                $g.FillRectangle($solid, [single]$x, [single]$y, [single]$cell, [single]$cell)
            }
        }
        $solid.Dispose()
    } finally { $g.Dispose() }
    return $bmp
}

# ---------------------------------------------------------------- write the ico
$dir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# Encodes one image the way the ICO format's original entry type wants it: a
# BITMAPINFOHEADER whose height is doubled to cover the colour bitmap and the
# mask that follows it, then 32bpp BGRA rows stored bottom-up, then a 1bpp mask.
# The mask is left all-zero because the alpha channel already carries
# transparency, but the format still requires the bytes to be there.
#
# PNG-compressed entries are smaller and the Windows shell reads them, but
# plenty of consumers do not - System.Drawing among them - so anything at or
# below 64px is written as a plain DIB and only the large sizes are PNG.
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

$frames = @()
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
    $frames += , @{ Size = $s; Bytes = $bytes }
    $bmp.Dispose()
}

$out = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter($out)

# ICONDIR: reserved, type 1 (icon), image count
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$frames.Count)

# Directory entries come first, so every image offset is known up front.
$offset = 6 + (16 * $frames.Count)
foreach ($f in $frames) {
    $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }   # 0 means 256 in this format
    $w.Write([byte]$dim); $w.Write([byte]$dim)
    $w.Write([byte]0)                 # palette count, 0 for truecolour
    $w.Write([byte]0)                 # reserved
    $w.Write([uint16]1)               # colour planes
    $w.Write([uint16]32)              # bits per pixel
    $w.Write([uint32]([byte[]]$f.Bytes).Length)
    $w.Write([uint32]$offset)
    $offset += ([byte[]]$f.Bytes).Length
}
foreach ($f in $frames) { $w.Write([byte[]]$f.Bytes) }

$w.Flush()
[IO.File]::WriteAllBytes($OutFile, $out.ToArray())
$w.Dispose(); $out.Dispose()

$kb = [Math]::Round((Get-Item $OutFile).Length / 1KB, 1)
Write-Host ("  wrote {0}  ({1} sizes, {2} KB)" -f $OutFile, $frames.Count, $kb) -ForegroundColor Green
