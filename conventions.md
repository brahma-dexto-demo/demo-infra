# Brahma demo conventions

AWS (demo account, region us-east-1; account id always resolved at deploy time with boto3 `sts.get_caller_identity()["Account"]`, never hard-coded):
- EKS cluster `brahma-demo`, namespace `demo`, Deployment + Service `accounts-api` (Service type LoadBalancer, port 80 -> 8000).
- ECR repositories `brahma-demo/accounts-api`, `brahma-demo/risk-engine`.
- AWS Batch (Fargate): job queue `brahma-demo-queue`, job definition name `risk-engine`, execution role `brahma-demo-batch-exec`, job role `brahma-demo-batch-job`.
- Elastic Beanstalk: application `ops-console`, environment `ops-console-staging`, platform "Corretto 17 running on 64bit Amazon Linux 2023", single instance, app listens on port 5000 (`SERVER_PORT=5000`).
- S3: `brahma-demo-artifacts-<account>` (JARs under `ops-console/<version>.jar`), `brahma-demo-data-<account>` (`accounts/accounts.json` input, `scores/latest.json` output from risk-engine).
- EKS Pod Identity gives the accounts-api pod read on `brahma-demo-data-<account>`.
- AWS CodeBuild projects `accounts-api-image` and `risk-engine-image`: source = the public GitHub repo, `sourceVersion` = commit SHA, privileged Docker build, run the repo's `buildspec.yml` which ONLY builds and pushes `<ecr-repo>:<sha>` to ECR (no deploy steps).
- Dexto role for the agent: `DextoDemoRole`. The agent reaches AWS ONLY through the managed AWS MCP Server (`aws___run_script` = sandboxed Python with boto3, `aws___get_presigned_url`, `aws___get_tasks`) and the managed Amazon EKS MCP Server (`apply_yaml`, `manage_k8s_resource`/`read_k8s_resource`, `get_pod_logs`, `get_k8s_events`). The agent's computer has NO AWS credentials, no AWS CLI, no kubectl.
- Deploy flow per target:
  - accounts-api: start CodeBuild `accounts-api-image` at SHA (boto3 via run_script) -> wait -> EKS MCP apply `k8s/*.yaml` with the image `<account>.dkr.ecr.us-east-1.amazonaws.com/brahma-demo/accounts-api:<sha>` -> read rollout status.
  - risk-engine: CodeBuild `risk-engine-image` at SHA -> boto3 `batch.register_job_definition` from `batch/job-definition.json` -> `submit_job` -> poll `describe_jobs` -> read CloudWatch logs -> read `scores/latest.json`.
  - ops-console: `mvn -B package` in the computer -> `aws___get_presigned_url` (PUT, artifacts bucket key `ops-console/<sha>.jar`) -> `curl --upload-file` -> boto3 `elasticbeanstalk.create_application_version` + `update_environment` -> poll `describe_environments` until Ready/Green -> CNAME URL.

GitHub: org `brahma-dexto-demo`, repos `ops-console`, `accounts-api`, `risk-engine`, `demo-infra`. CODEOWNER `@rahulkarajgikar` (PRs are opened by the Dexto GitHub App bot, dexto-cloud[bot]).

Env/config:
- ops-console reads `ACCOUNTS_API_URL` (base URL of accounts-api).
- accounts-api reads `DATA_BUCKET` (S3 bucket) or `LOCAL_DATA_DIR` (local JSON files for dev/tests; default `./data`).
- risk-engine reads `DATA_BUCKET` or `LOCAL_DATA_DIR`, same layout.

Computer toolchain (installed by the `dev-toolchain` platform skill): docker.io + dockerd (local integration runs only), openjdk-17-jdk-headless, maven. Python 3.11+ with uv and Node 22 already exist.
