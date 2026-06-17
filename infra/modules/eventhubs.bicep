// ============================================================================
// eventhubs.bicep
// Event Hubs namespace with RAW and FILTERED hubs.
//  - Public network access DISABLED (reachable only via Private Endpoint)
//  - Dedicated consumer groups for Stream Analytics and the Logic App
//  - Listen-only SAS rule on the filtered hub for the Logic App trigger
// ============================================================================

@description('Azure region.')
param location string

@description('Resource name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object = {}

@description('Raw hub name - receives the full Entra AuditLogs stream.')
param rawHubName string = 'insights-logs-auditlogs'

@description('Filtered hub name - consumed by the Logic App trigger.')
param filteredHubName string = 'insights-logs-auditlogs-filtered'

@description('Deploy the second (sign-in/risk) filtered hub + consumer group consumed by the parallel sign-in alerting pipeline.')
param deploySignInPipeline bool = false

@description('Sign-in/risk filtered hub name - consumed by the second Logic App trigger.')
param signInFilteredHubName string = 'insights-logs-signin-filtered'

@description('Message retention (days) for both hubs.')
param messageRetentionInDays int = 1

@description('Partition count for both hubs.')
param partitionCount int = 4

@description('Private Endpoint subnet resource id.')
param privateEndpointSubnetId string

@description('Logic App VNet-integration subnet resource id (used as a network rule when the firewall is opened to trusted services).')
param logicAppSubnetId string = ''

@description('Open the namespace firewall (deny-by-default) to the Azure Stream Analytics trusted Microsoft service. When false the namespace stays private-link-only (publicNetworkAccess = Disabled).')
param allowTrustedAsaAccess bool = false

@description('Private DNS zone id for privatelink.servicebus.windows.net.')
param eventHubDnsZoneId string

@description('Log Analytics workspace id for diagnostic settings.')
param logAnalyticsId string

resource ehNamespace 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: 'evhns-${namePrefix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    minimumTlsVersion: '1.2'
    // Private-link-only by default. When ASA runs in firewallException mode the
    // namespace must expose a (deny-by-default) public endpoint so the ASA
    // trusted Microsoft service can bypass the firewall via managed identity;
    // the network rule set below enforces deny + trusted-service-only access.
    publicNetworkAccess: allowTrustedAsaAccess ? 'Enabled' : 'Disabled'
    disableLocalAuth: false
    zoneRedundant: false
  }
}

resource rawHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: ehNamespace
  name: rawHubName
  properties: {
    messageRetentionInDays: messageRetentionInDays
    partitionCount: partitionCount
  }
}

resource filteredHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: ehNamespace
  name: filteredHubName
  properties: {
    messageRetentionInDays: messageRetentionInDays
    partitionCount: partitionCount
  }
}

// Dedicated consumer group for the Stream Analytics filter job (reads raw).
resource asaConsumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: rawHub
  name: 'asa-filter-cg'
}

// ---------------------------------------------------------------------------
// Sign-in/risk pipeline (parallel, isolated): second filtered hub fed by a
// second ASA job that reads the SAME raw hub via its own consumer group, so
// the existing customer pipeline is never touched.
// ---------------------------------------------------------------------------
resource signInFilteredHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = if (deploySignInPipeline) {
  parent: ehNamespace
  name: signInFilteredHubName
  properties: {
    messageRetentionInDays: messageRetentionInDays
    partitionCount: partitionCount
  }
}

// Dedicated consumer group on the RAW hub for the sign-in ASA job.
resource asaSignInConsumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = if (deploySignInPipeline) {
  parent: rawHub
  name: 'asa-signin-cg'
}

// Dedicated consumer group for the Logic App (reads filtered).
resource logicAppConsumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: filteredHub
  name: 'logicapp-cg'
}

// Listen-only authorization rule on the filtered hub for the Logic App trigger.
resource filteredListenRule 'Microsoft.EventHub/namespaces/eventhubs/authorizationRules@2024-01-01' = {
  parent: filteredHub
  name: 'logicapp-listen'
  properties: {
    rights: [ 'Listen' ]
  }
}

// Send authorization rule on the raw hub for diagnostic settings ingestion.
resource rawSendRule 'Microsoft.EventHub/namespaces/eventhubs/authorizationRules@2024-01-01' = {
  parent: rawHub
  name: 'diagnostics-send'
  properties: {
    rights: [ 'Send' ]
  }
}

// Deny-by-default firewall that bypasses only the Azure Stream Analytics
// trusted Microsoft service (which authenticates with its managed identity).
// A VNet rule on the Logic App subnet ensures the namespace is never left open
// to the public internet (a rule set with no rules defaults to allow-all).
// Only created in ASA firewallException mode; otherwise the namespace stays
// private-link-only via publicNetworkAccess = Disabled.
resource ehNetworkRules 'Microsoft.EventHub/namespaces/networkRuleSets@2024-01-01' = if (allowTrustedAsaAccess) {
  parent: ehNamespace
  name: 'default'
  properties: {
    publicNetworkAccess: 'Enabled'
    defaultAction: 'Deny'
    trustedServiceAccessEnabled: true
    ipRules: []
    virtualNetworkRules: empty(logicAppSubnetId) ? [] : [
      {
        subnet: { id: logicAppSubnetId }
        ignoreMissingVnetServiceEndpoint: false
      }
    ]
  }
}

resource ehPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pep-${namePrefix}-evhns'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'evhns'
        properties: {
          privateLinkServiceId: ehNamespace.id
          groupIds: [ 'namespace' ]
        }
      }
    ]
  }
}

resource ehDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: ehPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'servicebus'
        properties: { privateDnsZoneId: eventHubDnsZoneId }
      }
    ]
  }
}

resource ehDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-to-law'
  scope: ehNamespace
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

output namespaceId string = ehNamespace.id
output namespaceName string = ehNamespace.name
output namespaceFqdn string = replace(replace(ehNamespace.properties.serviceBusEndpoint, 'https://', ''), ':443/', '')
output rawHubName string = rawHub.name
output filteredHubName string = filteredHub.name
output signInFilteredHubName string = deploySignInPipeline ? signInFilteredHub.name : ''
output filteredListenRuleId string = filteredListenRule.id
output rawSendRuleId string = rawSendRule.id
