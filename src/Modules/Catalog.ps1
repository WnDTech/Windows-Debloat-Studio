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
#  Catalog.ps1 - loads data\catalog\*.json into view-models.
#
#  Each catalog file looks like:
#    { "category": { "key","name","glyph","blurb","order" },
#      "tweaks":   [ { "id","name","risk","impact","explain",
#                      "enableMeans","disableMeans","restart","actions":[...] } ] }
# =====================================================================

$script:TweakDefs = $null      # id -> raw definition (holds .actions)
$script:TweakVMs  = $null      # id -> TweakVM
$script:Categories = $null     # ordered list of category descriptors
$script:AllTweaks = $null      # flat list of TweakVM in display order

function Format-ActionSummary {
    param($Actions)
    $lines = @()
    foreach ($a in $Actions) {
        switch ($a.kind) {
            'reg' {
                $e = if ("$($a.enable)" -eq '@delete') { 'value removed' } else { "$($a.enable)" }
                $d = if ("$($a.disable)" -eq '@delete') { 'value removed' } else { "$($a.disable)" }
                $lines += "registry  $($a.hive)\$($a.path)  ->  $($a.name) ($($a.type))   enable = $e   disable = $d"
            }
            'service' {
                $lines += "service   $($a.name)   enable = $($a.enable)   disable = $($a.disable)"
            }
            'appx' {
                $lines += "appx      $([string]::Join(', ', $a.packages))   (removed for this account and deprovisioned for new accounts)"
            }
            'task' {
                foreach ($t in $a.tasks) { $lines += "task      $t" }
            }
            'feature' {
                $lines += "feature   Windows optional feature '$($a.name)' via DISM"
            }
            'capability' {
                $lines += "capability  '$($a.name)' via DISM"
            }
            'command' {
                $en = ($a.enable  -replace '\s+', ' ').Trim()
                $di = ($a.disable -replace '\s+', ' ').Trim()
                if ($di) { $lines += "command   disable: $di" }
                if ($en) { $lines += "command   enable:  $en" }
            }
        }
    }
    return [string]::Join("`n", $lines)
}

function Import-Catalog {
    $script:TweakDefs = @{}
    $script:TweakVMs = @{}
    $cats = New-Object Collections.ObjectModel.ObservableCollection[object]
    $all = New-Object Collections.ObjectModel.ObservableCollection[object]

    $files = Get-ChildItem -LiteralPath $script:Paths.Catalog -Filter '*.json' -ErrorAction Stop |
             Sort-Object Name

    $raw = @()
    foreach ($f in $files) {
        $doc = Read-JsonFile $f.FullName
        if ($null -eq $doc -or $null -eq $doc.category) {
            Write-AppLog "catalog file $($f.Name) is not usable - skipped" 'warn'
            continue
        }
        $raw += [pscustomobject]@{ Doc = $doc; File = $f.Name }
    }

    $raw = $raw | Sort-Object { [int]$_.Doc.category.order }, { $_.File }

    foreach ($r in $raw) {
        $c = $r.Doc.category
        $catTweaks = New-Object Collections.ObjectModel.ObservableCollection[object]

        foreach ($t in $r.Doc.tweaks) {
            if ($script:TweakDefs.ContainsKey($t.id)) {
                Write-AppLog "duplicate tweak id '$($t.id)' in $($r.File) - skipped" 'warn'
                continue
            }

            $vm = New-Object Debloat.TweakVM
            $vm.Id = $t.id
            $vm.Name = $t.name
            $vm.Category = $c.key
            $vm.CategoryName = $c.name
            $vm.Risk = if ($t.risk) { $t.risk } else { 'moderate' }
            $vm.Impact = $t.impact
            $vm.Explain = $t.explain
            $vm.EnableMeans = $t.enableMeans
            $vm.DisableMeans = $t.disableMeans
            $vm.RevertMeans = if ($t.revertMeans) {
                $t.revertMeans
            } else {
                'Puts this option back to exactly the value it had before this app first changed it. If the app has never touched it, Revert is skipped.'
            }
            $vm.RequiresRestart = [bool]$t.restart
            $vm.RequiresSignOut = [bool]$t.signout
            $vm.Docs = $t.docs
            $vm.ActionSummary = Format-ActionSummary $t.actions
            $tags = @($t.tags)
            $vm.SearchBlob = (@($t.name, $t.impact, $t.explain, $c.name, $t.id, ($tags -join ' ')) -join ' ').ToLower()

            $def = [pscustomobject]@{
                Id      = $t.id
                Name    = $t.name
                Risk    = $vm.Risk
                Tags    = $tags
                Actions = @($t.actions)
                Category = $c.key
                CategoryName = $c.name
                Restart = $vm.RequiresRestart
                SignOut = $vm.RequiresSignOut
                Explorer = [bool]$t.explorer
            }

            $script:TweakDefs[$t.id] = $def
            $script:TweakVMs[$t.id] = $vm
            $catTweaks.Add($vm)
            $all.Add($vm)
        }

        $cvm = New-Object Debloat.CategoryVM
        $cvm.Key = $c.key
        $cvm.Name = $c.name
        $cvm.Glyph = $c.glyph
        $cvm.Blurb = $c.blurb
        $cvm.Total = $catTweaks.Count

        $cats.Add([pscustomobject]@{
            Vm      = $cvm
            Key     = $c.key
            Name    = $c.name
            Blurb   = $c.blurb
            Tweaks  = $catTweaks
        })
    }

    $script:Categories = $cats
    $script:AllTweaks = $all
    Write-AppLog "loaded $($all.Count) options across $($cats.Count) categories" 'ok'
    return $cats
}

function Get-CategoryByKey {
    param([string]$Key)
    foreach ($c in $script:Categories) { if ($c.Key -eq $Key) { return $c } }
    return $null
}

function Get-TweakDef {
    param([string]$Id)
    if ($script:TweakDefs.ContainsKey($Id)) { return $script:TweakDefs[$Id] }
    return $null
}

function Get-TweakVm {
    param([string]$Id)
    if ($script:TweakVMs.ContainsKey($Id)) { return $script:TweakVMs[$Id] }
    return $null
}

# Refresh CurrentState / IsTouched for a set of options.
function Update-TweakStates {
    param(
        $Tweaks,
        [scriptblock]$OnProgress
    )
    $i = 0
    $n = @($Tweaks).Count
    foreach ($vm in $Tweaks) {
        $def = Get-TweakDef $vm.Id
        if ($def) {
            $vm.CurrentState = Get-TweakState $def
            $vm.IsTouched = Test-TweakTouched $vm.Id
        }
        $i++
        if ($OnProgress -and ($i % 12 -eq 0 -or $i -eq $n)) {
            & $OnProgress $i $n
        }
    }
}
