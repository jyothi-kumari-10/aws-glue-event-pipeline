#!/usr/bin/env bash
# Tears down every resource created by deploy.sh. Safe to re-run --
# ignores errors for resources that don't exist or are already gone.
set -uo pipefail

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

echo "== Removing S3 event notification =="
aws s3api put-bucket-notification-configuration \
  --bucket "$INPUT_BUCKET" \
  --notification-configuration '{}' 2>/dev/null || true

echo "== Deleting Lambda =="
aws lambda delete-function --function-name "$LAMBDA_NAME" 2>/dev/null || true

echo "== Deleting Glue Workflow and triggers =="
for TRIGGER in start-trigger after-input-crawler after-job; do
  aws glue delete-trigger --name "$TRIGGER" 2>/dev/null || true
done
aws glue delete-workflow --name "$WORKFLOW_NAME" 2>/dev/null || true

echo "== Deleting Glue Job =="
aws glue delete-job --job-name "$JOB_NAME" 2>/dev/null || true

echo "== Deleting Crawlers =="
aws glue delete-crawler --name "$INPUT_CRAWLER" 2>/dev/null || true
aws glue delete-crawler --name "$OUTPUT_CRAWLER" 2>/dev/null || true

echo "== Deleting Glue Database (and its tables) =="
aws glue delete-database --name "$DB_NAME" 2>/dev/null || true

echo "== Emptying and deleting S3 buckets =="
for BUCKET in "$INPUT_BUCKET" "$OUTPUT_BUCKET" "$SCRIPTS_BUCKET"; do
  aws s3 rm "s3://$BUCKET" --recursive 2>/dev/null || true
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null || true
done

echo "== Detaching policies and deleting IAM roles =="
for ROLE in "$LAMBDA_ROLE_NAME" "$GLUE_ROLE_NAME"; do
  ATTACHED=$(aws iam list-attached-role-policies --role-name "$ROLE" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)
  for POLICY_ARN in $ATTACHED; do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
done

echo "== Destroy complete =="
