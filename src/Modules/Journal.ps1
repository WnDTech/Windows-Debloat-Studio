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
#  Journal.ps1 - the safety net.
#
#  Every action this app performs writes one line to logs\journal.jsonl
#  holding the exact state that existed beforehand. That single file backs
#  both "Revert" on one option and the global "Undo all changes".
# =====================================================================

$script:Journal = $null

function Get-Journal {
    if ($null -eq $script:Journal) {
        $list = New-Object Collections.ObjectModel.ObservableCollection[object]
        if (Test-Path -LiteralPath $script:Paths.Journal) {
            foreach ($line in [IO.File]::ReadAllLines($script:Paths.Journal)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $list.Add(($line | ConvertFrom-Json)) } catch { }
            }
        }
        $script:Journal = $list
    }
    return , $script:Journal
}

function Add-JournalEntry {
    param(
        [Parameter(Mandatory)][string]$TweakId,
        [Parameter(Mandatory)][string]$TweakName,
        [Parameter(Mandatory)][string]$Direction,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)]$Capture
    )
    $j = Get-Journal
    $entry = [ordered]@{
        seq       = $j.Count + 1
        ts        = (Get-Date).ToString('o')
        tweakId   = $TweakId
        tweakName = $TweakName
        direction = $Direction
        idx       = $Index
        capture   = $Capture
    }
    $json = ($entry | ConvertTo-Json -Depth 12 -Compress)
    Add-Content -LiteralPath $script:Paths.Journal -Value $json -Encoding UTF8
    $j.Add(($json | ConvertFrom-Json))
}

# Number of distinct options this app has touched - what the Undo button counts.
function Get-JournalTweakCount {
    $j = Get-Journal
    if ($j.Count -eq 0) { return 0 }
    return @($j | Select-Object -ExpandProperty tweakId -Unique).Count
}

function Test-TweakTouched {
    param([string]$TweakId)
    foreach ($e in (Get-Journal)) { if ($e.tweakId -eq $TweakId) { return $true } }
    return $false
}

# The very first capture recorded for an option is its pre-app state, which is
# what Revert must go back to - not the state before the most recent change.
function Get-TweakOriginalCaptures {
    param([string]$TweakId)
    $byIdx = [ordered]@{}
    foreach ($e in (Get-Journal)) {
        if ($e.tweakId -ne $TweakId) { continue }
        $k = "$($e.idx)"
        if (-not $byIdx.Contains($k)) { $byIdx[$k] = $e.capture }
    }
    $out = @()
    foreach ($k in $byIdx.Keys) { $out += [pscustomobject]@{ Index = [int]$k; Capture = $byIdx[$k] } }
    return ($out | Sort-Object Index)
}

# Everything, newest first, so an undo unwinds in the reverse of the order applied.
function Get-JournalUndoPlan {
    $j = Get-Journal
    $seen = @{}
    $plan = New-Object Collections.ObjectModel.ObservableCollection[object]
    for ($i = $j.Count - 1; $i -ge 0; $i--) {
        $e = $j[$i]
        $key = "$($e.tweakId)|$($e.idx)"
        if ($seen.ContainsKey($key)) { continue }   # an older entry is the truer original
        $seen[$key] = $true
        $plan.Add($e)
    }
    # Re-order so the oldest capture wins but the unwind still runs newest-tweak-first.
    $orig = @{}
    foreach ($e in $j) {
        $key = "$($e.tweakId)|$($e.idx)"
        if (-not $orig.ContainsKey($key)) { $orig[$key] = $e }
    }
    $final = New-Object Collections.ObjectModel.ObservableCollection[object]
    foreach ($e in $plan) {
        $key = "$($e.tweakId)|$($e.idx)"
        $final.Add($orig[$key])
    }
    return , $final
}

function Clear-Journal {
    param([switch]$Archive)
    if ((Test-Path -LiteralPath $script:Paths.Journal) -and $Archive) {
        # Beside the journal, not in the per-user log folder: an archived
        # journal is still a record of machine changes, and someone looking for
        # what a previous undo threw away should find it in one place.
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $dest = Join-Path $script:Paths.State "journal-undone-$stamp.jsonl"
        Move-Item -LiteralPath $script:Paths.Journal -Destination $dest -Force
    } elseif (Test-Path -LiteralPath $script:Paths.Journal) {
        Remove-Item -LiteralPath $script:Paths.Journal -Force
    }
    $script:Journal = $null
}

# Drop the recorded history for one option once it has been reverted, so the
# option stops claiming it has been touched.
function Remove-JournalTweak {
    param([string]$TweakId)
    $j = Get-Journal
    $keep = @($j | Where-Object { $_.tweakId -ne $TweakId })
    $lines = @()
    $n = 1
    foreach ($e in $keep) {
        $e.seq = $n; $n++
        $lines += ($e | ConvertTo-Json -Depth 12 -Compress)
    }
    if ($lines.Count -eq 0) {
        if (Test-Path -LiteralPath $script:Paths.Journal) { Remove-Item -LiteralPath $script:Paths.Journal -Force }
    } else {
        [IO.File]::WriteAllLines($script:Paths.Journal, $lines)
    }
    $script:Journal = $null
}
