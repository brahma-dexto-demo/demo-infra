# Dexto enterprise demo run book

Rahul pastes the prompts below into Dexto chat. Dexto does the work on its cloud computer and shows progress in the same conversation. AWS region: `us-east-1`. AWS APIs use managed AWS MCP (`aws___run_script` = Python/boto3, `aws___get_presigned_url`, `aws___get_tasks` for task status); Kubernetes uses managed Amazon EKS MCP (`apply_yaml`, `read_k8s_resource`, `list_k8s_resources`, `get_pod_logs`, `get_k8s_events`). The computer has no AWS credentials, AWS CLI, or kubectl.

## 1. Before the demo (one-time)

- [ ] Administrator follows [README.md](README.md) to install [bootstrap.yaml](bootstrap.yaml). **Pass:** `dexto-demo-bootstrap` is `CREATE_COMPLETE`; retain `DextoDemoRoleArn` and `DextoDemoCfnExecRoleArn`. Broker principal and External ID match Dexto's connect screen.
- [ ] Connect **AWS** and **Amazon EKS** in Dexto with the bootstrap demo role. **Pass:** both connections are healthy; an AWS MCP identity check returns the assumed `DextoDemoRole` in the intended account. Test cluster access after Prompt 1 creates it.
- [ ] Connect GitHub with access to `brahma-dexto-demo` and turn **Push and open PRs as Dexto** on. **Pass:** the setting is on, all three repositories are accessible, and each CODEOWNERS file names `@rahulkarajgikar`.
- [ ] Settings › Computer: add `brahma-dexto-demo/accounts-api`, `brahma-dexto-demo/risk-engine`, and `brahma-dexto-demo/ops-console`. **Pass:** the computer base-clones all three into `/workspace/repos/brahma-dexto-demo/<repo>`. Make `brahma-dexto-demo/demo-infra/stack.yaml` and shared `conventions.md` available too (add demo-infra or clone it through the GitHub connection).
- [ ] Confirm platform skills `multi-repo-delivery`, `dev-toolchain`, and `browser` are available. **Pass:** Java 17/Maven and local Docker are installed through `dev-toolchain`; Python/uv and Node are available; browser can open a local page.
- [ ] Publish the baseline source revisions before rehearsal; record the three immutable baseline SHAs. **Pass:** CodeBuild can fetch the API and risk repositories at those SHAs (public by default; private needs an AVAILABLE CodeConnection).

## 2. Prompt 1 — provision staging

Replace the two role placeholders with bootstrap outputs, then paste:

```text
Provision staging in my connected AWS demo account in us-east-1. Read
brahma-dexto-demo/demo-infra/stack.yaml and the shared conventions.md on the
computer. Use AWS only through managed AWS MCP and Kubernetes only through
managed Amazon EKS MCP; do not use local AWS credentials, AWS CLI, or kubectl.

Use aws___run_script with boto3 to resolve Account via sts.get_caller_identity()
and verify the caller is DextoDemoRole. Validate the exact stack.yaml TemplateBody
and create CloudFormation stack brahma-demo-staging from that same text, with
RoleARN=<DextoDemoCfnExecRoleArn>, Capabilities=["CAPABILITY_NAMED_IAM"],
Tags=[{"Key":"project","Value":"brahma-demo"}], and parameters
GitHubOrg=brahma-dexto-demo, CodeConnectionArn="", AccountsApiImageTag=bootstrap,
DextoRoleArn=<DextoDemoRoleArn>, AccountsApiUrl="". Use the template platform
default; if rejected, select the available Corretto 17 AL2023 solution stack
through elasticbeanstalk.list_available_solution_stacks and report the change.
If the stack already exists, report its status instead of recreating it.

Wait for CREATE_COMPLETE, polling in separate MCP calls as needed; report
describe_stack_events on failure. Then use EKS MCP apply_yaml on cluster
brahma-demo to create Namespace demo and ServiceAccount accounts-api in demo
(apiVersion v1 for both). Verify them with read_k8s_resource; retry briefly for
access-entry propagation. Tag the ops-console application project=brahma-demo
through elasticbeanstalk.update_tags_for_resource, resolving its ARN at runtime.
Report every stack output, the stack status, and namespace/service-account checks.
This step provisions infrastructure only; do not deploy the applications yet.
```

