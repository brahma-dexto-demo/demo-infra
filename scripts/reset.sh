#!/usr/bin/env bash
# Admin-only fallback; Dexto follows RESET.md through managed MCP instead.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
base="$root/baseline.json"
profile='' region=$(jq -r .region "$base") dry=false
while (($#)); do
  case "$1" in
    --profile|--region) [[ $# -ge 2 ]] || { echo "Missing value: $1" >&2; exit 2; }
      if [[ $1 == --profile ]]; then profile=$2; else region=$2; fi; shift 2 ;;
    --dry-run) dry=true; shift ;;
    --help) echo 'Usage: scripts/reset.sh [--profile SSO_PROFILE] [--region us-east-1] [--dry-run]'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ $region == us-east-1 ]] || { echo 'Reset is restricted to us-east-1' >&2; exit 2; }
org=$(jq -r .github_org "$base")
[[ $org == brahma-dexto-demo ]] || exit 2
repos=(accounts-api risk-engine ops-console)
computer_note='Computer: follow RESET.md §2 for /workspace/tasks worktrees and local branches; keep and fast-forward base clones. This admin script skips computer cleanup.'
if $dry; then
  for repo in "${repos[@]}"; do
    echo "Would check/close open PRs and delete remote branches in $org/$repo matching $(jq -c .branch_prefixes "$base")."
  done
  echo "$computer_note"
  echo "Would read outputs of $(jq -r .stack "$base"), verify baseline images/EB version and absence of active writers."
  echo "Would render API Deployment from SHA $(jq -r '."accounts-api".sha' "$base"), apply only if image differs, and verify 2 replicas."
  echo "Would copy $(jq -r .scores.snapshot_key "$base") to $(jq -r .scores.live_key "$base") only if different."
  echo 'If snapshot is absent: resolve baseline Batch definition by image/SHA, resume one existing reset job or submit one, verify success/output, create snapshot once.'
  echo "Would update only EB VersionLabel to $(jq -r '."ops-console".version_label' "$base") if different; wait Ready/Green."
  echo 'Would verify snapshot equality, no risk_score, live API contracts and baseline console browser checks; report changed/already baseline.'
  exit 0
