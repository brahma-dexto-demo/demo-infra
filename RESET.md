# Reset the Brahma demo to baseline

Paste into Dexto, in a fresh chat:

```text
Reset the Brahma demo to baseline: follow demo-infra/RESET.md
```

The files are in `/workspace/repos/brahma-dexto-demo/demo-infra`. This returns the demo to the exact before state for another take. It is safe to run any
number of times and takes 2–4 minutes once the scores snapshot exists.

**Rules.** Do exactly the steps below, in order, and nothing else. Never build, never
create an EB version, never update CloudFormation, never seed data, never use presigned
URLs. Do not pause, edit, or create Loops, and do not change any Dexto setting. Skip any
check not listed here. Only the three repos `brahma-dexto-demo/{accounts-api,risk-engine,ops-console}`
and the resources named in [baseline.json](baseline.json) may change.

## 1. GitHub and the computer (one command)

```sh
git -C /workspace/repos/brahma-dexto-demo/demo-infra pull --quiet --ff-only origin main
bash /workspace/repos/brahma-dexto-demo/demo-infra/scripts/reset-computer.sh
```

It closes open PRs whose head branch starts with `dexto/` or `dexto-evidence/` without
merging, deletes those remote branches, removes the task worktrees under
`/workspace/tasks` and the takes' leftover task folders (old delivery reports), deletes
the local feature branches and their commits, and fast-forwards the base clones. It stops if a base clone has uncommitted changes; report that instead of
discarding work.

Every worktree of these three repos under `/workspace/tasks` is demo scratch, whichever
chat created it (earlier takes, the baseline deploy, a previous reset). Pasting the reset
prompt is the owner's instruction to remove them all, so do not stop to ask about
worktrees or branches that another chat recorded. Worktrees of other repos are not
touched by the script.

## 2. Scores and console (one AWS call)

Run the contents of `reset/aws_restore.py`, unchanged, as the code of **one** managed AWS
MCP `aws___run_script` call. It restores `scores/latest.json` from the baseline snapshot by server-side copy
when they differ, switches the console to the baseline version label when it differs,
and prints a JSON report: `cluster`, `api_url`, `api_image`, `api_digest`, `data_bucket`,
`console_url`, `scores`, `console`.

- `scores: snapshot_missing` → do the first-run step at the end of this file, then
  rerun the script.
- `console: busy` → wait 20 seconds and rerun the script.

## 3. API on EKS (apply only when it differs)

The EKS tool hides image tags, so compare digests. With managed EKS MCP
`list_k8s_resources` (cluster from the report, kind Pod, api_version `v1`, namespace
`demo`, label `app=accounts-api`): if there are exactly two Running pods and every
`status.containerStatuses[0].imageID` ends with `api_digest`, the API is already at
baseline; skip to step 4.

Otherwise render the pinned manifest and apply it with `apply_yaml`:

```sh
git -C /workspace/repos/brahma-dexto-demo/accounts-api show \
  f07918f05298373220da69ff027e38c973a6937f:k8s/deployment.yaml \
  | sed -e "s#ACCOUNTS_API_IMAGE#<api_image>#" -e "s#brahma-demo-data-ACCOUNT_ID#<data_bucket>#"
```

Then poll `read_k8s_resource` for Deployment `demo/accounts-api` in short calls until
`observedGeneration >= generation`, `updatedReplicas == 2` and `availableReplicas == 2`.
Do not touch the Service, ServiceAccount, or Pod Identity.

## 4. Wait for the console only if it was switched

If the report said `console: update_started`, poll
`elasticbeanstalk DescribeEnvironments` in short calls until Status `Ready`, Health
`Green`, and the baseline `VersionLabel`. Otherwise skip.

## 5. Verify (one command, one look)

```sh
bash /workspace/repos/brahma-dexto-demo/demo-infra/scripts/verify-baseline.sh <api_url> <console_url>
```

It fails if the API still returns `risk_score` or the console still shows any risk UI.
Then open `<console_url>` once in the browser and confirm the directory renders with no
risk badge and no High-risk filter.

## 6. Report

Five lines: GitHub and computer (the script's output), scores, console, API, and the
verify result, each marked *changed* or *already at baseline*, plus the elapsed time.

## First run only: create the scores snapshot

Needed once, when step 2 reports `snapshot_missing`. The before-state scores come from
one baseline Batch job:

1. Find the ACTIVE `risk-engine` job definition whose image tag is the baseline SHA in
   `baseline.json` (never a feature revision).
2. Submit exactly one job to the stack's `BatchQueueArn` named `reset_job_name` from
   `baseline.json`, tagged `project=brahma-demo` with `propagateTags=true`. If a job
   with that name is already active or SUCCEEDED, reuse it instead.
3. When it is SUCCEEDED, copy `scores/latest.json` to `baselines/scores/latest.json`
   with `s3 CopyObject`, only if the snapshot is still missing. Never overwrite a
   snapshot.

## Admin fallback

With AWS SSO and `gh`, outside Dexto:

```sh
./scripts/reset.sh --profile <admin-profile> --region us-east-1 --dry-run
./scripts/reset.sh --profile <admin-profile> --region us-east-1
```

It performs steps 2–5 and the GitHub half of step 1; clean the computer by running
`scripts/reset-computer.sh` there.
