// ============================================================================
// streamanalytics.bicep  (OPTIONAL - deployStreamAnalytics flag in main)
// SQL-based field-level pre-filter between the RAW and FILTERED event hubs.
//  - Preserves full audit fidelity (emits the whole record as rawEvent)
//  - Promotes the stable header fields the Logic App parses
//  - Uses managed-identity auth to Event Hubs (no SAS keys in the job)
// Networking note: when the Event Hubs namespace has public access disabled,
// the job must reach it privately (Stream Analytics cluster + managed private
// endpoint, or a temporary service-endpoint exception). See deployment guide.
// ============================================================================

@description('Azure region.')
param location string

@description('Resource name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object = {}

@description('Event Hubs namespace name.')
param eventHubNamespaceName string

@description('Raw (input) event hub name.')
param rawHubName string

@description('Filtered (output) event hub name.')
param filteredHubName string

@description('Consumer group on the raw hub dedicated to this job.')
param inputConsumerGroup string = 'asa-filter-cg'

var serviceBusNamespaceFqdnPrefix = eventHubNamespaceName

resource asaJob 'Microsoft.StreamAnalytics/streamingJobs@2021-10-01-preview' = {
  name: 'asa-${namePrefix}'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: { name: 'Standard' }
    jobType: 'Cloud'
    outputErrorPolicy: 'Drop'
    eventsOutOfOrderPolicy: 'Adjust'
    eventsOutOfOrderMaxDelayInSeconds: 5
    eventsLateArrivalMaxDelayInSeconds: 16
    dataLocale: 'en-US'
    compatibilityLevel: '1.2'
  }
}

resource asaInput 'Microsoft.StreamAnalytics/streamingJobs/inputs@2021-10-01-preview' = {
  parent: asaJob
  name: 'EntraAuditIn'
  properties: {
    type: 'Stream'
    datasource: {
      type: 'Microsoft.ServiceBus/EventHub'
      properties: {
        serviceBusNamespace: serviceBusNamespaceFqdnPrefix
        eventHubName: rawHubName
        consumerGroupName: inputConsumerGroup
        authenticationMode: 'Msi'
      }
    }
    serialization: {
      type: 'Json'
      properties: {
        encoding: 'UTF8'
      }
    }
  }
}

resource asaOutput 'Microsoft.StreamAnalytics/streamingJobs/outputs@2021-10-01-preview' = {
  parent: asaJob
  name: 'FilteredOut'
  properties: {
    datasource: {
      type: 'Microsoft.ServiceBus/EventHub'
      properties: {
        serviceBusNamespace: serviceBusNamespaceFqdnPrefix
        eventHubName: filteredHubName
        authenticationMode: 'Msi'
      }
    }
    serialization: {
      type: 'Json'
      properties: {
        encoding: 'UTF8'
        format: 'LineSeparated'
      }
    }
  }
}

resource asaTransformation 'Microsoft.StreamAnalytics/streamingJobs/transformations@2021-10-01-preview' = {
  parent: asaJob
  name: 'Transformation'
  properties: {
    streamingUnits: 1
    query: '''
WITH base AS (
  SELECT r.ArrayValue AS evt
  FROM EntraAuditIn AS e
  CROSS APPLY GetArrayElements(e.records) AS r
)
SELECT
  TRY_CAST(GetRecordPropertyValue(evt,'time') AS datetime)                                            AS eventTime,
  TRY_CAST(GetRecordPropertyValue(evt,'operationName') AS nvarchar(max))                              AS operationName,
  TRY_CAST(GetRecordPropertyValue(evt,'category') AS nvarchar(max))                                   AS category,
  TRY_CAST(GetRecordPropertyValue(evt,'correlationId') AS nvarchar(max))                              AS correlationId,
  TRY_CAST(GetRecordPropertyValue(GetRecordPropertyValue(evt,'properties'),'result') AS nvarchar(max))       AS activityResult,
  TRY_CAST(GetRecordPropertyValue(GetRecordPropertyValue(evt,'properties'),'resultReason') AS nvarchar(max)) AS activityResultReason,
  GetRecordPropertyValue(evt,'identity')                                                              AS [identity],
  evt                                                                                                 AS rawEvent
INTO FilteredOut
FROM base
WHERE
  TRY_CAST(GetRecordPropertyValue(evt,'category') AS nvarchar(max)) = 'AuditLogs'
  AND TRY_CAST(GetRecordPropertyValue(evt,'operationName') AS nvarchar(max)) LIKE '%security info%'
'''
  }
}

// ---- Managed-identity RBAC for the job against the Event Hubs namespace ----
var dataReceiverRoleId = 'f526a384-b230-433a-b45c-95f59c4a2dec' // Azure Event Hubs Data Receiver
var dataSenderRoleId = '2b629674-e913-4c01-ae53-ef4638d8f975'   // Azure Event Hubs Data Sender

resource ehNamespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: eventHubNamespaceName
}

resource asaReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ehNamespace.id, asaJob.id, dataReceiverRoleId)
  scope: ehNamespace
  properties: {
    principalId: asaJob.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataReceiverRoleId)
  }
}

resource asaSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ehNamespace.id, asaJob.id, dataSenderRoleId)
  scope: ehNamespace
  properties: {
    principalId: asaJob.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', dataSenderRoleId)
  }
}

output streamAnalyticsJobName string = asaJob.name
