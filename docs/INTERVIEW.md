# Interview answers: Azure AI/ML

Short, spoken-style answers. Each one ties back to something you built in this repo, so you can say "in my lab I…" instead of reciting theory.

---

### 1. ML vs GenAI: when would you use each?

Traditional ML when the output is a **prediction on structured data** with a label you can learn from: churn, fraud, demand, credit risk. It's cheaper per call, deterministic, explainable and easy to measure (AUC, precision/recall).
GenAI when the task is **language or reasoning over unstructured content**: summarizing, answering questions over documents, drafting, extracting meaning from free text.
They often combine: an LLM can turn a churn score into a personalized retention email. *In my lab the churn model is classic ML because it's tabular data with a clear label.*

### 2. What is RAG?

Retrieval-Augmented Generation. Instead of retraining the model on private documents, at query time you **retrieve** the most relevant chunks from a search index (Azure AI Search) and pass them to the LLM as context, with instructions to answer only from that context. Benefits: fresh data without retraining, citations, fewer hallucinations, and access control enforced at retrieval time.

### 3. What are embeddings and vector databases?

An embedding is a vector of numbers representing the **meaning** of text, so similar meanings land close together. A vector index stores these and finds nearest neighbours fast. Azure AI Search does this and also combines it with keyword search (**hybrid search**) plus a **semantic reranker**, which usually beats pure vector search.

### 4. Azure OpenAI vs Azure Machine Learning?

Azure OpenAI (in Microsoft Foundry) gives you **pre-trained foundation models** as an API: you consume and maybe fine-tune them. Azure ML is the platform to **build, train, track, register, deploy and monitor your own models**. Foundry is the umbrella for building GenAI apps and agents; Azure ML is the MLOps engine for custom models.

### 5. How do you securely expose an ML model?

*Exactly what this repo does:* the managed online endpoint uses `aad_token` auth, so there are no keys. APIM is the only entry point: subscription keys per consumer, rate limiting, payload validation. APIM authenticates to the endpoint with **its own managed identity**, holding a custom role that can only call `score`. In production I'd add private endpoints so the endpoint has no public route, APIM in a VNet, and App Gateway + WAF at the edge.

### 6. How would you prevent public access to AI resources?

Disable public network access on every resource (workspace, storage, Key Vault, ACR, Azure OpenAI, AI Search), add **private endpoints** with private DNS zones, use the AML **managed VNet** with approved-outbound-only, and enforce it with **Azure Policy** (deny `publicNetworkAccess = Enabled`) so nobody can quietly turn it back on.

### 7. Managed identity vs service principal vs API key?

- **API key**: a static shared secret. Anyone holding it has access; it must be stored and rotated, and it can't express fine-grained permissions.
- **Service principal with secret/certificate**: a real identity with RBAC, but you still manage and rotate a credential.
- **Managed identity**: Azure manages the credential; nothing to store, leak or rotate. System-assigned lives and dies with the resource; user-assigned is independent and reusable (like my pipeline and compute identities).
- For CI/CD outside Azure, use **workload identity federation (OIDC)**. *My GitHub pipeline logs in as a managed identity with no secret at all.*

### 8. How would you monitor a model in production?

Two layers. **Operational**: App Insights/Azure Monitor for latency (P95), throughput, error rates, CPU/memory, with alerts; APIM analytics per consumer. **Model quality**: Azure ML model monitoring for data drift, prediction drift and data quality against the training baseline, and performance once ground-truth labels arrive. Alerts can trigger the retraining pipeline.

### 9. What is model/data drift?

**Data drift**: input distributions change (e.g. a new pricing plan means more month-to-month customers). **Concept drift**: the relationship between inputs and outcome changes (customers now churn for reasons the model never saw). **Prediction drift**: the output distribution shifts. Detect with statistical distance measures against the training data, then retrain, investigate or roll back.

### 10. How would you implement CI/CD / MLOps?

*As in this repo:* infra via Terraform with plan-on-PR and apply-the-reviewed-plan on merge. ML via a pipeline that versions the data, runs a training pipeline with a **quality gate**, registers the model tagged with Git SHA and run ID for lineage, deploys to an endpoint, and smoke-tests. For production: separate dev/test/prod, promote the **same model artifact** through an Azure ML registry, approval gates between stages, blue/green or canary rollouts with automatic rollback.

### 11. How would you reduce hallucinations?

RAG with good chunking and hybrid search plus reranking; a system prompt that says "answer only from the sources, otherwise say you don't know"; require citations; lower temperature; groundedness checks (Foundry evaluations / Content Safety groundedness detection); an evaluation set run in CI so prompt or model changes can't silently regress quality.

### 12. How would you protect sensitive corporate data?

Data stays in your tenant and region; Azure OpenAI doesn't use your prompts to train models. Private networking everywhere; managed identities and RBAC; **document-level security trimming** in AI Search so users only retrieve what they're allowed to see; Purview for classification and DLP; Content Safety and **Prompt Shields** against prompt injection; customer-managed keys if required; logging with PII redaction.

### 13. How do private endpoints affect the AOAI / AML / Search architecture?

Every service gets a private IP in your VNet and private DNS zones (e.g. `privatelink.openai.azure.com`, `privatelink.api.azureml.ms`, `privatelink.search.windows.net`, blob/dfs, vault, ACR). Consequences:
- **DNS is the #1 failure point**: all clients, including on-prem via DNS forwarding, must resolve to the private IPs.
- **Service-to-service calls** need networking too: AI Search's indexer reaching Blob or Azure OpenAI needs **shared private links**; AML compute needs a managed VNet or VNet injection.
- **Build agents** must run inside the network (self-hosted runners or managed DevOps pools) to deploy to private resources.
- **APIM** must be VNet-integrated to reach private backends.
- Portal and Studio access require a jump box, VPN or ExpressRoute.

---

## The two 60-second answers

**"How would you implement an ML solution on Azure?"**
Define the prediction problem and success metric with the business first. Land data in Data Lake or SQL, register it as a versioned data asset in Azure ML. Build a training pipeline that prepares data, trains and compares candidates with MLflow tracking, and enforces a quality gate. Register the best model with lineage, deploy to a managed online endpoint with Entra ID auth, and expose it through APIM, which authenticates with its managed identity. Provision everything with Terraform; use managed identities and RBAC, Key Vault only where secrets are unavoidable, private endpoints and VNet integration. Monitor latency and errors in App Insights and drift in Azure ML, and automate retraining and deployment with CI/CD so nothing is deployed by hand.

**"How would you design a GenAI solution?"**
Azure OpenAI in Foundry with RAG. Documents in Blob or SharePoint are chunked, embedded and indexed in Azure AI Search with security trimming. The app retrieves relevant chunks with hybrid search and reranking and passes them as grounding context. APIM in front for auth, token rate limits and per-team usage tracking. Managed identity, private endpoints and RBAC throughout. Content filtering and Prompt Shields for safety, evaluations in CI for groundedness and quality, and token and cost monitoring in production.
