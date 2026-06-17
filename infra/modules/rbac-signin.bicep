// ============================================================================
// rbac-signin.bicep  (OPTIONAL - deploySignInPipeline flag in main)
// Least-privilege role assignments for the SECOND (sign-in/risk) Logic App.
// Mirrors rbac.bicep but for the sign-in app's system-assigned identity and
// its dedicated user-assigned storage identity. Assignment GUIDs are seeded
// with the new principal ids, so they never collide with the customer app.
// ============================================================================

@description('Sign-in Logic App system-assigned managed identity principal (object) id.')
param logicAppPrincipalId string

@description('Principal (object) id of the user-assigned identity the sign-in Logic App uses for AzureWebJobsStorage (Data.Edge runtime).')
param storageIdentityPrincipalId string

@description('Event Hubs namespace name.')
param eventHubNamespaceName string

@description('Backing storage account name (in the same resource group).')
param storageAccountName string

@description('Azure Communication Services resource name (in the same resource group).')
param communicationServiceName string

@description('Application Insights component name (in the same resource group).')
param appInsightsName string

var eventHubDataReceiverRoleId            = 'f526a384-b230-433a-b45c-95f59c4a2dec' // Azure Event Hubs Data Receiver
var storageBlobDataOwnerRoleId            = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner
var storageQueueDataContributorRoleId     = '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
var storageTableDataContributorRoleId     = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor
var storageAccountContributorRoleId       = '17d1049b-9a84-46fb-8f53-869881c3d3ab' // Storage Account Contributor
var storageFileSmbShareContributorRoleId  = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb' // Storage File Data SMB Share Contributor
var contributorRoleId                     = 'b24988ac-6180-42a0-ab88-20f7382dd24c' // Contributor (ACS data-plane Entra auth)
var monitoringMetricsPublisherRoleId      = '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher

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

// --- System-assigned identity: Event Hub trigger reads the sign-in hub ---
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

// --- User-assigned identity (Data.Edge storage engine) storage roles ---
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

// --- ACS Email send + App Insights ingestion (system-assigned identity) ---
resource acsContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(communicationService.id, logicAppPrincipalId, contributorRoleId)
  scope: communicationService
  properties: {
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRoleId)
  }
}

resource appInsightsMetricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, logicAppPrincipalId, monitoringMetricsPublisherRoleId)
  scope: appInsights
  properties: {
    principalId: logicAppPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
  }
}
