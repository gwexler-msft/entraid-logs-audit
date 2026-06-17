// ============================================================================
// acs.bicep
// Azure Communication Services + Email Communication Services.
//  - Azure-managed email domain (DoNotReply@<guid>.azurecomm.net) by default
//  - Domain linked to the ACS resource so the Logic App can send mail
// NOTE: ACS / Email Communication Services are GLOBAL resources; only certain
//       data locations are valid (e.g. "United States").
// ============================================================================

@description('Resource name prefix.')
param namePrefix string

@description('Tags applied to every resource.')
param tags object = {}

@description('ACS / Email data residency location.')
param dataLocation string = 'United States'

@description('Use the Azure-managed domain (true) or wire up a custom domain (false).')
param useAzureManagedDomain bool = true

@description('Custom sender domain (only used when useAzureManagedDomain = false), e.g. contoso.com.')
param customDomainName string = ''

resource emailService 'Microsoft.Communication/emailServices@2023-04-01' = {
  name: 'acs-email-${namePrefix}'
  location: 'global'
  tags: tags
  properties: {
    dataLocation: dataLocation
  }
}

resource managedDomain 'Microsoft.Communication/emailServices/domains@2023-04-01' = if (useAzureManagedDomain) {
  parent: emailService
  name: 'AzureManagedDomain'
  location: 'global'
  tags: tags
  properties: {
    domainManagement: 'AzureManaged'
    userEngagementTracking: 'Disabled'
  }
}

resource customDomain 'Microsoft.Communication/emailServices/domains@2023-04-01' = if (!useAzureManagedDomain) {
  parent: emailService
  name: empty(customDomainName) ? 'placeholder.invalid' : customDomainName
  location: 'global'
  tags: tags
  properties: {
    domainManagement: 'CustomerManaged'
    userEngagementTracking: 'Disabled'
  }
}

var linkedDomainId = useAzureManagedDomain ? managedDomain.id : customDomain.id

resource communicationService 'Microsoft.Communication/communicationServices@2023-04-01' = {
  name: 'acs-${namePrefix}'
  location: 'global'
  tags: tags
  properties: {
    dataLocation: dataLocation
    linkedDomains: [ linkedDomainId ]
  }
}

output communicationServiceName string = communicationService.name
output communicationServiceId string = communicationService.id
output communicationServiceHostName string = communicationService.properties.hostName
output emailServiceName string = emailService.name
output linkedDomainId string = linkedDomainId

// DoNotReply sender address derived from the linked email domain. For the
// Azure-managed domain this is DoNotReply@<guid>.azurecomm.net; for a custom
// domain it is DoNotReply@<customDomainName>.
output senderAddress string = useAzureManagedDomain ? 'DoNotReply@${managedDomain!.properties.fromSenderDomain}' : 'DoNotReply@${customDomainName}'
