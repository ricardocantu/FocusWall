<#
.SYNOPSIS
  usage-poll.ps1 - report this machine's Claude usage limits to Focus Wall.

.DESCRIPTION
  Windows PowerShell port of usage-poll.sh (the behavioral spec of record -
  keep the two in sync). Reads this machine's Claude OAuth token, calls
  Anthropic's /api/oauth/usage, reduces the response to the limit gauges, and
  POSTs ONLY the summary (never the token) to the Focus Wall server.

  Always exits 0 so a scheduler never surfaces failures. The token is NEVER
  logged. Runs on Windows PowerShell 5.1 and PowerShell 7+.

    Full flow (scheduled):  .\usage-poll.ps1
    Test/debug:             .\usage-poll.ps1 -Reduce raw.json [-FwHost x] [-FwLabel y]

  Env vars (optional overrides):
    FOCUSWALL_URL            default http://focus-wall.local:5050/events
    FOCUSWALL_ACCOUNT_LABEL  default the computer name
#>

# MAINTAINERS: keep this file ASCII-only. Windows PowerShell 5.1 reads a
# BOM-less file as the ANSI codepage (CP1252), which mangles any non-ASCII
# character into misleading parse errors far from the real line. Plain
# hyphens only; no em-dashes, no section signs.
[CmdletBinding()]
param(
    [string]$Reduce = '',
    [string]$FwHost = '',
    [string]$FwLabel = ''
)

$ErrorActionPreference = 'Stop'

$FocusWallUrl  = if ($env:FOCUSWALL_URL) { $env:FOCUSWALL_URL } else { 'http://focus-wall.local:5050/events' }
$ReportUrl     = ($FocusWallUrl -replace '/events$', '') + '/usage/report'
$UsageEndpoint = 'https://api.anthropic.com/api/oauth/usage'

# PS 5.1 can default to TLS 1.0 on older stacks; the usage endpoint needs 1.2+.
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

function Get-NowIso { [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss'Z'") }

# Reduce a parsed /api/oauth/usage response to the summary the server accepts.
# Limit fields stay snake_case - POST /usage/report and usage.js read them so.
function Reduce-Raw ($rawObj, $hostName, $label, $ts) {
    $limits = @()
    if ($rawObj -and $rawObj.PSObject.Properties.Name -contains 'limits' -and $rawObj.limits) {
        foreach ($l in @($rawObj.limits)) {
            $model = $null
            if ($l.scope -and $l.scope.model) { $model = $l.scope.model.display_name }
            $limits += [pscustomobject][ordered]@{
                kind      = $l.kind
                group     = $l.group
                percent   = $l.percent
                severity  = $l.severity
                resets_at = $l.resets_at
                model     = $model
                is_active = $l.is_active
            }
        }
    }
    $summary = [ordered]@{
        host   = $hostName
        label  = $label
        status = 'ok'
        ts     = $ts
        limits = @($limits)
    }
    return ([pscustomobject]$summary | ConvertTo-Json -Depth 10 -Compress)
}

# Summary with no limits, given a status string (no_token / auth_expired).
function New-EmptySummary ($hostName, $label, $ts, $status) {
    $summary = [ordered]@{ host = $hostName; label = $label; status = $status; ts = $ts; limits = @() }
    return ([pscustomobject]$summary | ConvertTo-Json -Depth 10 -Compress)
}

# ---- Test/debug mode --------------------------------------------------------
if ($Reduce) {
    $hostName = if ($FwHost) { $FwHost } else { $env:COMPUTERNAME }
    $label    = if ($FwLabel) { $FwLabel } else { $hostName }
    try {
        $rawObj = Get-Content -LiteralPath $Reduce -Raw | ConvertFrom-Json
        Reduce-Raw $rawObj $hostName $label (Get-NowIso)
    } catch {
        [Console]::Error.WriteLine("usage-poll: could not reduce $Reduce")
    }
    exit 0
}

# ---- Full flow ---------------------------------------------------------------
$HostName = $env:COMPUTERNAME
$Label    = if ($env:FOCUSWALL_ACCOUNT_LABEL) { $env:FOCUSWALL_ACCOUNT_LABEL } else { $HostName }
$Ts       = Get-NowIso

# Windows: same plain creds file as Linux (verified - no Credential Manager).
function Read-Token {
    $credPath = Join-Path $env:USERPROFILE '.claude\.credentials.json'
    if (-not (Test-Path -LiteralPath $credPath)) { return '' }
    try {
        $creds = Get-Content -LiteralPath $credPath -Raw | ConvertFrom-Json
        if ($creds.claudeAiOauth -and $creds.claudeAiOauth.accessToken) {
            return [string]$creds.claudeAiOauth.accessToken
        }
    } catch { }
    return ''
}

# Short timeout, all errors swallowed: a down wall never surfaces a failure.
function Send-Summary ($json) {
    try {
        Invoke-RestMethod -Uri $ReportUrl -Method Post -ContentType 'application/json' `
            -Body $json -TimeoutSec 5 -ErrorAction Stop | Out-Null
    } catch { }
}

$Token = Read-Token
if (-not $Token) {
    [Console]::Error.WriteLine('usage-poll: no token available')
    Send-Summary (New-EmptySummary $HostName $Label $Ts 'no_token')
    exit 0
}

$code = 0
$raw  = $null
try {
    $raw = Invoke-RestMethod -Uri $UsageEndpoint -TimeoutSec 10 -ErrorAction Stop -Headers @{
        'Authorization'  = "Bearer $Token"
        'anthropic-beta' = 'oauth-2025-04-20'
    }
    $code = 200
} catch {
    if ($_.Exception.Response) {
        try { $code = [int]$_.Exception.Response.StatusCode } catch { $code = 0 }
    }
}

if ($code -eq 200 -and $raw) {
    $summary = $null
    try { $summary = Reduce-Raw $raw $HostName $Label $Ts } catch { }
    if ($summary) { Send-Summary $summary }
} elseif ($code -eq 401 -or $code -eq 403) {
    [Console]::Error.WriteLine("usage-poll: auth rejected (HTTP $code)")
    Send-Summary (New-EmptySummary $HostName $Label $Ts 'auth_expired')
} else {
    [Console]::Error.WriteLine("usage-poll: usage endpoint HTTP $code")
}
exit 0
