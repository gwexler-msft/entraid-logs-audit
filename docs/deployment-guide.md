# EntraIdLogsAudit — Deployment Guide

This guide deploys the full solution: the locked-down Azure infrastructure
(Bicep), the post-deployment wiring that can't be done declaratively, and the
Logic App workflow code.

See [architecture.md](architecture.md) for the design and diagrams.

---

## 1. Prerequisites

| Requirement | Notes |
|-------------|-------|
| Azure subscription | Owner/Contributor + User Access Administrator on the target RG (RBAC role assignments are created) |
| Azure CLI | `az version` ≥ 2.60; `az bicep version` ≥ 0.30 |
| Azure Developer CLI (optional) | `azd version` ≥ 1.5 — for the one-command `azd up` path (§3a) |
| Azure Functions Core Tools | v4 — to deploy the Logic App workflow code (manual path) |
| Entra ID privileges | **Global Administrator** or **Security Administrator** to configure tenant Diagnostic Settings |
| Permission to create ACS / send email | Subscription must allow Communication Services |
| Network reachability | Resources are **private**; perform post-deploy steps from a host with line-of-sight to the VNet (jumpbox, VPN, Bastion, or self-hosted runner) or temporarily allow your IP |

Log in and select the subscription:

```powershell
az login
az account set --subscription "<SUBSCRIPTION_ID>"
```

---

## 2. Choose parameters

Edit [`infra/main.bicepparam`](../infra/main.bicepparam) (or copy it to
`infra/main.<env>.bicepparam`). Key parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `namePrefix` | — | Resource name prefix, e.g. `cf-entraaudit-prod` |
| `location` | `centralus` | Azure region |
| `vnetAddressPrefix` | `10.50.0.0/16` | VNet space — must not overlap peered networks |
| `privateEndpointSubnetPrefix` | `10.50.1.0/24` | PE subnet |
| `logicAppSubnetPrefix` | `10.50.2.0/24` | Logic App VNet-integration subnet |
| `planSku` | `WS1` | Workflow Standard plan size |
| `deployStreamAnalytics` | `true` | ASA pre-filter raw → filtered (on by default; keeps Logic App load low — see §7) |
| `asaConnectivityMode` | `firewallException` | How ASA reaches the private namespace: `firewallException` (trusted-service bypass, ~$80/mo) or `dedicatedCluster` (fully private, ~$2,890/mo — see §7) |
| `deploySignInPipeline` | **`false`** | *Opt-in.* Deploy the parallel sign-in/risk alerting probe (off by default — not part of the customer deliverable; see §7a) |
| `alertRecipientAddress` | `''` | Internal mailbox for sign-in/risk alerts — **required** when `deploySignInPipeline = true` |
| `socRecipientAddress` | `''` | *Optional.* SOC / security-team mailbox **BCC'd** on every MFA / security-info change notification. Empty = email only the affected end user |
| `signInLogicAppSubnetPrefix` | `10.50.3.0/24` | VNet-integration subnet for the opt-in sign-in Logic App (only used when enabled) |
| `useAzureManagedDomain` | `true` | ACS Azure-managed sender domain vs custom |
| `customDomainName` | `''` | Required when `useAzureManagedDomain = false` |
| `extraTags` | `{}` | Extra resource tags |

---

## 3. Validate and deploy the infrastructure

```powershell
# Create the resource group
az group create -n "rg-entraaudit-prod" -l "centralus"

# Optional: lint
az bicep build --file infra/main.bicep

# Preview changes (what-if)
az deployment group what-if `
  -g "rg-entraaudit-prod" `
  -f infra/main.bicep `
  -p infra/main.bicepparam

# Deploy
az deployment group create `
  -g "rg-entraaudit-prod" `
  -f infra/main.bicep `
  -p infra/main.bicepparam `
  -n entraaudit
```

Capture the outputs (used below):

```powershell
az deployment group show -g "rg-entraaudit-prod" -n entraaudit `
  --query properties.outputs -o json
```

Important outputs: `logicAppName`, `logicAppPrincipalId`, `eventHubNamespaceName`,
`rawHubName`, `filteredHubName`, `rawSendRuleId`, `communicationServiceName`,
`storageAccountName`.

---

## 3a. Alternative — deploy with Azure Developer CLI (`azd`)

[`azure.yaml`](../azure.yaml) wires the same Bicep and the Logic App project into
`azd`, so provisioning and the workflow code push happen in one flow. All
connectivity is identity-based, so there is no ACS connection key to wire.