**Duration:** approximately 15–20 minutes; EKS is the long pole. Keep polling visible, but compress the wait in the recording.

**Done:** stack `CREATE_COMPLETE`; EKS cluster and nodes active; `demo/accounts-api` service account exists. Report these exact output keys: `ClusterName`, `AccountsApiEcrUri`, `RiskEngineEcrUri`, `AccountsApiImageReference`, `ArtifactsBucketName`, `DataBucketName`, `AccountsApiCodeBuildProject`, `RiskEngineCodeBuildProject`, `BatchQueueArn`, `EbEnvironmentUrl`. The `bootstrap` image reference is a placeholder, and EB still serves its sample app. No API LoadBalancer exists yet.

**Console check:** AWS console → region **us-east-1** → CloudFormation → `brahma-demo-staging` → Events (completion) and Outputs (values). EKS → `brahma-demo` → Overview/Compute (active cluster, two nodes); Elastic Beanstalk → `ops-console-staging` (sample environment).

## 3. Prompt 2 — baseline deploy

Prompt 2 seeds `accounts-api/data/accounts/accounts.json` to the output `DataBucketName`, key `accounts/accounts.json`, using an MCP-generated presigned PUT and a computer upload. Replace the three placeholders with the recorded baseline SHAs, then paste:

```text
Deploy the before state to brahma-demo-staging in us-east-1. Use the immutable
baseline revisions accounts-api=<baseline-api-sha>, risk-engine=<baseline-risk-sha>,
ops-console=<baseline-console-sha>; retain these in the delivery report for resets.
Use each repo's DEPLOY.md and the multi-repo-delivery, dev-toolchain, and browser
skills. Use only managed AWS MCP for AWS and managed EKS MCP for Kubernetes.
Confirm accounts/accounts.json exists in DataBucketName. If missing, obtain an
aws___get_presigned_url PUT for DataBucketName/accounts/accounts.json and upload
accounts-api/data/accounts/accounts.json from the computer with
curl --fail --upload-file accounts-api/data/accounts/accounts.json "$PRESIGNED_PUT_URL". Keep the signed URL out of
logs. DextoDemoRole may write only accounts/* in this data bucket.

Start CodeBuild accounts-api-image and risk-engine-image at their published full
SHAs and wait for SUCCEEDED. Buildspecs only build/push ECR images. Apply the API
k8s manifests through apply_yaml with the SHA image and runtime bucket/account;
preserve demo/accounts-api Pod Identity. For every image change, re-render the
Deployment with the new image and re-apply it through apply_yaml. Preserve the
Service annotation already present in k8s/service.yaml:
service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags:
project=brahma-demo. Use read_k8s_resource to require observedGeneration >=
generation and two updated/available replicas, then obtain the Service
LoadBalancer hostname and run live API contract tests.

Use CloudFormation UpdateStack on brahma-demo-staging to set AccountsApiUrl to
http://<API-LoadBalancer-hostname> using the CloudFormation execution role,
retaining all other parameters with UsePreviousValue=true and stack tags. Wait for UPDATE_COMPLETE before the EB
application update, so ACCOUNTS_API_URL stays aligned with CloudFormation.

Register the rendered risk-engine batch/job-definition.json with the SHA image,
runtime account and bucket. Preserve assignPublicIp=ENABLED; tag the definition
and job project=brahma-demo, set propagateTags=true, and submit exactly one job
to brahma-demo-queue. Wait for SUCCEEDED; read CloudWatch logs, eval metrics,
and scores/latest.json, checking that generated_at belongs to this run.

Build ops-console on the computer with mvn -B package (or ./mvnw -B package),
get an aws___get_presigned_url PUT for ArtifactsBucketName/ops-console/<sha>.jar,
and upload target/ops-console.jar with curl without logging the signed URL.
Create/reuse the matching EB application version, then update ops-console-staging
with VersionLabel only. CloudFormation owns SERVER_PORT=5000, ACCOUNTS_API_URL
from AccountsApiUrl, and health path /healthz; keep these settings in the stack.
Wait for Ready/Green on the expected version. Run its live
browser smoke and show the account directory and detail before risk badges.
Report the live console CNAME URL, API URL, all baseline SHAs, CodeBuild ids,
Batch job id, and eval metrics. Do not add the feature or open PRs in this step.
```

