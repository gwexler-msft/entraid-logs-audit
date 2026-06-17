// ============================================================================
// logicapp-signin.bicep  (OPTIONAL - deploySignInPipeline flag in main)
// Second, fully isolated Logic App Standard for the sign-in / risk alerting
// pipeline. Identical lock-down posture to logicapp.bicep but:
//  - Its own plan, site, user-assigned identity and content share
//  - Its own VNet-integration subnet (a subnet can serve only ONE WS plan)
//  - Reads the SEPARATE sign-in filtered hub and emails an internal recipient
// The customer pipeline (logicapp.bicep) is never touched.
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

@description('Backing storage account name (shared with the customer app, isolated by content share).')
param storageAccountName string

@description('Sign-in Logic App regional VNet integration subnet id (must be distinct from the customer app subnet).')
param logicAppSubnetId string

@description('Private Endpoint subnet id.')
param privateEndpointSubnetId string

@description('Private DNS zone id for privatelink.azurewebsites.net.')
param sitesDnsZoneId string

@description('Application Insights connection string.')
param appInsightsConnectionString string

@description('Fully qualified DNS name of the Event Hubs namespace.')
param eventHubNamespaceFqdn string

@description('Log Analytics workspace id for diagnostic settings.')
param logAnalyticsId string

@description('ACS endpoint base URL (https://<acs>.<region>.communication.azure.com).')
param acsEndpoint string

@description('DoNotReply sender address provisioned on the ACS email domain.')
param acsSenderAddress string

@description('Recipient mailbox for sign-in / risk alert emails.')
param alertRecipientAddress string

@description('Pre-created content file share name dedicated to this app.')
param contentShareName string

var siteName = 'logic-signin-${namePrefix}'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// Dedicated user-assigned identity for the Data.Edge storage engine (see the
// matching note in logicapp.bicep).
resource storageIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-signin-${namePrefix}'
  location: location
  tags: tags
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'plan-signin-${namePrefix}'
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
  // 'azd-service-name' lets `azd deploy` discover this site as the
  // 'signinprocessor' service (see azure.yaml) and push the workflow code.
  tags: union(tags, { 'azd-service-name': 'signinprocessor' })
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
        { name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', value: 'Authorization=AAD' }
        { name: 'AzureWebJobsStorage__accountName', value: storageAccountName }
        { name: 'AzureWebJobsStorage__blobServiceUri', value: storage.properties.primaryEndpoints.blob }
        { name: 'AzureWebJobsStorage__queueServiceUri', value: storage.properties.primaryEndpoints.queue }
        { name: 'AzureWebJobsStorage__tableServiceUri', value: storage.properties.primaryEndpoints.table }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__credentialType', value: 'managedIdentity' }
        { name: 'AzureWebJobsStorage__managedIdentityResourceId', value: storageIdentity.id }
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
        { name: 'alert_recipient', value: alertRecipientAddress }
      ]
    }
  }
}

resource sitePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pep-signin-${namePrefix}-site'
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