```powershell
azd auth login
azd env new entraaudit-prod

# Resource group for the RG-scoped Bicep, plus region/subscription
azd env set AZURE_RESOURCE_GROUP "rg-entraaudit-prod"
azd env set AZURE_LOCATION       "centralus"
azd env set AZURE_SUBSCRIPTION_ID "<SUBSCRIPTION_ID>"

azd up      # = provision (infra) + postprovision hook (ACS settings) + deploy (workflow code)
```

Notes:

- `azd` uses [`infra/main.bicepparam`](../infra/main.bicepparam) (prod values) by
  default. For dev/test, edit that file or use the manual `az` path with
  `main.dev.bicepparam` / `main.test.bicepparam`.
- The **postprovision hook** ([`scripts/postprovision.ps1`](../scripts/postprovision.ps1))
  just prints the remaining manual steps — all connectivity is identity-based,
  so there is no ACS key step to run.
- `azd deploy logsprocessor` pushes the workflow code. Because the site is
  **private** (`publicNetworkAccess = Disabled`), run `azd up` / `azd deploy`
  from a host with line-of-sight to the VNet (jumpbox, VPN, Bastion, self-hosted
  runner). This is the same constraint as the manual `func publish` in §6.
- The Entra ID tenant Diagnostic Settings (§7) remain a manual step — they are
  tenant-scoped and outside the resource-group deployment.

If you use `azd`, you can skip §5 (nothing to do) and §6 (handled by `azd deploy`),
then continue at §7.

---

## 4. Post-deploy step A — verify the ACS email domain

The Bicep provisions the ACS resource, the Email Communication Services
resource, the email domain, and links them. You still need to confirm the
sender is ready:

1. In the portal open the **Email Communication Service** →
   **Provision domains**.
2. For an **Azure-managed** domain (`useAzureManagedDomain = true`) the
   `@<guid>.azurecomm.net` domain is verified automatically. Note the
   **MailFrom** address — it must match the `acs_sender` app setting consumed by
   the workflow (`DoNotReply@<guid>.azurecomm.net`).
3. For a **custom** domain, add the published **TXT / SPF / DKIM** DNS records and
   wait for verification, then confirm the domain is linked to the ACS resource.

> **Sender is an app setting, not a hardcoded value.** The workflow's
> `Set_SenderAddress` action reads `@{appsetting('acs_sender')}`. Bicep
> auto-populates `acs_sender` from the ACS Email managed-domain output
> (`acs.outputs.senderAddress`), so the default deployment works end-to-end.
>
> **Customer adoption:** in a production tenant you will almost always send from
> your own **verified email domain** (not the Azure-managed `azurecomm.net`
> one). Override the sender for your environment by setting the `acs_sender`
> app setting on the Logic App (or the `acsSenderAddress` Bicep param /
> `alertRecipientAddress` param file) to a `DoNotReply@<your-verified-domain>`
> address that is provisioned and verified in your ACS Email resource. No
> workflow code change is required.

---

## 5. Post-deploy step B — connectivity is identity-based (nothing to wire)

> **Using `azd`?** Nothing to do here — skip to §6.

All runtime connectivity uses the Logic App's managed identity, so there are
**no connection keys or strings to apply** after deployment:

- **Event Hub trigger** — the service-provider connection in
  [`LogsProcessor/connections.json`](../LogsProcessor/connections.json)
  authenticates with the managed identity against the namespace FQDN
  (`eventHub_fullyQualifiedNamespace` app setting); RBAC is granted by
  [`rbac.bicep`](../infra/modules/rbac.bicep) (**Event Hubs Data Receiver**).
- **ACS Email send** — the workflow `Send_email` action calls the **ACS Email
  REST API** directly over HTTP (`@{appsetting('acs_endpoint')}/emails:send`)
  with managed-identity auth (audience `https://communication.azure.com`);
  `rbac.bicep` grants **Contributor** on the Communication Services resource.
  The sender comes from the `acs_sender` app setting (§4).
- **Storage, Application Insights** — also identity-based (see
  [architecture.md](architecture.md)).

> This solution does **not** use the Logic Apps `acsemail` managed connector
> (`Microsoft.Web/connections`) or any `listConnectionKeys` secret. The Bicep
> deploys no `connections` module.

---

## 6. Post-deploy step C — deploy the workflow code

> **Using `azd`?** Run `azd deploy logsprocessor` (from a VNet-connected host) —
> this replaces the manual `func publish` below.

