# Azure MLOps: Customer Churn, End to End

A hands-on training project. You will build the full traditional-ML flow on Azure:

**Data → Train → Register → Deploy → Expose (APIM) → Monitor**, all provisioned with **Terraform**, all authenticated with **managed identities** (no secrets in code, pipelines or config).

```
                GitHub Actions  (logs in as a user-assigned managed identity via OIDC)
                     │                                   │
          terraform apply                       az ml job create / deploy
                     ▼                                   ▼
 ┌─────────────────────────── rg-churn-dev ───────────────────────────────────┐
 │                                                                            │
 │  Data Lake (ADLS Gen2) ──► Azure ML workspace ──► compute cluster (UAMI)   │
 │  Key Vault (RBAC)          ├─ data asset churn-raw (versioned)             │
 │  Container Registry        ├─ pipeline: prep → train → quality gate        │
 │  App Insights / Log Anal.  ├─ model registry: churn-model vN               │
 │                            └─ managed online endpoint (auth = Entra ID)    │
 │                                          ▲                                 │
 │                                          │ token for https://ml.azure.com  │
 │  APIM (system-assigned MI) ──────────────┘  custom role: score only        │
 │      ▲                                                                     │
 └──────┼─────────────────────────────────────────────────────────────────────┘
        │ HTTPS + APIM subscription key, rate limited
   Application (CRM, retention dashboard…)
```

## Repository layout

| Path | What it is |
|---|---|
| `bootstrap/` | One-time Terraform: state storage, workload RG, pipeline managed identity + OIDC federation |
| `infra/` | Main Terraform: ML workspace, storage, Key Vault, ACR, App Insights, compute, APIM, RBAC |
| `ml/data/` | Synthetic churn data generator |
| `ml/src/` | `prep.py` and `train.py` (the code that runs on the cluster) |
| `ml/jobs/` | Data asset + Azure ML pipeline definitions |
| `ml/endpoints/` | Online endpoint, deployment and a sample request |
| `.github/workflows/` | `infra.yml` (Terraform) and `mlops.yml` (train → register → deploy) |
| `docs/INTERVIEW.md` | Model answers to the common interview questions |

---

## Step 0 — Prerequisites (30 min)

1. An Azure subscription where you are **Owner** (a free/pay-as-you-go account works).
2. **Create a budget alert first**: Cost Management → Budgets → e.g. $30/month with email alerts.
3. Install: Azure CLI, the ML extension (`az extension add -n ml`), Terraform ≥ 1.6, Python 3.11, Git.
4. `az login` and `az account set --subscription <id>`.
5. Push this folder to a new GitHub repo (needed for step 9).

**Cost notes.** The compute cluster scales to zero. The real cost drivers are the online endpoint (one `Standard_DS3_v2` runs 24/7 while it exists) and APIM Developer tier. Use `apim_sku = "Consumption_0"` while learning, and delete everything when you finish (step 12).

**Provider versions.** The code targets the AzureRM provider `~> 4.0`. If `terraform validate` reports a renamed argument on a newer 4.x release, the error message names the replacement.

---

## Step 1 — Understand what you are building (read, 15 min)

- **Data asset**: the raw CSV registered in Azure ML with a version. Every run records which version it trained on, so you get lineage.
- **Pipeline**: two steps. `prep` cleans and splits; `train` trains two candidates (logistic regression, gradient boosting), logs metrics to MLflow, picks the best by AUC, and **fails the job if AUC < 0.75**. That quality gate means a bad model can never reach the registry.
- **Model registry**: each passing run becomes `churn-model:N`, tagged with the Git SHA and the run ID.
- **Managed online endpoint**: a stable HTTPS URL. The `blue` deployment behind it serves the model. Because the model is saved in MLflow format, no scoring script is needed.
- **APIM**: the only door applications use. It holds the subscription keys, rate-limits callers, validates payload size and, crucially, calls the endpoint with **its own managed identity**.

