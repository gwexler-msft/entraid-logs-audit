// ============================================================================
// main.bicep  —  EntraIdLogsAudit
// Deploys the full, network-locked-down solution into a resource group:
//   Entra AuditLogs -> (Diag Settings) -> RAW Event Hub
//        -> [optional] Stream Analytics filter -> FILTERED Event Hub
//        -> Logic App Standard -> ACS Email
// Everything is private by default: public network access is disabled on the
// data/compute plane and all PaaS traffic flows over Private Endpoints.
// ============================================================================

targetScope = 'resourceGroup'

@description('Azure region for regional resources.')
param location string = resourceGroup().location

@description('Short resource name prefix, e.g. cf-entraaudit-prod.')
@minLength(3)
@maxLength(30)
param namePrefix string

@description('Environment tag value (dev | test | prod).')
param environmentName string = 'prod'

@description('VNet address space.')
param vnetAddressPrefix string = '10.50.0.0/16'

@description('Private endpoint subnet prefix.')
param privateEndpointSubnetPrefix string = '10.50.1.0/24'

@description('Logic App VNet-integration subnet prefix.')
param logicAppSubnetPrefix string = '10.50.2.0/24'

@description('Second (sign-in/risk) Logic App VNet-integration subnet prefix.')
param signInLogicAppSubnetPrefix string = '10.50.3.0/24'

@description('Workflow Standard plan SKU.')
@allowed([ 'WS1', 'WS2', 'WS3' ])
param planSku string = 'WS1'

@description('Deploy the Azure Stream Analytics pre-filter job (raw hub -> filtered hub). On by default so the Logic App only ever processes pre-filtered security-info events.')
param deployStreamAnalytics bool = true

@description('Deploy the parallel sign-in/risk alerting pipeline (second ASA job + second filtered hub + second Logic App that emails an internal recipient). OPT-IN, off by default: this is an internal security probe, not part of the customer deliverable. Fully isolated from the customer pipeline (own consumer group, hub, plan and app). Enable per-environment (see main.test/dev.bicepparam) when you want sign-in/risk telemetry.')
param deploySignInPipeline bool = false

@description('Recipient mailbox for sign-in/risk alert emails (required when deploySignInPipeline = true).')
param alertRecipientAddress string = ''

@description('Optional SOC / security-team mailbox to BCC on every MFA / security-info change notification emitted by the customer LogsProcessor pipeline. Leave empty (default) to email only the affected end user.')
param socRecipientAddress string = ''

@description('How the Stream Analytics job reaches the private Event Hubs namespace. firewallException (default): keep the namespace deny-by-default but allow the ASA trusted Microsoft service to bypass the firewall via managed identity (low cost). dedicatedCluster: fully private via an ASA dedicated cluster + managed private endpoint (opt-in, significant fixed monthly cost — see docs).')
@allowed([ 'firewallException', 'dedicatedCluster' ])
param asaConnectivityMode string = 'firewallException'

@description('Use the Azure-managed ACS email domain (true) or a custom domain (false).')
param useAzureManagedDomain bool = true

@description('Custom ACS sender domain when useAzureManagedDomain = false.')
param customDomainName string = ''

@description('Override the generated backing storage account name (optional).')
param storageAccountNameOverride string = ''

@description('Additional resource tags.')
param extraTags object = {}

var tags = union({
  solution: 'EntraIdLogsAudit'
  environment: environmentName
  managedBy: 'bicep'
}, extraTags)

var storageAccountName = empty(storageAccountNameOverride)
  ? 'st${take(uniqueString(resourceGroup().id, namePrefix), 20)}'
  : storageAccountNameOverride

// The content file share name must match the site name the Logic App expects.
var contentShareName = toLower('logic-${namePrefix}')

// Dedicated content share for the second (sign-in/risk) Logic App.
var signInContentShareName = toLower('logic-signin-${namePrefix}')

// 1) Network -----------------------------------------------------------------
module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    namePrefix: namePrefix
    vnetAddressPrefix: vnetAddressPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    logicAppSubnetPrefix: logicAppSubnetPrefix
    signInLogicAppSubnetPrefix: signInLogicAppSubnetPrefix
    tags: tags
  }
}

// 2) Monitoring --------------------------------------------------------------
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
  }
}

// 3) Event Hubs --------------------------------------------------------------
module eventHubs 'modules/eventhubs.bicep' = {
  name: 'eventHubs'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    logicAppSubnetId: network.outputs.logicAppSubnetId
    eventHubDnsZoneId: network.outputs.eventHubDnsZoneId
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    // Open the namespace firewall to the ASA trusted service only when ASA is
    // deployed in firewallException mode; otherwise stay private-link-only.
    allowTrustedAsaAccess: deployStreamAnalytics && asaConnectivityMode == 'firewallException'
    deploySignInPipeline: deploySignInPipeline
  }
}

// 4) Storage -----------------------------------------------------------------
module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    storageAccountName: storageAccountName
    tags: tags
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    logicAppSubnetId: network.outputs.logicAppSubnetId
    blobDnsZoneId: network.outputs.blobDnsZoneId
    fileDnsZoneId: network.outputs.fileDnsZoneId
    queueDnsZoneId: network.outputs.queueDnsZoneId
    tableDnsZoneId: network.outputs.tableDnsZoneId
    contentShareName: contentShareName
    signInContentShareName: deploySignInPipeline ? signInContentShareName : ''
  }
}

