# hook-send.ps1 - Windows PowerShell port of hook-send.sh.
# Reads hook JSON on stdin, filters + augments it, POSTs to focus-wall.
# Usage in settings.json (Windows):
#   "command": "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\path\\to\\hook-send.ps1"
#
# Behavioural spec of record is the Unix wrapper (hooks/hook-send.sh /
# IMPLEMENTATION.md section hook-send.sh). This mirrors it with two platform
# differences, both deliberate:
#   * No jq / curl - PowerShell has native JSON + Invoke-RestMethod.
#   * The POST is SYNCHRONOUS with a short timeout (there is no clean,
#     window-less, job-safe way to background it on Windows). It always
#     exits 0 and swallows every error, so a down server can never break
#     Claude Code; because the default URL is an IP there is no DNS stall,
#     so a reachable wall costs a few ms and only a fully-unreachable
#     server can add up to FOCUSWALL_TIMEOUT seconds.
#
# Env vars (optional overrides):
#   FOCUSWALL_URL      default http://focus-wall.local:5050/events (the Pi)
#   FOCUSWALL_TIMEOUT  Invoke-RestMethod -TimeoutSec, default 2
#
# Requires Windows PowerShell 5.1+ (ships with Windows) or PowerShell 7+.
#
# MAINTAINERS: keep this file ASCII-only. Windows PowerShell 5.1 reads a
# BOM-less file as the ANSI codepage (CP1252), which turns a UTF-8 em-dash into
# a byte sequence ending in U+201D (a curly quote PS treats as a string
# delimiter) -- that closes strings early and produces bogus parse errors far
# from the real line. Use a plain hyphen instead of an em-dash, the word
# 'section' instead of the section sign, and so on.

$ErrorActionPreference = 'SilentlyContinue'

$Url     = if ($env:FOCUSWALL_URL)     { $env:FOCUSWALL_URL }          else { 'http://focus-wall.local:5050/events' }
$Timeout = if ($env:FOCUSWALL_TIMEOUT) { [int]$env:FOCUSWALL_TIMEOUT } else { 2 }

# Read the whole hook payload from stdin.
$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

# Parse + augment. On ANY failure, forward the raw input unchanged - the
# server must still see the event even if our filtering breaks.
$payload = $raw
try {
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop

    # Strip tool_input down to file_path - raw PreToolUse payloads carry full
    # Bash command lines and entire Write file bodies; source code stays on
    # this machine. (jq's `{file_path}` yields null when absent; so do we.)
    if ($obj.PSObject.Properties.Name -contains 'tool_input' -and $obj.tool_input) {
        $obj.tool_input = [pscustomobject]@{ file_path = $obj.tool_input.file_path }
    }

    # Truncate a submitted prompt to its first line, <=60 chars, so full
    # prompt text never leaves the workstation.
    if ($obj.hook_event_name -eq 'UserPromptSubmit' -and $obj.prompt -is [string]) {
        $line = ($obj.prompt -split "`n")[0]
        if ($line.Length -gt 60) { $line = $line.Substring(0, 60) }
        $obj.prompt = $line
    }

    # Host metadata. Git branch is best-effort: a non-repo cwd or missing
    # git on PATH just omits the field, and never blocks the hook.
    $cwd    = (Get-Location).Path
    $branch = ''
    try { $branch = (& git -C $cwd rev-parse --abbrev-ref HEAD 2>$null) } catch { }
    if ($branch) { $branch = ([string]$branch).Trim() }

    $meta = [ordered]@{
        hostname           = $env:COMPUTERNAME
        cwd                = $cwd
        received_at_client = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss'Z'")
    }
    if ($branch) { $meta.branch = $branch }

    $obj | Add-Member -NotePropertyName '_meta' -NotePropertyValue ([pscustomobject]$meta) -Force
    $payload = $obj | ConvertTo-Json -Depth 64 -Compress
} catch {
    $payload = $raw
}

# Bounded, non-throwing POST. See the header note on why this is synchronous.
try {
    Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json' `
        -Body $payload -TimeoutSec $Timeout -ErrorAction Stop | Out-Null
} catch { }

# Exit 0 always - a hook failing must not break Claude Code.
exit 0
