# AWS Activity

An event-driven ETL pipeline built on AWS Glue, orchestrated with Glue Workflows,
triggered automatically via S3 + Lambda, and deployed end-to-end through
GitHub Actions (no Terraform, no manual console clicking required after setup).

```
Upload CSV → S3 (input/) → S3 event notification → Lambda
    → Glue Workflow
        → Crawler #1 (catalogs input/)
        → Python Shell Job (transforms data)
        → Crawler #2 (catalogs output/)
    → S3 (output/<filename>_transformed.csv)
```

All screenshots referenced below are in `screenshots/`, numbered in the order
the pipeline was actually built.

---

## AWS Resources Used

- **S3** — three separate buckets: input, output, and scripts
- **S3 Event Notification** — invokes Lambda when a `.csv` is created under `input/`
- **Lambda** — receives the S3 event and starts the Glue Workflow
- **AWS Glue Data Catalog** — one database holding two tables (input + output)
- **AWS Glue Crawlers** — two crawlers, populate the catalog tables from S3
- **AWS Glue Job** — Python Shell job that transforms the CSV
- **AWS Glue Workflow** — orchestrates crawler → job → crawler as one chain
- **IAM Roles** — `lambda-role`, `glue-role` (least-privilege-ish, see note below)
- **IAM User** — `github-actions-ci`, the credential GitHub Actions authenticates
  with to create/destroy the resources above (see note below)


## Resource Names

Region: `ap-southeast-2`

| Resource | Name |
|---|---|
| Input bucket | `adej-pipeline-input` |
| Output bucket | `adej-pipeline-output` |
| Scripts bucket | `adej-pipeline-scripts` |
| Glue database | `adej_pipeline_db` |
| Input table (via crawler) | `input_input` |
| Output table (via crawler) | `output_output` |
| Crawler (input) | `input-crawler` |
| Crawler (output) | `output-crawler` |
| Glue job | `product-transform-job` |
| Glue workflow | `pipeline-workflow` |
| Lambda function | `trigger-glue-workflow` |
| Lambda IAM role | `lambda-role` |
| Glue IAM role | `glue-role` |
| CI-only IAM user (manual, one-time) | `github-actions-ci` |

## Build Phases

1. **IAM Roles** — created `lambda-role` and `glue-role` with the permissions each service needs.
2. **S3 Buckets** — created three buckets: input, output, and scripts.
3. **Glue Database** — created an empty Glue Catalog database (`adej_pipeline_db`) as the namespace for tables.
4. **Crawler #1 (input)** — created and ran a crawler against `input/`, generating the `input_input` catalog table.
5. **Glue Job** — wrote and ran a Python Shell job that reads the input table's location from the catalog, transforms the data, and writes the result to the output bucket.
6. **Crawler #2 (output)** — created and ran a second crawler against `output/`, generating the `output_output` catalog table.
7. **Glue Workflow** — chained the crawler → job → crawler sequence into one orchestrated workflow (`pipeline-workflow`), tested manually end-to-end.
8. **Lambda** — created `trigger-glue-workflow`, which starts the Glue Workflow and passes the uploaded file's S3 key through as a workflow run property.
9. **S3 Event Notification** — wired the input bucket to invoke Lambda automatically on any `.csv` upload under `input/`.
10. **End-to-end validation** — confirmed a real CSV upload triggers the full chain automatically, with per-file output naming (no manual clicks).
11. **CI IAM User & Access Keys** — created a dedicated IAM user (`github-actions-ci`), separate from any personal AWS login, with programmatic-only access. Generated an access key pair and added them as GitHub repository secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) so GitHub Actions could authenticate to AWS without exposing any personal credentials.
12. **GitHub Actions CI/CD** — rewrote every step above (1–9) as AWS CLI commands in `deploy.sh`/`destroy.sh`, wrapped in GitHub Actions workflows (`deploy.yml`, `destroy.yml`), using the credentials from step 11.
13. **Idempotency & Destroy/Redeploy test** — re-ran `deploy.sh` against an already-built environment to confirm it only reports "already exists, skipping" rather than erroring or duplicating; then ran `destroy.sh` followed by `deploy.sh` again to prove the entire pipeline can be torn down and rebuilt from nothing.

---

## 1. Manual build (proving the design first)

Before automating anything, every piece was built and tested by hand in the
AWS Console. This is the same order a person would click through, and it's
what the CI script in `scripts/deploy.sh` later recreates as code.

