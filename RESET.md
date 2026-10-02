# Reset the Brahma demo to baseline

Paste into Dexto:

```text
Reset the Brahma demo to baseline: follow demo-infra/RESET.md
```

Read this file and `baseline.json` from demo-infra. The manifest is recorded once;
never replace its SHAs with main, a feature tip, or a newly built artifact. Source
conventions were checked at these SHAs: both image buildspecs tag the full
`CODEBUILD_RESOLVED_SOURCE_VERSION`; ops-console/DEPLOY.md uses the full SHA as
EB `VersionLabel`, with `ops-console/<sha>.jar` as its source bundle.

Target: normally 2–5 minutes, comfortably below 10 minutes with a snapshot and
healthy staging. EKS and EB rollouts are the long poles; start them then interleave
short checks with score restoration. First-run Fargate startup can take longer;
prepare the snapshot before recording. No builds, infrastructure recreation,
CloudFormation updates, seeding, presigned URLs, or version creation on reset.
Never claim success on timeout or a failed check.

## 0. Resolve and check before acting

Pause the review Loop, stop active delivery agents/builds/jobs, and preserve recordings
outside task worktrees. Serialize resets across Dexto and admins; do not run two
resetters concurrently. This is required for the one-job first-run guarantee.

Use the GitHub connection (brokered gh/git; no separate personal credentials) only
for `brahma-dexto-demo/{accounts-api,risk-engine,ops-console}`. Use managed
`aws___run_script` with boto3 `call_boto3` for AWS; use only managed EKS
`apply_yaml`, `read_k8s_resource`, `list_k8s_resources` for Kubernetes.
The Dexto computer has no AWS CLI credentials or kubectl. Do not run the admin
script on it. Do not modify bootstrap from the agent: an admin must install its
updated template once before using snapshot writes.

Resolve region `us-east-1`, check `sts.get_caller_identity` is assumed
`DextoDemoRole`, and `cloudformation.describe_stacks(StackName="brahma-demo-staging")`.
Require stable CREATE_COMPLETE/UPDATE_COMPLETE and `project=brahma-demo`.
Map Outputs by OutputKey; substitute `${...}` placeholders in `baseline.json`
with their exact OutputValue. Do not use `AccountsApiImageReference` (it may still
be the bootstrap tag). Do not substitute account-specific literals. Read account
from STS only for role ARN placeholders when rendering a Batch definition.

Preflight existing ECR SHA tags with `ecr.describe_images`. Read
`elasticbeanstalk.describe_application_versions` for the pinned application/label;
require exactly one version with SourceBundle matching ArtifactsBucketName and
`source_key`. If missing, stop: recover the original artifact/version with an
administrator, never rebuild during reset. Read EB environment and API Service.
Check CodeBuild projects for IN_PROGRESS builds and Batch queue for jobs in
SUBMITTED/PENDING/RUNNABLE/STARTING/RUNNING. Do not reset while another writer is
active; do not cancel unrelated resources. A matching interrupted baseline reset
job (§4) is the only allowed writer, and only while its snapshot is missing.
If a snapshot already exists, wait for all writers to finish before restoring it. If EB is Updating to the baseline label,
resume polling; if updating another version, wait for that operation before acting.

Keep a small ledger: step, changed/already baseline, resource and check result.
Per `multi-repo-delivery` waiting guidance: start an operation, return its ID,
poll once or briefly (at most ~20 seconds) in a subsequent call, do other independent
work, and return to polling. Use `aws___get_tasks` for asynchronous MCP execution
status when appropriate; inspect the API result too. No long sleep loops in an MCP
call. Retain job IDs in the conversation. After ~8 minutes report pending checks
and continue/resume them; never submit again just because polling timed out.

## 1. GitHub cleanup (check, then close/delete)

For each of the three allowed repositories, paginate **all** open PRs (not the
default 30/100 limit). Select only head branch names starting with a manifest
prefix (`dexto/` or `dexto-evidence/`). Include matching PRs regardless of author
or whether their head is a fork. Re-read each PR; if still open and the head still
matches, close without merging. Leave all other PRs alone.

Paginate remote branch refs for that repository, select the same prefixes,
recheck existence, and delete only those refs. With brokered gh, use
`gh api --paginate repos/<org>/<repo>/branches?per_page=100` and
`DELETE repos/<org>/<repo>/git/refs/heads/<URL-encoded-branch>`; an absent ref is
already done. Never delete main, tags, baseline refs, or branches in a fork/other
repository. Re-list to require no matching open PRs or remote refs remain. Do not
push, open a new PR, or merge anything as part of reset.

## 2. Dexto computer cleanup (keep base clones)

For each `/workspace/repos/brahma-dexto-demo/<repo>`:

