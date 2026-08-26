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
#  Presets.ps1 - built-in and user presets.
#
#  A preset only ever contains option ids and the word Enable, Disable or
#  Revert. It can never carry a registry path or a command, so importing a
#  preset a stranger sent you cannot make this app do anything that is not
#  already in the catalog and visible on screen.
#
#  Built-in presets may also use rules (by category, risk or tag) so they
#  stay complete as the catalog grows. User presets are always explicit.
# =====================================================================

$script:Presets = $null       # list of PresetVM
$script:PresetSel = $null     # preset id -> hashtable of tweakId -> state

function Resolve-PresetSelections {
    param($Preset)

    $sel = @{}

    foreach ($rule in @($Preset.rules)) {
        if ($null -eq $rule) { continue }
        $action = if ($rule.action) { $rule.action } else { 'Disable' }

        $cats = @($rule.categories | Where-Object { $_ })
        $risks = @($rule.risk | Where-Object { $_ })
        $tags = @($rule.tags | Where-Object { $_ })
        $exTags = @($rule.excludeTags | Where-Object { $_ })
        $exIds = @($rule.excludeIds | Where-Object { $_ })
        $exCats = @($rule.excludeCategories | Where-Object { $_ })
        $ids = @($rule.ids | Where-Object { $_ })

        # A rule only sweeps the catalogue when it actually names a selector.
        # Without one it would silently match every option, which is never
        # what a preset means - unless it also names no ids at all, which is
        # how the deliberate "everything" rule is written.
        $hasSelector = ($cats.Count + $risks.Count + $tags.Count) -gt 0
        $sweepAll = (-not $hasSelector) -and ($ids.Count -eq 0)

        if ($hasSelector -or $sweepAll) {
            foreach ($vm in $script:AllTweaks) {
                $def = Get-TweakDef $vm.Id

                if ($cats.Count -and $cats -notcontains $vm.Category) { continue }
                if ($risks.Count -and $risks -notcontains $vm.Risk) { continue }
                if ($tags.Count) {
                    $hit = $false
                    foreach ($tg in $tags) { if (@($def.Tags) -contains $tg) { $hit = $true; break } }
                    if (-not $hit) { continue }
                }
                if ($exTags.Count) {
                    $skip = $false
                    foreach ($tg in $exTags) { if (@($def.Tags) -contains $tg) { $skip = $true; break } }
                    if ($skip) { continue }
                }
                if ($exIds.Count -and $exIds -contains $vm.Id) { continue }
                if ($exCats.Count -and $exCats -contains $vm.Category) { continue }

                $sel[$vm.Id] = $action
            }
        }

        foreach ($id in $ids) {
            if ($exIds.Count -and $exIds -contains $id) { continue }
            if ($script:TweakVMs.ContainsKey($id)) { $sel[$id] = $action }
        }
    }

    # Explicit selections always win over rules.
    if ($Preset.selections) {
        foreach ($p in $Preset.selections.PSObject.Properties) {
            if ($script:TweakVMs.ContainsKey($p.Name)) { $sel[$p.Name] = $p.Value }
        }
    }

    # Drop anything that no longer exists in the catalog.
    $clean = @{}
    foreach ($k in $sel.Keys) {
        if ($script:TweakVMs.ContainsKey($k) -and @('Enable','Disable','Revert') -contains $sel[$k]) {
            $clean[$k] = $sel[$k]
        }
    }
    return $clean
}

function New-PresetVm {
    param($Preset, [string]$Origin, [string]$Path)

    $sel = Resolve-PresetSelections $Preset

    $vm = New-Object Debloat.PresetVM
    $vm.Id = $Preset.id
    $vm.Name = $Preset.name
    $vm.Summary = $Preset.summary
    $vm.Detail = $Preset.detail
    $vm.Risk = if ($Preset.risk) { $Preset.risk } else { 'mixed' }
    $vm.Glyph = if ($Preset.glyph) { $Preset.glyph } else { [char]0xE9D9 }
    $vm.Warning = $Preset.warning
    $vm.Tier = if ($Preset.tier) { "$($Preset.tier)" } else { 'free' }
    $vm.Origin = $Origin
    $vm.Path = $Path

    $e = 0; $d = 0; $r = 0
    $cats = New-Object Collections.Generic.List[string]
    foreach ($k in $sel.Keys) {
        switch ($sel[$k]) {
            'Enable'  { $e++ }
            'Disable' { $d++ }
            'Revert'  { $r++ }
        }
        $cn = $script:TweakVMs[$k].CategoryName
        if (-not $cats.Contains($cn)) { $cats.Add($cn) }
    }
    $vm.EnableCount = $e
    $vm.DisableCount = $d
    $vm.RevertCount = $r
    $vm.Categories = if ($cats.Count -eq 0) { 'no matching options' }
                     else { 'touches: ' + [string]::Join(', ', ($cats | Sort-Object)) }

    if ([string]::IsNullOrWhiteSpace($vm.Detail)) {
        $vm.Detail = New-PresetDetailText $sel
    }

    $script:PresetSel[$Preset.id] = $sel
    return $vm
}

# Auto-written description for presets that did not ship with one.
function New-PresetDetailText {
    param($Selections)
    $byCat = @{}
    foreach ($k in $Selections.Keys) {
        $vm = $script:TweakVMs[$k]
        if (-not $byCat.ContainsKey($vm.CategoryName)) { $byCat[$vm.CategoryName] = @{ E = 0; D = 0; R = 0 } }
        switch ($Selections[$k]) {
            'Enable'  { $byCat[$vm.CategoryName].E++ }
            'Disable' { $byCat[$vm.CategoryName].D++ }
            'Revert'  { $byCat[$vm.CategoryName].R++ }
        }
    }
    $lines = @()
    foreach ($c in ($byCat.Keys | Sort-Object)) {
        $bits = @()
        if ($byCat[$c].D) { $bits += "disable $($byCat[$c].D)" }
        if ($byCat[$c].E) { $bits += "enable $($byCat[$c].E)" }
        if ($byCat[$c].R) { $bits += "revert $($byCat[$c].R)" }
        $lines += ([char]0x2022 + " $c " + [char]0x2014 + " " + [string]::Join(', ', $bits))
    }
    if ($lines.Count -eq 0) { return 'This preset does not match any option in the current catalog.' }
    return [string]::Join("`n", $lines)
}

