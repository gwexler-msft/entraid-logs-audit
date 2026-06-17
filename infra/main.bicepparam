using './main.bicep'

// ----------------------------------------------------------------------------
// Example parameters for the PRODUCTION environment.
// Copy to main.<env>.bicepparam per environment and adjust values.
// ----------------------------------------------------------------------------

param namePrefix = 'cf-entraaudit-prod'
param environmentName = 'prod'
param location = 'centralus'

// Network (size subnets to your IPAM plan; /24s shown are generous)
param vnetAddressPrefix = '10.50.0.0/16'
param privateEndpointSubnetPrefix = '10.50.1.0/24'
param logicAppSubnetPrefix = '10.50.2.0/24'
param signInLogicAppSubnetPrefix = '10.50.3.0/24'

// Compute
param planSku = 'WS1'

// Filtering: ASA pre-filter is ON by default so the Logic App only processes
// pre-filtered security-info events (raw hub -> ASA -> filtered hub).
param deployStreamAnalytics = true

// How ASA reaches the private Event Hubs namespace:
//   'firewallException' (default) - deny-by-default firewall + ASA trusted-service
//      bypass via managed identity. Low cost (~$80/mo for the standard job).
//   'dedicatedCluster' - fully private (ASA cluster + managed PE), keeps PNA
//      Disabled, but adds a ~$2,890/mo fixed ASA cluster cost (36-SU minimum).
param asaConnectivityMode = 'firewallException'

// Email: Azure-managed domain for quick start; switch to a custom domain for prod branding.
param useAzureManagedDomain = true
param customDomainName = ''

// Parallel sign-in/risk alerting pipeline (separate ASA + Logic App that emails
// an internal recipient). OPT-IN internal security probe — OFF by default for
// the customer deliverable. Enable + set a recipient mailbox only if you want
// this subscription to also receive sign-in/risk alerts.
param deploySignInPipeline = false
param alertRecipientAddress = ''

// Optional SOC / security-team mailbox to BCC on every MFA / security-info
// change notification from the customer LogsProcessor pipeline. Empty = email
// only the affected end user (default).
param socRecipientAddress = ''

param extraTags = {
  owner: 'identity-security'
  costCenter: 'TBD'
}
