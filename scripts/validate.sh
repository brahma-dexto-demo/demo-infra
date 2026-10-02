#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if ! command -v cfn-lint >/dev/null 2>&1; then
  echo 'Install cfn-lint with uv tool install cfn-lint and add its bin directory to PATH.' >&2
  exit 1
fi
cfn-lint --version
cfn-lint --regions us-east-1 --template bootstrap.yaml stack.yaml
for template in bootstrap.yaml stack.yaml; do
  bytes=$(wc -c < "$template" | tr -d ' ')
  printf '%s: %s bytes (limit 51200)\n' "$template" "$bytes"
  if (( bytes > 51200 )); then
    echo "$template exceeds the CloudFormation TemplateBody limit" >&2
    exit 1
  fi
done
echo 'cfn-lint: PASS (no errors or warnings)'

jq empty baseline.json
bash -n scripts/reset.sh
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/reset.sh
else
  echo 'shellcheck unavailable: reset.sh lint skipped (bash syntax checked)'
fi
./scripts/reset.sh --dry-run >/dev/null
echo 'baseline JSON and reset script: PASS'
python3 - <<'PY'
import ast, json, re
baseline = json.load(open("baseline.json"))
source = open("reset/aws_restore.py").read()
embedded = ast.literal_eval(re.search(r"^BASELINE = (\{.*?^\})", source, re.S | re.M).group(1))
for section, values in embedded.items():
    expected = baseline[section] if isinstance(values, dict) else baseline[section]
    if isinstance(values, dict):
        for key, value in values.items():
            assert expected[key] == value, f"aws_restore.py {section}.{key} differs from baseline.json"
    else:
        assert expected == values, f"aws_restore.py {section} differs from baseline.json"
PY
echo 'aws_restore.py baseline matches baseline.json: PASS'
