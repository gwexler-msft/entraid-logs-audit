// ============================================================================
// storage.bicep
// Backing storage account for the Logic App Standard runtime.
//  - Public network access DISABLED; reachable only via Private Endpoints
//  - Private Endpoints for blob, file, queue and table sub-resources
//  - TLS 1.2, no blob public access, no shared-key-over-internet
// ============================================================================

@description('Azure region.')
param location string

@description('Globally unique storage account name (3-24 lowercase alphanumeric).')
param storageAccountName string

@description('Tags applied to every resource.')
param tags object = {}

@description('Private Endpoint subnet resource id.')
param privateEndpointSubnetId string

@description('Logic App integration subnet id (allowed via service endpoint as a fallback).')
param logicAppSubnetId string

@description('Private DNS zone ids keyed by sub-resource.')
param blobDnsZoneId string
param fileDnsZoneId string
param queueDnsZoneId string
param tableDnsZoneId string

@description('Content file share name the Logic App will mount over SMB (must be pre-created so the identity-based runtime does not need shared-key access to create it).')
param contentShareName string

@description('Content file share quota in GiB.')
param contentShareQuotaGiB int = 5120

@description('Optional second content share name for the parallel sign-in/risk Logic App. Empty = not created.')
param signInContentShareName string = ''

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    // Shared-key data-plane access is enabled ONLY because the Logic App
    // Standard WS plan platform validation requires a literal
    // WEBSITE_CONTENTAZUREFILECONNECTIONSTRING (managed-identity content-share
    // mount is Flex-Consumption-only as of 2026-06). Covered by scoped
    // exemption 'exempt-entraaudit-test-shared-key' against MG policy
    // StorageAccountDisableLocalAuth. All other access (AzureWebJobsStorage,
    // workflow runtime) uses managed identity - see rbac.bicep.
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          id: logicAppSubnetId
          action: 'Allow'
        }
      ]
    }
  }
}

// Pre-create the content file share. Identity-based runtime cannot auto-create
// it (no shared key), so the Logic App host expects it to exist.
resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' existing = {
  parent: storage
  name: 'default'
}

resource contentShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: contentShareName
  properties: {
    shareQuota: contentShareQuotaGiB
    enabledProtocols: 'SMB'
    accessTier: 'TransactionOptimized'
  }
}

// Second content share for the parallel sign-in/risk Logic App (shares this
// same storage account, isolated by share name).
resource signInContentShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = if (!empty(signInContentShareName)) {
  parent: fileService
  name: empty(signInContentShareName) ? 'placeholder' : signInContentShareName
  properties: {
    shareQuota: contentShareQuotaGiB
    enabledProtocols: 'SMB'
    accessTier: 'TransactionOptimized'
  }
}

var subResources = [
  { group: 'blob', zoneId: blobDnsZoneId }
  { group: 'file', zoneId: fileDnsZoneId }
  { group: 'queue', zoneId: queueDnsZoneId }
  { group: 'table', zoneId: tableDnsZoneId }
]

resource storagePrivateEndpoints 'Microsoft.Network/privateEndpoints@2023-11-01' = [for sr in subResources: {
  name: 'pep-${storageAccountName}-${sr.group}'
  location: location
  tags: tags
  properties: {
    subnet: { id: privateEndpointSubnetId }
    privateLinkServiceConnections: [
      {
        name: sr.group
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [ sr.group ]
        }
      }
    ]
  }
}]

resource storageDnsZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = [for (sr, i) in subResources: {
  parent: storagePrivateEndpoints[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: sr.group
        properties: { privateDnsZoneId: sr.zoneId }
      }
    ]
  }
}]

output storageAccountName string = storage.name
output storageAccountId string = storage.id
output contentShareName string = contentShare.name
output signInContentShareName string = empty(signInContentShareName) ? '' : signInContentShare.name