fi
for tool in aws gh kubectl jq curl git uv node npm; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
# One reset at a time per admin computer. Never run concurrently with Dexto.
lock="${TMPDIR:-/tmp}/brahma-baseline-reset.lock"
mkdir "$lock" 2>/dev/null || { echo "Reset lock exists: $lock; check its owner before removal" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; rmdir "$lock"' EXIT
export AWS_PAGER=''
aws_args=(--region "$region")
[[ -z $profile ]] || aws_args+=(--profile "$profile")
aw() { aws "${aws_args[@]}" "$@"; }
fail() { echo "$*" >&2; exit 1; }
# A deadline is diagnostic, not success. Rerun to resume; never rebuild on timeout.
deadline=$((SECONDS + 540))
pause() { ((SECONDS < deadline)) || fail 'Reset timed out; rerun to resume, inspect EB/Batch events.'; sleep 5; }
report() { printf '%-20s %s\n' "$1" "$2"; }
aw cloudformation describe-stacks --stack-name "$(jq -r .stack "$base")" > "$tmp/stack.json"
jq -e '.Stacks[0].StackStatus | IN("CREATE_COMPLETE", "UPDATE_COMPLETE")' "$tmp/stack.json" >/dev/null || fail 'Stack must be stable'
jq -e 'any(.Stacks[0].Tags[]; .Key=="project" and .Value=="brahma-demo")' "$tmp/stack.json" >/dev/null || fail 'Wrong stack project tag'
output() { jq -er --arg key "$1" '.Stacks[0].Outputs[] | select(.OutputKey==$key) | .OutputValue' "$tmp/stack.json"; }
resolve() { local value=$1 key replacement; for key in AccountsApiEcrUri RiskEngineEcrUri DataBucketName ArtifactsBucketName ClusterName BatchQueueArn; do
  if [[ $value == *"\${$key}"* ]]; then replacement=$(output "$key"); value=${value//\$\{$key\}/$replacement}; fi
 done; printf '%s' "$value"; }
bucket=$(resolve "$(jq -r .scores.bucket "$base")")
live=$(jq -r .scores.live_key "$base"); snapshot=$(jq -r .scores.snapshot_key "$base")
api_image=$(resolve "$(jq -r '."accounts-api".image' "$base")")
risk_image=$(resolve "$(jq -r '."risk-engine".image' "$base")")
queue=$(resolve "$(jq -r '."risk-engine".job_queue' "$base")")
job_name=$(jq -r '."risk-engine".reset_job_name' "$base")
app=$(jq -r '."ops-console".application' "$base"); env=$(jq -r '."ops-console".environment' "$base")
label=$(jq -r '."ops-console".version_label' "$base")
ns=$(jq -r .kubernetes.namespace "$base"); deployment=$(jq -r .kubernetes.deployment "$base")
container=$(jq -r .kubernetes.container "$base"); service=$(jq -r .kubernetes.service "$base")
# Only a real missing-key 404 selects first-run Batch. AccessDenied is fatal.
head() {
  if aw s3api head-object --bucket "$bucket" --key "$1" > "$2" 2> "$tmp/head.err"; then return 0; fi
  if grep -Eq '\(404\)|\(NoSuchKey\)|\(NotFound\)' "$tmp/head.err"; then return 1; fi
  cat "$tmp/head.err" >&2; exit 1
}
valid_scores() { jq -e '[.. | objects | has("risk_score")] | any | not' "$1" >/dev/null && jq -e '.scores | length>0 and all(.[]; has("id") and (.probability | type=="number" and .>=0 and .<=1))' "$1" >/dev/null; }
# Fail closed before destructive GitHub cleanup if required artifacts are absent.
for repo in accounts-api risk-engine; do
  uri=$(output "$([[ $repo == accounts-api ]] && echo AccountsApiEcrUri || echo RiskEngineEcrUri)")
  aw ecr describe-images --repository-name "${uri#*/}" --image-ids "imageTag=$(jq -r --arg repo "$repo" '.[$repo].image_tag' "$base")" >/dev/null
done
aw elasticbeanstalk describe-application-versions --application-name "$app" --version-labels "$label" > "$tmp/version.json"
jq -e --arg bucket "$(output ArtifactsBucketName)" --arg key "$(jq -r '."ops-console".source_key' "$base")" '.ApplicationVersions | length==1 and (.[0].SourceBundle.S3Bucket==$bucket and .[0].SourceBundle.S3Key==$key)' "$tmp/version.json" >/dev/null || fail 'Baseline EB version missing or wrong source bundle; do not rebuild'
aw elasticbeanstalk describe-environments --application-name "$app" --environment-names "$env" > "$tmp/env.json"
jq -e --arg label "$label" '.Environments | length==1 and (.[0].Status=="Ready" or (.[0].Status=="Updating" and .[0].VersionLabel==$label))' "$tmp/env.json" >/dev/null || fail 'EB deployment active; wait before reset'
snapshot_exists=false
if head "$snapshot" "$tmp/snapshot-head.json"; then
  snapshot_exists=true
  aw s3api get-object --bucket "$bucket" --key "$snapshot" "$tmp/snapshot.json" >/dev/null
  valid_scores "$tmp/snapshot.json" || fail 'Snapshot is not baseline; do not overwrite it'
fi
# No competing writers; an interrupted reset job is allowed and reused below.
for status in SUBMITTED PENDING RUNNABLE STARTING RUNNING; do
  aw batch list-jobs --job-queue "$queue" --job-status "$status" > "$tmp/jobs-$status.json"
  jq -e --arg name "$job_name" 'all(.jobSummaryList[]; .jobName==$name)' "$tmp/jobs-$status.json" >/dev/null || fail 'Other Batch jobs are active; stop writers before reset'
  if $snapshot_exists; then
    jq -e '.jobSummaryList | length==0' "$tmp/jobs-$status.json" >/dev/null || fail 'Batch writer active with existing snapshot; wait before restoring scores'
  fi
done
for key in AccountsApiCodeBuildProject RiskEngineCodeBuildProject OpsConsoleCodeBuildProject; do
  project=$(output "$key")
  aw codebuild list-builds-for-project --project-name "$project" > "$tmp/builds.json"
  # Check all returned pages rather than assuming the newest build is the only writer.
  jq -r '.ids | . as $ids | range(0; length; 100) as $i | $ids[$i:$i+100] | join(" ")' "$tmp/builds.json" > "$tmp/build-ids"
  while IFS= read -r build_group; do
    read -r -a build_ids <<< "$build_group"
    aw codebuild batch-get-builds --ids "${build_ids[@]}" > "$tmp/build.json"
    jq -e 'all(.builds[]; .buildStatus!="IN_PROGRESS")' "$tmp/build.json" >/dev/null || fail 'CodeBuild is active; stop delivery before reset'
  done < "$tmp/build-ids"
done
prefix_filter=$(jq -c .branch_prefixes "$base")
for repo in "${repos[@]}"; do
  gh api --paginate "repos/$org/$repo/pulls?state=open&per_page=100" | jq -sr --argjson prefixes "$prefix_filter" '[.[][]] | .[] | select(.head.ref as $b | any($prefixes[]; . as $p | $b | startswith($p))) | .number' > "$tmp/prs"
  while IFS= read -r number; do
    # Recheck immediately before close; never merge.
    gh api "repos/$org/$repo/pulls/$number" > "$tmp/pr.json"
    if jq -e --argjson prefixes "$prefix_filter" '.state=="open" and (.head.ref as $b | any($prefixes[]; . as $p | $b | startswith($p)))' "$tmp/pr.json" >/dev/null; then gh api --method PATCH "repos/$org/$repo/pulls/$number" -f state=closed >/dev/null; fi
  done < "$tmp/prs"
  gh api --paginate "repos/$org/$repo/branches?per_page=100" | jq -sr --argjson prefixes "$prefix_filter" '[.[][]] | .[].name | select(. as $b | any($prefixes[]; . as $p | $b | startswith($p)))' > "$tmp/branches"
  while IFS= read -r branch; do
    encoded=$(jq -rn --arg b "$branch" '$b | @uri')
    gh api --method DELETE "repos/$org/$repo/git/refs/heads/$encoded"
  done < "$tmp/branches"
  report "$repo GitHub" "closed $(wc -l < "$tmp/prs" | tr -d ' ') PRs; deleted $(wc -l < "$tmp/branches" | tr -d ' ') branches"
done
echo "$computer_note"
# Private kubeconfig avoids changing the admin's default context.
export KUBECONFIG="$tmp/kubeconfig"
aw eks update-kubeconfig --name "$(output ClusterName)" --kubeconfig "$KUBECONFIG" >/dev/null
kubectl -n "$ns" get deployment "$deployment" -o json > "$tmp/deploy.json"
jq -e --arg sa "$(jq -r .kubernetes.service_account "$base")" '.spec.template.spec.serviceAccountName==$sa' "$tmp/deploy.json" >/dev/null || fail 'Unexpected service account; investigate Pod Identity'
kubectl -n "$ns" get serviceaccount "$(jq -r .kubernetes.service_account "$base")" -o json >/dev/null
api_changed=false
if ! jq -e --arg c "$container" --arg image "$api_image" '.spec.template.spec.containers[] | select(.name==$c) | .image==$image' "$tmp/deploy.json" >/dev/null; then
  # Read the pinned files from the sibling base clone; never check out or modify it.
  api_repo="$root/../accounts-api"; sha=$(jq -r '."accounts-api".sha' "$base")
  git -C "$api_repo" show "$sha:k8s/deployment.yaml" > "$tmp/deployment.yaml"
  sed -e "s|ACCOUNTS_API_IMAGE|$api_image|g" -e "s|brahma-demo-data-ACCOUNT_ID|$bucket|g" "$tmp/deployment.yaml" > "$tmp/rendered.yaml"
  kubectl apply -f "$tmp/rendered.yaml" >/dev/null
  api_changed=true
fi
# Service/SA/Pod Identity are kept; require the original Service tag.
kubectl -n "$ns" get service "$service" -o json > "$tmp/service.json"
jq -e '.metadata.annotations["service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags"]=="project=brahma-demo"' "$tmp/service.json" >/dev/null || fail 'Service annotation changed; investigate before proceeding'
eb_changed=false
if [[ $(jq -r '.Environments[0].VersionLabel' "$tmp/env.json") != "$label" ]]; then
  aw elasticbeanstalk update-environment --environment-name "$env" --version-label "$label" >/dev/null
  eb_changed=true
fi
# Compare pinned fields exactly while permitting service-added default object fields.
# These dollar-prefixed names are jq variables, intentionally literal.
# shellcheck disable=SC2016
definition_filter='def matches($expected): if ($expected | type)=="object" then . as $actual | all($expected | keys[]; . as $key | $actual[$key] | matches($expected[$key])) else .==$expected end;'
if ! head "$snapshot" "$tmp/snapshot-head.json"; then
  aw batch describe-job-definitions --job-definition-name "$(jq -r '."risk-engine".job_definition_name' "$base")" --status ACTIVE > "$tmp/definitions.json"
  sha=$(jq -r '."risk-engine".sha' "$base")
  account=$(aw sts get-caller-identity --query Account --output text)
  git -C "$root/../risk-engine" show "$sha:batch/job-definition.json" > "$tmp/definition-template.json"
  sed -e "s|RISK_ENGINE_IMAGE|$risk_image|g" -e "s|brahma-demo-data-ACCOUNT_ID|$bucket|g" -e "s|ACCOUNT_ID|$account|g" "$tmp/definition-template.json" > "$tmp/definition.json"
  definition=$(jq -r --slurpfile expected "$tmp/definition.json" "$definition_filter"'[.jobDefinitions[] | select(matches($expected[0])) | select(.tags.project=="brahma-demo" and ((.tags.sha // $expected[0].containerProperties.image | split(":") | last)==($expected[0].containerProperties.image | split(":") | last)))] | sort_by(.revision) | last | .jobDefinitionArn // empty' "$tmp/definitions.json")
  if [[ -z $definition ]]; then
    definition=$(aw batch register-job-definition --cli-input-json "file://$tmp/definition.json" --query jobDefinitionArn --output text)
  fi
  # ListJobs pages automatically. Fixed job name + selected definition binds resumable jobs.
  for status in SUCCEEDED FAILED; do aw batch list-jobs --job-queue "$queue" --job-status "$status" > "$tmp/jobs-$status.json"; done
  jq -s --arg name "$job_name" '[.[].jobSummaryList[] | select(.jobName==$name)] | sort_by(.createdAt) | reverse' "$tmp"/jobs-*.json > "$tmp/candidates.json"
  jq -e 'length<=1' "$tmp/candidates.json" >/dev/null || fail 'Multiple baseline reset jobs; inspect concurrent submissions'
  job=$(jq -r '.[0].jobId // empty' "$tmp/candidates.json")
  if [[ -z $job ]]; then
    job=$(aw batch submit-job --job-name "$job_name" --job-queue "$queue" --job-definition "$definition" --tags project=brahma-demo --propagate-tags --query jobId --output text)
  fi
  while :; do
    aw batch describe-jobs --jobs "$job" > "$tmp/job.json"
    jq -e --arg image "$risk_image" --arg bucket "$bucket" '.jobs | length==1 and (.[0].container.image==$image and .[0].tags.project=="brahma-demo" and any(.[0].container.environment[]; .name=="DATA_BUCKET" and .value==$bucket))' "$tmp/job.json" >/dev/null || fail 'Reset job does not match baseline definition; inspect, never blindly resubmit'
    aw batch describe-job-definitions --job-definitions "$(jq -r '.jobs[0].jobDefinition' "$tmp/job.json")" > "$tmp/job-definition.json"
    jq -e --slurpfile expected "$tmp/definition.json" "$definition_filter"'.jobDefinitions | length==1 and (.[0] | matches($expected[0]))' "$tmp/job-definition.json" >/dev/null || fail 'Reset job definition config differs from pinned baseline'
    status=$(jq -r '.jobs[0].status' "$tmp/job.json")
    [[ $status != FAILED ]] || fail "Baseline job $job failed; inspect logs, do not automatically resubmit"
    [[ $status != SUCCEEDED ]] || break
    pause
  done
  stream=$(jq -er '.jobs[0].container.logStreamName' "$tmp/job.json")
  aw logs get-log-events --log-group-name /aws/batch/job --log-stream-name "$stream" --start-from-head > "$tmp/logs.json"
  jq -r '.events[].message' "$tmp/logs.json"
  aw s3api get-object --bucket "$bucket" --key "$live" "$tmp/scores.json" >/dev/null
  valid_scores "$tmp/scores.json" || fail 'Baseline output has invalid probabilities or risk_score'
  # Reject stale output from a prior take before preserving it forever.
  node -e 'const fs=require("fs"); const s=JSON.parse(fs.readFileSync(process.argv[1])); const j=JSON.parse(fs.readFileSync(process.argv[2])).jobs[0]; const t=Date.parse(s.generated_at); if(!(t>=j.startedAt && t<=j.stoppedAt)) process.exit(1)' "$tmp/scores.json" "$tmp/job.json" || fail 'Scores are not from the baseline job'
  if head "$snapshot" "$tmp/snapshot-head.json"; then
    fail 'Snapshot appeared during initialization; concurrent reset detected, rerun serially'
  fi
  aw s3api copy-object --bucket "$bucket" --key "$snapshot" --copy-source "$bucket/$live" >/dev/null
  head "$snapshot" "$tmp/snapshot-head.json"
  report 'Snapshot' "created from $job"
fi
aw s3api get-object --bucket "$bucket" --key "$snapshot" "$tmp/snapshot.json" >/dev/null
valid_scores "$tmp/snapshot.json" || fail 'Snapshot is not baseline; do not overwrite it'
scores_changed=false
if ! head "$live" "$tmp/live-head.json" || ! jq -e -s '.[0].ETag==.[1].ETag and .[0].ContentLength==.[1].ContentLength' "$tmp/snapshot-head.json" "$tmp/live-head.json" >/dev/null; then
  aw s3api copy-object --bucket "$bucket" --key "$live" --copy-source "$bucket/$snapshot" >/dev/null
  scores_changed=true
fi
head "$live" "$tmp/live-head.json"
jq -e -s '.[0].ETag==.[1].ETag and .[0].ContentLength==.[1].ContentLength' "$tmp/snapshot-head.json" "$tmp/live-head.json" >/dev/null || fail 'Snapshot/live mismatch'
aw s3api get-object --bucket "$bucket" --key "$live" "$tmp/live.json" >/dev/null
valid_scores "$tmp/live.json" || fail 'Live scores invalid'
while :; do
  kubectl -n "$ns" get deployment "$deployment" -o json > "$tmp/deploy.json"
  if jq -e --arg c "$container" --arg image "$api_image" '.status.observedGeneration>=.metadata.generation and .status.updatedReplicas==2 and .status.availableReplicas==2 and .spec.replicas==2 and any(.spec.template.spec.containers[]; .name==$c and .image==$image)' "$tmp/deploy.json" >/dev/null; then break; fi
  pause
done
while :; do
  aw elasticbeanstalk describe-environments --application-name "$app" --environment-names "$env" > "$tmp/env.json"
  jq -e '.Environments[0].Status | IN("Terminated", "Terminating") | not' "$tmp/env.json" >/dev/null || fail 'EB terminated'
  if jq -e --arg label "$label" '.Environments[0] | .Status=="Ready" and .Health=="Green" and .VersionLabel==$label' "$tmp/env.json" >/dev/null; then break; fi
  pause
done
host=$(jq -er '.status.loadBalancer.ingress[0].hostname' "$tmp/service.json")
api_url="http://$host"; console_url="http://$(jq -er '.Environments[0].CNAME' "$tmp/env.json")"
configured_api=$(jq -er '.Stacks[0].Parameters[] | select(.ParameterKey=="AccountsApiUrl") | .ParameterValue' "$tmp/stack.json")
[[ $configured_api == "$api_url" ]] || fail 'Stack API URL drift; report it, do not update CloudFormation on reset'
# Baseline test sources are exported to temp so feature tests cannot validate the wrong contract.
for repo in accounts-api ops-console; do
  mkdir "$tmp/$repo"
  git -C "$root/../$repo" archive "$(jq -r --arg repo "$repo" '.[$repo].sha' "$base")" | tar -x -C "$tmp/$repo"
done
(cd "$tmp/accounts-api" && BASE_URL="$api_url" uv run --locked pytest tests/contract)
curl --fail --silent --show-error --max-time 20 "$api_url/accounts" > "$tmp/accounts.json"
jq -e '[.. | objects | has("risk_score")] | any | not' "$tmp/accounts.json" >/dev/null || fail 'API list exposes risk_score'
id=$(jq -er '.accounts[0].id' "$tmp/accounts.json")
curl --fail --silent --show-error --max-time 20 "$api_url/accounts/$(jq -rn --arg id "$id" '$id|@uri')" > "$tmp/detail.json"
jq -e '[.. | objects | has("risk_score")] | any | not' "$tmp/detail.json" >/dev/null || fail 'API detail exposes risk_score'
cat > "$tmp/ops-console/e2e/baseline-reset.spec.js" <<'JS'
const {test, expect} = require('@playwright/test');
test('baseline has no risk UI in directory or detail', async ({page}) => {
  await page.goto('/');
  await expect(page.getByRole('heading', {name:'Accounts', exact:true})).toBeVisible();
  await expect(page.locator('tbody tr').first()).toBeVisible();
  await expect(page.getByText(/high[ -]risk/i)).toHaveCount(0);
  await expect(page.locator('[class*="risk"], [data-testid*="risk"]')).toHaveCount(0);
  await expect(page.getByRole('columnheader', {name:/risk/i})).toHaveCount(0);
  const link=page.locator('tbody tr').first().getByRole('link');
  const name=await link.innerText(); await link.click();
  await expect(page.getByRole('heading', {name, exact:true})).toBeVisible();
  await expect(page.getByText(/risk score|high[ -]risk/i)).toHaveCount(0);
  await expect(page.locator('[class*="risk"], [data-testid*="risk"]')).toHaveCount(0);
});
JS
(cd "$tmp/ops-console/e2e" && npm ci --silent && npx playwright install chromium && BASE_URL="$console_url" npm test)
for repo in "${repos[@]}"; do
  gh api --paginate "repos/$org/$repo/pulls?state=open&per_page=100" | jq -se --argjson prefixes "$prefix_filter" 'all(.[][]; .head.ref as $b | any($prefixes[]; . as $p | $b | startswith($p)) | not)' >/dev/null || fail "Matching PR remains in $repo"
  gh api --paginate "repos/$org/$repo/branches?per_page=100" | jq -se --argjson prefixes "$prefix_filter" 'all(.[][]; .name as $b | any($prefixes[]; . as $p | $b | startswith($p)) | not)' >/dev/null || fail "Matching branch remains in $repo"
done
report 'API Deployment' "$($api_changed && echo changed || echo 'already baseline')"
report 'Scores' "$($scores_changed && echo restored || echo 'already baseline')"
report 'EB version' "$($eb_changed && echo changed || echo 'already baseline')"
report 'Verification' "PASS: $api_url ; $console_url"