1. Check `git remote get-url origin` identifies the exact allowed repository.
   List `git worktree list --porcelain`; parse records, not whitespace-split paths.
   For each registered worktree with a canonical path **under `/workspace/tasks/`**,
   remove it with `git -C <base> worktree remove --force -- <path>`. Only remove
   worktrees belonging to these three repositories; keep base clones and unrelated
   task directories. Already absent is done. Run `git worktree prune` on the base.
2. Ensure the base is clean and on main. If dirty, stop and report rather than
   discard uncommitted base-clone work. If checked out on a matching feature branch
   and clean, switch to main first. Delete local branch refs beginning with a
   manifest prefix using `git branch -D -- <branch>`; re-list and confirm absence.
   If a matching branch is checked out in a worktree outside the allowed task
   root, stop and report; do not force-delete that worktree.
3. `git fetch origin`, then `git merge --ff-only origin/main`. If local main
   diverges, stop rather than reset it. Main need not equal the immutable baseline:
   use `git show <baseline-sha>:<path>` or a temporary `git archive` export for
   deployments/tests. Fetch a missing immutable SHA through the connection, verify
   it resolves exactly; never modify or push main. Keep the three base clones.

## 3. EKS baseline Deployment (check, then apply)

Read Deployment and Service `demo/accounts-api` with `read_k8s_resource`, using
ClusterName. If the accounts-api container image is already the resolved baseline
URI, skip apply but still require rollout readiness below. If different, read
`k8s/deployment.yaml` **at the accounts-api baseline SHA**, replace
`ACCOUNTS_API_IMAGE` with the baseline URI and the complete
`brahma-demo-data-ACCOUNT_ID` placeholder with DataBucketName. Preserve all other
baseline env, probes, resources, two replicas, namespace, labels and
`serviceAccountName: accounts-api`. Send the rendered YAML to `apply_yaml`.
Do not patch only the live image with an alternative tool.

Preserve the existing ServiceAccount and its Pod Identity association. Do not
recreate the Service or LoadBalancer. Require Service annotation
`service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags: project=brahma-demo`
from the baseline service manifest; if absent, render/re-apply baseline
`k8s/service.yaml` with that annotation through `apply_yaml`, preserving any
additional existing annotations. Read it back. If SA/Pod Identity or env is
unexpected, stop for diagnosis; don't modify IAM or infrastructure during reset.

Poll `read_k8s_resource` until the expected container image and `spec.replicas=2`,
`status.observedGeneration >= metadata.generation`, `updatedReplicas=2` and
`availableReplicas=2`. Obtain the API URL from Service ingress hostname, port 80.
Start EB (§5) before waiting for EKS so both rollouts can proceed together.

## 4. Scores (check, then copy; first run only: one baseline job)

All objects are in DataBucketName; manifest `live_key` is `scores/latest.json`,
`snapshot_key` is `baselines/scores/latest.json`. Use `s3.head_object`; **only**
404/NoSuchKey/NotFound means missing. AccessDenied or other errors stop the reset.
Do not create a snapshot from arbitrary currently live scores.

If snapshot exists, use `get_object` to validate JSON: nonempty `scores`, every
entry has `id` and numeric `probability` in [0,1], recursively **no `risk_score`**.
An invalid snapshot is an error, never overwrite it. Compare both heads by ETag
and ContentLength; if equal, skip write. Otherwise through `aws___run_script`
`call_boto3`, make the server-side copy:

```python
# Values are the resolved manifest values. This is a boto3 call specification;
# adapt argument syntax to the managed MCP call_boto3 wrapper's documented signature.
s3.copy_object(
    Bucket=bucket, Key=live_key,
    CopySource={"Bucket": bucket, "Key": snapshot_key},
)
```

This transfers no scores through the computer and needs no presigned URL. Preserve
snapshot content/metadata. Re-read live JSON, require no `risk_score`, and require
live ETag/ContentLength equal snapshot. Timestamps are deliberately the snapshot's
original timestamp: do not require a fresh generated_at on ordinary resets.

If snapshot is missing (first run):

1. Paginate `batch.describe_job_definitions(jobDefinitionName="risk-engine",
   status="ACTIVE")`. Select a definition with the baseline full-SHA image,
   `project=brahma-demo`, DATA_BUCKET=DataBucketName and assignPublicIp=ENABLED;
   optional SHA tag must agree. Choose the highest matching revision, **not**
   the latest feature revision. Verify roles/config against the pinned
   `risk-engine/batch/job-definition.json`; do not hardcode a revision.
   If none exists, render that pinned JSON with the baseline image, STS account,
   DataBucketName and region; preserve FARGATE, roles, resource requirements,
   public IP, timeout, retries, logs, tags and propagateTags. Register it once
   with `batch.register_job_definition`; re-use matching definitions thereafter.