**Done:** console lists the 200 synthetic accounts with existing search/industry/pagination/detail behavior, without risk badges or High-risk filter. Baseline Batch produces `probability` in `[0,1]`; eval passes (AUC ≥ 0.80, bounds and determinism pass). `/healthz` alone is insufficient: verify real accounts render. Preserve a baseline screenshot and the three SHAs.

## 4. Prompt 3 — the feature

Paste verbatim:

```text
Add a risk score to accounts across our three repos. risk-engine should compute a 0–100 score per account in its Batch job, accounts-api should return it on /accounts and /accounts/{id}, and ops-console should show it as a coloured badge with a High-risk filter. Deploy each to staging, QA the whole flow, and open PRs for the owners.
```

Rehearse the following beats. Agree the wire contract and Low/Med/High thresholds in the plan; record them in tests and the report. The mismatch check must use observed failures or explicit regression fixtures, never a fabricated tool result.

| Beat | What should happen / pass criterion | Dexto UI to capture |
| --- | --- | --- |
| Plan | `multi-repo-delivery` reads all three repos and DEPLOY.md files, maps dependencies, defines snake_case `risk_score` on a 0–100 scale, badge/filter thresholds, and QA gates. | Chat plan; Todos panel |
| Parallel implementation | Three subagents, one per repo, each in its own git worktree and `dexto/*` branch from baseline. `dev-toolchain` supplies local tools. | Subagents view; worktree tool rows |
| Local integration QA | Run risk score + eval on shared local data, API list/detail contract tests, Java tests, and browser directory/detail/filter tests against the local stack. Regenerate API OpenAPI schema. | Test tool rows; Todos panel |
| Contract mismatch catch | Catch snake_case `risk_score` vs Java camelCase mapping and 0–1 probability vs 0–100 score. Show the failing assertion, fix the DTO mapping/scale boundary, and rerun green; verify both endpoints and badge/filter boundaries. | Failed then passing tool rows; subagent handoff |
| Image builds | Commit and push feature branches through GitHub so CodeBuild can fetch SHAs; build API and risk images at those exact SHAs, with no deploy in buildspec. | GitHub tool rows; approvals when presented; AWS MCP build rows |
| EKS rollout | Apply API SHA image via `apply_yaml`; verify two updated/available replicas with `read_k8s_resource`. Use `list_k8s_resources`, `get_pod_logs`, `get_k8s_events` if needed; check live list/detail responses. | EKS MCP tool rows; rollout result |
| Batch run + eval | Register SHA job definition, preserve public IP and tags, submit job, wait for SUCCEEDED, show CloudWatch eval metrics and fresh S3 output with 0–100 scores for every account. Deploy console JAR to EB per DEPLOY.md, retaining API URL. | AWS MCP tool rows; eval JSON; approvals when presented |
| Staging browser QA | `browser` opens the live console; verify badges, High-risk filter, search/industry/pagination/detail, and API consistency. Save actual screenshots on an orphan `dexto-evidence/*` branch (no application history), linking exact evidence files. | Inline screenshots; browser tool rows; evidence branch push |
| Three linked PRs | Open three ready-for-review PRs as `dexto-cloud[bot]`, cross-link dependencies and evidence, request CODEOWNER `@rahulkarajgikar`, and verify author/review request. Do not use draft PRs or `[codex]` titles. | GitHub tool rows; approvals when presented; PR links |
| Delivery report | Report deployed SHAs, URLs, PRs, tests, screenshot evidence, build ids, Batch job id/metrics, and any remaining issues; all Todos complete only after verified delivery. | Final chat report; artifact |

