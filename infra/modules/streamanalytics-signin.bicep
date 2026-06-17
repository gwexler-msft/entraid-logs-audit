// ============================================================================
// streamanalytics-signin.bicep  (OPTIONAL - deploySignInPipeline flag in main)
// Second, fully isolated SQL pre-filter for the sign-in / risk alerting
// pipeline. Reads the SAME raw event hub as the customer job, but through its
// OWN consumer group, and writes to a SEPARATE filtered hub so the existing
// customer deliverable is never modified.
//  - Emits sign-in failures (excluding benign interactive interrupt codes),
//    risky sign-ins, user risk detections and at-risk users.
//  - Preserves the full record as rawEvent for the Logic App to render emails.
//  - Uses managed-identity auth to Event Hubs (no SAS keys in the job).
// ============================================================================

@description('Azure region.')
param location string

@description('Resource name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object = {}

@description('Event Hubs namespace name.')
param eventHubNamespaceName string

@description('Raw (input) event hub name - shared with the customer pipeline.')
param rawHubName string

@description('Sign-in/risk filtered (output) event hub name.')
param signInFilteredHubName string

@description('Consumer group on the raw hub dedicated to THIS job.')
param inputConsumerGroup string = 'asa-signin-cg'

var serviceBusNamespaceFqdnPrefix = eventHubNamespaceName

resource asaJob 'Microsoft.StreamAnalytics/streamingJobs@2021-10-01-preview' = {
  name: 'asa-signin-${namePrefix}'
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
  name: 'SignInRiskOut'
  properties: {
    datasource: {
      type: 'Microsoft.ServiceBus/EventHub'
      properties: {
        serviceBusNamespace: serviceBusNamespaceFqdnPrefix
        eventHubName: signInFilteredHubName
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
    // Extractions are pushed into the `proj` stage because ASA cannot reference
    // SELECT aliases from a WHERE clause. Benign interactive interrupt codes are
    // excluded so the "failed sign-in" branch is not flooded by MFA/CA prompts.
    query: '''
WITH base AS (
  SELECT r.ArrayValue AS evt
  FROM EntraAuditIn AS e
  CROSS APPLY GetArrayElements(e.records) AS r
),
proj AS (
  SELECT
    TRY_CAST(GetRecordPropertyValue(evt,'time') AS datetime)                AS eventTime,
    TRY_CAST(GetRecordPropertyValue(evt,'category') AS nvarchar(max))       AS category,
    TRY_CAST(GetRecordPropertyValue(evt,'correlationId') AS nvarchar(max))  AS correlationId,
    GetRecordPropertyValue(evt,'properties')                               AS props,
    evt                                                                    AS evt
  FROM base
)
SELECT
  eventTime,
  category,
  correlationId,
  TRY_CAST(GetRecordPropertyValue(props,'userPrincipalName') AS nvarchar(max))                          AS userPrincipalName,
  TRY_CAST(GetRecordPropertyValue(props,'userDisplayName') AS nvarchar(max))                            AS userDisplayName,
  TRY_CAST(GetRecordPropertyValue(props,'ipAddress') AS nvarchar(max))                                  AS ipAddress,
  TRY_CAST(GetRecordPropertyValue(props,'appDisplayName') AS nvarchar(max))                             AS appDisplayName,
  TRY_CAST(GetRecordPropertyValue(props,'riskLevelDuringSignIn') AS nvarchar(max))                      AS riskLevelDuringSignIn,
  TRY_CAST(GetRecordPropertyValue(props,'riskLevel') AS nvarchar(max))                                  AS riskLevel,
  TRY_CAST(GetRecordPropertyValue(props,'riskState') AS nvarchar(max))                                  AS riskState,
  TRY_CAST(GetRecordPropertyValue(props,'riskEventType') AS nvarchar(max))                              AS riskEventType,
  TRY_CAST(GetRecordPropertyValue(props,'riskDetail') AS nvarchar(max))                                 AS riskDetail,
  TRY_CAST(GetRecordPropertyValue(GetRecordPropertyValue(props,'status'),'errorCode') AS bigint)        AS errorCode,
  TRY_CAST(GetRecordPropertyValue(GetRecordPropertyValue(props,'status'),'failureReason') AS nvarchar(max)) AS failureReason,
  TRY_CAST(GetRecordPropertyValue(GetRecordPropertyValue(props,'location'),'city') AS nvarchar(max))        AS locationCity,
  TRY_CAST(GetRecordPropertyValue(GetRecordPropertyValue(props,'location'),'countryOrRegion') AS nvarchar(max)) AS locationCountry,
  evt AS rawEvent
INTO SignInRiskOut
FROM proj
WHERE
  (
    category = 'SignInLogs' AND (
         TRY_CAST(GetRecordPropertyValue(props,'riskLevelDuringSignIn') AS nvarchar(max)) IN ('medium','high')
      OR TRY_CAST(GetRecordPropertyValue(props,'riskState') AS nvarchar(max)) = 'atRisk'
      OR (
           TRY_CAST(GetRecordPropertyValue(GetRecordPropertyValue(props,'status'),'errorCode') AS bigint) <> 0
           AND TRY_CAST(GetRecordPropertyValue(GetRecordPropertyValue(props,'status'),'errorCode') AS bigint) NOT IN (50058,50140,50097,16000,16001,50074,50079,65001,50072,50076,50125,50129,81010,81012)
         )
    )
  )
  OR category = 'UserRiskEvents'
  OR (category = 'RiskyUsers' AND TRY_CAST(GetRecordPropertyValue(props,'riskState') AS nvarchar(max)) = 'atRisk')
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
