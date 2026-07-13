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
    - merges  %USERPROFILE%\.claude\settings.json  (adds 7 hook entries; your
              existing hooks are preserved; a timestamped .bak is kept)

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
# Pi's reserved LAN IP (DHCP reservation). Preferred over focuswall.local -
# mDNS proved unreliable across reboots on this network; see PHASE2-RUNBOOK.md section 6.
$DefaultUrl   = 'http://focus-wall.local:5050/events'
$SettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
$WrapperPath  = Join-Path $Dir 'hook-send.ps1'
$Events       = @('Notification','Stop','SessionStart','SessionEnd','UserPromptSubmit','PreToolUse','PostToolUse')

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

# Add our 7 hook entries, first removing any prior FocusWall entry (matched by
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
# Reads hook JSON on stdin, filters + augments it, POSTs to focus-wall.
# Behavioural spec of record: the Unix hooks/hook-send.sh (IMPLEMENTATION.md).
# The POST is synchronous with a short timeout and always exits 0, so a down
# server can never break Claude Code (default URL is an IP => no DNS stall).
#
# Env vars (optional overrides):
#   FOCUSWALL_URL      default baked in below by the installer
#   FOCUSWALL_TIMEOUT  Invoke-RestMethod -TimeoutSec, default 2

$ErrorActionPreference = 'SilentlyContinue'

$Url     = if ($env:FOCUSWALL_URL)     { $env:FOCUSWALL_URL }          else { '@@FOCUSWALL_URL@@' }
$Timeout = if ($env:FOCUSWALL_TIMEOUT) { [int]$env:FOCUSWALL_TIMEOUT } else { 2 }

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

$payload = $raw
try {
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop

    if ($obj.PSObject.Properties.Name -contains 'tool_input' -and $obj.tool_input) {
        $obj.tool_input = [pscustomobject]@{ file_path = $obj.tool_input.file_path }
    }

    if ($obj.hook_event_name -eq 'UserPromptSubmit' -and $obj.prompt -is [string]) {
        $line = ($obj.prompt -split "`n")[0]
        if ($line.Length -gt 60) { $line = $line.Substring(0, 60) }
        $obj.prompt = $line
    }

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

try {
    Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json' `
        -Body $payload -TimeoutSec $Timeout -ErrorAction Stop | Out-Null
} catch { }

exit 0
'@

function Write-Wrapper {
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $content = $WrapperTemplate.Replace('@@FOCUSWALL_URL@@', $Url)
    [IO.File]::WriteAllText($WrapperPath, $content, ([Text.UTF8Encoding]::new($false)))
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
