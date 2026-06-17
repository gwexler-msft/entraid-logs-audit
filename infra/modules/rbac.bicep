// ============================================================================
// rbac.bicep
// Least-privilege role assignments for the Logic App managed identity.
//  - Azure Event Hubs Data Receiver on the Event Hubs namespace
//    (enables switching the Event Hub trigger to identity-based auth)
//  - Storage roles on the backing storage account so the runtime can use
//    AzureWebJobsStorage__accountName (identity-based) instead of a shared
//    key. Required for orgs that disable allowSharedKeyAccess.
// ============================================================================

@description('Logic App managed identity principal (object) id.')
param logicAppPrincipalId string

@description('Principal (object) id of the user-assigned identity the Logic App uses for AzureWebJobsStorage (Data.Edge runtime). Granted the same storage data-plane roles as the system-assigned identity.')
param storageIdentityPrincipalId string

@description('Event Hubs namespace name.')
param eventHubNamespaceName string

@description('Backing storage account name (in the same resource group).')
param storageAccountName string

@description('Azure Communication Services resource name (in the same resource group). The Logic App calls the ACS Email REST API with managed identity.')
param communicationServiceName string

@description('Application Insights component name (in the same resource group). The Logic App host ingests telemetry with managed identity (Entra-authenticated ingestion).')
param appInsightsName string

// Azure built-in role IDs (last GUID segment of the role definition resourceId)
var eventHubDataReceiverRoleId            = 'f526a384-b230-433a-b45c-95f59c4a2dec' // Azure Event Hubs Data Receiver
var storageBlobDataOwnerRoleId            = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner
var storageQueueDataContributorRoleId     = '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
var storageTableDataContributorRoleId     = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor
var storageAccountContributorRoleId       = '17d1049b-9a84-46fb-8f53-869881c3d3ab' // Storage Account Contributor (for content-share mgmt)
var storageFileSmbShareContributorRoleId  = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb' // Storage File Data SMB Share Contributor
var contributorRoleId                     = 'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor (ACS data-plane Entra auth requires an RBAC role on the resource)
var monitoringMetricsPublisherRoleId      = '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher (Entra-authenticated App Insights ingestion)

resource ehNamespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: eventHubNamespaceName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource communicationService 'Microsoft.Communication/communicationServices@2023-04-01' existing = {
  name: communicationServiceName
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}

resource ehDataReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ehNamespace.id, logicAppPrincipalId, eventHubDataReceiverRoleId)
  scope: ehNamespace
  properties: {
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', eventHubDataReceiverRoleId)
  }
}

resource storageBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, logicAppPrincipalId, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
  }
}

resource storageQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, logicAppPrincipalId, storageQueueDataContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
  }
}

resource storageTableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, logicAppPrincipalId, storageTableDataContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
  }
}

resource storageAccountContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, logicAppPrincipalId, storageAccountContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageAccountContributorRoleId)
  }
}

resource storageFileSmbContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, logicAppPrincipalId, storageFileSmbShareContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageFileSmbShareContributorRoleId)
  }
}

// User-assigned identity storage roles. The workflow Data.Edge engine reaches
// AzureWebJobsStorage with this user-assigned identity, so it needs the same
// blob/queue/table data + account + file SMB roles on the backing storage.
resource uamiStorageBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, storageIdentityPrincipalId, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    principalId: storageIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
  }
}

resource uamiStorageQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, storageIdentityPrincipalId, storageQueueDataContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: storageIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
  }
}

resource uamiStorageTableContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, storageIdentityPrincipalId, storageTableDataContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: storageIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
  }
}

resource uamiStorageAccountContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, storageIdentityPrincipalId, storageAccountContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: storageIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageAccountContributorRoleId)
  }
}

resource uamiStorageFileSmbContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, storageIdentityPrincipalId, storageFileSmbShareContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: storageIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageFileSmbShareContributorRoleId)
  }
}

// ACS Email send via REST + managed identity. ACS data-plane Entra ID auth
// validates that the caller holds an RBAC role on the Communication Services
// resource; Contributor scoped to just this ACS resource grants that. This
// replaces the former key-based acsemail managed API connection.
resource acsContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(communicationService.id, logicAppPrincipalId, contributorRoleId)
  scope: communicationService
  properties: {
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
  }
}

// Entra-authenticated Application Insights ingestion. With DisableLocalAuth=true
// on the component, the instrumentation key is inert; the Logic App host sends
// telemetry using its managed identity, which needs Monitoring Metrics Publisher
// on the component (paired with APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD).
resource appInsightsMetricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, logicAppPrincipalId, monitoringMetricsPublisherRoleId)
  scope: appInsights
  properties: {
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
  }
}
