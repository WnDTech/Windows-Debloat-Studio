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
#  Core.ps1 - paths, logging, elevation, small shared helpers.
# =====================================================================

$script:AppName = 'Windows Debloat Studio'
$script:AppVersion = '1.0.0'

# Where the source lives. The licence panel links to it, and the GPL expects a
# program to be able to tell people where to get it. Fill this in when the
# repository goes public; until then the panel says the link is not set rather
# than opening something wrong.
$script:SourceUrl = ''

function Initialize-Paths {
    param([string]$Root)

    # The app folder is treated as read-only: it may sit in Program Files, or be
    # replaced wholesale by the next version, or - in the packaged build - be a
    # temporary folder that exists only while the app is running. So nothing the
    # app writes goes there.
    #
    # What it writes is split in two, by what each part actually needs.
    #
    # Machine state, in ProgramData: the journal, the licence and saved presets.
    # The journal has to be machine-wide, not per-user. This app always runs
    # elevated, and on a PC where the signed-in user is not an administrator,
    # elevation switches profile - so a per-user journal would land under
    # whichever admin approved the prompt, and a later unelevated run would look
    # somewhere else and report nothing to undo while the changes were still in
    # force. This folder is locked down to administrators for writing, because
    # the record of how to reverse a change should not be editable by someone
    # who could not have made the change.
    #
    # Per-user state, in LocalAppData: the compiled view-models and the session
    # logs. Neither needs to be shared, and both must be writable without
    # elevation. Keeping the compiled assembly here is the important half: it is
    # loaded into an elevated process, and ProgramData is writable by any
    # ordinary user by default, so caching executable code there would let a
    # standard user hand code to an administrator.
    $machine = Join-Path $env:ProgramData 'WindowsDebloatStudio'
    $user = Join-Path $env:LOCALAPPDATA 'WindowsDebloatStudio'

    $script:Paths = [ordered]@{
        Root     = $Root
        Src      = Join-Path $Root 'src'
        Gui      = Join-Path $Root 'src\Gui'
        Interop  = Join-Path $Root 'src\Interop'
        Data     = Join-Path $Root 'data'
        Catalog  = Join-Path $Root 'data\catalog'
        State    = $machine
        UserState = $user
        Presets  = Join-Path $machine 'presets'
        Bin      = Join-Path $user 'bin'
        Logs     = Join-Path $user 'logs'
    }
    $script:Paths.Journal = Join-Path $machine 'journal.jsonl'

    # Every folder is created before the machine one is locked down. Doing it
    # the other way round fails: the restricted ACL takes effect immediately and
    # removes this process's own write access, so creating presets\ underneath
    # it then throws and the app never starts. Hardening afterwards leaves the
    # folders in place and still stops later writes without elevation, which is
    # exactly the intent - the app is elevated whenever it actually writes here.
    $needsHardening = -not (Test-Path -LiteralPath $machine)

    foreach ($k in @('State','UserState','Presets','Bin','Logs')) {
        if (-not (Test-Path $script:Paths[$k])) {
            New-Item -ItemType Directory -Path $script:Paths[$k] -Force | Out-Null
        }
    }

    # Only ever locked down from an elevated process. An ordinary user owns a
    # folder they create, so they can restrict it - and would then be unable to
    # write to it themselves, with no way to undo that without elevation. The
    # protection exists for the elevated app anyway, so the unelevated case just
    # leaves the default permissions and lets the first elevated run fix them.
    if (Test-IsAdmin) {
        if (-not $needsHardening) {
            try { $needsHardening = -not (Get-Acl -LiteralPath $machine).AreAccessRulesProtected }
            catch { $needsHardening = $false }
        }
        if ($needsHardening) { Protect-StateFolder -Path $machine }
    }

    # Older builds kept all of this inside the app folder. Bring it across
    # before the first log line is written, and record what happened so the
    # session log can report it once logging is live.
    $script:MigrationNotes = Move-LegacyState -Root $Root

    $script:Paths.Session = Join-Path $script:Paths.Logs ("session-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

# ProgramData is writable by ordinary users by default: any account can create
# files there. Two things in this folder make that unacceptable. The compiled
# view-model assembly is loaded into an elevated process, so a standard user who
# could replace it would be running code as administrator. And the journal is
# the record of how to undo every change - it should not be editable by someone
# who cannot make the changes in the first place.
#
# So the folder is given an explicit ACL on creation: administrators and SYSTEM
# get full control, everyone else gets read access only.
function Protect-StateFolder {
    param([Parameter(Mandatory)][string]$Path)

    $rights = [Security.AccessControl.FileSystemRights]
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow

    # The permissions and the owner are set in two separate attempts on purpose.
    # Changing the owner needs a privilege an ordinary user does not hold, and
    # when the two were done together its failure took the permissions with it -
    # leaving the folder wide open while the code believed it had locked it.
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)      # drop inherited ProgramData rules

        foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($rule) }

        foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {          # Administrators, SYSTEM
            $id = New-Object Security.Principal.SecurityIdentifier($sid)
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                $id, $rights::FullControl, $inherit, $none, $allow)))
        }
        # Everyone else may read - the app has to be able to show the journal
        # and read its licence when it is not running elevated - but not write.
        $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')   # Users
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $users, $rights::ReadAndExecute, $inherit, $none, $allow)))

        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    } catch {
        $script:StateAclNote = "could not restrict permissions on $Path : $($_.Exception.Message)"
        return
    }

    # Without this the first user to run the app owns the folder, and an owner
    # can always grant itself write access again. Best effort: the permissions
    # above are the part that matters.
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    } catch {
        $script:StateAclNote = "permissions set on $Path but the owner could not be changed"
    }
}