Approvals are shown when Dexto actually requests them; Rahul approves the displayed concrete action. Keep AWS and GitHub activity visible as Dexto tool rows throughout.

## 5. Prompt 4 — review Loop (optional wow)

Paste after the three PRs exist:

```text
Create a Loop triggered by github.comment.created for brahma-dexto-demo/accounts-api,
brahma-dexto-demo/risk-engine, and brahma-dexto-demo/ops-console. Handle top-level
PR comments by @rahulkarajgikar on this demo's open dexto/* PRs. Ignore bot comments,
non-PR issue comments, and unrelated PRs to prevent feedback loops. Read the PR and
linked delivery context, implement requested review changes on its existing branch,
rerun relevant tests, deploy to staging through managed AWS/EKS MCP per DEPLOY.md,
and browser-QA the change. Push to the same PR, refresh evidence on the orphan
dexto-evidence/* branch, and reply on the PR with the commit, test/deploy results,
and screenshots. Report the Loop configuration and enabled status in this chat.
```

Rahul adds **“Show Low/Med/High next to the number”** as a **top-level PR comment** on the ops-console PR, not an inline review comment. Expected: Loop trigger/run appears in Dexto; agent reads context, adds the agreed labels alongside numeric badges, tests boundaries, builds/uploads a new JAR, waits for EB Ready/Green, captures staging screenshots, pushes to the same PR, and posts its evidence reply as the bot. Keep the existing review request; refresh the delivery artifact. Pause the Loop before reset/teardown.

## 6. Recording and assets

Save everything together in one Dexto artifact/folder named **`brahma-demo-<date>`** (`<date>` = `YYYY-MM-DD`):

- Screen recording file (original and edited cut).
- Key screenshots: connections/computer setup, baseline, plan/Todos, three subagents, contract failure/fix, rollout, eval, staging badges/filter/detail, PR author/reviewer, optional Loop before/after.
- Delivery report; baseline and deployed SHAs; three PR links; orphan evidence branch/file links; console and API staging URLs.
- Batch job id, definition revision, timestamp and eval metrics (AUC, bounds, determinism, pass); both CodeBuild ids and statuses.

Exclude External ID and presigned upload URLs from captures. Screenshots in the orphan evidence branch are linked from the same artifact.

| Suggested 9-minute cut | Beats to show |
| --- | --- |
| 0:00–0:45 | Dexto connections/computer setup; Prompt 1 and completed outputs (compress 15–20-minute wait) |
| 0:45–1:15 | Prompt 2 result: live before state |
| 1:15–2:00 | Verbatim Prompt 3; plan and Todos |
| 2:00–3:00 | Three subagents/worktrees and implementation |
| 3:00–4:15 | Local integration; contract mismatch failure, fix, green tests |
| 4:15–5:15 | CodeBuild SHA builds and EKS rollout (compress waits) |
| 5:15–6:00 | Batch run/eval and EB update |
| 6:00–7:15 | Live staging badges, High-risk filter, detail, inline screenshots/evidence |
| 7:15–8:00 | Three linked bot PRs, CODEOWNER review, delivery artifact |
| 8:00–9:00 | Optional Loop: Rahul's top-level comment → label change → refreshed QA/reply |

Without the Loop, expand staging QA/report to finish near eight minutes; allow ten minutes for fuller review context. Label time cuts so wait compression is clear.

## 7. If something goes wrong