function Import-Presets {
    $script:PresetSel = @{}
    $list = New-Object Collections.ObjectModel.ObservableCollection[object]

    $builtinPath = Join-Path $script:Paths.Data 'presets.json'
    $doc = Read-JsonFile $builtinPath
    if ($doc -and $doc.presets) {
        foreach ($p in $doc.presets) {
            try { $list.Add((New-PresetVm $p 'builtin' $builtinPath)) }
            catch { Write-AppLog "built-in preset '$($p.id)' failed: $($_.Exception.Message)" 'warn' }
        }
    }

    foreach ($f in (Get-ChildItem -LiteralPath $script:Paths.Presets -Filter '*.json' -ErrorAction SilentlyContinue |
                    Sort-Object Name)) {
        $p = Read-JsonFile $f.FullName
        if ($null -eq $p) { continue }
        if (-not $p.id) { $p | Add-Member -NotePropertyName id -NotePropertyValue ("user." + $f.BaseName) -Force }
        if (-not $p.name) { $p | Add-Member -NotePropertyName name -NotePropertyValue $f.BaseName -Force }
        if ($script:PresetSel.ContainsKey($p.id)) { $p.id = $p.id + '.' + [guid]::NewGuid().ToString('N').Substring(0, 6) }
        try { $list.Add((New-PresetVm $p 'user' $f.FullName)) }
        catch { Write-AppLog "preset file $($f.Name) failed: $($_.Exception.Message)" 'warn' }
    }

    $script:Presets = $list
    Write-AppLog "loaded $($list.Count) presets" 'ok'
    return $list
}

function Get-PresetSelections {
    param([string]$PresetId)
    if ($script:PresetSel.ContainsKey($PresetId)) { return $script:PresetSel[$PresetId] }
    return @{}
}

function Save-UserPreset {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Summary,
        [string]$Detail,
        [Parameter(Mandatory)]$Selections
    )
    $sel = [ordered]@{}
    foreach ($k in ($Selections.Keys | Sort-Object)) { $sel[$k] = $Selections[$k] }

    $risk = 'safe'
    foreach ($k in $Selections.Keys) {
        $r = $script:TweakVMs[$k].Risk
        if ($r -eq 'aggressive') { $risk = 'aggressive'; break }
        if ($r -eq 'moderate' -and $risk -eq 'safe') { $risk = 'moderate' }
    }

    $doc = [ordered]@{
        schema     = 'debloat-preset/1'
        id         = 'user.' + (Get-SafeFileName $Name).ToLower().Replace(' ', '-')
        name       = $Name
        summary    = if ($Summary) { $Summary } else { "Custom preset with $($Selections.Count) options." }
        detail     = $Detail
        risk       = $risk
        glyph      = [string][char]0xE8FD
        tier       = 'free'
        createdBy  = "$env:USERNAME on $env:COMPUTERNAME"
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        appVersion = $script:AppVersion
        selections = $sel
    }

    $file = Join-Path $script:Paths.Presets ((Get-SafeFileName $Name) + '.json')
    Write-JsonFile -Path $file -Object $doc
    Write-AppLog "saved preset '$Name' to $file" 'ok'
    return $file
}

function Remove-UserPreset {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
}

function Copy-PresetIn {
    param([Parameter(Mandatory)][string]$SourcePath)
    $doc = Read-JsonFile $SourcePath
    if ($null -eq $doc) { throw 'That file is not valid JSON.' }
    if (-not $doc.selections -and -not $doc.rules) { throw 'That file has no selections in it.' }

    $base = if ($doc.name) { Get-SafeFileName $doc.name } else { [IO.Path]::GetFileNameWithoutExtension($SourcePath) }
    $dest = Join-Path $script:Paths.Presets ($base + '.json')
    $n = 2
    while (Test-Path -LiteralPath $dest) {
        $dest = Join-Path $script:Paths.Presets ("$base ($n).json")
        $n++
    }
    Copy-Item -LiteralPath $SourcePath -Destination $dest -Force
    return $dest
}

function Export-PresetOut {
    param(
        [Parameter(Mandatory)][string]$PresetId,
        [Parameter(Mandatory)][string]$DestPath
    )
    $vm = $null
    foreach ($p in $script:Presets) { if ($p.Id -eq $PresetId) { $vm = $p; break } }
    if ($null -eq $vm) { throw 'Preset not found.' }

    $sel = Get-PresetSelections $PresetId
    $ordered = [ordered]@{}
    foreach ($k in ($sel.Keys | Sort-Object)) { $ordered[$k] = $sel[$k] }

    $doc = [ordered]@{
        schema     = 'debloat-preset/1'
        id         = $vm.Id
        name       = $vm.Name
        summary    = $vm.Summary
        detail     = $vm.Detail
        risk       = $vm.Risk
        glyph      = $vm.Glyph
        warning    = $vm.Warning
        exportedBy = "$env:USERNAME on $env:COMPUTERNAME"
        exportedUtc = (Get-Date).ToUniversalTime().ToString('o')
        appVersion = $script:AppVersion
        selections = $ordered
    }
    Write-JsonFile -Path $DestPath -Object $doc
    return $DestPath
}
