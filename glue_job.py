import sys
import os
import io
import boto3
import pandas as pd
from awsglue.utils import getResolvedOptions

DATABASE_NAME = "adej_pipeline_db"
TABLE_NAME = "input_input"
OUTPUT_BUCKET = "adej-pipeline-output"
OUTPUT_PREFIX = "output/"

glue = boto3.client("glue")
s3 = boto3.client("s3")

# --- Step 1: figure out which file to process ---
# When this job runs as part of a Glue Workflow, AWS automatically injects
# --WORKFLOW_NAME and --WORKFLOW_RUN_ID as job arguments. We use those to look
# up the run properties Lambda set (source_bucket / source_key) so we process
# only the file that was just uploaded, not everything in input/.
source_bucket = None
source_key = None

try:
    args = getResolvedOptions(sys.argv, ["WORKFLOW_NAME", "WORKFLOW_RUN_ID"])
    workflow_name = args["WORKFLOW_NAME"]
    run_id = args["WORKFLOW_RUN_ID"]
    run_props = glue.get_workflow_run_properties(
        Name=workflow_name, RunId=run_id
    )["RunProperties"]
    source_bucket = run_props.get("source_bucket")
    source_key = run_props.get("source_key")
    if source_key:
        print(f"Workflow run properties point to: s3://{source_bucket}/{source_key}")
except Exception as e:
    print(f"No workflow run properties available ({e}) -- falling back to catalog scan")

# --- Step 2: read the file(s) ---
dfs = []

if source_bucket and source_key:
    # Process only the specific uploaded file
    print(f"Reading single file: s3://{source_bucket}/{source_key}")
    resp = s3.get_object(Bucket=source_bucket, Key=source_key)
    body = resp["Body"].read()
    df = pd.read_csv(io.BytesIO(body), encoding="cp1252")
    dfs.append(df)
    base_filename = os.path.splitext(os.path.basename(source_key))[0]
else:
    # Fallback: no run properties (e.g. manual test run) -- ask the catalog
    # where the input table's data lives, and process everything there.
    table = glue.get_table(DatabaseName=DATABASE_NAME, Name=TABLE_NAME)
    location = table["Table"]["StorageDescriptor"]["Location"]
    print(f"Catalog says data lives at: {location}")
    assert location.startswith("s3://")
    bucket_key = location[len("s3://"):]
    input_bucket, input_prefix = bucket_key.split("/", 1)

    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=input_bucket, Prefix=input_prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith(".csv"):
                print(f"Reading s3://{input_bucket}/{key}")
                resp = s3.get_object(Bucket=input_bucket, Key=key)
                body = resp["Body"].read()
                df = pd.read_csv(io.BytesIO(body), encoding="cp1252")
                dfs.append(df)
    base_filename = "products"

if not dfs:
    raise Exception("No CSV data found to process")

df = pd.concat(dfs, ignore_index=True)
print(f"Loaded {len(df)} rows total")

# --- Step 3: transform ---
df = df[df["discontinued"] == 0].copy()          # drop discontinued items
df["productName"] = df["productName"].str.upper()  # uppercase productName
df["priceWithTax"] = (df["unitPrice"] * 1.1).round(2)  # add priceWithTax

print(f"{len(df)} rows remain after dropping discontinued items")

# --- Step 4: write result with a name tied to the source file ---
output_key = f"{OUTPUT_PREFIX}{base_filename}_transformed.csv"
csv_buffer = io.StringIO()
df.to_csv(csv_buffer, index=False, encoding="utf-8")
s3.put_object(
    Bucket=OUTPUT_BUCKET,
    Key=output_key,
    Body=csv_buffer.getvalue().encode("utf-8"),
)

print(f"Wrote {len(df)} rows to s3://{OUTPUT_BUCKET}/{output_key}")
