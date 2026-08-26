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
#  Unattended.ps1 - applying a preset with no window. A Technician feature.
#
#  Kept in a module rather than inline in Debloat.ps1 for one reason: a
#  code path that writes to the registry on someone else's machines has to
#  be testable, and an inline block in a script's entry point is not.
#
#  What is NOT gated here: the journal. An unattended apply records the
#  prior state of every action exactly as the window does, so it is just
#  as reversible, and Undo everything works on it afterwards. The paid
#  part is doing it without a person present, never the safety net.
# =====================================================================

# Reads a preset file and turns it into a selection map, or explains why not.
function Read-PresetFile {
    param([Parameter(Mandatory)][string]$Path)

    $full = $Path
    try { $full = [IO.Path]::GetFullPath($Path) } catch { }

    if (-not (Test-Path -LiteralPath $full)) {
        return [pscustomobject]@{ Ok = $false; Code = 3; Message = "No preset file at $full"; Selections = $null; Name = $null }
    }

    $doc = $null
    try { $doc = Read-JsonFile $full } catch {
        return [pscustomobject]@{ Ok = $false; Code = 3; Message = "$full is not valid JSON: $($_.Exception.Message)"; Selections = $null; Name = $null }
    }
    if ($null -eq $doc -or (-not $doc.selections -and -not $doc.rules)) {
        return [pscustomobject]@{ Ok = $false; Code = 3
            Message = "$full is not a preset: it has no selections and no rules."
            Selections = $null; Name = $null }
    }

    $sel = Resolve-PresetSelections $doc
    $name = if ($doc.name) { "$($doc.name)" } else { Split-Path -Leaf $full }
    return [pscustomobject]@{ Ok = $true; Code = 0; Message = $null; Selections = $sel; Name = $name; Path = $full }
}

# Applies one option, exactly the way the window does: capture the prior state,
# journal it, then change the setting - in that order, per action.
function Invoke-UnattendedTweak {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Direction,
        [switch]$DryRun
    )

    $vm = $script:TweakVMs[$Id]
    $def = Get-TweakDef $Id
    if ($null -eq $def -or $null -eq $vm) {
        return [pscustomobject]@{ Outcome = 'unknown'; Notes = @("no such option: $Id"); Restart = $false }
    }

    $problems = New-Object Collections.Generic.List[string]

    if ($Direction -eq 'Revert') {
        $caps = @(Get-TweakOriginalCaptures $Id)
        if ($caps.Count -eq 0) {
            return [pscustomobject]@{ Outcome = 'skipped'
                Notes = @('this app has never changed it, so there is nothing recorded to go back to')
                Restart = $false }
        }
        foreach ($c in $caps) {
            foreach ($note in (Restore-ActionCapture -Capture $c.Capture -DryRun:$DryRun)) {
                if ($note -match 'ACCESS DENIED|could not|cannot') { $problems.Add($note) }
            }
        }
        if (-not $DryRun) {
            Remove-JournalTweak $Id
            $vm.IsTouched = $false
        }
    } else {
        $idx = 0
        foreach ($a in $def.Actions) {
            if (-not $DryRun) {
                $cap = Get-ActionCapture $a
                Add-JournalEntry -TweakId $Id -TweakName $vm.Name -Direction $Direction -Index $idx -Capture $cap
            }
            foreach ($note in (Set-ActionState -Action $a -Direction $Direction -DryRun:$DryRun)) {
                if ($note -match 'ACCESS DENIED|could not|cannot') { $problems.Add($note) }
            }
            $idx++
        }
        if (-not $DryRun) { $vm.IsTouched = $true }
    }

    $outcome = if ($problems.Count) { 'failed' } else { 'applied' }
    return [pscustomobject]@{
        Outcome = $outcome
        Notes = $problems.ToArray()
        Restart = [bool]$vm.RequiresRestart
    }
}

# The whole unattended run. Returns a result rather than exiting, so the caller
# decides the exit code and so this can be tested without ending the process.
function Invoke-UnattendedApply {
    param(
        [Parameter(Mandatory)][string]$PresetPath,
        [switch]$DryRun,
        [scriptblock]$OnLine
    )

    $say = {
        param($text, $colour)
        if ($OnLine) { & $OnLine $text $colour }
    }

    $read = Read-PresetFile -Path $PresetPath
    if (-not $read.Ok) {
        & $say $read.Message 'Red'
        return [pscustomobject]@{ Code = $read.Code; Applied = 0; Failed = 0; Skipped = 0; Restart = $false }
    }

    $sel = $read.Selections
    if ($sel.Count -eq 0) {
        & $say 'That preset matches no option in this catalogue. Nothing to do.' 'Yellow'
        return [pscustomobject]@{ Code = 0; Applied = 0; Failed = 0; Skipped = 0; Restart = $false }
    }

    $mode = if ($DryRun) { '  DRY RUN - nothing will be changed' } else { $null }
    if ($mode) { & $say $mode 'Yellow' }

    $applied = 0; $failed = 0; $skipped = 0; $restart = $false

    foreach ($id in ($sel.Keys | Sort-Object)) {
        $dir = "$($sel[$id])"
        $r = Invoke-UnattendedTweak -Id $id -Direction $dir -DryRun:$DryRun
        $vm = $script:TweakVMs[$id]
        $label = if ($vm) { "$($vm.Name)" } else { $id }

        switch ($r.Outcome) {
            'applied' {
                $applied++
                if ($r.Restart) { $restart = $true }
                & $say ("  {0,-9}{1}" -f $dir.ToLower(), $label) 'DarkGray'
            }
            'skipped' {
                $skipped++
                & $say ("  {0,-9}{1}  -  {2}" -f 'skipped', $label, ($r.Notes -join '; ')) 'DarkYellow'
            }
            default {
                $failed++
                & $say ("  {0,-9}{1}  -  {2}" -f 'FAILED', $label, ($r.Notes -join '; ')) 'Red'
            }
        }
    }

    return [pscustomobject]@{
        Code = if ($failed) { 4 } else { 0 }
        Applied = $applied; Failed = $failed; Skipped = $skipped
        Restart = $restart; Name = $read.Name; Total = $sel.Count
    }
}
