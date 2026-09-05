#!/usr/bin/env bash
# Deploys the entire event-driven Glue pipeline using AWS CLI.
# Safe to re-run: each step checks if the resource already exists before creating it.
set -euo pipefail

# ---------- Config: change these to match your setup ----------
REGION="ap-southeast-2"
INPUT_BUCKET="adej-pipeline-input"
OUTPUT_BUCKET="adej-pipeline-output"
SCRIPTS_BUCKET="adej-pipeline-scripts"
DB_NAME="adej_pipeline_db"
INPUT_CRAWLER="input-crawler"
OUTPUT_CRAWLER="output-crawler"
JOB_NAME="product-transform-job"
WORKFLOW_NAME="pipeline-workflow"
LAMBDA_NAME="trigger-glue-workflow"
LAMBDA_ROLE_NAME="lambda-role"
GLUE_ROLE_NAME="glue-role"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Deploying to account $ACCOUNT_ID in $REGION"

# ---------- 1. IAM Roles ----------
echo "== IAM roles =="

if ! aws iam get-role --role-name "$LAMBDA_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --assume-role-policy-document "file://$SCRIPT_DIR/iam/lambda-trust-policy.json"
  aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess
  aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess
  aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
  echo "Created $LAMBDA_ROLE_NAME"
else
  echo "$LAMBDA_ROLE_NAME already exists, skipping"
fi

if ! aws iam get-role --role-name "$GLUE_ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$GLUE_ROLE_NAME" \
    --assume-role-policy-document "file://$SCRIPT_DIR/iam/glue-trust-policy.json"
  aws iam attach-role-policy --role-name "$GLUE_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
  aws iam attach-role-policy --role-name "$GLUE_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
  aws iam attach-role-policy --role-name "$GLUE_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
  echo "Created $GLUE_ROLE_NAME"
else
  echo "$GLUE_ROLE_NAME already exists, skipping"
fi

# IAM roles take a few seconds to propagate before other services can assume them
sleep 10

LAMBDA_ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" --query 'Role.Arn' --output text)
GLUE_ROLE_ARN=$(aws iam get-role --role-name "$GLUE_ROLE_NAME" --query 'Role.Arn' --output text)

# ---------- 2. S3 Buckets ----------
echo "== S3 buckets =="

for BUCKET in "$INPUT_BUCKET" "$OUTPUT_BUCKET" "$SCRIPTS_BUCKET"; do
  if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
    aws s3api put-public-access-block \
      --bucket "$BUCKET" \
      --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
    echo "Created bucket $BUCKET"
  else
    echo "Bucket $BUCKET already exists, skipping"
  fi
done

# Upload the Glue job script
aws s3 cp "$SCRIPT_DIR/../glue_job.py" "s3://$SCRIPTS_BUCKET/scripts/glue_job.py"
echo "Uploaded glue_job.py to scripts bucket"

# ---------- 3. Glue Database ----------
echo "== Glue database =="

if ! aws glue get-database --name "$DB_NAME" >/dev/null 2>&1; then
  aws glue create-database --database-input "{\"Name\":\"$DB_NAME\"}"
  echo "Created database $DB_NAME"
else
  echo "Database $DB_NAME already exists, skipping"
fi

# ---------- 4. Crawlers ----------
echo "== Crawlers =="

if ! aws glue get-crawler --name "$INPUT_CRAWLER" >/dev/null 2>&1; then
  aws glue create-crawler \
    --name "$INPUT_CRAWLER" \
    --role "$GLUE_ROLE_ARN" \
    --database-name "$DB_NAME" \
    --targets "{\"S3Targets\":[{\"Path\":\"s3://$INPUT_BUCKET/input/\"}]}"
  echo "Created crawler $INPUT_CRAWLER"
else
  echo "Crawler $INPUT_CRAWLER already exists, skipping"
fi

if ! aws glue get-crawler --name "$OUTPUT_CRAWLER" >/dev/null 2>&1; then
  aws glue create-crawler \
    --name "$OUTPUT_CRAWLER" \
    --role "$GLUE_ROLE_ARN" \
    --database-name "$DB_NAME" \
    --targets "{\"S3Targets\":[{\"Path\":\"s3://$OUTPUT_BUCKET/output/\"}]}"
  echo "Created crawler $OUTPUT_CRAWLER"
else
  echo "Crawler $OUTPUT_CRAWLER already exists, skipping"
fi

# ---------- 5. Glue Job ----------
echo "== Glue job =="