### Where managed identity is used

| Identity | Type | Used for | Role(s) |
|---|---|---|---|
| `id-churn-github` | User-assigned | CI/CD login (OIDC federated credential) | Contributor + User Access Admin on the workload RG only; Blob Data Contributor on state |
| ML workspace | System-assigned | Workspace access to its storage, Key Vault, ACR | Granted automatically by Azure ML |
| `id-…-compute` | User-assigned | Training cluster reads/writes data, pulls images | Storage Blob Data Contributor, AcrPull |
| Online endpoint | System-assigned | Pulling the model and image at deploy time | Granted automatically |
| APIM | System-assigned | Getting Entra ID tokens to call the endpoint | Custom role with only `onlineEndpoints/score/action` |

The endpoint uses `auth_mode: aad_token`, so there is **no endpoint key** to leak or rotate.

---

## Step 2 — Bootstrap: identity and state (15 min)

```bash
cd bootstrap
terraform init
terraform apply \
  -var="subscription_id=$(az account show --query id -o tsv)" \
  -var="github_repo=<your-github-user>/<your-repo>"
terraform output
```

This creates the state storage account (shared keys **disabled**), the workload resource group, and the pipeline's managed identity with two **federated credentials**: one for jobs in the GitHub `dev` environment and one for pull requests. GitHub presents a short-lived OIDC token; Entra ID swaps it for an Azure token. No client secret ever exists.

> **Interview point:** "Workload identity federation removes the long-lived service principal secret, the most common credential leaked from CI systems."

Keep the outputs; you need them in steps 3 and 9.

---

## Step 3 — Provision the platform, phase 1 (20–45 min)

```bash
cd ../infra
cp terraform.tfvars.example terraform.tfvars   # fill in subscription, RG, email
terraform init \
  -backend-config="resource_group_name=<TFSTATE_RESOURCE_GROUP>" \
  -backend-config="storage_account_name=<TFSTATE_STORAGE_ACCOUNT>"
terraform plan -out tfplan
terraform apply tfplan
terraform output
```

You need **Storage Blob Data Contributor** on the state account yourself to run this locally (the state backend uses Entra ID, not keys):

```bash
az role assignment create --assignee $(az ad signed-in-user show --query id -o tsv) \
  --role "Storage Blob Data Contributor" \
  --scope $(az storage account show -n <TFSTATE_STORAGE_ACCOUNT> --query id -o tsv)
```

Phase 1 creates everything except the APIM API, because the endpoint it points at does not exist yet.

