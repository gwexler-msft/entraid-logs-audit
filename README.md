# EntraIdLogsAudit

Automated detection and user notification for **Microsoft Entra ID security-info
(MFA) changes**. When a user's authentication methods are registered, updated, or
deleted, an **Azure Logic Apps Standard** workflow emails the affected user a
security alert via **Azure Communication Services (ACS) Email** — providing rapid,
self-service detection of potential account-takeover activity.

> Detect an unexpected MFA change → the real user gets an email → they call the
> service desk if it wasn't them.

## How it works

```
Entra ID Audit Logs → Diagnostic Settings → Raw Event Hub
   → [optional] Stream Analytics filter → Filtered Event Hub
   → Logic App Standard → ACS Email → affected user
```

The entire data/compute plane is **private by default**: public network access is
disabled and all PaaS traffic flows over Private Endpoints inside a locked-down
VNet. See the **[full system diagram](docs/architecture.md#2a-full-system-diagram-all-deployed-components)**
for every component (both pipelines, networking, identities, monitoring) and
[docs/architecture.md](docs/architecture.md) for the rest of the diagrams.

## Repository layout

| Path | Contents |
|------|----------|
| [`LogsProcessor/`](LogsProcessor/) | Logic App Standard project (workflow, connections, host config) |
| [`LogsProcessor/LogsProcessor/workflow.json`](LogsProcessor/LogsProcessor/workflow.json) | The stateful workflow definition |
| [`LogsProcessor/connections.json`](LogsProcessor/connections.json) | Event Hub service-provider connection metadata (managed-identity auth) |
| [`SignInProcessor/`](SignInProcessor/) | *Optional* sign-in/risk alerting Logic App project (off by default — see below) |
| [`infra/`](infra/) | Bicep IaC (private/locked-down) — `main.bicep` + `modules/` |
| [`infra/main.bicepparam`](infra/main.bicepparam) | Prod parameters (also `main.dev.bicepparam`, `main.test.bicepparam`) |
| [`azure.yaml`](azure.yaml) | Azure Developer CLI (`azd`) project — maps the Bicep + Logic App for `azd up` |
| [`scripts/`](scripts/) | `postprovision.ps1` (azd post-deploy notes hook), `Publish-Snapshot.ps1` (clean release tool) |
| [`docs/architecture.md`](docs/architecture.md) | Architecture reference + Mermaid diagrams |
| [`docs/deployment-guide.md`](docs/deployment-guide.md) | Step-by-step deployment instructions |
| [`docs/operations-runbook.md`](docs/operations-runbook.md) | Day-2 operations & incident response |

## Quick start

```powershell
az login
az group create -n "rg-entraaudit-prod" -l "centralus"

az deployment group create `
  -g "rg-entraaudit-prod" `
  -f infra/main.bicep `
  -p infra/main.bicepparam `
  -n entraaudit
```

Then complete the post-deploy steps (ACS domain, workflow code, Entra Diagnostic
Settings) — full instructions in
[docs/deployment-guide.md](docs/deployment-guide.md). Connectivity is
identity-based, so there is no connection key to wire.

### Or with Azure Developer CLI

```powershell
azd auth login
azd env new entraaudit-prod
azd env set AZURE_RESOURCE_GROUP "rg-entraaudit-prod"
azd env set AZURE_LOCATION       "centralus"
azd up
```

`azd up` provisions the Bicep, runs the `postprovision` notes hook, and deploys
the workflow code. Run it from a host with line-of-sight to the VNet — the Logic
App site is private. Connectivity is identity-based (no connection key to wire).
The tenant-scoped Entra Diagnostic Settings remain a manual step. See
[docs/deployment-guide.md §3a](docs/deployment-guide.md).

## Infrastructure highlights

- **Private by default** — Storage and the Logic App site have
  `publicNetworkAccess = Disabled`; traffic flows over Private Endpoints. The
  Event Hubs namespace is likewise private, except in the default ASA
  `firewallException` mode where it keeps a deny-by-default firewall that allows
  only the ASA trusted Microsoft service (use `dedicatedCluster` for a fully
  private namespace).
- **Deny-by-default networking** — NSGs deny all inbound; 6 private DNS zones are
  VNet-linked for private name resolution.
- **Managed identity + RBAC** — the Logic App uses a system-assigned identity for
  **all** service connectivity: Event Hubs (**Data Receiver**), the backing
  storage account (**Blob/Queue/Table** data roles for `AzureWebJobsStorage`),
  ACS Email (**Contributor**, called via the ACS REST API), and Application
  Insights ingestion (**Monitoring Metrics Publisher**, local auth disabled).
  A companion **user-assigned identity** (`id-<prefix>`) holds the same storage
  roles because the workflow `Data.Edge` runtime only accepts a user-assigned
  identity for `AzureWebJobsStorage`. No connection strings or access keys are
  used for connectivity. **Two** shared keys remain — the Logic Apps Standard
  content share and the Event Hub SAS rule that Azure Monitor uses to deliver
  tenant logs — see **Security & secrets**.
- **Observability** — Log Analytics workspace + Application Insights, with
  diagnostics enabled on the Logic App and Event Hubs.
- **Pre-filtering on by default** — an Azure Stream Analytics job pre-filters
  events (raw → filtered) so the Logic App only processes security-info changes,
  minimizing filtered-hub volume and Logic App load. ASA reaches the private
  namespace via the trusted-service firewall bypass (`firewallException`) by
  default, or a fully-private dedicated cluster (`dedicatedCluster`, opt-in).

## Optional add-on — sign-in / risk alerting probe *(off by default)*

> **This is an internal security probe, not part of the customer deliverable.**
> It is **disabled by default** (`deploySignInPipeline = false`) and the primary
> MFA-change pipeline above is completely unaffected whether it is on or off.

The same raw Event Hub already carries Entra **sign-in** and **risk** logs
(`SignInLogs`, `UserRiskEvents`, `RiskyUsers`). Setting
`deploySignInPipeline = true` stands up a **fully isolated parallel pipeline** —
its **own** Stream Analytics job, filtered hub, Logic App, plan and identities —
that filters for risky/failed sign-ins and risk detections and emails an
**internal recipient** (`alertRecipientAddress`) instead of the affected end
user. It reuses the existing raw hub through a **separate consumer group**, so it
never changes the customer pipeline's data, throughput, or behavior.

```
Raw Event Hub ──(asa-signin-cg)──▶ ASA #2 ──▶ signin filtered hub
                                                  ──▶ Logic App #2 ──▶ ACS Email ──▶ your mailbox
```

| Aspect | Value |
|--------|-------|
| Enable | `deploySignInPipeline = true` + `alertRecipientAddress = '<you@org>'` |
| Default | **off** — only enabled in `main.dev.bicepparam` / `main.test.bicepparam` probe envs |
| Cost when on | ~$255/mo (second WS plan ~$175 + second ASA job ~$80) |
| Isolation | New consumer group `asa-signin-cg`, hub `insights-logs-signin-filtered`, app `logic-signin-<prefix>`, subnet `snet-logicapp2` |

See [docs/architecture.md §10](docs/architecture.md) and
[docs/deployment-guide.md §7a](docs/deployment-guide.md) for details.

## Security & secrets

- `local.settings.json`, `appsettings.json`, and `.env` files are **git-ignored**
  and must never be committed.
- **Application connectivity is identity-based (key-less).** Event Hubs, storage
  (`AzureWebJobsStorage`), ACS Email, and Application Insights ingestion all use
  the Logic App's managed identity + Azure RBAC. There are **no** connection
  strings or access keys applied as app settings for these.
- **Two shared keys remain**, both driven by platform limitations rather than our
  design. Both are covered by the scoped policy exemption
  `exempt-entraaudit-test-shared-key` (a **Waiver** against the org governance
  assignment `MCAPSGovDeployPolicies`), which otherwise force-disables local auth
  on storage and Event Hubs:
    1. **Logic Apps Standard content share.** The **Workflow Standard (WS) plan**
       requires `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING`, an Azure Files
       **shared-key** connection string, to mount its workflow content. The
       identity-based form (`__accountName`/`__credential`) is only supported on
       **Flex Consumption**, not WS plans. The storage account keeps
       `allowSharedKeyAccess = true` (exemption reference
       `StorageAccountDisableLocalAuth`); the key is **never stored in source** —
       it is resolved at deploy time via `storage.listKeys()` inside
       [`logicapp.bicep`](infra/modules/logicapp.bicep).
    2. **Event Hub SAS rule for tenant-log delivery.** The Entra (tenant)
       Diagnostic Setting delivers Audit/Sign-in logs to the raw Event Hub. Azure
       Monitor diagnostic settings can authenticate to Event Hubs **only via a
       SAS authorization rule** (`RootManageSharedAccessKey`) — there is **no**
       managed-identity option for that destination. The namespace must therefore
       keep `disableLocalAuth = false` (exemption reference
       `eventhubdisablelocalauth`). With local auth disabled, intake silently
       stops: the raw hub receives 0 events and the whole pipeline goes dark.
  > ⚠️ **These shared keys may not be acceptable in the customer's tenant.** The
  > customer is confirming how tenant-log export to Event Hubs was set up before
  > us. The content-share key can be eliminated by moving the Logic App off the WS
  > plan to **Flex Consumption**; the Event Hub SAS key is an Azure Monitor
  > platform constraint with no first-party key-less alternative today (an
  > alternative export path — e.g. Log Analytics + a different connector — would
  > be required to remove it). See the architecture doc §8 “Known constraints”.
- Compiled Bicep output (`infra/**/*.json`) is git-ignored.

## Documentation

- [Architecture reference](docs/architecture.md)
- [Deployment guide](docs/deployment-guide.md)
- [Operations runbook](docs/operations-runbook.md)