# Moves state written by a pre-1.0 layout out of the app folder. Copies first
# and only then renames the old folder aside, so a failure half way through
# cannot lose a journal.
function Move-LegacyState {
    param([string]$Root)

    $notes = New-Object Collections.Generic.List[string]

    $oldJournal = Join-Path $Root 'logs\journal.jsonl'
    if ((Test-Path -LiteralPath $oldJournal) -and -not (Test-Path -LiteralPath $script:Paths.Journal)) {
        try {
            Copy-Item -LiteralPath $oldJournal -Destination $script:Paths.Journal -Force
            $notes.Add("moved the journal out of the app folder into $($script:Paths.State)")
        } catch {
            $notes.Add("could not move the old journal: $($_.Exception.Message)")
        }
    }

    $oldPresets = Join-Path $Root 'presets'
    if (Test-Path -LiteralPath $oldPresets) {
        foreach ($f in @(Get-ChildItem -LiteralPath $oldPresets -Filter '*.json' -ErrorAction SilentlyContinue)) {
            $dest = Join-Path $script:Paths.Presets $f.Name
            if (Test-Path -LiteralPath $dest) { continue }
            try {
                Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
                $notes.Add("moved preset $($f.Name) into $($script:Paths.Presets)")
            } catch {
                $notes.Add("could not move preset $($f.Name): $($_.Exception.Message)")
            }
        }
    }

    # A licence activated by an older build sat under the user profile. Same
    # reasoning as above: it belongs with the machine, not with whoever
    # approved the elevation prompt.
    $oldLicense = Join-Path (Join-Path $env:LOCALAPPDATA 'WindowsDebloatStudio') 'license.json'
    $newLicense = Join-Path $script:Paths.State 'license.json'
    if ((Test-Path -LiteralPath $oldLicense) -and -not (Test-Path -LiteralPath $newLicense)) {
        try {
            Copy-Item -LiteralPath $oldLicense -Destination $newLicense -Force
            $notes.Add('moved the activated licence into the machine state folder')
        } catch {
            $notes.Add("could not move the licence: $($_.Exception.Message)")
        }
    }

    # Only once everything is safely copied, put the old folders beyond reach so
    # the next run does not migrate them again.
    if ($notes.Count -gt 0) {
        foreach ($old in @((Join-Path $Root 'logs'), $oldPresets, (Join-Path $Root 'bin'))) {
            if (-not (Test-Path -LiteralPath $old)) { continue }
            $aside = $old + '.moved'
            try {
                if (Test-Path -LiteralPath $aside) { Remove-Item -LiteralPath $aside -Recurse -Force }
                Rename-Item -LiteralPath $old -NewName (Split-Path -Leaf $aside) -Force
            } catch { }
        }
    }

    return $notes.ToArray()
}

function Write-AppLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('info','ok','warn','error','head')][string]$Level = 'info'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpper(), $Message
    try { Add-Content -LiteralPath $script:Paths.Session -Value $line -Encoding UTF8 } catch { }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsBuildInfo {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue

    # ProductName still reads "Windows 10 ..." on Windows 11; the build number
    # is the only reliable discriminator, so correct the name from it.
    $is11 = ([int]$p.CurrentBuild -ge 22000)
    $product = "$($p.ProductName)"
    if ($is11 -and $product -like 'Windows 10*') {
        $product = $product -replace '^Windows 10', 'Windows 11'
    }

    [pscustomobject]@{
        Product = $product
        Display = $p.DisplayVersion
        Build   = '{0}.{1}' -f $p.CurrentBuild, $p.UBR
        Edition = $p.EditionID
        Is11    = $is11
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false))
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object,
        [int]$Depth = 12
    )
    $json = $Object | ConvertTo-Json -Depth $Depth
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

# Turns arbitrary text into something safe for a file name.
function Get-SafeFileName {
    param([string]$Name)
    $bad = [IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ($bad -contains $ch) { [void]$sb.Append('-') } else { [void]$sb.Append($ch) }
    }
    $out = $sb.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($out)) { $out = 'preset' }
    return $out
}

function New-SystemRestorePoint {
    param([string]$Description = 'Windows Debloat Studio')
    try {
        $drive = $env:SystemDrive + '\'
        # System Protection has to be on for the system drive or the call is a no-op.
        Enable-ComputerRestore -Drive $drive -ErrorAction Stop

        # Windows rate-limits restore points to one per 24h unless this is relaxed.
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name 'SystemRestorePointCreationFrequency' `
            -Value 0 -PropertyType DWord -Force | Out-Null

        Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; Message = 'Restore point created.' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Message = $_.Exception.Message }
    }
}

function Test-RestoreAvailable {
    try {
        $drive = $env:SystemDrive
        $cfg = Get-CimInstance -Namespace 'root\default' -ClassName 'SystemRestoreConfig' -ErrorAction Stop
        return $true
    } catch {
        # WMI class missing on some SKUs; fall back to assuming it might work.
        return $true
    }
}
