using './main.bicep'

// ----------------------------------------------------------------------------
// DEV environment parameters.
// ----------------------------------------------------------------------------

param namePrefix = 'cf-entraaudit-dev'
param environmentName = 'dev'
param location = 'centralus'

param vnetAddressPrefix = '10.51.0.0/16'
param privateEndpointSubnetPrefix = '10.51.1.0/24'
param logicAppSubnetPrefix = '10.51.2.0/24'
param signInLogicAppSubnetPrefix = '10.51.3.0/24'

param planSku = 'WS1'
param deployStreamAnalytics = true
param asaConnectivityMode = 'firewallException'
param useAzureManagedDomain = true
param customDomainName = ''

// Parallel sign-in/risk alerting pipeline (separate ASA + Logic App).
// ENABLED here: internal security probe (off by default for the customer
// deliverable). Emails the recipient below with sign-in/risk alerts.
param deploySignInPipeline = true
param alertRecipientAddress = 'gwexler@MngEnvMCAP578097.onmicrosoft.com'
// SOC BCC on the customer LogsProcessor MFA-change notifications (dev probe).
param socRecipientAddress = 'gwexler@MngEnvMCAP578097.onmicrosoft.com'

param extraTags = {
  owner: 'identity-security'
  costCenter: 'TBD'
}
