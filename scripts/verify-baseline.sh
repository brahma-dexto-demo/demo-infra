#!/usr/bin/env bash
# Usage: verify-baseline.sh <api-url> <console-url>
# Fails unless the live API and console are in the before state (no risk score anywhere).
set -euo pipefail

api=${1%/}
console=${2%/}

list=$(curl --fail --silent --show-error --max-time 20 "$api/accounts")
count=$(printf '%s' "$list" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["accounts"]))')
id=$(printf '%s' "$list" | python3 -c 'import json,sys; print(json.load(sys.stdin)["accounts"][0]["id"])')
detail=$(curl --fail --silent --show-error --max-time 20 "$api/accounts/$id")
[ "$count" -gt 0 ] || { echo "API returned no accounts" >&2; exit 1; }
if printf '%s%s' "$list" "$detail" | grep -q 'risk_score'; then
  echo "API still returns risk_score" >&2
  exit 1
fi

directory=$(curl --fail --silent --show-error --max-time 20 "$console/")
account=$(curl --fail --silent --show-error --max-time 20 "$console/accounts/$id")
printf '%s' "$directory" | grep -q 'Customer directory' || { echo "Console directory did not render" >&2; exit 1; }
if printf '%s%s' "$directory" "$account" | grep -qi 'risk'; then
  echo "Console still shows risk UI" >&2
  exit 1
fi

echo "baseline verified: $count accounts on list, detail $id ok, no risk_score in API, no risk UI in console"
