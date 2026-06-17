// ============================================================================
// monitoring.bicep
// Log Analytics workspace + Application Insights used by the Logic App and for
// diagnostic settings of Event Hubs, Storage, and ACS.
// ============================================================================

@description('Azure region.')
param location string

@description('Resource name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object = {}

@description('Log Analytics data retention in days.')
param retentionInDays int = 90

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${namePrefix}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: retentionInDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${namePrefix}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    // Require Microsoft Entra (managed-identity) authentication for telemetry
    // ingestion. The instrumentation key in APPLICATIONINSIGHTS_CONNECTION_STRING
    // becomes inert: the Logic App host authenticates with its managed identity
    // (Monitoring Metrics Publisher role, see rbac.bicep) via the
    // APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD app setting.
    DisableLocalAuth: true
  }
}

output logAnalyticsId string = logAnalytics.id
output appInsightsName string = appInsights.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
