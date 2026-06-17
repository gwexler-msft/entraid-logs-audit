using './main.bicep'

// ----------------------------------------------------------------------------
// TEST environment parameters.
// ----------------------------------------------------------------------------

param namePrefix = 'cf-entraaudit-test'
param environmentName = 'test'
param location = 'centralus'

param vnetAddressPrefix = '10.52.0.0/16'
param privateEndpointSubnetPrefix = '10.52.1.0/24'
param logicAppSubnetPrefix = '10.52.2.0/24'
param signInLogicAppSubnetPrefix = '10.52.3.0/24'

param planSku = 'WS1'
param deployStreamAnalytics = true
param asaConnectivityMode = 'firewallException'

// Parallel sign-in/risk alerting pipeline (separate ASA + Logic App).
// ENABLED here: internal security probe running in the test subscription to
// validate the workflow and collect sign-in/risk telemetry (emails the
// recipient below). Off by default for the customer deliverable (prod param).
param deploySignInPipeline = true
param alertRecipientAddress = 'gwexler@MngEnvMCAP578097.onmicrosoft.com'
// SOC BCC on the customer LogsProcessor MFA-change notifications (test probe).
param socRecipientAddress = 'gwexler@MngEnvMCAP578097.onmicrosoft.com'
param useAzureManagedDomain = true
param customDomainName = ''

param extraTags = {
  owner: 'identity-security'
  costCenter: 'TBD'
}
