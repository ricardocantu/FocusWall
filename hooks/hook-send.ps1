# hook-send.ps1 - Windows PowerShell port of hook-send.sh.
# Reads hook JSON on stdin, filters it down to the fields the wall uses, adds
# host metadata, and POSTs it to focus-wall.
# Usage in settings.json (Windows):
#   "command": "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\path\\to\\hook-send.ps1"
# Test/debug:  hook-send.ps1 -TransformOnly < payload.json  (prints, sends nothing)
#
# Behavioural spec of record is the Unix wrapper (hooks/hook-send.sh /
# IMPLEMENTATION.md section hook-send.sh). This mirrors it with two platform
# differences, both deliberate:
#   * No jq / curl - PowerShell has native JSON + Invoke-RestMethod.
#   * The POST is SYNCHRONOUS with a short timeout (there is no clean,
#     window-less, job-safe way to background it on Windows). It always
#     exits 0 and swallows every error, so a down server can never break
#     Claude Code; the worst case is FOCUSWALL_TIMEOUT seconds (1..10) when
#     the wall is unreachable or its name does not resolve.
#
# Privacy: only an allowlist of fields leaves this machine. If parsing or
# filtering fails, NOTHING is sent.
#
# Env vars (optional overrides):
#   FOCUSWALL_URL      default http://focus-wall.local:5050/events (the Pi)
#   FOCUSWALL_TIMEOUT  Invoke-RestMethod -TimeoutSec, 1..10, default 2
#
# Requires Windows PowerShell 5.1+ (ships with Windows) or PowerShell 7+.
#
# MAINTAINERS: keep this file ASCII-only. Windows PowerShell 5.1 reads a
# BOM-less file as the ANSI codepage (CP1252), which turns a UTF-8 em-dash into
# a byte sequence ending in U+201D (a curly quote PS treats as a string
# delimiter) -- that closes strings early and produces bogus parse errors far
# from the real line. Use a plain hyphen instead of an em-dash, the word
# 'section' instead of the section sign, and so on.
param([switch]$TransformOnly)

$ErrorActionPreference = 'SilentlyContinue'

$Url = if ($env:FOCUSWALL_URL) { $env:FOCUSWALL_URL } else { 'http://focus-wall.local:5050/events' }
$Timeout = 2
$parsedTimeout = 0
if ($env:FOCUSWALL_TIMEOUT -and [int]::TryParse($env:FOCUSWALL_TIMEOUT, [ref]$parsedTimeout) -and
        $parsedTimeout -ge 1 -and $parsedTimeout -le 10) {
    $Timeout = $parsedTimeout
}

function Test-CredentialShaped([string]$Value) {
    return $Value -match '(?i)(api[_-]?key|password|passwd|secret|token|credential|authorization|bearer|private[_-]?key|(^|[_:-])sk[_-])'
}

# Returns $null for non-strings, the fallback for credential-shaped text,
# otherwise the text cut to $Max characters.
function Limit-Text($Value, [int]$Max, $Fallback) {
    if ($Value -isnot [string]) { return $null }
    if (Test-CredentialShaped $Value) { return $Fallback }
    if ($Value.Length -gt $Max) { return $Value.Substring(0, $Max) }
    return $Value
}

function Get-Prop($Obj, [string]$Name) {
    if ($null -ne $Obj -and $Obj.PSObject.Properties.Name -contains $Name) { return $Obj.$Name }
    return $null
}

# Read the whole hook payload from stdin.
$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

$payload = $null
try {
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    $hookName = Get-Prop $obj 'hook_event_name'
    if ($hookName -isnot [string]) { exit 0 }

    # Allowlist - mirrors the jq filter in hook-send.sh. tool_response,
    # transcript_path, error_details, permission_mode and the raw tool_input
    # command line never leave this machine.
    $out = [ordered]@{ hook_event_name = $hookName }

    $sessionId = Get-Prop $obj 'session_id'
    if ($sessionId -is [string]) {
        $out.session_id = $sessionId.Substring(0, [Math]::Min(128, $sessionId.Length))
    }

    $message = Limit-Text (Get-Prop $obj 'message') 200 'Notification'
    if ($null -ne $message) { $out.message = $message }

    $toolName = Limit-Text (Get-Prop $obj 'tool_name') 64 $null
    if ($null -ne $toolName) { $out.tool_name = $toolName }

    if ($hookName -eq 'UserPromptSubmit') {
        $prompt = Get-Prop $obj 'prompt'
        if ($prompt -is [string]) {
            $line = ($prompt -split "`n")[0]
            if ($line.Length -gt 60) { $line = $line.Substring(0, 60) }
            $out.prompt = Limit-Text $line 60 'Prompt submitted'
        }
    }

    $err = Get-Prop $obj 'error'
    if ($err -is [string] -and $err -cmatch '^[a-z][a-z0-9_]{0,47}$') { $out.error = $err }

    $toolInput = Get-Prop $obj 'tool_input'
    if ($null -ne $toolInput -and $toolInput -isnot [string]) {
        $filePath = Get-Prop $toolInput 'file_path'
        if ($filePath -is [string]) { $out.tool_input = [pscustomobject]@{ file_path = $filePath } }
    }

    # Host metadata. Git branch is best-effort: a non-repo cwd or missing git
    # on PATH just omits the field, and never blocks the hook. The
    # FOCUSWALL_TEST_* overrides give tests/hook-send.Tests.ps1 deterministic
    # output.
    $cwd = if ($env:FOCUSWALL_TEST_CWD) { $env:FOCUSWALL_TEST_CWD } else { (Get-Location).Path }
    $hostName = if ($env:FOCUSWALL_TEST_HOST) { $env:FOCUSWALL_TEST_HOST } else { $env:COMPUTERNAME }
    $ts = if ($env:FOCUSWALL_TEST_NOW) { $env:FOCUSWALL_TEST_NOW } else { [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss'Z'") }
    $branch = ''
    if ($env:FOCUSWALL_TEST_BRANCH) { $branch = $env:FOCUSWALL_TEST_BRANCH }
    else { try { $branch = (& git -C $cwd rev-parse --abbrev-ref HEAD 2>$null) } catch { } }
    if ($branch) { $branch = ([string]$branch).Trim() }

    $meta = [ordered]@{ hostname = $hostName; cwd = $cwd; received_at_client = $ts }
    if ($branch -and -not (Test-CredentialShaped $branch)) { $meta.branch = $branch }
    $out._meta = [pscustomobject]$meta

    $payload = [pscustomobject]$out | ConvertTo-Json -Depth 8 -Compress
} catch {
    # Fail closed: never forward a payload we could not filter.
    exit 0
}
if (-not $payload) { exit 0 }

if ($TransformOnly) {
    [Console]::Out.Write($payload + "`n")
    exit 0
}

# Bounded, non-throwing POST. See the header note on why this is synchronous.
try {
    $body = [Text.Encoding]::UTF8.GetBytes($payload)
    Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json; charset=utf-8' `
        -Body $body -TimeoutSec $Timeout -ErrorAction Stop | Out-Null
} catch { }

# Exit 0 always - a hook failing must not break Claude Code.
exit 0
