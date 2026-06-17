# EntraIdLogsAudit — Operations Runbook

Day-2 operations, monitoring, and incident response for the EntraIdLogsAudit
solution. For design see [architecture.md](architecture.md); for first-time
setup see [deployment-guide.md](deployment-guide.md).

---

## 1. Service overview

| Item | Value |
|------|-------|
| What it does | Emails users when their Entra security info (MFA) changes |
| Trigger | Filtered Event Hub `insights-logs-auditlogs-filtered` |
| Compute | Logic App Standard `logic-<namePrefix>` (plan `plan-<namePrefix>`) |
| Email | ACS `acs-<namePrefix>` + Email service `acs-email-<namePrefix>` |
| Telemetry | Log Analytics `log-<namePrefix>`, App Insights `appi-<namePrefix>` |
| Network | VNet `vnet-<namePrefix>`, all PaaS via Private Endpoints |

> **Optional sign-in/risk probe (off by default).** If `deploySignInPipeline =
> true` (internal probe environments only), a **parallel, isolated** pipeline
> also runs: ASA `asa-signin-<namePrefix>`, Logic App `logic-signin-<namePrefix>`
> (plan `plan-signin-<namePrefix>`), filtered hub `insights-logs-signin-filtered`,
> reading the raw hub via consumer group `asa-signin-cg` and emailing
> `alertRecipientAddress`. It is **not part of the customer deliverable** and does
> not affect the MFA-change pipeline. Health-check and operate it exactly like the
> primary app using its `*-signin-*` resource names. To stop alerts without
> tearing down, stop the `asa-signin-<namePrefix>` job; to remove it entirely set
> `deploySignInPipeline = false` and redeploy. See
> [architecture §10](architecture.md#10-optional-sign-inrisk-alerting-pipeline-off-by-default).

---

## 2. Health checks

**Is it running?**

```powershell
$rg = "rg-entraaudit-prod"; $site = "logic-<namePrefix>"
az webapp show -g $rg -n $site --query "{state:state, https:httpsOnly, pna:publicNetworkAccess}" -o table
```

**Recent workflow runs** — Portal → Logic App → **Workflows** → `LogsProcessor`
→ **Run history**. Healthy = trigger fires on events; `Send_email` succeeds for
security-info changes; non-matching events end without sending.

**Event flow** — Portal → Event Hubs namespace → the hubs → **Metrics**:
- Raw hub `insights-logs-auditlogs`: `Incoming Messages` > 0 when Entra is active.
- Filtered hub `insights-logs-auditlogs-filtered`: `Outgoing Messages` consumed by
  the Logic App.

---

## 3. Monitoring queries (Log Analytics)

Workflow failures in the last 24h:

```kusto
union *
| where TimeGenerated > ago(24h)
| where Category has "Workflow" and (Level == "Error" or status_s == "Failed")
| project TimeGenerated, OperationName, resource_workflowName_s, status_s, error_message_s
| order by TimeGenerated desc
```

Emails sent (trace-based, adjust to your instrumentation):

```kusto
traces
| where timestamp > ago(7d)
| where message has "Send_email"
| summarize count() by bin(timestamp, 1h)
| render timechart
```

> Recommended alerts: (a) any workflow run failure, (b) zero incoming messages on
> the raw hub for N hours during business hours (intake broken), (c) ACS send
> failures.

---

## 4. Common incidents

### 4.1 No emails are being sent

1. **Are events arriving?** Check raw hub `Incoming Messages`. If zero → the Entra
   **Diagnostic Setting** is missing/disabled or points at the wrong hub. Re-check
   deployment guide §7.
2. **Is the workflow triggering?** Run history empty → confirm the Logic App is
   reading the **filtered** hub and the consumer group exists.
3. **Is `Send_email` failing?** See 4.2.

### 4.2 `Send_email` action fails

| Error | Cause | Action |
|-------|-------|--------|
| 401 / 403 | Logic App managed identity missing **Contributor** on the ACS resource, or RBAC not yet propagated | Confirm the role assignment in [`rbac.bicep`](../infra/modules/rbac.bicep); the workflow calls the ACS REST API with managed identity (no key) |
| Domain / sender error | Sender domain not verified or MailFrom mismatch | Verify ACS domain; set the `acs_sender` app setting to a sender from a verified domain |
| Throttled | ACS send-rate limits | Review ACS quotas; batch/limit triggering |

### 4.3 Private connectivity problems

- Confirm the 6 **private DNS zones** are VNet-linked and each Private Endpoint
  has a `default` DNS zone group.
- Confirm the Logic App is **VNet-integrated** (`virtualNetworkSubnetId` set) with
  `vnetRouteAllEnabled`.
- From a VNet-connected host, resolve `<namespace>.servicebus.windows.net` and the
  storage/site FQDNs — they should return **private** IPs.

### 4.4 Suspected real account-takeover (user replies "I didn't do this")

This is the intended detection path. Follow IR process: lock/disable the account,
revoke sessions/tokens, reset credentials and MFA, and investigate the
`initiatedBy` actor from the audit event. Escalate to `#IncidentGroup@example.com`.
### 4.5 No events in *either* hub (whole pipeline dark)

**Symptom:** the raw hub `insights-logs-auditlogs` shows **0 Incoming Messages**
(it normally receives tens of messages/hour), Stream Analytics has no input, the
filtered hub is empty, and the Logic App never triggers.

**Most likely cause — governance policy disabled Event Hub local auth.** The org
assignment `MCAPSGovDeployPolicies` carries a `modify`-effect policy
(`EventHub_DisableLocalAuth_Modify`) that forces `disableLocalAuth = true` on the
namespace **and re-applies on every write** (so a redeploy or any namespace update
can silently re-trigger it). Azure Monitor diagnostic settings deliver to Event
Hubs **only via the SAS rule** `RootManageSharedAccessKey` — with local auth
disabled, that delivery is rejected and intake stops. See architecture §8 for the
full rationale.

**Check:**

```powershell
$ns='evhns-cf-entraaudit-test'; $rg='rg-entraaudit-test'
az eventhubs namespace show -g $rg -n $ns --query disableLocalAuth -o tsv   # want: false
# confirm the exemption still covers Event Hubs:
az policy exemption show --name exempt-entraaudit-test-shared-key -g $rg `
  --query policyDefinitionReferenceIds -o json   # must include 'eventhubdisablelocalauth'
```

**Fix:**

```powershell
# 1) ensure the exemption waives BOTH local-auth policies
az policy exemption update --name exempt-entraaudit-test-shared-key -g $rg `
  --policy-definition-reference-ids StorageAccountDisableLocalAuth eventhubdisablelocalauth
# 2) re-assert local auth on the namespace (now sticks because the exemption applies)
az eventhubs namespace update -g $rg -n $ns --disable-local-auth false
```

Intake resumes within a few minutes; confirm via raw-hub `Incoming Messages`.

> ⚠️ This shared-key dependency is under customer review (see architecture §8).
> If the customer disallows the Event Hub SAS key, tenant-log export must move to
> a different architecture — escalate before removing the exemption.
---

### 4.6 Logic App host runtime in `Error` (storage credential invalid)

**Symptom:** the Logic App **Overview** shows a runtime error, the host status
reports `state = Error` with
`Microsoft.Azure.Workflows.Data.Edge: The authentication credential type for the
storage account isn't valid`, and every workflow trigger/run call returns
`Encountered an error (ServiceUnavailable) from host runtime`. The site itself is
`Running` and resource health is `Available` — only the workflow data plane is down.

**Cause.** The workflow data engine (`Data.Edge`) only authenticates to
`AzureWebJobsStorage` with a **user-assigned** managed identity; it ignores the
system-assigned one. It requires `AzureWebJobsStorage__credentialType =
managedIdentity` (camelCase) **and** `AzureWebJobsStorage__managedIdentityResourceId`
pointing at a user-assigned identity that holds the storage data-plane roles.

**Check:**

```powershell
$rg='rg-entraaudit-test'; $app='logic-cf-entraaudit-test'
$sub='f5d37d62-c374-4dd0-a34a-e6012752ffb9'
az rest --method get --uri "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/sites/$app/hostruntime/admin/host/status?api-version=2018-11-01" --query "{state:state,errors:errors}" -o json
az webapp config appsettings list -g $rg -n $app `
  --query "[?starts_with(name,'AzureWebJobsStorage__credential') || name=='AzureWebJobsStorage__managedIdentityResourceId'].{name:name,value:value}" -o table
```

**Fix.** This is provisioned by `infra/modules/logicapp.bicep` (the `id-<prefix>`
user-assigned identity) + `rbac.bicep` (its storage roles). A clean redeploy
restores it. To repair in place:

```powershell
$uami = az identity show -g $rg -n id-cf-entraaudit-test --query id -o tsv
az webapp identity assign -g $rg -n $app --identities $uami
az webapp config appsettings set -g $rg -n $app --settings `
  "AzureWebJobsStorage__credentialType=managedIdentity" `
  "AzureWebJobsStorage__managedIdentityResourceId=$uami"
az webapp restart -g $rg -n $app
```

Wait ~60 s, then re-check host status — `state` should return to `Running` with no
errors.
---

## 5. Routine operations

### Connectivity is key-less (no key rotation needed)

All service connectivity uses the Logic App's **managed identity** + Azure RBAC —
Event Hubs, storage (`AzureWebJobsStorage`), ACS Email (REST API), and App
Insights ingestion. There are **no** connection keys or strings to rotate. The
only shared key is the WS-plan content share
(`WEBSITE_CONTENTAZUREFILECONNECTIONSTRING`), regenerated automatically at each
Bicep deploy via `storage.listKeys()` (see architecture.md §8). If you ever
rotate the storage account keys manually, re-run the infra deploy so the content
share string is refreshed.

### View Event Hub events (temporary, manual)

The Event Hubs namespace is **deny-by-default** and **local auth is disabled**, so
the portal Data Explorer cannot browse events out of the box. To inspect events
you need **both** a network path (firewall IP rule) **and** a data path
(Entra RBAC). This is a deliberate, opt-in operator step — revert it when done.

1. **Grant your user the data role** (once per operator):

   ```powershell
   $rg='rg-entraaudit-prod'; $ns='evhns-<namePrefix>'
   $oid = az ad signed-in-user show --query id -o tsv
   $nsId = az eventhubs namespace show -g $rg -n $ns --query id -o tsv
   az role assignment create --assignee $oid --role "Azure Event Hubs Data Receiver" --scope $nsId
   ```

2. **Add your client IP to the namespace firewall:**

   ```powershell
   $myip = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json').ip
   az eventhubs namespace network-rule-set ip-rule add -g $rg --namespace-name $ns --ip-rule ip-address=$myip action=Allow
   ```

3. **Browse:** Portal → Event Hubs namespace → the hub → **Data Explorer** →
   click **"Switch to Microsoft Entra authentication"** (this uses *your* identity;
   it is expected because key/local auth is disabled) → pick a partition +
   `$Default` consumer group → **View events**.
   - Security-info changes land in `insights-logs-auditlogs-filtered`; raw events
     (if Diagnostic Settings target it) land in `insights-logs-auditlogs`.

   > **The "Switch to Microsoft Entra authentication" click cannot be automated.**
   > It is not a resource setting — it is a per-session choice the portal Data
   > Explorer UI makes about how *your browser session* authenticates. It only
   > appears because local/key auth is disabled on the namespace (by design), so
   > the portal must use your signed-in identity. There is no Bicep/CLI property to
   > pre-set it; clicking it is the operator action. The two infrastructure parts
   > (firewall IP rule and Data Receiver RBAC) *are* scriptable — see steps 1–2.

4. **Revert when finished** (restores deny-by-default + least privilege):

   ```powershell
   az eventhubs namespace network-rule-set ip-rule remove -g $rg --namespace-name $ns --ip-rule ip-address=$myip action=Allow
   az role assignment delete --assignee $oid --role "Azure Event Hubs Data Receiver" --scope $nsId
   ```

   > The firewall IP rule is **not** in the Bicep, so the next infra deploy also
   > removes it automatically. The RBAC assignment is a separate object — remove
   > it manually with the command above.

### View Event Hub events headlessly (no portal, fully scriptable)

To avoid the portal entirely (and the manual Entra-auth click), read events with
the SDK using `DefaultAzureCredential` — this authenticates with your `az login`
context or a managed identity, so no keys and no UI. You still need the firewall
IP rule (step 1 above) and **Data Receiver** RBAC (step 2 above). Example
(PowerShell + .NET SDK, peeks recent events without committing offsets):

```powershell
# Requires: dotnet-script or a small console app referencing Azure.Messaging.EventHubs
# dotnet add package Azure.Messaging.EventHubs ; using Azure.Identity
$fqdn = "evhns-<namePrefix>.servicebus.windows.net"   # .servicebus.usgovcloudapi.net in Gov
$hub  = "insights-logs-auditlogs-filtered"
# In C#:
#   var consumer = new EventHubConsumerClient(
#       EventHubConsumerClient.DefaultConsumerGroupName, fqdn, hub, new DefaultAzureCredential());
#   await foreach (var pe in consumer.ReadEventsAsync(new ReadEventOptions { MaximumWaitTime = TimeSpan.FromSeconds(5) }))
#       Console.WriteLine(pe.Data.EventBody.ToString());
```

> This is the recommended path for automation/CI or for operators who prefer a
> command line. The portal Data Explorer is only a convenience for ad-hoc viewing.

### Pause / resume intake

- **Pause:** disable the Entra Diagnostic Setting (stops new events).
- **Resume:** re-enable it.

### Update workflow logic

Edit [`LogsProcessor/LogsProcessor/workflow.json`](../LogsProcessor/LogsProcessor/workflow.json),
test locally, then redeploy with `func azure functionapp publish <logicAppName> --no-build`
(deployment guide §6). Commit changes to git.

### Update infrastructure

Edit Bicep under [`infra/`](../infra/), run `what-if`, then redeploy
(idempotent). See deployment guide §3.

---

## 6. Change-control checklist

- [ ] Change tested in `dev` / `test` (`main.dev.bicepparam` / `main.test.bicepparam`)
- [ ] `az deployment group what-if` reviewed
- [ ] Workflow run validated with a test MFA change
- [ ] Email delivery confirmed
- [ ] Changes committed to git with a descriptive message
- [ ] Secrets kept out of source control

---

## 7. Escalation

| Tier | Contact |
|------|---------|
| Service desk | Ext. NNNN |
| Security incidents | `#IncidentGroup@example.com` |
