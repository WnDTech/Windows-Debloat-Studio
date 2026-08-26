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
#  Report.ps1 - the hand-over report. A Technician feature.
#
#  Everything in here comes out of the journal, which already records the
#  previous state of every action before it is performed. So the report is
#  not a second record that could disagree with the first: it is the same
#  record, rendered for someone who is not going to open a .jsonl file.
#
#  Written for the person receiving the machine back, which is why it
#  leads with how to reverse everything rather than burying it.
# =====================================================================

function Get-ReportModel {
    $j = Get-Journal
    $byTweak = [ordered]@{}

    foreach ($e in $j) {
        $id = "$($e.tweakId)"
        if (-not $byTweak.Contains($id)) {
            $vm = $null
            if ($script:TweakVMs.ContainsKey($id)) { $vm = $script:TweakVMs[$id] }
            $byTweak[$id] = [ordered]@{
                Id = $id
                Name = if ($vm) { "$($vm.Name)" } else { "$($e.tweakName)" }
                Category = if ($vm) { "$($vm.CategoryName)" } else { 'Other' }
                Risk = if ($vm) { "$($vm.Risk)" } else { '' }
                Direction = "$($e.direction)"
                FirstSeen = "$($e.ts)"
                Details = New-Object Collections.Generic.List[string]
            }
        }
        # Only the earliest capture per action index matters: that is the value
        # the machine had before this app touched it, and so the value a revert
        # would put back.
        $cap = $e.capture
        $line = Format-CaptureLine $cap
        if ($line -and -not $byTweak[$id].Details.Contains($line)) {
            $byTweak[$id].Details.Add($line)
        }
    }

    return @($byTweak.Keys | ForEach-Object { $byTweak[$_] })
}

# Turns one captured action into a sentence about what it used to be.
function Format-CaptureLine {
    param($Capture)
    if ($null -eq $Capture) { return $null }
    $kind = "$($Capture.kind)"
    switch ($kind) {
        'reg' {
            $existed = [bool]$Capture.existed
            $path = "$($Capture.path)"
            $name = "$($Capture.name)"
            if (-not $existed) { return "registry $path -> $name was not set" }
            return "registry $path -> $name was $($Capture.value) ($($Capture.type))"
        }
        'service' { return "service $($Capture.name) start type was $($Capture.startType), $(if ($Capture.running) { 'running' } else { 'stopped' })" }
        'task' { return "scheduled task $($Capture.path) was $(if ($Capture.enabled) { 'enabled' } else { 'disabled' })" }
        'appx' {
            $inst = if ($Capture.installed) { 'installed' } else { 'not installed' }
            $prov = if ($Capture.provisioned) { ', provisioned for new accounts' } else { '' }
            return "package $($Capture.name) was $inst$prov"
        }
        'feature' { return "Windows feature $($Capture.name) was $($Capture.state)" }
        'capability' { return "capability $($Capture.name) was $($Capture.state)" }
        'command' { return "ran a command; previous state recorded as $($Capture.state)" }
    }
    return $null
}

