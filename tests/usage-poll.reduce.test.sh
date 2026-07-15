#!/usr/bin/env bash
# Verifies usage-poll.sh --reduce produces the expected summary shape.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/../hooks/usage-poll.sh" --reduce "$here/fixtures/usage-sample.json" \
        FW_HOST=testbox FW_LABEL=Personal)"

# status ok, 3 limits, scoped model flattened, credits/scope dropped
echo "$out" | jq -e '.status == "ok"'                              >/dev/null
echo "$out" | jq -e '.host == "testbox" and .label == "Personal"' >/dev/null
echo "$out" | jq -e '(.limits | length) == 3'                     >/dev/null
echo "$out" | jq -e '.limits[2].model == "Fable"'                 >/dev/null
echo "$out" | jq -e '.limits[2].is_active == true'                >/dev/null
echo "$out" | jq -e 'has("extra_usage") | not'                    >/dev/null
echo "$out" | jq -e '.limits[0] | has("scope") | not'             >/dev/null
echo "PASS"