From the Logic App project root (`LogsProcessor/`):

```powershell
cd LogsProcessor
func azure functionapp publish "<logicAppName>" --no-build
```

If publishing fails due to the private site (`publicNetworkAccess = Disabled`),
run the publish from a host inside/peered to the VNet, or zip-deploy via the
Kudu private endpoint. Alternatively use VS Code **Azure Logic Apps (Standard)**
→ **Deploy to Logic App** from a network-connected client.

The connection metadata in
[`LogsProcessor/connections.json`](../LogsProcessor/connections.json) resolves at
runtime from the app settings (`WORKFLOWS_SUBSCRIPTION_ID`,
`WORKFLOWS_RESOURCE_GROUP_NAME`, `WORKFLOWS_LOCATION_NAME`,
`eventHub_fullyQualifiedNamespace`) using the managed identity.

---

## 7. Post-deploy step D — wire Entra ID Diagnostic Settings (tenant scope)

Entra Audit Logs are **tenant-level** and not part of the resource-group
template. In the **default** configuration (`deployStreamAnalytics = true`) you
point Diagnostic Settings at the **raw** Event Hub; the Stream Analytics job then
filters raw → filtered, and the Logic App triggers only on the pre-filtered
**filtered** hub. This is the intended design — it keeps the filtered-hub volume
and the Logic App load to a minimum.

1. Portal → **Microsoft Entra ID** → **Monitoring** → **Diagnostic settings** →
   **Add diagnostic setting**.
2. Select the **AuditLogs** category.
3. Destination: **Stream to an event hub** → choose the namespace
   `evhns-<namePrefix>`, the raw hub `insights-logs-auditlogs`, and the
   `diagnostics-send` (Send) policy.
4. Save.

CLI equivalent (replace the event hub authorization rule id with `rawSendRuleId`
from the outputs):

```powershell
az monitor diagnostic-settings create `
  --name "entra-auditlogs-to-eh" `
  --resource "/providers/Microsoft.aadiam" `
  --logs '[{"category":"AuditLogs","enabled":true}]' `
  --event-hub "insights-logs-auditlogs" `
  --event-hub-rule "<rawSendRuleId>"
```

> **Source filtering is category-level only** — you select `AuditLogs`, not
> specific operations. The per-operation (security-info) filtering happens
> downstream in Stream Analytics.

> **No-ASA fallback.** If you set `deployStreamAnalytics = false`, nothing fills
> the filtered hub, so point Diagnostic Settings at the **filtered** hub
> (`insights-logs-auditlogs-filtered`) instead. The Logic App then filters every
> event internally and discards non-security-info events — higher Logic App load,
> which is exactly what the ASA pre-filter is designed to avoid.

### Stream Analytics → private Event Hubs connectivity (`asaConnectivityMode`)

The Event Hubs namespace is private. How the ASA job reaches it is controlled by
the `asaConnectivityMode` parameter:

| Mode | What it does | Network posture | Added cost (Central US retail) |
|------|--------------|-----------------|--------------------------------|
| **`firewallException`** *(default)* | ASA is an Event Hubs **trusted Microsoft service**. The namespace is set to `publicNetworkAccess = Enabled` with a **deny-by-default** network rule set, `trustedServiceAccessEnabled = true`, and a VNet rule on the Logic App subnet. ASA authenticates with its **managed identity** (already configured) and bypasses the firewall; everything else is denied. | Deny-by-default public endpoint + Private Endpoint. Not "no public endpoint", but no anonymous/keyless public path. | **~$80/mo** for the standard 1‑SU job; networking is free. |
| **`dedicatedCluster`** *(opt-in, fully private)* | ASA runs in a **dedicated cluster** with a **managed private endpoint** into the namespace. The namespace keeps `publicNetworkAccess = Disabled` (private-link only). | Fully private — no public endpoint at all. | **~$2,890/mo fixed** — the ASA dedicated cluster has a **36 streaming-unit minimum** × ~$0.11/SU‑hr × 730 hr, billed regardless of event volume. |

> ⚠️ **Cost cliff.** `dedicatedCluster` is the only way to keep the namespace
> fully private *and* use ASA, but the ~$2,890/mo cluster floor is fixed even for
> tiny audit-log volumes. Confirm this is acceptable before choosing it. The
> cluster + managed PE resources are **not yet provisioned** in the Bicep — when
> approved, they must be added and the job bound to the cluster. Until then a
> `dedicatedCluster` deployment will not connect to the namespace.

ASA uses managed identity, so after deployment ensure the job's identity holds
**Azure Event Hubs Data Receiver** (raw hub) and **Data Sender** (filtered hub)
roles — these are created by `streamanalytics.bicep`. Then start the job:

```powershell
az stream-analytics job start -g "rg-entraaudit-prod" -n "asa-<namePrefix>" `
  --output-start-mode JobStartTime
```

