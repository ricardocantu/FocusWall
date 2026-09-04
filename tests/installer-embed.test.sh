#!/usr/bin/env bash
# Guards the two installers' embedded sender copies against drifting from
# hooks/hook-send.sh and hooks/hook-send.ps1. Header comments may differ and the
# installers template the default URL; the code bodies must be identical.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Unix: compare from `set -u` onward, normalizing the URL placeholder.
embed_sh="$(sed -n '/^  cat > "\$tmp" <<.WRAPPER_EOF.$/,/^WRAPPER_EOF$/p' "$ROOT/hooks/install-workstation.sh" \
  | sed '1d;$d' | sed -n '/^set -u$/,$p' | sed 's#@@FOCUSWALL_URL@@#http://localhost:5050/events#')"
sender_sh="$(sed -n '/^set -u$/,$p' "$ROOT/hooks/hook-send.sh")"
[ -n "$embed_sh" ] || fail "could not find the WRAPPER_EOF heredoc in install-workstation.sh"
if [ "$embed_sh" != "$sender_sh" ]; then
  diff <(printf '%s\n' "$sender_sh") <(printf '%s\n' "$embed_sh") >&2 || true
  fail "install-workstation.sh's embedded wrapper differs from hooks/hook-send.sh"
fi

# Windows: compare from the param block onward, same normalization.
embed_ps="$(awk "/^\\\$WrapperTemplate = @'\$/{f=1;next} /^'@\$/{if(f){exit}} f" "$ROOT/hooks/install-workstation.ps1" \
  | sed -n '/^param(/,$p' | sed "s#'@@FOCUSWALL_URL@@'#'http://focus-wall.local:5050/events'#")"
sender_ps="$(sed -n '/^param(/,$p' "$ROOT/hooks/hook-send.ps1")"
[ -n "$embed_ps" ] || fail "could not find \$WrapperTemplate in install-workstation.ps1"
if [ "$embed_ps" != "$sender_ps" ]; then
  diff <(printf '%s\n' "$sender_ps") <(printf '%s\n' "$embed_ps") >&2 || true
  fail "install-workstation.ps1's embedded wrapper differs from hooks/hook-send.ps1"
fi

echo "PASS"
