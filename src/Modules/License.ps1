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
#  License.ps1 - Polar license keys, with an offline-first posture.
#
#  Honest scope, stated once here so nobody is misled by the rest of the
#  file: this app ships as plain-text PowerShell. Anyone can open
#  Test-Feature and make it return $true. This is therefore a purchase
#  prompt for honest people, not copy protection, and it is deliberately
#  written to be readable rather than obfuscated. Obfuscating a .ps1
#  would make the code worse and stop nobody.
#
#  Rules it follows:
#    * A free user never makes a network call. Not one.
#    * Nothing that protects the user is ever gated - the journal, Revert,
#      Undo everything, dry run and restore points are free forever, and
#      so is every one of the 355 options.
#    * Losing internet access never takes away what someone paid for.
#      An activated key keeps working offline for the grace period, and
#      only a definite answer from Polar - revoked, expired - downgrades.
#    * No nagging. The tier is a quiet chip in the title bar; a gated
#      feature explains itself once, when you reach for it.
# =====================================================================

$script:LicCfg = $null
$script:LicState = $null
$script:LicEntitlement = $null

function Get-LicenseConfigPath { Join-Path $script:Paths.Data 'licensing.json' }

function Get-LicenseStatePath {
    # Machine state, alongside the journal. An activation is bound to this PC
    # by its machine label, and the app always runs elevated - so a per-user
    # path would lose the licence whenever a different administrator approved
    # the prompt. Initialize-Paths migrates a licence written by older builds.
    $dir = if ($script:Paths -and $script:Paths.State) { $script:Paths.State }
           else { Join-Path $env:ProgramData 'WindowsDebloatStudio' }
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return (Join-Path $dir 'license.json')
}

function Import-LicenseConfig {
    $cfg = Read-JsonFile (Get-LicenseConfigPath)
    if ($null -eq $cfg) {
        $cfg = [pscustomobject]@{
            provider = 'polar'; organizationId = ''; apiBase = 'https://api.polar.sh'
            checkout = [pscustomobject]@{ pro = ''; technician = ''; portal = '' }
            tiers = @(); features = [pscustomobject]@{}
            revalidateAfterDays = 14; offlineGraceDays = 60; requestTimeoutSeconds = 8
        }
    }
    $script:LicCfg = $cfg
    return $cfg
}

function Test-LicenseConfigured {
    if ($null -eq $script:LicCfg) { Import-LicenseConfig | Out-Null }
    return -not [string]::IsNullOrWhiteSpace("$($script:LicCfg.organizationId)")
}

# A stable, non-personal identifier for this machine, so a three-PC licence
# can tell one PC from another and the customer can recognise it in their
# Polar portal.
function Get-MachineLabel {
    $guid = ''
    try {
        $guid = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' `
                -Name MachineGuid -ErrorAction Stop).MachineGuid
    } catch { $guid = "$env:COMPUTERNAME-fallback" }
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$guid"))
    $sha.Dispose()
    $short = ([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 8).ToLower()
    return "$env:COMPUTERNAME ($short)"
}

# --------------------------------------------------------------- state

function Get-LicenseState {
    if ($null -ne $script:LicState) { return $script:LicState }
    $p = Get-LicenseStatePath
    $s = Read-JsonFile $p
    $script:LicState = $s
    return $s
}

function Save-LicenseState {
    param($State)
    Write-JsonFile -Path (Get-LicenseStatePath) -Object $State
    $script:LicState = $State
    $script:LicEntitlement = $null
}

function Clear-LicenseState {
    $p = Get-LicenseStatePath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    $script:LicState = $null
    $script:LicEntitlement = $null
}

# --------------------------------------------------------------- Polar calls