---

## 7a. Optional — enable the sign-in/risk alerting probe *(off by default)*

> **This is an opt-in internal security probe, not part of the customer
> deliverable.** It is **disabled by default** (`deploySignInPipeline = false`).
> Leave it off for the customer deployment. Enable it only in an environment
> where *you* want an internal mailbox to receive sign-in/risk alerts (it is
> pre-enabled in `main.dev.bicepparam` / `main.test.bicepparam`). The primary
> MFA-change pipeline is unaffected either way — see
> [architecture §10](architecture.md#10-optional-sign-inrisk-alerting-pipeline-off-by-default).

**1. Enable it in your parameter file:**

```bicep
param deploySignInPipeline = true
param alertRecipientAddress = 'you@yourtenant.onmicrosoft.com'  // required
```

**2. Deploy** — same `az deployment group create` command as §3 (the new
resources are additive and fully isolated: own consumer group `asa-signin-cg`,
hub `insights-logs-signin-filtered`, ASA job `asa-signin-<prefix>`, Logic App
`logic-signin-<prefix>`, plan, identity and subnet `snet-logicapp2`).

> If the namespace has `disableLocalAuth` re-forced to `true` by governance
> policy after the write, re-assert it: `az eventhubs namespace update -g <rg> -n
> evhns-<prefix> --disable-local-auth false` (the Azure Monitor SAS delivery to
> the raw hub depends on it — see [architecture §8](architecture.md#8-known-constraints)).

**3. Start the second ASA job** (ARM creates it `Stopped`; the query is only
validated at start):

```powershell
az stream-analytics job start -g "<rg>" -n "asa-signin-<namePrefix>" `
  --output-start-mode JobStartTime
```

**4. Deploy the second workflow's code** to `logic-signin-<prefix>` (the
`signinprocessor` azd service, or `func azure functionapp publish` from a
VNet-connected host — same mechanics as §6).

**5. Validate** — a risky/failed sign-in or risk detection in the tenant should
produce an alert email to `alertRecipientAddress` within a few minutes.

**To turn it off / tear it down:** set `deploySignInPipeline = false` and
redeploy (the conditional modules are removed), or delete the `*-signin-*`
resources directly. The customer pipeline is untouched.

---

## 8. Validation

1. **Trigger a test event** — in a test account, change a security method
   (e.g. add/remove a phone number) at <https://aka.ms/mysecurityinfo>.
2. **Watch the run** — Logic App → **Workflows** → `LogsProcessor` → **Run
   history**. Confirm the trigger fired and `Send_email` succeeded.
3. **Confirm delivery** — the test user receives the security-notification email
   from the ACS sender address.
4. **Telemetry** — check Application Insights / Log Analytics
   (`log-<namePrefix>`) for traces and the Event Hub diagnostics.

---

## 9. Rollback / teardown

- **Re-run** the deployment to converge configuration (idempotent).
- **Disable** intake by removing/disabling the Entra Diagnostic Setting (stops
  new events immediately).
- **Full teardown**:

  ```powershell
  az group delete -n "rg-entraaudit-prod" --yes --no-wait
  ```

  Then remove the tenant-level Entra Diagnostic Setting separately (it is not in
  the resource group).

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| No runs triggered | Diagnostic Setting missing or pointed at wrong hub | Verify §7; with ASA off, point Entra at the **filtered** hub |
| `Send_email` fails (401/403) | Logic App identity missing **Contributor** on the ACS resource, or App Insights/EH RBAC not yet propagated | Confirm the Logic App managed identity holds **Contributor** on the Communication Services resource; the workflow calls the ACS REST API with managed identity (no key) |
| Email rejected / not delivered | Sender domain not verified or MailFrom mismatch | Verify §4; set the `acs_sender` app setting to a sender from a verified domain |
| `func publish` fails | Site is private | Publish from VNet-connected host or use Kudu PE |
| EH consume fails | Missing RBAC | Confirm Logic App identity has **Event Hubs Data Receiver** on the namespace |
| Private DNS not resolving | PE/DNS zone link issue | Confirm the 6 private DNS zones are VNet-linked and PEs have zone groups |
