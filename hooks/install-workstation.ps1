<#
.SYNOPSIS
  install-workstation.ps1 - set up Claude Focus Wall reporting on this Windows machine.

.DESCRIPTION
  Windows PowerShell port of install-workstation.sh. Installs the hook wrapper
  and wires it into Claude Code so your sessions show up on a Focus Wall
  dashboard (idle / working / waiting / done). Self-contained: this one file is
  all you need - no repo clone, no build, no .NET SDK, no Docker, no jq.

    Install:      .\install-workstation.ps1 -Url http://focus-wall.local:5050/events
    Interactive:  .\install-workstation.ps1            (prompts for the URL)
    Uninstall:    .\install-workstation.ps1 -Uninstall

  What it changes:
    - writes  <Dir>\hook-send.ps1              (the wrapper; server URL baked in)
    - merges  %USERPROFILE%\.claude\settings.json  (adds 8 hook entries; your
              existing hooks are preserved; a timestamped .bak is kept)
    - copies  <Dir>\usage-poll.ps1 + writes <Dir>\usage-poll.vbs and registers
              a per-user scheduled task 'FocusWall Usage Poll' (every 5 min)
              that reports this machine's Claude usage limits to /usage.
              Skipped with a warning if usage-poll.ps1 is not next to this
              installer - hooks-only installs stay single-file.

  The wrapper body is embedded verbatim from hooks\hook-send.ps1 (whose
  behavioural spec of record is the Unix hook-send.sh) - keep them in sync.

.PARAMETER Url
  Focus Wall events endpoint. Default http://focus-wall.local:5050/events (use the Pi's LAN IP if mDNS is unreliable).
.PARAMETER Dir
  Where to install the wrapper. Default %USERPROFILE%\.focus-wall.
.PARAMETER Uninstall
  Remove the Focus Wall hooks and (optionally) the install dir.
.PARAMETER Yes
  Non-interactive: assume yes, skip prompts (for scripted rollout).
#>

