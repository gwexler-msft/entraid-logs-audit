// ============================================================================
// network.bicep
// Locked-down hub VNet for the EntraIdLogsAudit solution.
//  - Two subnets: private endpoints + Logic App regional VNet integration
//  - NSGs that DENY all inbound from the Internet by default
//  - Private DNS zones for every PaaS service consumed over Private Link
// ============================================================================

@description('Azure region for all network resources.')
param location string

@description('Resource name prefix, e.g. cf-entraaudit-prod.')
param namePrefix string

@description('Address space for the virtual network.')
param vnetAddressPrefix string = '10.50.0.0/16'

@description('Subnet that hosts all Private Endpoints.')
param privateEndpointSubnetPrefix string = '10.50.1.0/24'

@description('Subnet delegated to the Logic App Standard plan for regional VNet integration.')
param logicAppSubnetPrefix string = '10.50.2.0/24'

@description('Subnet delegated to the second (sign-in/risk) Logic App Standard plan for regional VNet integration.')
param signInLogicAppSubnetPrefix string = '10.50.3.0/24'

@description('Tags applied to every resource.')
param tags object = {}

var peSubnetName = 'snet-privateendpoints'
var appSubnetName = 'snet-logicapp'
var signInAppSubnetName = 'snet-logicapp2'

// ---------------------------------------------------------------------------
// NSG for the private-endpoint subnet: deny inbound Internet, allow intra-VNet.
// ---------------------------------------------------------------------------
resource nsgPe 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${namePrefix}-pe'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-VNet-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// NSG for the Logic App integration subnet: deny inbound Internet by default.
// ---------------------------------------------------------------------------
resource nsgApp 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${namePrefix}-app'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-VNet-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '*'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-${namePrefix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetAddressPrefix ]
    }
    subnets: [
      {
        name: peSubnetName
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          networkSecurityGroup: { id: nsgPe.id }
          privateEndpointNetworkPolicies: 'Enabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
      {
        name: appSubnetName
        properties: {
          addressPrefix: logicAppSubnetPrefix
          networkSecurityGroup: { id: nsgApp.id }
          delegations: [
            {
              name: 'webserverfarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
            { service: 'Microsoft.EventHub' }
          ]
        }
      }
      {
        name: signInAppSubnetName
        properties: {
          addressPrefix: signInLogicAppSubnetPrefix
          networkSecurityGroup: { id: nsgApp.id }
          delegations: [
            {
              name: 'webserverfarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          serviceEndpoints: [
            { service: 'Microsoft.Storage' }
            { service: 'Microsoft.EventHub' }
          ]
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Private DNS zones for each PaaS service reached over Private Link.
// ---------------------------------------------------------------------------
var privateDnsZoneNames = [
  'privatelink.servicebus.windows.net'   // Event Hubs
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.file.${environment().suffixes.storage}'
  'privatelink.queue.${environment().suffixes.storage}'
  'privatelink.table.${environment().suffixes.storage}'
  'privatelink.azurewebsites.net'        // Logic App Standard (App Service)
]

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zone in privateDnsZoneNames: {
  name: zone
  location: 'global'
  tags: tags
}]

resource dnsZoneVnetLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zone, i) in privateDnsZoneNames: {
  parent: privateDnsZones[i]
  name: 'link-${namePrefix}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

output vnetId string = vnet.id
output privateEndpointSubnetId string = '${vnet.id}/subnets/${peSubnetName}'
output logicAppSubnetId string = '${vnet.id}/subnets/${appSubnetName}'
output signInLogicAppSubnetId string = '${vnet.id}/subnets/${signInAppSubnetName}'
output eventHubDnsZoneId string = privateDnsZones[0].id
output blobDnsZoneId string = privateDnsZones[1].id
output fileDnsZoneId string = privateDnsZones[2].id
output queueDnsZoneId string = privateDnsZones[3].id
output tableDnsZoneId string = privateDnsZones[4].id
output sitesDnsZoneId string = privateDnsZones[5].id