| Failure | Fix prompt or console action |
| --- | --- |
| AssumeRole denied | Admin compares broker IAM principal and **External ID** from Dexto with bootstrap parameters; update bootstrap retaining other values, then reconnect. |
| MCP denied by routing condition | Admin updates bootstrap **EnforceMcpOnly=false**, retaining all other parameters. Prompt: “Retry through managed MCP and report the exact denied action; do not broaden IAM grants.” |
| CodeBuild cannot fetch source | Confirm repo is **public** and SHA is pushed. If still an auth failure, admin authorizes an AVAILABLE GitHub CodeConnection; update `CodeConnectionArn`, retaining other parameters. |
| EKS apply forbidden | EKS console → cluster Access: verify access entry uses bootstrap **IAM role ARN**, with cluster-scoped AmazonEKSClusterAdminPolicy; check `DextoRoleArn` and connection role match. Retry after propagation. |
| EB stuck | “Use aws___run_script to describe EB environments and **describe_events** for ops-console-staging; report version, health and failing event before fixing.” Verify JAR, port 5000 and API URL. |
| Batch RUNNABLE forever | Admin checks queue enabled and compute environment **ENABLED/VALID**, capacity (4 vCPU), Fargate compatibility and subnet connectivity. Preserve job-definition `assignPublicIp=ENABLED`; there is no NAT. |
| PR opened as user | Turn **Push and open PRs as Dexto** on. Close the incorrectly authored PR and reopen the same feature branch as `dexto-cloud[bot]`; refresh cross-links and review request. |

## 8. Reset between takes

1. Pause the review Loop. Preserve the recording/artifact and immutable baseline SHAs. Stop any active deployment/job before reset.
2. Ask Dexto through its GitHub connection to close this take's three PRs without merging and delete this demo's remote `dexto/*` and `dexto-evidence/*` branches; remove their local worktrees/branches. Scope deletion to the three demo repos and this take; preserve baseline branches.
3. Run **Prompt 2** again with the saved baseline SHAs. Reuse existing EB versions when present. The baseline Batch run overwrites feature scores with the before-state output; verify its fresh timestamp and eval pass.
4. Browser-check no badges/High-risk filter, capture a fresh baseline, and start a fresh Dexto conversation for the next take. Re-enable/recreate the Loop only when the new PRs exist.

### Teardown

1. Pause the Loop, then follow [README.md → Teardown](README.md#teardown): stop builds/jobs, retain the API Service hostname, and use EKS MCP `apply_yaml` to re-apply `demo/accounts-api` as `ClusterIP` (preserve selector, ports and annotations). Verify with `read_k8s_resource` so Kubernetes cannot recreate the load balancer. If it remains, use the README's `aws___run_script` Classic ELB deletion script, which checks the hostname and both `project=brahma-demo` and `kubernetes.io/service-name=demo/accounts-api` tags. Bootstrap conditions deletion on the project resource tag. Poll until the load balancer is gone; a human verifies its ENIs have disappeared in **EC2 → Network Interfaces** before `DeleteStack`. If the script is denied or tags differ, a human verifies both tags in **EC2 → Load Balancers**, deletes only that load balancer, and waits for its ENIs to disappear. Inspect residual load balancer security groups as described in the README.
2. Human admin empties **both** output buckets in S3 (including multipart uploads and any versions/delete markers). Stop writers first. DextoDemoRole has no dedicated data-bucket deletion permission.
3. Paste into Dexto, substituting the execution-role output:

   ```text
   Delete CloudFormation stack brahma-demo-staging in us-east-1 through
   aws___run_script with boto3 and RoleARN=<DextoDemoCfnExecRoleArn>. First confirm
   Service is ClusterIP, the API LoadBalancer and its ENIs are gone, and the
   human has emptied both demo buckets.
   Poll until deletion completes; report any DELETE_FAILED events and remaining
   resources. Keep all AWS activity in managed MCP.
   ```

4. Admin deregisters agent-created `risk-engine` job-definition revisions (outside CFN), removes residual EB application versions if they block deletion, and checks for orphaned LB/ENI/security groups, logs and EB storage. Preserve shared EB buckets.
5. After staging deletion completes, admin deletes `dexto-demo-bootstrap` in CloudFormation, removes any separately hosted bootstrap template, and removes the demo's AWS, Amazon EKS and GitHub connections in Dexto. Remove demo repos from computer setup if no longer needed.