# MAINTAINERS: keep this file ASCII-only. Windows PowerShell 5.1 reads a
# BOM-less file as the ANSI codepage (CP1252), which turns a UTF-8 em-dash into
# a byte sequence ending in U+201D (a curly quote PS treats as a string
# delimiter) -- that closes strings early and produces bogus parse errors far
# from the real line. Use a plain hyphen instead of an em-dash, the word
# 'section' instead of the section sign, and so on.
[CmdletBinding()]
param(
    [string]$Url = '',
    [string]$Dir = (Join-Path $env:USERPROFILE '.focus-wall'),
    [switch]$Uninstall,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

# ---- defaults ---------------------------------------------------------------
# Default to the Pi over mDNS (focus-wall.local). If mDNS is unreliable on your
# network, pass -Url with the Pi's LAN IP instead; see PHASE2-RUNBOOK.md section 6.
$DefaultUrl   = 'http://focus-wall.local:5050/events'
$SettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$WrapperPath  = Join-Path $Dir 'hook-send.ps1'
$PollDst      = Join-Path $Dir 'usage-poll.ps1'
$ShimPath     = Join-Path $Dir 'usage-poll.vbs'
$PollTaskName = 'FocusWall Usage Poll'
$Events       = @('Notification','Stop','StopFailure','SessionStart','SessionEnd','UserPromptSubmit','PreToolUse','PostToolUse')

# ---- little helpers ---------------------------------------------------------
function Say  ($m) { Write-Host $m }
function Info ($m) { Write-Host "  $m" }
function Ok   ($m) { Write-Host "  " -NoNewline; Write-Host "OK" -ForegroundColor Green -NoNewline; Write-Host " $m" }
function Warn ($m) { Write-Host "  " -NoNewline; Write-Host "!"  -ForegroundColor Yellow -NoNewline; Write-Host " $m" }
function Die  ($m) { Write-Host "Error: $m" -ForegroundColor Red; exit 1 }

function Confirm-Prompt ($prompt) {
    if ($Yes) { return $true }
    $reply = Read-Host "  $prompt [y/N]"
    return ($reply -match '^(y|yes)$')
}

# The hook command Claude Code runs. Quote the path so a spaced profile works.
function Get-HookCommand { "powershell -NoProfile -ExecutionPolicy Bypass -File `"$WrapperPath`"" }

# ---- settings.json helpers --------------------------------------------------
# Read current settings as a PSCustomObject ('{}' if the file is absent).
# Aborts if the file exists but isn't valid JSON - we never clobber it.
function Read-Settings {
    if (Test-Path -LiteralPath $SettingsPath) {
        $text = Get-Content -LiteralPath $SettingsPath -Raw
        try { return ($text | ConvertFrom-Json) }
        catch { Die "$SettingsPath is not valid JSON. Fix or move it, then re-run." }
    }
    return ([pscustomobject]@{})
}

# Back up then atomically write settings.json from a JSON string.
function Write-Settings ($json) {
    $dir = Split-Path -Parent $SettingsPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $SettingsPath) {
        $bak = "$SettingsPath.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $SettingsPath -Destination $bak -Force
        Info "Backup: $bak"
    }
    # Write BOM-less UTF-8: Set-Content -Encoding UTF8 emits a BOM on Windows
    # PowerShell 5.1, and a leading BOM breaks Claude Code's JSON parser.
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($tmp, $json, ([Text.UTF8Encoding]::new($false)))
    Move-Item -LiteralPath $tmp -Destination $SettingsPath -Force
}

# True when a hook-array entry points at our wrapper command.
function Entry-IsOurs ($entry, $cmd) {
    if (-not $entry.hooks) { return $false }
    foreach ($h in @($entry.hooks)) { if ($h.command -eq $cmd) { return $true } }
    return $false
}

# Add our 8 hook entries, first removing any prior FocusWall entry (matched by
# the wrapper command) so re-runs are idempotent and existing user hooks survive.
function Merge-Hooks {
    $cmd = Get-HookCommand
    $settings = Read-Settings
    $hooks = if ($settings.PSObject.Properties.Name -contains 'hooks' -and $settings.hooks) { $settings.hooks } else { [pscustomobject]@{} }

    foreach ($e in $Events) {
        $existing = @()
        if ($hooks.PSObject.Properties.Name -contains $e) {
            $existing = @($hooks.$e) | Where-Object { -not (Entry-IsOurs $_ $cmd) }
        }
        $ours = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $cmd }) }
        $hooks | Add-Member -NotePropertyName $e -NotePropertyValue (@($existing) + $ours) -Force
    }

    $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue $hooks -Force
    return ($settings | ConvertTo-Json -Depth 20)
}

# Remove our entries and prune anything left empty.
function Strip-Hooks {
    $cmd = Get-HookCommand
    $settings = Read-Settings
    if (-not ($settings.PSObject.Properties.Name -contains 'hooks') -or -not $settings.hooks) {
        return ($settings | ConvertTo-Json -Depth 20)
    }
    $hooks = $settings.hooks
    foreach ($e in $Events) {
        if ($hooks.PSObject.Properties.Name -contains $e) {
            $kept = @($hooks.$e) | Where-Object { -not (Entry-IsOurs $_ $cmd) }
            if (@($kept).Count -eq 0) { $hooks.PSObject.Properties.Remove($e) }
            else { $hooks | Add-Member -NotePropertyName $e -NotePropertyValue @($kept) -Force }
        }
    }
    if (@($hooks.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('hooks') }
    return ($settings | ConvertTo-Json -Depth 20)
}

# ---- wrapper ----------------------------------------------------------------
# Embedded verbatim from hooks\hook-send.ps1, with the URL default templated so
# the chosen server URL is baked in. Single-quoted here-string => no expansion
# of the wrapper's own $-vars at install time.
$WrapperTemplate = @'
# hook-send.ps1 - installed by install-workstation.ps1.
# Reads hook JSON on stdin, filters it down to the fields the wall uses, adds
# host metadata, and POSTs it to focus-wall.
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
#   FOCUSWALL_URL      default baked in below by the installer
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

$Url = if ($env:FOCUSWALL_URL) { $env:FOCUSWALL_URL } else { '@@FOCUSWALL_URL@@' }
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
'@

function Write-Wrapper {
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $content = $WrapperTemplate.Replace('@@FOCUSWALL_URL@@', $Url)
    [IO.File]::WriteAllText($WrapperPath, $content, ([Text.UTF8Encoding]::new($false)))
}

# ---- usage poller -----------------------------------------------------------
# Copies usage-poll.ps1 alongside the wrapper, writes a WScript shim that runs
# it fully hidden (a scheduled powershell.exe can flash a console window even
# with -WindowStyle Hidden), and registers a per-user scheduled task: every 5
# minutes plus at logon. No admin needed. Idempotent - files are overwritten
# and Register-ScheduledTask -Force replaces the task in place. The URL and
# label are baked into the shim so the task needs no environment of its own.
# RepetitionDuration is a long finite span - [TimeSpan]::MaxValue misbehaves
# on some Windows builds.
$ShimTemplate = @'
' usage-poll.vbs - installed by install-workstation.ps1.
' Launches usage-poll.ps1 with window style 0 (fully hidden) so the
' 5-minute scheduled task never flashes a console window.
Set sh = CreateObject("WScript.Shell")
Set env = sh.Environment("PROCESS")
env("FOCUSWALL_URL") = "@@URL@@"
env("FOCUSWALL_ACCOUNT_LABEL") = "@@LABEL@@"
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""@@POLL@@""", 0, False
'@

function Install-UsagePoller {
    $src = Join-Path $PSScriptRoot 'usage-poll.ps1'
    if (-not (Test-Path -LiteralPath $src)) {
        Warn "usage-poll.ps1 not found next to the installer - skipping usage poller (run the installer from the repo to enable it)."
        return
    }
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $PollDst -Force

    $label = if ($env:FOCUSWALL_ACCOUNT_LABEL) { $env:FOCUSWALL_ACCOUNT_LABEL } else { $env:COMPUTERNAME }
    $shim  = $ShimTemplate.Replace('@@URL@@', $Url).Replace('@@LABEL@@', $label).Replace('@@POLL@@', $PollDst)
    [IO.File]::WriteAllText($ShimPath, $shim, ([Text.UTF8Encoding]::new($false)))

    try {
        $action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B //Nologo `"$ShimPath`""
        $every5   = New-ScheduledTaskTrigger -Once -At (Get-Date) `
                        -RepetitionInterval (New-TimeSpan -Minutes 5) `
                        -RepetitionDuration (New-TimeSpan -Days 3650)
        $atLogon  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
                        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskName $PollTaskName -Action $action `
            -Trigger @($every5, $atLogon) -Settings $settings -Force | Out-Null
        Ok "Installed scheduled task '$PollTaskName' (every 5 min)."
    } catch {
        Warn "Could not register scheduled task '$PollTaskName': $($_.Exception.Message)"
    }
}

# ---- flows ------------------------------------------------------------------
function Do-Install {
    Say "Installing Claude Focus Wall reporting on this machine..."

    # Resolve URL: -Url > $env:FOCUSWALL_URL > prompt > default.
    if (-not $Url) { $script:Url = $env:FOCUSWALL_URL }
    if (-not $Url) {
        if ($Yes) { $script:Url = $DefaultUrl; Warn "No URL given; using default $Url" }
        else {
            $entered = Read-Host "  Focus Wall URL [$DefaultUrl]"
            $script:Url = if ($entered) { $entered } else { $DefaultUrl }
        }
    }
    Ok "Server URL: $Url"

    Write-Wrapper
    Ok "Wrapper: $WrapperPath"

    Write-Settings (Merge-Hooks)
    Ok "Hooks merged into $SettingsPath"

    Install-UsagePoller

    # Non-fatal reachability check.
    try {
        Invoke-WebRequest -Uri $Url -TimeoutSec 2 -UseBasicParsing | Out-Null
        Ok "Server reachable at $Url"
    } catch {
        Warn "Could not reach $Url yet - that's fine if the server isn't up. Hooks are fire-and-forget."
    }

    # Smoke event through the installed wrapper.
    try {
        '{"hook_event_name":"Notification","message":"install smoke test"}' |
            powershell -NoProfile -ExecutionPolicy Bypass -File $WrapperPath | Out-Null
        Ok "Sent a smoke event - look for a 'Notification' on the wall."
    } catch { Warn "Smoke event failed to send (non-fatal)." }

    Say ""
    Say "Done. New Claude Code sessions will report to the wall. Re-run any time to change the URL."
}

function Do-Uninstall {
    Say "Removing Claude Focus Wall reporting..."
    Write-Settings (Strip-Hooks)
    Ok "Removed Focus Wall hooks from $SettingsPath"

    try {
        Unregister-ScheduledTask -TaskName $PollTaskName -Confirm:$false -ErrorAction Stop
        Ok "Removed scheduled task '$PollTaskName'"
    } catch { }
    Remove-Item -LiteralPath $PollDst, $ShimPath -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $Dir) {
        if (Confirm-Prompt "Also delete $Dir?") {
            Remove-Item -LiteralPath $Dir -Recurse -Force
            Ok "Deleted $Dir"
        } else { Info "Left $Dir in place." }
    }
    Say ""
    Say "Done. Focus Wall hooks removed."
}

# ---- main -------------------------------------------------------------------
if ($Uninstall) { Do-Uninstall } else { Do-Install }
