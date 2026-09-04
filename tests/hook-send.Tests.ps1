# Contract tests for hooks/hook-send.ps1's privacy filter. Spawns the sender in
# a child process of the SAME engine (pwsh or powershell.exe) so stdin piping
# matches how Claude Code invokes it. No Pester dependency.
#
# MAINTAINERS: keep this file ASCII-only (Windows PowerShell 5.1 reads a
# BOM-less file as CP1252; CI byte-checks hooks\*.ps1 and tests\*.ps1).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sender = Join-Path $root 'hooks\hook-send.ps1'
$fixtures = Join-Path $root 'tests\fixtures\hooks'
$engine = (Get-Process -Id $PID).Path

function Fail([string]$Message) { Write-Host "FAIL: $Message"; exit 1 }

function Transform([string]$Fixture) {
    $env:FOCUSWALL_TEST_HOST = 'test-host'
    $env:FOCUSWALL_TEST_CWD = '/work/project'
    $env:FOCUSWALL_TEST_BRANCH = 'main'
    $env:FOCUSWALL_TEST_NOW = '2026-09-03T12:00:00Z'
    $raw = [IO.File]::ReadAllText((Join-Path $fixtures $Fixture))
    $lines = @($raw | & $engine -NoProfile -ExecutionPolicy Bypass -File $sender -TransformOnly)
    return ($lines -join "`n").Trim()
}

function Parse([string]$Text) { return ($Text | ConvertFrom-Json) }
function Has($Obj, [string]$Name) { return ($Obj.PSObject.Properties.Name -contains $Name) }

$out = Transform 'pre-tool.json'
$o = Parse $out
if ($o.hook_event_name -ne 'PreToolUse' -or $o.session_id -ne 'sess-1' -or $o.tool_name -ne 'Bash') { Fail "pre-tool basics: $out" }
if ($o.tool_input.file_path -ne '/home/you/projects/my-project/src/app.js') { Fail "pre-tool file_path: $out" }
foreach ($k in 'transcript_path', 'permission_mode', 'tool_use_id', 'cwd') { if (Has $o $k) { Fail "pre-tool leaked $k" } }
if (Has $o.tool_input 'command') { Fail 'Bash command leaked' }
if ($out.Contains('aws/credentials')) { Fail 'Bash command text leaked' }
if ($o._meta.hostname -ne 'test-host' -or $o._meta.cwd -ne '/work/project' -or $o._meta.branch -ne 'main' -or $o._meta.received_at_client -ne '2026-09-03T12:00:00Z') { Fail "meta: $out" }

$out = Transform 'post-tool.json'
$o = Parse $out
if (Has $o 'tool_response') { Fail 'tool_response leaked' }
if ($out.Contains('SECRET_FILE_BODY')) { Fail 'tool_response body leaked' }
if ($o.tool_input.file_path -ne '/home/you/projects/my-project/README.md') { Fail "post-tool file_path: $out" }

$line = 'Refactor the event store so that sessions are keyed by host and id, then run the tests'
$out = Transform 'prompt.json'
$o = Parse $out
if ($o.prompt -ne $line.Substring(0, 60)) { Fail "prompt truncation: $out" }
if ($out.Contains('second line')) { Fail 'prompt second line leaked' }

$out = Transform 'prompt-password.json'
$o = Parse $out
if ($o.prompt -ne 'Prompt submitted') { Fail "credential gate: $out" }
if ($out.Contains('hunter2')) { Fail 'password leaked' }

$out = Transform 'notification.json'
$o = Parse $out
if ($o.message -ne 'Claude needs your permission to use Bash') { Fail "notification message: $out" }
if (Has $o 'notification_type') { Fail 'notification_type leaked' }

$out = Transform 'stop-failure.json'
$o = Parse $out
if ($o.error -ne 'rate_limit') { Fail "stop-failure error: $out" }
if (Has $o 'error_details') { Fail 'error_details leaked' }
if ($out.Contains('user@example.com')) { Fail 'error_details text leaked' }

if ((Transform 'no-hook-name.json') -ne '') { Fail 'no-hook-name should produce no output' }
if ((Transform 'invalid.json') -ne '') { Fail 'invalid JSON should produce no output' }

$env:FOCUSWALL_TEST_BRANCH = 'feature/api-key-rotation'
$raw = [IO.File]::ReadAllText((Join-Path $fixtures 'notification.json'))
$out = ((@($raw | & $engine -NoProfile -ExecutionPolicy Bypass -File $sender -TransformOnly)) -join "`n").Trim()
$o = Parse $out
if (Has $o._meta 'branch') { Fail "credential-shaped branch leaked: $out" }

Write-Host 'PASS'
exit 0
