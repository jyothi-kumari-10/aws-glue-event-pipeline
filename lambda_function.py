import boto3

WORKFLOW_NAME = "pipeline-workflow"

glue = boto3.client("glue")


def lambda_handler(event, context):
    records = event.get("Records", [])
    if not records:
        print("No S3 records in event, starting workflow with no run properties")
        response = glue.start_workflow_run(Name=WORKFLOW_NAME)
        print(f"Started workflow '{WORKFLOW_NAME}', run id: {response['RunId']}")
        return {"statusCode": 200, "body": f"Started workflow run {response['RunId']}"}

    # Handle the (usual) case of one uploaded file per event.
    # If multiple files land in the same event batch, we only pass the first --
    # good enough for this pipeline's scale, and the job falls back to scanning
    # the whole input/ prefix if this property is ever missing.
    record = records[0]
    bucket = record["s3"]["bucket"]["name"]
    key = record["s3"]["object"]["key"]
    print(f"Triggered by upload: s3://{bucket}/{key}")

    response = glue.start_workflow_run(
        Name=WORKFLOW_NAME,
        RunProperties={"source_bucket": bucket, "source_key": key},
    )
    run_id = response["RunId"]
    print(f"Started workflow '{WORKFLOW_NAME}', run id: {run_id}, source_key: {key}")

    return {
        "statusCode": 200,
        "body": f"Started workflow run {run_id} for s3://{bucket}/{key}"
    }