**Check it worked:** open [ml.azure.com](https://ml.azure.com), select the workspace, then Compute → Compute clusters → `cpu-cluster` (0 nodes, idle).

---

## Step 4 — Data: register a versioned data asset (5 min)

```bash
cd ..
az configure --defaults group=rg-churn-dev workspace=<aml_workspace output>
python ml/data/generate_churn_data.py --out ml/data/churn_raw.csv
az ml data create -f ml/jobs/data-asset.yml --version 1
```

**Check:** Studio → Data → `churn-raw` v1. Use "Explore" to preview rows.

**Try it locally first (optional, no Azure cost):**

```bash
pip install scikit-learn pandas mlflow
python ml/src/prep.py  --raw ml/data/churn_raw.csv --train /tmp/tr --test /tmp/te
python ml/src/train.py --train /tmp/tr --test /tmp/te --model_output /tmp/model
```

---

## Step 5 — Train: run the Azure ML pipeline (10–20 min)

```bash
RUN=$(az ml job create -f ml/jobs/train-pipeline.yml --query name -o tsv)
az ml job stream -n $RUN
```

The first run is slow because Azure ML builds the environment image from `conda.yml`; later runs reuse it.

**Check in Studio → Jobs → churn-prediction:**
- The pipeline graph: prep → train.
- Open `train` → Metrics: `logreg_auc` vs `gbm_auc`, `best_auc`. This is **experiment tracking**.
- Run it again with a different threshold to see the gate fail:
  `az ml job create -f ml/jobs/train-pipeline.yml --set inputs.auc_threshold=0.95`

---

## Step 6 — Register the model (2 min)

```bash
az ml model create --name churn-model --type mlflow_model \
  --path azureml://jobs/$RUN/outputs/model_output \
  --tags pipeline_run=$RUN
```

**Check:** Studio → Models → `churn-model` → the "Jobs" link takes you back to the exact run, data version and code snapshot. That is **lineage**.

---

## Step 7 — Deploy to a managed online endpoint (10–15 min)

```bash
EP=<suggested_endpoint_name output>
az ml online-endpoint create -f ml/endpoints/endpoint.yml --name $EP
az ml online-deployment create -f ml/endpoints/deployment.yml \
  --endpoint-name $EP --all-traffic
az ml online-endpoint invoke -n $EP --request-file ml/endpoints/sample-request.json
```

Expected output, `[P(stay), P(churn)]` per customer:

```
[[0.018, 0.982], [0.983, 0.017]]
```

The first customer (month-to-month, e-check, 3 months tenure, 4 tickets) is very likely to churn; the second is not.

Call it directly with an Entra ID token (this is exactly what APIM will do):

```bash
URI=$(az ml online-endpoint show -n $EP --query scoring_uri -o tsv)
TOKEN=$(az account get-access-token --resource https://ml.azure.com --query accessToken -o tsv)
curl -s -X POST "$URI" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d @ml/endpoints/sample-request.json
```

### Safe rollouts (blue/green)

To test a new model without risk, create a second deployment and shift a slice of traffic:

```bash
az ml online-deployment create -f ml/endpoints/deployment.yml --name green \
  --endpoint-name $EP --set model=azureml:churn-model:2
az ml online-endpoint update -n $EP --traffic "blue=90 green=10"
# watch metrics, then: --traffic "green=100", and delete blue
```

You can also **mirror** traffic (`--mirror-traffic "green=10"`) so green receives copies of live requests without answering users.

---

## Step 8 — Put APIM in front, phase 2 (5 min)

Set the endpoint base URL (scoring URI without `/score`) and apply again:

```bash
cd infra
# in terraform.tfvars:
# aml_endpoint_base_url = "https://<EP>.<region>.inference.ml.azure.com"
terraform apply
KEY=$(terraform output -raw apim_test_subscription_key)
curl -s -X POST "$(terraform output -raw apim_predict_url)" \
  -H "Ocp-Apim-Subscription-Key: $KEY" \
  -H "Content-Type: application/json" -d @../ml/endpoints/sample-request.json
```

What happens on each call:
1. APIM checks the subscription key and the rate limit (60/min).
2. `validate-content` rejects anything that isn't JSON or is larger than 100 KB.
3. `authentication-managed-identity` fetches a token for `https://ml.azure.com` using APIM's own identity.
4. The request is rewritten to `/score` and forwarded.
5. The endpoint verifies the token and checks that APIM's identity holds the custom **score-only** role.

The application only ever holds an APIM key, which you can revoke per consumer. It never sees Azure credentials.

---

## Step 9 — Automate: CI/CD with GitHub Actions (30 min)

1. In GitHub → Settings → Environments, create **`dev`**. Add yourself as a required reviewer if you want a manual approval gate before `apply`.
2. Settings → Secrets and variables → Actions → **Variables** (not secrets; none of these are sensitive):

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | bootstrap outputs |
| `TFSTATE_RESOURCE_GROUP`, `TFSTATE_STORAGE_ACCOUNT` | bootstrap outputs |
| `WORKLOAD_RESOURCE_GROUP` | `rg-churn-dev` |
| `APIM_PUBLISHER_EMAIL` | your email |
| `APIM_SKU` | `Consumption_0` |
| `AML_WORKSPACE` | infra output `aml_workspace` |
| `AML_ENDPOINT_NAME` | infra output `suggested_endpoint_name` |
| `AML_ENDPOINT_BASE_URL` | set after the first deployment |

3. Push to `main`.

- **`infra.yml`**: PR → `fmt`, `validate`, `plan`. Merge → `apply` the exact reviewed plan.
- **`mlops.yml`**: change in `ml/`, manual run, or weekly schedule → new data version → pipeline (with quality gate) → register (tagged with Git SHA) → create/update deployment → smoke test.

Note that the repository contains **no secrets at all**. That is the point of the managed identity + OIDC design.

---

## Step 10 — Monitor (30 min)

**Operational health (App Insights / Azure Monitor):**
- Endpoint: Azure portal → the endpoint → Metrics: Request latency (P50/P95), Requests per minute, Errors (4xx/5xx), CPU/memory utilization.
- Logs: the deployment sends request logs to App Insights (`app_insights_enabled: true`).
- APIM: Analytics blade shows calls per consumer, latency and failures.
- Create alerts, e.g. P95 latency > 1 s for 5 minutes, or 5xx rate > 1%.

**Model health (Azure ML model monitoring):**
- **Data drift**: are incoming feature distributions different from training data? (e.g. far more month-to-month customers than before)
- **Prediction drift**: has the share of predicted churners shifted?
- **Model performance**: once actual churn outcomes arrive weeks later, join them to predictions and recompute AUC.
- Setup: enable data collection on the deployment (requires a scoring script with the collector, or use the `data_collector` settings), then create a monitor in Studio → Monitoring that compares production data to `churn-raw` and alerts on a threshold.
- Close the loop: a drift alert can trigger `mlops.yml` (`workflow_dispatch`) to retrain.

---

## Step 11 — Harden for production (read, then try)

This learning setup keeps public access on so you can reach everything from your laptop. For production:

| Control | How |
|---|---|
| No public endpoints | `public_network_access = false`; private endpoints for workspace, storage (blob + dfs), Key Vault, ACR (Premium SKU) with private DNS zones |
| Managed VNet for AML | Workspace `managed_network { isolation_mode = "AllowOnlyApprovedOutbound" }` so compute and endpoints have no unmanaged egress |
| Online endpoint private | `public_network_access: disabled` on the endpoint; inbound only via the workspace private endpoint |
| APIM in VNet | Developer/Premium (or v2) tier in internal/VNet mode; expose externally via Application Gateway + WAF |
| No storage keys | Identity-based datastores, then `shared_access_key_enabled = false` |
| Secrets where unavoidable | Key Vault + APIM named values referencing Key Vault (fetched with APIM's managed identity) |
| Least privilege | Replace User Access Administrator with RBAC Administrator + an ABAC condition; separate identities per environment |
| Governance | Azure Policy (deny public network access, require tags, allowed SKUs/regions), Defender for Cloud |
| Promotion | Separate dev/test/prod workspaces; promote models via an Azure ML **registry** rather than retraining in prod |

---

## Step 12 — Clean up

```bash
az group delete -n rg-churn-dev --yes --no-wait
az group delete -n rg-churn-tfstate --yes --no-wait   # only when fully done
```

The Key Vault is soft-deleted for 7 days; purge it if you want to reuse the name: `az keyvault purge -n <name>`.

---

## Exercises (do these to really learn it)

1. Add a third candidate model (e.g. `RandomForestClassifier`) and see whether it wins.
2. Add a `validate` step to the pipeline that checks the data for missing columns before training.
3. Change the deployment to green, shift 10% of traffic, and watch the metrics.
4. Add an APIM `validate-jwt` policy so callers need an Entra ID token as well as a subscription key.
5. Add a private endpoint for the storage account in Terraform.
6. Write a batch endpoint that scores every customer nightly instead of in real time. When is batch the better choice?