if ! aws glue get-job --job-name "$JOB_NAME" >/dev/null 2>&1; then
  aws glue create-job \
    --name "$JOB_NAME" \
    --role "$GLUE_ROLE_ARN" \
    --command "{\"Name\":\"pythonshell\",\"ScriptLocation\":\"s3://$SCRIPTS_BUCKET/scripts/glue_job.py\",\"PythonVersion\":\"3.9\"}" \
    --default-arguments '{"--library-set":"analytics"}' \
    --max-capacity 0.0625 \
    --timeout 10
  echo "Created job $JOB_NAME"
else
  echo "Job $JOB_NAME already exists, skipping"
fi

# ---------- 6. Glue Workflow + Triggers ----------
echo "== Glue workflow =="

if ! aws glue get-workflow --name "$WORKFLOW_NAME" >/dev/null 2>&1; then
  aws glue create-workflow --name "$WORKFLOW_NAME"
  echo "Created workflow $WORKFLOW_NAME"
else
  echo "Workflow $WORKFLOW_NAME already exists, skipping"
fi

if ! aws glue get-trigger --name "start-trigger" >/dev/null 2>&1; then
  aws glue create-trigger \
    --name "start-trigger" \
    --workflow-name "$WORKFLOW_NAME" \
    --type ON_DEMAND \
    --actions "[{\"CrawlerName\":\"$INPUT_CRAWLER\"}]"
  echo "Created start-trigger"
else
  echo "start-trigger already exists, skipping"
fi

if ! aws glue get-trigger --name "after-input-crawler" >/dev/null 2>&1; then
  aws glue create-trigger \
    --name "after-input-crawler" \
    --workflow-name "$WORKFLOW_NAME" \
    --type CONDITIONAL \
    --predicate "{\"Conditions\":[{\"LogicalOperator\":\"EQUALS\",\"CrawlerName\":\"$INPUT_CRAWLER\",\"CrawlState\":\"SUCCEEDED\"}]}" \
    --actions "[{\"JobName\":\"$JOB_NAME\"}]" \
    --start-on-creation
  echo "Created after-input-crawler"
else
  echo "after-input-crawler already exists, skipping"
fi

if ! aws glue get-trigger --name "after-job" >/dev/null 2>&1; then
  aws glue create-trigger \
    --name "after-job" \
    --workflow-name "$WORKFLOW_NAME" \
    --type CONDITIONAL \
    --predicate "{\"Conditions\":[{\"LogicalOperator\":\"EQUALS\",\"JobName\":\"$JOB_NAME\",\"State\":\"SUCCEEDED\"}]}" \
    --actions "[{\"CrawlerName\":\"$OUTPUT_CRAWLER\"}]" \
    --start-on-creation
  echo "Created after-job"
else
  echo "after-job already exists, skipping"
fi

# ---------- 7. Lambda ----------
echo "== Lambda function =="

cd "$SCRIPT_DIR/.."
zip -q -r /tmp/lambda_function.zip lambda_function.py

if ! aws lambda get-function --function-name "$LAMBDA_NAME" >/dev/null 2>&1; then
  aws lambda create-function \
    --function-name "$LAMBDA_NAME" \
    --runtime python3.12 \
    --role "$LAMBDA_ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file fileb:///tmp/lambda_function.zip \
    --timeout 30
  echo "Created Lambda function $LAMBDA_NAME"
else
  aws lambda update-function-code \
    --function-name "$LAMBDA_NAME" \
    --zip-file fileb:///tmp/lambda_function.zip >/dev/null
  echo "Lambda function $LAMBDA_NAME already exists, updated code"
fi

LAMBDA_ARN=$(aws lambda get-function --function-name "$LAMBDA_NAME" --query 'Configuration.FunctionArn' --output text)

# Allow S3 to invoke this Lambda (idempotent: ignore error if statement already exists)
aws lambda add-permission \
  --function-name "$LAMBDA_NAME" \
  --statement-id "AllowS3Invoke" \
  --action "lambda:InvokeFunction" \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::$INPUT_BUCKET" \
  --source-account "$ACCOUNT_ID" 2>/dev/null || echo "S3 invoke permission already granted"

# Wire the S3 event notification: prefix=input/, suffix=.csv -> Lambda
cat > /tmp/notification.json <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "$LAMBDA_ARN",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "prefix", "Value": "input/"},
            {"Name": "suffix", "Value": ".csv"}
          ]
        }
      }
    }
  ]
}
EOF

aws s3api put-bucket-notification-configuration \
  --bucket "$INPUT_BUCKET" \
  --notification-configuration file:///tmp/notification.json
echo "S3 event notification wired to Lambda"

echo "== Deploy complete =="