function Export-ChangeReport {
    param([Parameter(Mandatory)][string]$Path)

    $rows = @(Get-ReportModel)
    $os = Get-WindowsBuildInfo
    $now = Get-Date

    $enc = { param($s) [Web.HttpUtility]::HtmlEncode("$s") }
    Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

    $sb = New-Object Text.StringBuilder
    $add = { param($s) [void]$sb.AppendLine($s) }

    & $add '<!doctype html>'
    & $add '<html lang="en"><head><meta charset="utf-8">'
    & $add ('<title>Changes to ' + (& $enc $env:COMPUTERNAME) + '</title>')
    & $add @'
<style>
  :root { color-scheme: light; }
  body { margin: 0; padding: 2.4rem 1.6rem 4rem; background: #f6f7f9; color: #12161d;
         font: 15px/1.6 "Segoe UI", system-ui, sans-serif; }
  main { max-width: 60rem; margin: 0 auto; }
  h1 { font-size: 1.6rem; margin: 0 0 .3rem; }
  .sub { color: #5b6472; margin: 0 0 1.8rem; }
  .undo { background: #e8f2ff; border: 1px solid #b9d6f7; border-radius: .5rem;
          padding: 1rem 1.15rem; margin-bottom: 2rem; }
  .undo h2 { font-size: 1rem; margin: 0 0 .5rem; }
  .undo ol { margin: .4rem 0 0; padding-left: 1.3rem; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 2rem; }
  caption { text-align: left; font-weight: 600; padding: .8rem 0 .5rem; font-size: 1.05rem; }
  th, td { text-align: left; padding: .55rem .7rem; border-bottom: 1px solid #e2e6ec; vertical-align: top; }
  th { font-size: .72rem; letter-spacing: .05em; text-transform: uppercase; color: #6b7480;
       border-bottom: 1px solid #cfd6df; }
  td.dir { white-space: nowrap; font-weight: 600; }
  .was { font: 12.5px/1.55 "Cascadia Mono", Consolas, monospace; color: #4a5361; }
  .risk { font-size: .72rem; text-transform: uppercase; letter-spacing: .04em; }
  .safe { color: #0b7a2e; } .moderate { color: #8a5a00; } .aggressive { color: #a3251f; }
  footer { color: #6b7480; font-size: .84rem; border-top: 1px solid #e2e6ec; padding-top: 1rem; }
  .none { background: #fff; border: 1px solid #e2e6ec; border-radius: .5rem; padding: 1.4rem; }
</style>
</head><body><main>
'@
    & $add ('<h1>Changes to ' + (& $enc $env:COMPUTERNAME) + '</h1>')
    & $add ('<p class="sub">' + (& $enc $os.Product) + ' ' + (& $enc $os.Display) +
        ', build ' + (& $enc $os.Build) + ' &middot; report written ' +
        (& $enc $now.ToString('d MMMM yyyy, HH:mm')) + '</p>')

    if ($rows.Count -eq 0) {
        & $add '<div class="none"><strong>Nothing has been changed on this PC.</strong> The journal is empty, so there is nothing to reverse.</div>'
    } else {
        & $add '<div class="undo"><h2>How to put all of this back</h2><ol>'
        & $add '<li>Open Windows Debloat Studio on this PC.</li>'
        & $add '<li>Press <strong>Undo everything</strong> in the footer. It replays the list below in reverse, restoring each value shown in the <em>was</em> column.</li>'
        & $add '<li>Or reverse one item at a time by finding it and choosing <strong>Revert</strong>.</li>'
        & $add '</ol><p style="margin:.6rem 0 0">This works after a reboot and after closing the app: the record lives in <code>%ProgramData%\WindowsDebloatStudio\journal.jsonl</code>, not in the app folder. Some changes cannot be reversed and say so on their own card &mdash; a removed app can only be reinstalled while its files are still on disk.</p></div>'

        $cats = @($rows | ForEach-Object { $_.Category } | Sort-Object -Unique)
        foreach ($c in $cats) {
            $inCat = @($rows | Where-Object { $_.Category -eq $c })
            & $add ('<table><caption>' + (& $enc $c) + ' &mdash; ' + $inCat.Count + ' changed</caption>')
            & $add '<thead><tr><th>Option</th><th>Action</th><th>Risk</th><th>What it was before</th></tr></thead><tbody>'
            foreach ($r in $inCat) {
                $was = if ($r.Details.Count) {
                    [string]::Join('<br>', @($r.Details | ForEach-Object { & $enc $_ }))
                } else { '<span class="was">not recorded</span>' }
                & $add ('<tr><td>' + (& $enc $r.Name) + '</td>' +
                    '<td class="dir">' + (& $enc $r.Direction) + '</td>' +
                    '<td class="risk ' + (& $enc $r.Risk) + '">' + (& $enc $r.Risk) + '</td>' +
                    '<td class="was">' + $was + '</td></tr>')
            }
            & $add '</tbody></table>'
        }
    }

    & $add ('<footer>' + $rows.Count + ' option(s) changed in total. Produced by ' +
        (& $enc $script:AppName) + ' ' + (& $enc $script:AppVersion) +
        '. This report is a rendering of the app''s own journal, not a separate record.</footer>')
    & $add '</main></body></html>'

    [IO.File]::WriteAllText($Path, $sb.ToString(), [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Path = $Path; Count = $rows.Count }
}