### 1.1 IAM Roles
Two roles were created first, since every other service depends on them:
- **`lambda-role`** — lets Lambda call `glue:StartWorkflowRun` and write logs
- **`glue-role`** — lets Glue crawlers/jobs read and write S3, and use the Data Catalog

![Lambda role created](screenshots/01-iam-lambda-role-created.png)
*lambda-role created, with S3 read, Glue, and CloudWatch Logs permissions attached.*




![Glue role created](screenshots/02-iam-glue-role-created.png)
*glue-role created, with S3 full access, Glue service, and CloudWatch Logs permissions attached.*

### 1.2 S3 Buckets
Three separate buckets (per-file separation, rather than one bucket with
prefixes — this was a deliberate choice; see [Design Decisions](#design-decisions)):
- `adej-pipeline-input/input/` — where CSVs are uploaded
- `adej-pipeline-output/output/` — where transformed results land
- `adej-pipeline-scripts/scripts/` — holds the Glue job's Python script

![S3 buckets created](screenshots/03-s3-buckets-created.png)
*All three buckets (input, output, scripts) visible in the S3 console.*

### 1.3 Glue Database (the Catalog namespace)
An empty Glue Database (`adej_pipeline_db`) was created to hold the catalog
tables that crawlers would later populate.

![Glue database create form](screenshots/04-glue-database-create-form.png)
*Creating the empty adej_pipeline_db Glue database.*

### 1.4 Crawler #1 — catalogs the input data
Points at `s3://adej-pipeline-input/input/`, infers the CSV schema, and
creates a table (`input_input`) in the catalog.

![Crawler input set properties](screenshots/05-crawler-input-set-properties.png)
*Naming the crawler input-crawler in the first setup step.*


![Crawler input add datasource](screenshots/06-crawler-input-add-datasource.png)
*Pointing the crawler at s3://adej-pipeline-input/input/ as its data source.*


![Crawler input created](screenshots/07-crawler-input-created.png)
*input-crawler successfully created, state READY.*


![Crawler input run completed](screenshots/08-crawler-input-run-completed.png)
*First manual run of input-crawler completes in 37 seconds.*


![Glue catalog table input created](screenshots/09-glue-catalog-table-input-created.png)
*The input_input table appears in the Glue Data Catalog after the crawler run.*

### 1.5 Glue Job — the transform
A **Python Shell** job (`product-transform-job`, 0.0625 DPU, 10 min timeout)
that:
1. Looks up the input table's location in the Glue Catalog
2. Reads the CSV directly from S3 (`boto3` + `pandas`)
3. Drops discontinued items (`discontinued == 1`)
4. Uppercases `productName`
5. Adds `priceWithTax = unitPrice * 1.1`
6. Writes the result to the output bucket

**Input** (`products.csv`)
```csv
productID,productName,quantityPerUnit,unitPrice,discontinued,categoryID
1,Chai,10 boxes x 20 bags,18,0,1
5,Chef Anton's Gumbo Mix,36 boxes,21.35,1,2
```

**Output** (`products_transformed.csv`)
```csv
productID,productName,quantityPerUnit,unitPrice,discontinued,categoryID,priceWithTax
1,CHAI,10 boxes x 20 bags,18,0,1,19.8
```
(Row 5 is dropped — `discontinued == 1`.)

![Glue job script upload](screenshots/10-glue-job-script-upload.png)
*Uploading glue_job.py as the script for the new Python Shell job.*
![Glue job details saved](screenshots/11-glue-job-details-saved.png)
*Job details saved for product-transform-job, using glue-role.*
![Glue job run succeeded](screenshots/12-glue-job-run-succeeded.png)
*First manual run of the job succeeds in 14 seconds on 0.0625 DPUs.*
![CloudWatch job logs output](screenshots/13-cloudwatch-job-logs-output.png)
*CloudWatch output logs showing the job's print statements as it ran.*
![S3 output file created](screenshots/14-s3-output-file-created.png)
*products_transformed.csv appears in the output bucket.*
![Output CSV opened in Excel](screenshots/15-output-csv-opened-excel.png)
*Output file opened in Excel: discontinued rows dropped, names uppercased, priceWithTax added.*

### 1.6 Crawler #2 — catalogs the output data
Points at `s3://adej-pipeline-output/output/`, creating a second table
(`output_output`) so the transformed data is also queryable (e.g. via Athena).

![Glue catalog both tables](screenshots/16-glue-catalog-both-tables.png)
*Both input_input and output_output tables now listed in the catalog.*


![Glue catalog output table schema](screenshots/17-glue-catalog-output-table-schema.png)
*Schema of output_output, confirming priceWithTax was inferred as a double (numeric), not a string.*

### 1.7 Glue Workflow — orchestration
Chains the three pieces above into one sequence, so the whole thing runs with
a single trigger instead of three manual clicks:

```
start-trigger → input-crawler → after-input-crawler
    → product-transform-job → after-job → output-crawler
```

![Glue workflow created](screenshots/18-glue-workflow-created.png)
*pipeline-workflow created, with an empty graph before any triggers are added.*


![Glue workflow trigger add crawler](screenshots/19-glue-workflow-trigger-add-crawler.png)
*Attaching input-crawler to the workflow's first trigger.*


![Glue workflow full graph built](screenshots/20-glue-workflow-full-graph-built.png)
*The full workflow graph: start-trigger through output-crawler, all wired together.*


![Glue workflow first full run succeeded](screenshots/21-glue-workflow-first-full-run-succeeded.png)
*First full manual run of the workflow completes, every node succeeded.*

### 1.8 Lambda — the automatic entry point
A small Lambda function (`trigger-glue-workflow`) that calls
`glue.start_workflow_run()`, passing along the exact S3 key that was uploaded
(via workflow **run properties**) so the job processes only that file, not
everything in the bucket.

![Lambda create function](screenshots/22-lambda-create-function.png)
*Creating the trigger-glue-workflow Lambda function.*


![Lambda code pasted](screenshots/23-lambda-code-pasted.png)
*Lambda code pasted in, calling glue.start_workflow_run().*


![Lambda test invocation succeeded](screenshots/24-lambda-test-invocation-succeeded.png)
*Manual Lambda test succeeds, returning the started workflow's run ID.*

### 1.9 S3 Event Notification
A rule on the input bucket: whenever an object matching `prefix=input/`,
`suffix=.csv` is created, invoke the Lambda above. This is what makes the
whole thing actually event-driven rather than manually triggered.

![Lambda S3 trigger config](screenshots/25-lambda-s3-trigger-config.png)
*Configuring the S3 trigger on Lambda: prefix input/, suffix .csv.*


![Lambda S3 trigger added](screenshots/26-lambda-s3-trigger-added.png)
*S3 trigger now attached to the Lambda function.*

### 1.10 End-to-end proof (manual)
Uploading a real CSV produced a uniquely-named output file per input file
(`products_transformed.csv`, `products_1_transformed.csv`, …), confirming the
whole chain — S3 → Lambda → Workflow → Crawler → Job → Crawler — works without
any manual intervention.

![S3 output two distinct files](screenshots/27-s3-output-two-distinct-files.png)
*Two separate, correctly-named output files after fixing per-file output naming.*

---

## 2. Automating it: GitHub Actions CI/CD

Once the manual build was fully verified, every resource above was rewritten
as AWS CLI commands in [`scripts/deploy.sh`](scripts/deploy.sh), wrapped in a
GitHub Actions workflow. No Terraform — plain AWS CLI, chosen since it needed
no new tooling on top of everything else being learned.

### 2.1 Repository structure
```
.
├── .github/workflows/
│   ├── deploy.yml       # recreates every AWS resource, idempotent
│   └── destroy.yml      # tears everything down
├── iam/                 # trust policies for the two IAM roles
├── scripts/
│   ├── deploy.sh
│   └── destroy.sh
├── sample-input/
│   └── products.csv     
├── glue_job.py
└── lambda_function.py
```

![GitHub repo structure](screenshots/28-github-repo-structure.png)
*Repository pushed to GitHub with the final folder structure.*

### 2.2 CI-specific IAM user
A dedicated IAM user (`github-actions-ci`) was created — separate from any
personal AWS login — with access keys stored as GitHub repository secrets
(`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).

![IAM CI user permissions summary](screenshots/29-iam-ci-user-permissions-summary.png)
*Permissions attached to the github-actions-ci IAM user before creation.*


![IAM CI user access key usecase](screenshots/30-iam-ci-user-access-key-usecase.png)
*Selecting "Third-party service" as the access key's use case for CI.*

### 2.3 `deploy.sh` — idempotent, safe to re-run
Every resource creation is guarded by an existence check (`aws ... get-... ||
create-...`), so running `deploy.sh` against an already-built environment just
confirms everything is in place rather than erroring or duplicating anything.
The very last step uploads `sample-input/products.csv` to the input bucket —
since the S3 notification is wired up by this point in the script, this
upload triggers a **real** run of the pipeline as a built-in smoke test.

![GitHub Actions Deploy Pipeline setup](screenshots/31-github-actions-deploy-pipeline-setup.png)
*Deploy Pipeline workflow visible in the Actions tab, not yet run.*


![GitHub Actions deploy succeeded](screenshots/32-github-actions-deploy-succeeded.png)
*Deploy Pipeline run completes successfully end to end.*


![Glue workflow run triggered by CI](screenshots/33-glue-workflow-run-triggered-by-ci.png)
*A new Glue Workflow run appears, triggered by the file CI uploaded.*

### 2.4 `destroy.sh` — proving it's genuinely reproducible
Tears down every resource in reverse order (Lambda → Workflow/triggers → Job
→ Crawlers → Database → S3 buckets → IAM roles). Running **destroy → deploy**
back-to-back is the real test of "infrastructure as code": it proves the
whole pipeline can be rebuilt from nothing, not just that it worked once.

![GitHub Actions destroy succeeded](screenshots/34-github-actions-destroy-succeeded.png)
*Destroy Pipeline run completes, tearing down every AWS resource.*


![Glue workflows empty after destroy](screenshots/35-glue-workflows-empty-after-destroy.png)
*Glue Workflows list is empty, confirming Destroy removed pipeline-workflow.*


![GitHub Actions deploy after destroy succeeded](screenshots/36-github-actions-deploy-after-destroy-succeeded.png)
*Deploy Pipeline re-run after Destroy, rebuilding everything from nothing.*


![Glue workflow fresh run after redeploy](screenshots/37-glue-workflow-fresh-run-after-redeploy.png)
*Fresh workflow run after redeploy, all nodes succeeded again.*


![S3 output after redeploy](screenshots/38-s3-output-after-redeploy.png)
*Output bucket after redeploy, containing the freshly generated file.*


![Final output verified in Excel](screenshots/39-final-output-verified-excel.png)
*Final output re-verified in Excel after the full destroy/redeploy cycle.*

---


## Local / manual testing

To re-run the pipeline manually without touching CI:
1. Upload any CSV with columns `productID, productName, quantityPerUnit,
   unitPrice, discontinued, categoryID` to `s3://adej-pipeline-input/input/`
2. Watch **Glue → Workflows → pipeline-workflow → History** for a new run
3. Check `s3://adej-pipeline-output/output/` for `<filename>_transformed.csv`

To deploy/destroy via CI: go to the repo's **Actions** tab → select **Deploy
Pipeline** or **Destroy Pipeline** → **Run workflow**.

---

## What to Verify

- [ ] CSV appears under `input/` in the input bucket
- [ ] Lambda's CloudWatch logs show the upload event and a Glue workflow run ID
- [ ] Glue Workflow History shows all six nodes (start-trigger →
      input-crawler → after-input-crawler → product-transform-job →
      after-job → output-crawler) as **Succeeded**
- [ ] A new table appears/refreshes in the Glue Catalog for both `input/`
      and `output/`
- [ ] Transformed CSV appears under `output/<filename>_transformed.csv`
- [ ] Re-running `deploy.sh` (via Actions) reports `already exists,
      skipping` for every resource — proves idempotency, not just a
      one-time success

## Cost Controls

- Glue job runs as a **Python Shell job on 0.0625 DPU** — the smallest,
  cheapest option, appropriate since the dataset is tens of rows
- **Job timeout capped at 10 minutes** — prevents a runaway job from
  burning compute indefinitely
- Lambda and the Glue Workflow only run **on-demand / event-triggered** —
  nothing polls or runs on a schedule
- **No EC2, no NAT Gateway, no always-on compute** anywhere in the pipeline
- All three S3 buckets have **public access fully blocked**

## Cleanup

Run the **Destroy Pipeline** workflow (Actions tab) to remove every AWS
resource `deploy.sh` created: Lambda, the Glue Workflow and its triggers,
the Glue Job, both Crawlers, the Glue Database (and its tables), all three
S3 buckets (contents included), and both `lambda-role`/`glue-role` IAM
roles.

**What Destroy does *not* touch:** the `github-actions-ci` IAM user and its
access keys. That user was created manually, one time, specifically so
GitHub Actions itself has credentials to run `deploy.sh`/`destroy.sh` — it
was never part of what those scripts manage, which is exactly why
Destroy → Deploy can run back-to-back without locking you out of your own
CI.