2. Before submitting, paginate `batch.list_jobs` in the demo queue for active,
   SUCCEEDED and FAILED statuses and select exact manifest `reset_job_name`.
   Describe matching jobs; require their definition image/config is baseline.
   Reuse an active job, or a prior SUCCEEDED job whose live output timestamp lies
   between that job's startedAt/stoppedAt. If a reset job failed or a succeeded
   job's output was replaced, stop for explicit recovery; never silently submit
   another. If no reset job exists, submit **exactly one** using the resolved
   definition ARN, BatchQueueArn, fixed reset_job_name, tags project=brahma-demo,
   propagateTags=true. Record ID immediately. No rebuild.
3. Poll `describe_jobs` asynchronously until SUCCEEDED; on FAILED, read logs and
   stop. Successful baseline job includes passing eval per DEPLOY.md (AUC ≥ .80,
   probability bounds and determinism); inspect `/aws/batch/job` logs and metrics.
   Read live JSON; require the baseline shape above and generated_at between the
   recorded job start/stop. Only then `s3.copy_object` live → snapshot. Never
   overwrite an existing snapshot: recheck head just before creating it.
4. Execute the ordinary snapshot → live path and equality checks above. Preserve
   this snapshot across all takes. If an interrupted successful job is no longer
   discoverable (Batch retention), stop for admin recovery; do not guess.

## 5. Elastic Beanstalk (check, then version-only update)

Read `describe_environments` for ops-console / ops-console-staging. Verify the
preflight application version still exists and has the pinned source bundle. If
VersionLabel equals the manifest label, skip update (even if a baseline update is
still finishing). Otherwise require Ready and call only:

```python
eb.update_environment(EnvironmentName="ops-console-staging", VersionLabel=baseline_label)
```

No OptionSettings, no platform change, no API URL change, no version/JAR creation,
no build. Poll separate `describe_environments` calls until Ready, Green, and the
exact baseline VersionLabel. Fail on terminating/terminated; report events on
failure. Obtain console URL from CNAME. Check ACCOUNTS_API_URL still matches the
API Service URL; report drift rather than silently updating CloudFormation.

## 6. Verify and report

Export baseline tests with `git archive <sha>` into temporary directories, so
feature tests on main cannot redefine the baseline contract. Run the API's live
contract tests with `BASE_URL=http://<Service-hostname> uv run --locked pytest tests/contract`
from a baseline accounts-api export. Additionally GET `/accounts`, assert no
`risk_score` recursively, extract a real ID from `accounts[0].id`, GET
`/accounts/<id>`, and assert no `risk_score` recursively. Require nonempty results,
valid schema and successful HTTP statuses; `/healthz` alone is insufficient.

Use the `browser` skill on live EB CNAME: directory heading and real rows render;
open one account link and require its detail heading/data. Check **both** pages
have no risk badge/score and the directory has no High-risk filter. Run baseline
ops-console `e2e` smoke when available (search, industry and detail) with the live
BASE_URL; capture a real baseline screenshot outside the task cleanup directories.
Do not infer browser success from an HTTP 200. Compare snapshot/live heads again
and re-list GitHub/local refs to confirm no matching branches/PRs remain.

Report a short table, including already-baseline rows, with evidence:

| Target | Changed / already baseline | Verified |
| --- | --- | --- |
| GitHub (each allowed repo) | PR/ref counts | no matching open PRs or refs |
| Computer | worktree/branch counts | base clones retained, main fast-forwarded |
| API | image applied/skipped | image, generation, two replicas, list/detail contracts |
| Scores | copied/skipped; snapshot initialized if needed | no risk_score, ETag + size equal |
| Console | version changed/skipped | label, Ready/Green, browser directory/detail/no risk UI |

Report elapsed time and pending failures honestly. Keep Loop paused until the
next take's PRs exist. Preserve infrastructure, main/other branches, input data,
images, JARs, baseline snapshot, recordings, unrelated repos and resources.

## Admin fallback

An administrator with AWS SSO permissions, broker-independent `gh` access,
AWS CLI v2, kubectl, jq, curl, git, uv, Node/npm and Playwright prerequisites can run:

```sh
aws sso login --profile <admin-profile>
./scripts/reset.sh --profile <admin-profile> --region us-east-1 --dry-run
./scripts/reset.sh --profile <admin-profile> --region us-east-1
```

The script reads this manifest, uses a temporary kubeconfig, polls with a bounded
wait, and prints the computer cleanup instructions instead of modifying Dexto's
filesystem. Keep sibling base clones accessible for read-only `git show/archive`
at the pinned SHAs. Prepare uv/npm/browser caches before recording. Dry run makes
no AWS/GitHub calls or mutations and prints the conditional plan; it does not
assert live resource state. AWS/GitHub transport failures are fatal; rerun after
inspection to resume. The admin role is separate from MCP-only DextoDemoRole.

IAM: bootstrap already allows data-bucket GetObject (including the snapshot), EB
operations through AdministratorAccess-AWSElasticBeanstalk, and EKS API access
through its inline policy plus stack access entry. The only added grant is
PutObject for the two exact score keys, under the existing MCP-only deny. There
is no s3:CopyObject IAM action; copying needs source GetObject + destination PutObject.
