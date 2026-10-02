# Paste this whole file, unchanged, as the code of one managed AWS MCP `aws___run_script`
# call. Idempotent: restores the baseline
# scores and console version only when they differ, and prints one JSON state report.
# `call_boto3` is provided by the tool; adapt only the call syntax if its documented
# signature differs. Operation names are the AWS API names.
import json

REGION = "us-east-1"
# Copied from baseline.json; scripts/validate.sh fails if the two drift apart.
BASELINE = {
    "stack": "brahma-demo-staging",
    "accounts-api": {
        "image_tag": "f07918f05298373220da69ff027e38c973a6937f"
    },
    "scores": {
        "live_key": "scores/latest.json",
        "snapshot_key": "baselines/scores/latest.json"
    },
    "ops-console": {
        "application": "ops-console",
        "environment": "ops-console-staging",
        "version_label": "b05ffa20b97bf66eb73845a4eb8fe4ad8a3ecfbf"
    }
}


async def aws(service, operation, **params):
    return await call_boto3(
        service_name=service, operation_name=operation, region_name=REGION, params=params
    )


async def head(bucket, key):
    try:
        found = await aws("s3", "HeadObject", Bucket=bucket, Key=key)
    except Exception as error:  # only a missing object is an expected miss
        if "404" in str(error) or "NotFound" in str(error) or "NoSuchKey" in str(error):
            return None
        raise
    return {"etag": found["ETag"], "size": found["ContentLength"]}


stack = (await aws("cloudformation", "DescribeStacks", StackName=BASELINE["stack"]))["Stacks"][0]
outputs = {item["OutputKey"]: item["OutputValue"] for item in stack["Outputs"]}
parameters = {item["ParameterKey"]: item["ParameterValue"] for item in stack["Parameters"]}
report = {"cluster": outputs["ClusterName"], "api_url": parameters["AccountsApiUrl"]}

api_repository = outputs["AccountsApiEcrUri"].split("/", 1)[1]
api_image = await aws(
    "ecr",
    "DescribeImages",
    repositoryName=api_repository,
    imageIds=[{"imageTag": BASELINE["accounts-api"]["image_tag"]}],
)
report["api_image"] = f'{outputs["AccountsApiEcrUri"]}:{BASELINE["accounts-api"]["image_tag"]}'
report["api_digest"] = api_image["imageDetails"][0]["imageDigest"]
report["data_bucket"] = outputs["DataBucketName"]

bucket = outputs["DataBucketName"]
live_key = BASELINE["scores"]["live_key"]
snapshot_key = BASELINE["scores"]["snapshot_key"]
snapshot = await head(bucket, snapshot_key)
live = await head(bucket, live_key)
if snapshot is None:
    report["scores"] = "snapshot_missing"
elif live == snapshot:
    report["scores"] = "already_baseline"
else:
    await aws(
        "s3",
        "CopyObject",
        Bucket=bucket,
        Key=live_key,
        CopySource={"Bucket": bucket, "Key": snapshot_key},
    )
    restored = await head(bucket, live_key)
    report["scores"] = "restored" if restored == snapshot else "restore_mismatch"

console = BASELINE["ops-console"]
environment = (
    await aws(
        "elasticbeanstalk",
        "DescribeEnvironments",
        ApplicationName=console["application"],
        EnvironmentNames=[console["environment"]],
    )
)["Environments"][0]
report["console_url"] = f'http://{environment["CNAME"]}'
if environment["VersionLabel"] == console["version_label"]:
    report["console"] = f'already_baseline ({environment["Status"]}/{environment["Health"]})'
elif environment["Status"] != "Ready":
    report["console"] = f'busy ({environment["Status"]}); rerun this script shortly'
else:
    await aws(
        "elasticbeanstalk",
        "UpdateEnvironment",
        EnvironmentName=console["environment"],
        VersionLabel=console["version_label"],
    )
    report["console"] = "update_started"

print(json.dumps(report, indent=2))
