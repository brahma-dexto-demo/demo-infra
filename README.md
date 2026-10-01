# demo-infra

CloudFormation infrastructure for an enterprise demo of Dexto, an AI agent product. The dedicated AWS member account **865579549254** holds only this demo and stands in for a customer's account. All names follow `../conventions.md`; all regional resources run in **us-east-1**. There is no Terraform and no automatic deployment in this repository.

`bootstrap.yaml` is installed once by a human administrator. `stack.yaml` is then deployed as **brahma-demo-staging** by Dexto using the managed AWS MCP Server's `aws___run_script` (Python/boto3 with the caller's role credentials). Kubernetes changes use the managed Amazon EKS MCP Server. The agent's computer has no AWS credentials, AWS CLI, or kubectl.

## One-time administrator setup

1. Use a dedicated demo account. Confirm that the convention names and account-global S3 bucket names are unused. Obtain the broker **IAM principal ARN** and **ExternalId** from Dexto's AWS connect screen. The default broker principal is `arn:aws:iam::138185518449:user/dexto-aws-mcp-broker`; use an IAM user or role ARN, not an STS assumed-role session ARN.
2. Open the [CloudFormation console in us-east-1](https://console.aws.amazon.com/cloudformation/home?region=us-east-1). Upload `bootstrap.yaml` through **Create stack → With new resources (standard)**, or use the quick-create route below. Name the stack **dexto-demo-bootstrap** (outside the agent's `brahma-demo-*` stack scope).
3. For console quick-create, first upload this exact file to a private, existing administrator-controlled S3 bucket. Do not use the demo artifacts bucket: it does not exist yet. URL-encode its HTTPS S3 object URL and open:

   ```text
   https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/create/review?stackName=dexto-demo-bootstrap&templateURL=<URL-encoded-HTTPS-S3-object-URL>
   ```

   Review `DextoPrincipalArn` (default broker above), fill in `ExternalId` and `BudgetEmail`, and review `MonthlyBudgetUsd` (default 150) and `EnforceMcpOnly` (default `true`) in the console. Keep the external ID out of shared quick-create URLs. Acknowledge **CAPABILITY_NAMED_IAM**, review, and create. Add the stack tag `project=brahma-demo` in either flow.
4. Wait for `CREATE_COMPLETE`. Copy both role ARN outputs. Enter `DextoDemoRoleArn` into Dexto's AWS connection and retain `DextoDemoCfnExecRoleArn` for provisioning. Ensure the broker sets source identity when assuming the role and supplies the external ID. Sessions are limited to one hour.
5. The monthly budget covers the entire dedicated member account, including untagged costs. Confirm that both email alerts arrive when spending exceeds 80% and 100%. Alerts have billing delay and do not stop resources.
6. Public repositories are the default. For private repos, a human must create and authorize a GitHub CodeConnection with access to `accounts-api`, `risk-engine`, and `ops-console`; its status must be **AVAILABLE**. Pass its ARN as `CodeConnectionArn`. The template grants each build role use of only that connection, including the legacy ARN/action prefix.

`EnforceMcpOnly=true` (the default) enables one explicit deny across the broker's inline and AWS-managed Beanstalk grants: direct requests must carry `aws:ViaAWSMCPService=true`. AWS services acting on the caller's behalf remain allowed through `aws:ViaAWSService=true`; Elastic Beanstalk and CloudFormation use forward access sessions that carry this key without the MCP key. If the managed MCP servers turn out not to set `aws:ViaAWSMCPService` for `run_script` calls, a human administrator must update the **dexto-demo-bootstrap** stack with `EnforceMcpOnly=false`, retaining all other parameters. The agent should still use MCP as instructed. The account seed uses a scoped `s3:PutObject` grant on `brahma-demo-data-<account>/accounts/*` through `aws___run_script`, subject to the same routing deny as other AWS actions. There are no computer-upload exemptions. The separate `ops-console-jar` CodeBuild service role writes only `brahma-demo-artifacts-<account>/ops-console/*`. Legacy `aws-mcp:*` and `eks-mcp:*` permissions are retained and exempt from the routing deny. [MCP IAM context](https://docs.aws.amazon.com/agent-toolkit/latest/userguide/security_iam_service-with-iam.html).

CloudFormation assumes `DextoDemoCfnExecRole`, whose trust permits only CloudFormation. Its AdministratorAccess is needed for this demo's IAM roles, EKS and VPC. Explicit denies block IAM user/access-key/login-profile creation, Organizations/Account actions, and mutation of either bootstrap role. This is a powerful demo-account execution role, not isolation from a malicious template: it can still create other privileged roles. Deploy reviewed templates in this dedicated account.

## Exact Dexto provisioning prompt

Replace the two role ARN placeholders with bootstrap outputs, then give Dexto this prompt:

```text
Provision the Brahma enterprise demo in my connected AWS demo account, region us-east-1.
Read demo-infra/stack.yaml and the shared conventions.md. Use AWS only through the
managed AWS MCP Server (aws___run_script with Python/boto3), and Kubernetes only
through the managed Amazon EKS MCP Server. Do not use AWS credentials, AWS CLI,
or kubectl on the computer.

Through aws___run_script, call sts.get_caller_identity() and resolve Account at
runtime. Verify the caller is DextoDemoRole. Call cloudformation.validate_template
with the exact stack.yaml text as TemplateBody. Create stack brahma-demo-staging
using that same TemplateBody, RoleARN=<DextoDemoCfnExecRoleArn>,
Capabilities=["CAPABILITY_NAMED_IAM"], Tags=[{"Key":"project","Value":"brahma-demo"}],
and parameters GitHubOrg=brahma-dexto-demo, CodeConnectionArn="",
AccountsApiImageTag=bootstrap, DextoRoleArn=<DextoDemoRoleArn>,
AccountsApiUrl="". Preserve the platform default unless
AWS rejects it; if so use the current available Corretto 17 AL2023 solution stack
from elasticbeanstalk.list_available_solution_stacks. Poll describe_stacks and
report describe_stack_events on failure. Do not retry with broader IAM grants.

On first application deploy, use EKS MCP apply_yaml to create namespace demo and
service account accounts-api in that namespace before applying workloads.

Report all stack outputs. Tag the ops-console application project=brahma-demo
with elasticbeanstalk.update_tags_for_resource (resolve its ARN at runtime).
This provisions infrastructure; it does not deploy the three applications. Before
application deployment, seed accounts/accounts.json in the output data bucket:
embed the full accounts-api/data/accounts/accounts.json JSON (about 52 KB) inline
in aws___run_script, call boto3 s3.put_object, and verify with head_object,
following accounts-api/DEPLOY.md.
Build the accounts-api and risk-engine images with their CodeBuild projects at explicit
commit SHAs. Their repo buildspec.yml files only build/push images; they must not
deploy anything. For accounts-api, use EKS MCP to apply its repo's k8s manifests,
substituting the SHA image and runtime data bucket. Wait for readiness and the
Service LoadBalancer hostname, then update stack parameter AccountsApiUrl to
http://<hostname> through CloudFormation UpdateStack of brahma-demo-staging,
retaining all other parameters with UsePreviousValue=true and the stack tags.
Wait for UPDATE_COMPLETE; CloudFormation sets ACCOUNTS_API_URL.
Register risk-engine from its repo's batch/job-definition.json, substituting the
image, account and data bucket; ensure networkConfiguration.assignPublicIp is
ENABLED and add project=brahma-demo to the definition and submitted job, with
propagateTags=true. For ops-console, start CodeBuild ops-console-jar at its
published full SHA via aws___run_script, wait for SUCCEEDED, and verify the resolved
source SHA. Use its published ops-console/<sha>.jar S3 key with boto3 via MCP to
create_application_version and update_environment with VersionLabel only.
Wait for Ready/Green and report the application URLs.
```

For an existing stack, use `UpdateStack` with the execution role and retain all unchanged parameters with `UsePreviousValue=true`; do not overwrite `AccountsApiUrl` or the selected platform. Pass stack-level `project=brahma-demo` tags on creation and retain them on updates. A `bootstrap` image tag is only an initial image reference output; the infrastructure does not create a Kubernetes Deployment or require that image to exist. `AccountsApiImageTag` affects that output, not running pods.

Dexto seeds `accounts-api/data/accounts/accounts.json` at `accounts/accounts.json` in the output data bucket using `aws___run_script` with the complete JSON embedded inline in boto3 `s3.put_object`, then verifies its size and content type with `head_object`, as shown in accounts-api's DEPLOY.md. The broker's dedicated PutObject grant covers `accounts/*` in the data bucket under the normal MCP routing deny; the Batch job role writes `scores/latest.json`. No seed data custom resource is hidden in the templates.

## EKS access and initial namespace

Default Kubernetes version **1.36** is currently supported, according to the [EKS platform release table](https://docs.aws.amazon.com/eks/latest/userguide/platform-versions.html) checked on 2026-09-30. The public endpoint makes EKS MCP reachable; the private endpoint also lets nodes communicate locally. Two AL2023 managed nodes run in distinct public AZ subnets. Subnets auto-assign public IPs and have an Internet Gateway; there is **no NAT**. Pod Identity uses `demo/accounts-api`, and the node role supports `eks-auth:AssumeRoleForPodIdentity` through AmazonEKSWorkerNodePolicy.

CloudFormation creates the Pod Identity association but does not create the Kubernetes namespace or service account. `DextoRoleArn` permanently receives `AmazonEKSClusterAdminPolicy` at cluster scope because this is a dedicated demo cluster in a dedicated account; a customer POC would scope access to namespaces. On first deploy, the agent uses EKS MCP `apply_yaml` to create namespace `demo` and service account `accounts-api` in `demo` before applying the application workloads. Use only `apply_yaml`, `read_k8s_resource`, `list_k8s_resources`, `get_pod_logs`, and `get_k8s_events`. Image changes re-apply the rendered deployment with the new image through `apply_yaml`. Access is eventually consistent; retry briefly after CFN completion. [AWS policy tables](https://docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html).

The namespace and service account live inside the EKS cluster and disappear with it. The API's existing `Service type: LoadBalancer` uses EKS's standard service integration; do not add NLB-controller-specific annotations without provisioning that controller and its IAM permissions. Tag the Service's AWS load balancer with `service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags: project=brahma-demo` when applying the manifest.

## Build, Batch, Beanstalk and tagging details

- CodeBuild uses `aws/codebuild/amazonlinux-x86_64-standard:5.0`, privileged Docker builds, repo `buildspec.yml`, and `ECR_URI`/`AWS_DEFAULT_REGION`. StartBuild must set `sourceVersion` to the commit SHA. Each build role can push only to its own ECR repo; authorization-token retrieval requires `Resource: '*'`. Build logs and Batch logs have seven-day retention. ECR expires images beyond the newest 20 and empties repositories on deletion.
- The `ops-console-jar` project uses the same standard Linux image with `java: corretto17` selected by its repo buildspec, without privileged Docker mode. Its `ARTIFACTS_BUCKET` is the stack artifacts bucket; its role can only publish under `ops-console/*` and write its dedicated seven-day build logs (plus use the optional source connection). It builds the executable JAR and prints the SHA-derived S3 key; deployment remains a separate MCP step.
- Empty `CodeConnectionArn` omits `Source.Auth` and requests anonymous public GitHub access. No account-default credential is created here; an existing default GitHub credential may affect source behavior. Anonymous builds have not been live-tested, and AWS's [source documentation](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-codebuild-project-source.html) describes account authorization without clearly guaranteeing the public anonymous path. If DOWNLOAD_SOURCE reports an authentication error, configure an AVAILABLE connection and update this parameter; do not place tokens in templates. [Per-project connection configuration](https://docs.aws.amazon.com/codebuild/latest/userguide/multiple-access-tokens.html).
- Batch max compute capacity is 4 vCPU, with outbound-only networking. **`assignPublicIp: ENABLED` is a job-definition property**, not a compute-environment property. It is already present in `risk-engine/batch/job-definition.json`; the agent must preserve it. Otherwise Fargate cannot reach ECR/logs/S3 without NAT/endpoints. There is intentionally no CFN job definition. Tag definitions and jobs `project=brahma-demo` and propagate job tags to tasks. Bootstrap grants `batch:TagResource` on the risk-engine definition (including revisions) and job ARNs so tagged registration and submission can succeed.
- Beanstalk starts with its platform's sample app; no JAR exists at stack creation. It uses one `t3.small`, the public subnet, HTTP on port 80 through nginx, and `SERVER_PORT=5000`. The agent replaces the sample through an application version after CodeBuild publishes the JAR and updates `AccountsApiUrl` once the API LB is available. The parameter is passed into `ACCOUNTS_API_URL`.
- Default solution stack **64bit Amazon Linux 2023 v4.12.9 running Corretto 17** comes from AWS's [supported platforms table](https://docs.aws.amazon.com/elasticbeanstalk/latest/platforms/platforms-supported.html), checked on 2026-09-30. It is mutable over time and has not been verified against a live us-east-1 API. The agent can use `list_available_solution_stacks` through MCP and override `EbSolutionStackName` if necessary.
- Every template resource exposing tags has `project=brahma-demo`; the node launch template also tags EC2 instances and EBS volumes. Stack tags are required as well. CFN does **not** expose a Tags property for routes, gateway attachments, route associations, IAM instance profiles or EB applications; use supported stack-tag propagation rather than invalid YAML fields. The agent should tag the EB application via `elasticbeanstalk.update_tags_for_resource` after creation (its application ARN is resolved at runtime), because that API supports tags although CFN's Application schema does not. Generated/service-linked resources may not inherit tags; the account-wide budget includes their costs. [CFN tagging behavior](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-properties-resource-tags.html).

## Approximate cost

Budget about **$50/week** with light demo activity (168 hours in us-east-1, on-demand Linux, no credits or taxes). The always-on core is roughly $43/week; disks, small builds/jobs and storage bring it toward $50. This is an estimate, not a spending cap.

| Resource | Assumed rate/quantity | Approx. weekly USD |
| --- | --- | ---: |
| EKS control plane, standard support | $0.10/hour | 16.80 |
| EKS nodes | 2 × t3.medium, ~$0.0416/hour each | 13.98 |
| Single-instance Beanstalk EC2 | 1 × t3.small, ~$0.0208/hour | 3.49 |
| API Classic Load Balancer | ~$0.025/hour + light data | 4.20+ |
| Public IPv4 | ~5 addresses × $0.005/hour (3 EC2 + 2 LB) | 4.20 |
| EBS volumes | 2 × 20 GiB nodes + EB root disk | ~1–2 |
| ECR/S3/logs, short builds and Fargate jobs | light usage; tasks add transient IPv4 cost | ~3–6 |
| NAT gateway | none | 0 |
| **Total** | depends on LB type/traffic and build frequency | **~48–51** |

Check current [EKS prices](https://aws.amazon.com/eks/pricing/), [EC2 pricing](https://aws.amazon.com/ec2/pricing/on-demand/), [T3 estimates](https://docs.aws.amazon.com/prescriptive-guidance/latest/optimize-costs-microsoft-workloads/right-size-selection.html), [ELB pricing](https://aws.amazon.com/elasticloadbalancing/pricing/) and [public IPv4 pricing](https://aws.amazon.com/vpc/pricing/). T3 surplus CPU credits, data transfer, extended EKS support, additional public IPs and heavy build/job usage can raise the bill. A $150 monthly budget can be exceeded by running this continuously: $50/week is roughly $215/month. Tear down after demos.

## Teardown

1. Stop builds and terminate running Batch jobs; wait for completion. Read Service `demo/accounts-api` with EKS MCP `read_k8s_resource` and retain its LoadBalancer hostname. Through `apply_yaml`, re-apply `accounts-api/k8s/service.yaml` with `spec.type: ClusterIP`, preserving its name, namespace, selector, ports and annotations. Verify `ClusterIP` with `read_k8s_resource`. This stops Kubernetes from recreating the load balancer; allow the service controller to clean it up. Use only the five documented EKS tools.
2. If the Classic Load Balancer remains, run the following through `aws___run_script`. Bootstrap grants `elasticloadbalancing:DeleteLoadBalancer` only on this account/region's load balancers tagged `project=brahma-demo`; the script also requires the Service tag and the recorded hostname. [Classic ELB tag conditions](https://docs.aws.amazon.com/service-authorization/latest/reference/list_elb.html). Do not proceed to stack deletion until the load balancer is gone and a human has verified its ENIs have disappeared in **EC2 → Network Interfaces**. Inspect residual load balancer security groups too; an admin removes any that still block the VPC after their ENIs disappear.

   ```python
   import boto3

   elb = boto3.Session(region_name="us-east-1").client("elb")
   hostname = "<hostname-recorded-before-ClusterIP-change>"
   matches = [
       lb for page in elb.get_paginator("describe_load_balancers").paginate()
       for lb in page["LoadBalancerDescriptions"] if lb["DNSName"] == hostname
   ]
   if len(matches) > 1:
       raise RuntimeError("Ambiguous API load balancer; stop teardown")
   if matches:
       name = matches[0]["LoadBalancerName"]
       tags = {t["Key"]: t["Value"] for t in elb.describe_tags(
           LoadBalancerNames=[name]
       )["TagDescriptions"][0]["Tags"]}
       if (tags.get("project") != "brahma-demo" or
               tags.get("kubernetes.io/service-name") != "demo/accounts-api"):
           raise RuntimeError("Unexpected load balancer tags; stop teardown")
       elb.delete_load_balancer(LoadBalancerName=name)
       print({"deletion_requested": name})
   else:
       print("API load balancer is already absent")
   ```

   Poll `describe_load_balancers` through subsequent `run_script` calls until the recorded hostname is absent, then wait for its ENIs to disappear. If deletion is denied or the tags differ, a human uses **EC2 → Load Balancers** to verify `project=brahma-demo` and `kubernetes.io/service-name=demo/accounts-api`, deletes only that load balancer, and waits for its ENIs to disappear. Keep the Service as `ClusterIP` until the cluster is deleted.
3. A human admin empties **both** `brahma-demo-artifacts-<account>` and `brahma-demo-data-<account>` in S3, including multipart uploads and versions/delete markers if versioning was later enabled. Repeat if an app/job writes during cleanup. The agent is not granted dedicated data deletion permission. S3 buckets cannot be deleted while nonempty. EB may create its own regional S3 bucket outside this stack; inspect it separately and preserve it if shared.
4. Ask Dexto: `Delete CloudFormation stack brahma-demo-staging in us-east-1 through aws___run_script using RoleARN=<DextoDemoCfnExecRoleArn>. Confirm the Service is ClusterIP, the API LoadBalancer and its ENIs are gone, and the human has emptied both buckets first. Poll until deletion completes and report any DELETE_FAILED events.` Alternatively a human uses the console (the stack retains its execution role).
5. The agent-registered `risk-engine` job-definition revisions are outside CFN: a human admin deregisters them through the Batch console. EB versions created outside CFN should be removed during application cleanup if they prevent deletion. Check for orphaned LB/ENI/security groups, residual logs, EB storage, and service-linked roles; these may survive outside stack ownership.
6. Only after staging deletion completes, the human deletes **dexto-demo-bootstrap** in the CloudFormation console. This removes both roles and the budget. Disconnect the AWS integration in Dexto. Remove the separately hosted bootstrap template if no longer needed.

## Local checks

```sh
uv tool install cfn-lint
# Put uv's tool bin directory on PATH if it is not already there.
./scripts/validate.sh
```

Validation runs cfn-lint for **both** templates in us-east-1 and rejects either file above **51,200 bytes**, so the agent can use TemplateBody without a preexisting artifacts bucket. cfn-lint is schema/static validation, not a live deployment or IAM authorization test. Bootstrap's broker role has one local `W3037` suppression because the required legacy `aws-mcp:*` namespace is absent from cfn-lint's current IAM action catalog; no error rules are disabled. There are no AWS calls in the validation script.