function Invoke-PolarCall {
    param(
        [Parameter(Mandatory)][ValidateSet('validate', 'activate', 'deactivate')][string]$Action,
        [Parameter(Mandatory)][hashtable]$Body
    )
    if (-not (Test-LicenseConfigured)) {
        return [pscustomobject]@{ Ok = $false; Kind = 'notconfigured'
            Message = 'This build has no Polar organisation id set, so keys cannot be checked.' }
    }

    $Body['organization_id'] = "$($script:LicCfg.organizationId)"
    $url = "$($script:LicCfg.apiBase)/v1/customer-portal/license-keys/$Action"
    $timeout = [int]$script:LicCfg.requestTimeoutSeconds
    if ($timeout -le 0) { $timeout = 8 }

    try {
        # Windows PowerShell defaults to older TLS on some builds, which fails
        # against modern APIs with a misleading "could not create SSL channel".
        [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
    } catch { }

    try {
        $json = $Body | ConvertTo-Json -Depth 6 -Compress
        $res = Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' `
            -Body $json -TimeoutSec $timeout -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; Kind = 'ok'; Data = $res; Message = '' }
    } catch {
        $code = 0
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }

        # A definite "no" from Polar is different from not being able to ask.
        if ($code -eq 404) {
            return [pscustomobject]@{ Ok = $false; Kind = 'rejected'
                Message = 'Polar does not recognise that key for this product.' }
        }
        if ($code -eq 403) {
            return [pscustomobject]@{ Ok = $false; Kind = 'rejected'
                Message = 'That key is no longer valid. It may have been revoked or refunded.' }
        }
        if ($code -eq 422) {
            return [pscustomobject]@{ Ok = $false; Kind = 'rejected'
                Message = 'That does not look like a licence key for this product.' }
        }
        if ($code -eq 409) {
            return [pscustomobject]@{ Ok = $false; Kind = 'limit'
                Message = 'That key has already been activated on the maximum number of PCs. Deactivate one from your Polar purchases page, or use the Technician licence.' }
        }
        return [pscustomobject]@{ Ok = $false; Kind = 'unreachable'
            Message = "Could not reach Polar ($($_.Exception.Message))." }
    }
}

# Which tier does this benefit id map to? An empty benefitIds list means
# "any valid key for this organisation", which is the sensible default for a
# single-product setup.
function Resolve-LicenseTier {
    param([string]$BenefitId)
    $fallback = $null
    foreach ($t in @($script:LicCfg.tiers)) {
        $ids = @($t.benefitIds | Where-Object { $_ })
        if ($ids.Count -eq 0) { if ($null -eq $fallback) { $fallback = $t }; continue }
        if ($ids -contains $BenefitId) { return $t }
    }
    return $fallback
}

# --------------------------------------------------------------- activate

function Register-License {
    param([Parameter(Mandatory)][string]$Key)

    $key = "$Key".Trim()
    if ([string]::IsNullOrWhiteSpace($key)) {
        return [pscustomobject]@{ Ok = $false; Message = 'Paste your licence key first.' }
    }

    $label = Get-MachineLabel
    $act = Invoke-PolarCall -Action 'activate' -Body @{ key = $key; label = $label }
    $activationId = $null
    $lk = $null
    if ($act.Ok) {
        $activationId = "$($act.Data.id)"
        $lk = $act.Data.license_key
    } else {
        Write-AppLog "license activate returned $($act.Kind); falling back to validate" 'info'
        $val = Invoke-PolarCall -Action 'validate' -Body @{ key = $key }
        if (-not $val.Ok) {
            Write-AppLog "license activate and validate both failed: $($act.Kind) $($act.Message)" 'warn'
            return [pscustomobject]@{ Ok = $false; Message = $act.Message }
        }
        $lk = $val.Data.license_key
    }

    $benefitId = "$($lk.benefit_id)"
    $tier = Resolve-LicenseTier $benefitId
    if ($null -eq $tier) {
        return [pscustomobject]@{ Ok = $false
            Message = 'That key is valid but this build does not know which tier it grants. Check the benefit ids in data\licensing.json.' }
    }

    $state = [ordered]@{
        provider         = 'polar'
        key              = $key
        activationId     = $activationId
        tierId           = "$($tier.id)"
        tierName         = "$($tier.name)"
        benefitId        = $benefitId
        label            = $label
        limitActivations = $lk.limit_activations
        expiresUtc       = if ($lk.expires_at) { "$($lk.expires_at)" } else { $null }
        activatedUtc     = (Get-Date).ToUniversalTime().ToString('o')
        lastValidatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        lastResult       = 'valid'
    }
    Save-LicenseState $state
    Write-AppLog "license activated: tier=$($tier.id) machine='$label'" 'ok'
    return [pscustomobject]@{ Ok = $true; Message = "$($tier.name) unlocked on this PC."; Tier = $tier }
}

