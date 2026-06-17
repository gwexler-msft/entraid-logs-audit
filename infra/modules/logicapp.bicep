// ============================================================================
// logicapp.bicep
// Logic App Standard (Workflow Standard plan) - locked down:
//  - Regional VNet integration (all traffic routed through the VNet)
//  - Inbound Private Endpoint; public network access DISABLED
//  - System-assigned managed identity
//  - Backing storage reached over Private Endpoints
// ============================================================================

@description('Azure region.')
param location string

@description('Resource name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object = {}

@description('Workflow Standard plan SKU (WS1 | WS2 | WS3).')
@allowed([ 'WS1', 'WS2', 'WS3' ])
param planSku string = 'WS1'

@description('Backing storage account name (must already exist).')
param storageAccountName string

@description('Logic App regional VNet integration subnet id.')
param logicAppSubnetId string

@description('Private Endpoint subnet id.')
param privateEndpointSubnetId string

@description('Private DNS zone id for privatelink.azurewebsites.net.')
param sitesDnsZoneId string

@description('Application Insights connection string.')
param appInsightsConnectionString string

@description('Fully qualified DNS name of the Event Hubs namespace (e.g. evhns-xxx.servicebus.windows.net). The Logic App Event Hub trigger uses managed-identity auth.')
param eventHubNamespaceFqdn string

@description('Log Analytics workspace id for diagnostic settings.')
param logAnalyticsId string

@description('ACS endpoint base URL (https://<acs>.<region>.communication.azure.com). The workflow Send_email action calls the ACS Email REST API with managed-identity auth.')
param acsEndpoint string

@description('ACS verified sender address (e.g. DoNotReply@<domain>). Surfaced to the workflow as the acs_sender app setting. Customers MUST override this with a sender from a verified email domain provisioned in their own environment.')
param acsSenderAddress string

@description('Optional SOC / security-team mailbox to BCC on every MFA / security-info change notification. Surfaced to the workflow as the alert_recipient app setting. Leave empty to email only the affected end user (default).')
param socRecipientAddress string = ''

@description('Pre-created content file share name on the backing storage account.')
param contentShareName string

var siteName = 'logic-${namePrefix}'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// Identity-based storage: the Logic App's system-assigned managed identity is
// granted Storage Blob/Queue/Table Data + File SMB + Account Contributor roles
// in rbac.bicep. The runtime uses AzureWebJobsStorage__accountName + the
// pre-created file share (no shared-key connection strings anywhere).
//
// The newer workflow data engine (Microsoft.Azure.Workflows.Data.Edge) only
// honors a USER-assigned identity for AzureWebJobsStorage (it ignores the
// system-assigned one and demands AzureWebJobsStorage__managedIdentityResourceId).
// We therefore create a dedicated user-assigned identity, attach it to the site,
// and grant it the same storage roles (see rbac.bicep). The classic WebJobs host
// continues to use the system-assigned identity via AzureWebJobsStorage__credential.
resource storageIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${namePrefix}'
  location: location
  tags: tags
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'plan-${namePrefix}'
  location: location
  tags: tags
  sku: {
    name: planSku
    tier: 'WorkflowStandard'
  }
  properties: {
    elasticScaleEnabled: true
    maximumElasticWorkerCount: 20
    zoneRedundant: false
  }
}

resource site 'Microsoft.Web/sites@2023-12-01' = {
  name: siteName
  location: location
  // 'azd-service-name' lets `azd deploy` discover this site as the 'logsprocessor'
  // service (see azure.yaml) and push the workflow code to it.
  tags: union(tags, { 'azd-service-name': 'logsprocessor' })
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${storageIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: logicAppSubnetId
    vnetRouteAllEnabled: true
    vnetContentShareEnabled: true
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      vnetRouteAllEnabled: true
      http20Enabled: true
      use32BitWorkerProcess: false
      appSettings: [
        { name: 'APP_KIND', value: 'workflowapp' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet' }
        { name: 'AzureFunctionsJobHost__extensionBundle__id', value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows' }
        { name: 'AzureFunctionsJobHost__extensionBundle__version', value: '[1.*, 2.0.0)' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsightsConnectionString }
        // Entra-authenticated telemetry ingestion. The component has local auth
        // disabled, so the instrumentation key in the connection string is inert;
        // the host sends telemetry using the system-assigned managed identity
        // (Monitoring Metrics Publisher on the component, see rbac.bicep).
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD' }
        // Identity-based AzureWebJobsStorage (system-assigned MI). The host
        // resolves the queue/blob/table service endpoints from the supplied
        // service URIs and authenticates via Entra ID.
        { name: 'AzureWebJobsStorage__accountName', value: storageAccountName }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: storage.properties.primaryEndpoints.blob }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: storage.properties.primaryEndpoints.queue }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: storage.properties.primaryEndpoints.table }
        // Classic WebJobs host: uses the system-assigned identity.
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        // Workflow Data.Edge engine: requires a user-assigned identity (camelCase
        // value, case-sensitive). managedIdentityResourceId points at the UAMI
        // created above, which holds the storage data-plane roles (rbac.bicep).
        { name: 'AzureWebJobsStorage__credentialType', value: 'managedIdentity' }
        { name: 'AzureWebJobsStorage__managedIdentityResourceId', value: storageIdentity.id }
        // WS plan platform validation REQUIRES a literal
        // WEBSITE_CONTENTAZUREFILECONNECTIONSTRING (the __accountName/__credential
        // identity form is only honored on Flex Consumption). This single
        // shared-key setting is covered by the scoped policy exemption
        // 'exempt-entraaudit-test-shared-key' against StorageAccountDisableLocalAuth.
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}' }
        { name: 'WEBSITE_CONTENTSHARE', value: contentShareName }
        { name: 'WEBSITE_CONTENTOVERVNET', value: '1' }
        { name: 'WEBSITE_VNET_ROUTE_ALL', value: '1' }
        { name: 'WORKFLOWS_SUBSCRIPTION_ID', value: subscription().subscriptionId }
        { name: 'WORKFLOWS_RESOURCE_GROUP_NAME', value: resourceGroup().name }
        { name: 'WORKFLOWS_LOCATION_NAME', value: location }
        { name: 'eventHub_fullyQualifiedNamespace', value: eventHubNamespaceFqdn }
        { name: 'acs_endpoint', value: acsEndpoint }
        { name: 'acs_sender', value: acsSenderAddress }
        { name: 'alert_recipient', value: socRecipientAddress }
      ]
    }
  }
}

resource sitePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pep-${namePrefix}-site'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'sites'
        properties: {
          privateLinkServiceId: site.id
          groupIds: [ 'sites' ]
        }
      }
    ]
  }
}

resource siteDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: sitePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sites'
        properties: { privateDnsZoneId: sitesDnsZoneId }
      }
    ]
  }
}

resource siteDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: site
  properties: {
    workspaceId: logAnalyticsId
    logs: [
      { categoryGroup: 'allLogs', enabled: true }
    ]
    metrics: [
      { category: 'AllMetrics', enabled: true }
    ]
  }
}

output siteName string = site.name
output siteId string = site.id
output principalId string = site.identity.principalId
output storageIdentityPrincipalId string = storageIdentity.properties.principalId
output defaultHostName string = site.properties.defaultHostName