// 5) ACS + Email -------------------------------------------------------------
module acs 'modules/acs.bicep' = {
  name: 'acs'
  params: {
    namePrefix: namePrefix
    tags: tags
    useAzureManagedDomain: useAzureManagedDomain
    customDomainName: customDomainName
  }
}

// 6) Logic App Standard ------------------------------------------------------
module logicApp 'modules/logicapp.bicep' = {
  name: 'logicApp'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    planSku: planSku
    storageAccountName: storage.outputs.storageAccountName
    logicAppSubnetId: network.outputs.logicAppSubnetId
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    sitesDnsZoneId: network.outputs.sitesDnsZoneId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    eventHubNamespaceFqdn: eventHubs.outputs.namespaceFqdn
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    acsEndpoint: 'https://${acs.outputs.communicationServiceHostName}'
    acsSenderAddress: acs.outputs.senderAddress
    socRecipientAddress: socRecipientAddress
    contentShareName: storage.outputs.contentShareName
  }
}

// 7) RBAC --------------------------------------------------------------------
module rbac 'modules/rbac.bicep' = {
  name: 'rbac'
  params: {
    logicAppPrincipalId: logicApp.outputs.principalId
    storageIdentityPrincipalId: logicApp.outputs.storageIdentityPrincipalId
    eventHubNamespaceName: eventHubs.outputs.namespaceName
    storageAccountName: storage.outputs.storageAccountName
    communicationServiceName: acs.outputs.communicationServiceName
    appInsightsName: monitoring.outputs.appInsightsName
  }
}

// 9) Stream Analytics (raw -> filtered pre-filter; on by default) ------------
// NOTE: the standard ASA job below reaches the Event Hubs namespace via the
// trusted-service firewall bypass (asaConnectivityMode = 'firewallException').
// The fully-private 'dedicatedCluster' mode (ASA dedicated cluster + managed
// private endpoint) is documented in docs/deployment-guide.md but the cluster
// resources are intentionally NOT provisioned here yet (significant fixed cost,
// ~$2,890/mo). When that mode is approved, add the cluster + managed PE and bind
// this job to it; until then a 'dedicatedCluster' deployment will not connect
// to the PNA-disabled namespace.
module streamAnalytics 'modules/streamanalytics.bicep' = if (deployStreamAnalytics) {
  name: 'streamAnalytics'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    eventHubNamespaceName: eventHubs.outputs.namespaceName
    rawHubName: eventHubs.outputs.rawHubName
    filteredHubName: eventHubs.outputs.filteredHubName
  }
}

// 10) Sign-in/risk pipeline (parallel, isolated) -----------------------------
// Second ASA job reads the SAME raw hub via its own consumer group and writes
// to a SEPARATE filtered hub; a second Logic App emails an internal recipient.
module streamAnalyticsSignIn 'modules/streamanalytics-signin.bicep' = if (deploySignInPipeline) {
  name: 'streamAnalyticsSignIn'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    eventHubNamespaceName: eventHubs.outputs.namespaceName
    rawHubName: eventHubs.outputs.rawHubName
    signInFilteredHubName: eventHubs.outputs.signInFilteredHubName
  }
}

module logicAppSignIn 'modules/logicapp-signin.bicep' = if (deploySignInPipeline) {
  name: 'logicAppSignIn'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    planSku: planSku
    storageAccountName: storage.outputs.storageAccountName
    logicAppSubnetId: network.outputs.signInLogicAppSubnetId
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    sitesDnsZoneId: network.outputs.sitesDnsZoneId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    eventHubNamespaceFqdn: eventHubs.outputs.namespaceFqdn
    logAnalyticsId: monitoring.outputs.logAnalyticsId
    acsEndpoint: 'https://${acs.outputs.communicationServiceHostName}'
    acsSenderAddress: acs.outputs.senderAddress
    alertRecipientAddress: alertRecipientAddress
    contentShareName: storage.outputs.signInContentShareName
  }
}

module rbacSignIn 'modules/rbac-signin.bicep' = if (deploySignInPipeline) {
  name: 'rbacSignIn'
  params: {
    logicAppPrincipalId: logicAppSignIn!.outputs.principalId
    storageIdentityPrincipalId: logicAppSignIn!.outputs.storageIdentityPrincipalId
    eventHubNamespaceName: eventHubs.outputs.namespaceName
    storageAccountName: storage.outputs.storageAccountName
    communicationServiceName: acs.outputs.communicationServiceName
    appInsightsName: monitoring.outputs.appInsightsName
  }
}

// ---- Outputs ---------------------------------------------------------------
output logicAppName string = logicApp.outputs.siteName
output logicAppPrincipalId string = logicApp.outputs.principalId
output eventHubNamespaceName string = eventHubs.outputs.namespaceName
output rawHubName string = eventHubs.outputs.rawHubName
output filteredHubName string = eventHubs.outputs.filteredHubName
output rawSendRuleId string = eventHubs.outputs.rawSendRuleId
output communicationServiceName string = acs.outputs.communicationServiceName
output storageAccountName string = storage.outputs.storageAccountName
output logAnalyticsId string = monitoring.outputs.logAnalyticsId
output signInFilteredHubName string = eventHubs.outputs.signInFilteredHubName
output signInLogicAppName string = deploySignInPipeline ? logicAppSignIn!.outputs.siteName : ''