function Unregister-License {
    $st = Get-LicenseState
    if ($null -eq $st) { return [pscustomobject]@{ Ok = $true; Message = 'No licence was stored on this PC.' } }

    $msg = 'Licence removed from this PC.'
    if ($st.key -and $st.activationId) {
        $res = Invoke-PolarCall -Action 'deactivate' `
            -Body @{ key = "$($st.key)"; activation_id = "$($st.activationId)" }
        if ($res.Ok) { $msg = 'Licence removed and this PC released, so the slot is free for another machine.' }
        else { $msg = "Licence removed locally, but Polar could not be told: $($res.Message) You can release this PC from your Polar purchases page." }
    }
    Clear-LicenseState
    Write-AppLog 'license removed from this PC' 'info'
    return [pscustomobject]@{ Ok = $true; Message = $msg }
}

# --------------------------------------------------------------- validate

function Update-LicenseValidation {
    param([switch]$Force)

    $st = Get-LicenseState
    if ($null -eq $st -or -not $st.key) { return $null }

    $days = 9999
    try { $days = ((Get-Date).ToUniversalTime() - [datetime]::Parse($st.lastValidatedUtc).ToUniversalTime()).TotalDays } catch { }
    $due = [double]$script:LicCfg.revalidateAfterDays
    if ($due -le 0) { $due = 14 }
    if (-not $Force -and $days -lt $due) { return $st }

    $body = @{ key = "$($st.key)" }
    if ($st.activationId) { $body['activation_id'] = "$($st.activationId)" }
    $res = Invoke-PolarCall -Action 'validate' -Body $body

    if ($res.Ok) {
        $lk = $res.Data.license_key
        if ($null -eq $lk) { $lk = $res.Data }
        $st.lastValidatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $st.lastResult = 'valid'
        if ($lk.expires_at) { $st.expiresUtc = "$($lk.expires_at)" }
        Save-LicenseState $st
        Write-AppLog 'license re-validated with Polar' 'ok'
    } elseif ($res.Kind -eq 'rejected') {
        # A definite no. This is the only thing that takes a licence away.
        $st.lastResult = 'revoked'
        $st.lastValidatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Save-LicenseState $st
        Write-AppLog "license rejected by Polar: $($res.Message)" 'warn'
    } else {
        # Could not ask. Say so and carry on; the grace period covers it.
        Write-AppLog "license re-check skipped: $($res.Message)" 'info'
    }
    return (Get-LicenseState)
}

# --------------------------------------------------------------- entitlement

function Get-Entitlement {
    param([switch]$Refresh)

    if ($null -ne $script:LicEntitlement -and -not $Refresh) { return $script:LicEntitlement }
    if ($null -eq $script:LicCfg) { Import-LicenseConfig | Out-Null }

    $free = [pscustomobject]@{
        TierId = 'free'; TierName = 'Free'; Features = @(); IsPaid = $false
        Status = 'free'; Detail = 'Every option and the whole safety net are yours. Pro adds the advanced presets, saving your own, and applying to every account.'
        DaysSinceCheck = $null; Label = $null; Limit = $null
    }

    $st = Get-LicenseState
    if ($null -eq $st -or -not $st.key) { $script:LicEntitlement = $free; return $free }

    if ($st.lastResult -eq 'revoked') {
        $r = $free.PSObject.Copy()
        $r.Status = 'revoked'
        $r.Detail = 'Polar reports this key as no longer valid. If that is wrong, re-enter it below.'
        $script:LicEntitlement = $r
        return $r
    }

    if ($st.expiresUtc) {
        try {
            if ([datetime]::Parse($st.expiresUtc).ToUniversalTime() -lt (Get-Date).ToUniversalTime()) {
                $r = $free.PSObject.Copy()
                $r.Status = 'expired'
                $r.Detail = 'This licence has expired. Renew it from your Polar purchases page.'
                $script:LicEntitlement = $r
                return $r
            }
        } catch { }
    }

    $days = 0
    try { $days = [math]::Floor(((Get-Date).ToUniversalTime() - [datetime]::Parse($st.lastValidatedUtc).ToUniversalTime()).TotalDays) } catch { $days = 9999 }
    $grace = [double]$script:LicCfg.offlineGraceDays
    if ($grace -le 0) { $grace = 60 }

    if ($days -gt $grace) {
        $r = $free.PSObject.Copy()
        $r.Status = 'stale'
        $r.Detail = "This licence has not been checked for $days days, past the $([int]$grace) day offline allowance. Connect to the internet and press Check now."
        $r.DaysSinceCheck = $days
        $script:LicEntitlement = $r
        return $r
    }

    $tier = $null
    foreach ($t in @($script:LicCfg.tiers)) { if ("$($t.id)" -eq "$($st.tierId)") { $tier = $t; break } }
    if ($null -eq $tier) { $script:LicEntitlement = $free; return $free }

    $ent = [pscustomobject]@{
        TierId = "$($tier.id)"; TierName = "$($tier.name)"
        Features = @($tier.features); IsPaid = $true
        Status = if ($days -gt [double]$script:LicCfg.revalidateAfterDays) { 'offline' } else { 'active' }
        Detail = if ($days -le 0) { 'Verified with Polar today.' } elseif ($days -eq 1) { 'Verified with Polar yesterday.' } else { "Verified with Polar $days days ago." }
        DaysSinceCheck = $days; Label = "$($st.label)"; Limit = $st.limitActivations
    }
    $script:LicEntitlement = $ent
    return $ent
}

# The gate. One call, used everywhere a paid feature is reached for.
function Test-Feature {
    param([Parameter(Mandatory)][string]$Name)
    $e = Get-Entitlement
    return (@($e.Features) -contains $Name)
}

function Get-FeatureDescription {
    param([string]$Name)
    if ($null -eq $script:LicCfg) { Import-LicenseConfig | Out-Null }
    $p = $script:LicCfg.features.PSObject.Properties | Where-Object { $_.Name -eq $Name }
    if ($p) { return "$($p.Value)" }
    return 'This feature'
}

# --------------------------------------------------------------- tiers
#
# The tiers are ordered by rank and each one's features are a superset of the
# one below. That is what lets the app answer two questions honestly: what did
# this person pay for, and what would the next tier add. Before this, Pro and
# Technician had identical feature lists - so a Technician key unlocked exactly
# what a Pro key did, and the more expensive tier bought nothing the app could
# point at.

function Get-Tiers {
    if ($null -eq $script:LicCfg) { Import-LicenseConfig | Out-Null }
    return @($script:LicCfg.tiers | Sort-Object { [int]$_.rank })
}

function Get-Tier {
    param([string]$Id)
    foreach ($t in (Get-Tiers)) { if ("$($t.id)" -eq "$Id") { return $t } }
    return $null
}

# The cheapest tier that grants a given feature - so a locked control can say
# which product it belongs to rather than just "this is paid".
function Get-TierForFeature {
    param([Parameter(Mandatory)][string]$Feature)
    foreach ($t in (Get-Tiers)) {
        if (@($t.features) -contains $Feature) { return $t }
    }
    return $null
}

# What the current licence does not yet include, and which tier would add it.
# Returns $null when the top tier is already held.
function Get-UpgradeOffer {
    $e = Get-Entitlement
    $have = @($e.Features)
    foreach ($t in (Get-Tiers)) {
        $missing = @($t.features | Where-Object { $have -notcontains $_ })
        if ($missing.Count -gt 0) {
            return [pscustomobject]@{
                TierId = "$($t.id)"; TierName = "$($t.name)"
                Machines = "$($t.machines)"; Blurb = "$($t.blurb)"
                Adds = $missing
            }
        }
    }
    return $null
}

# Which feature, if any, a preset of this tier needs. Kept in config so adding
# a tier does not mean editing a comparison in three files - the old code tested
# the preset's tier against the literal string 'pro', which meant a preset
# marked 'technician' could never lock at all.
function Get-PresetFeature {
    param([string]$Tier)
    if ($null -eq $script:LicCfg) { Import-LicenseConfig | Out-Null }
    $key = if ([string]::IsNullOrWhiteSpace($Tier)) { 'free' } else { "$Tier".ToLower() }
    $p = $script:LicCfg.presetTierFeature.PSObject.Properties | Where-Object { $_.Name -eq $key }
    if ($p -and -not [string]::IsNullOrWhiteSpace("$($p.Value)")) { return "$($p.Value)" }
    return $null
}

# True when a preset of this tier is usable on the current licence.
function Test-PresetAllowed {
    param([string]$Tier)
    $f = Get-PresetFeature $Tier
    if ($null -eq $f) { return $true }        # free presets are always allowed
    return (Test-Feature $f)
}

# The name of the product a preset of this tier belongs to, for the button.
function Get-PresetTierName {
    param([string]$Tier)
    $f = Get-PresetFeature $Tier
    if ($null -eq $f) { return $null }
    $t = Get-TierForFeature $f
    if ($t) { return "$($t.name)" }
    return 'Pro'
}

function Get-CheckoutUrl {
    param([ValidateSet('pro', 'technician', 'portal')][string]$Which = 'pro')
    if ($null -eq $script:LicCfg) { Import-LicenseConfig | Out-Null }
    $u = "$($script:LicCfg.checkout.$Which)"
    if ([string]::IsNullOrWhiteSpace($u)) { return $null }
    return $u
}

# Called once at startup: never for a free user, so a free install makes no
# network call at all.
function Initialize-License {
    Import-LicenseConfig | Out-Null
    $st = Get-LicenseState
    if ($null -ne $st -and $st.key) { Update-LicenseValidation | Out-Null }
    return (Get-Entitlement -Refresh)
}
