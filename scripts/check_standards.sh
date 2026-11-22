#!/usr/bin/env bash
# No inline IAM policies, no IAM users or keys, no SSH, no AWS keys in the repo,
# and the pinned nested template version matches the templates (also run in CI).
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
python3 scripts/check_no_inline_policies.py templates/*.yaml bootstrap/*.yaml || fail=1
grep -nE 'Type:\s*"?AWS::IAM::(User|AccessKey)"?\s*$' templates/*.yaml bootstrap/*.yaml && { echo "FAIL: IAM user or access key resource"; fail=1; }
grep -nE '^\s+KeyName:|AWS::EC2::KeyPair|FromPort: 22\b' templates/*.yaml && { echo "FAIL: SSH key or port 22"; fail=1; }
git grep -nIE '(AKIA|ASIA)[0-9A-Z]{16}|aws_secret_access_key' -- . ':!scripts/check_standards.sh' 2>/dev/null && { echo "FAIL: AWS key committed"; fail=1; }
for f in deployments/*/*.yaml; do
  t=$(awk '/^template-file-path:/ {print $2}' "$f")
  [[ -f "$t" ]] || { echo "FAIL: $f points at missing $t"; fail=1; }
done
for env_dir in deployments/*/; do
  ENVIRONMENT="$(basename "$env_dir")" scripts/nested-templates.sh check || fail=1
done
[[ $fail == 0 ]] && echo "PASS: managed policies only; no IAM users, access keys, SSH keys or port 22; deployment files valid"
exit $fail
