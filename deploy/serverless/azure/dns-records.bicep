// Creates A records in an Azure DNS zone for Container Apps custom domains.
// Each app gets an A record pointing to the environment's static IP.
// Uses private DNS zones for internal ingress, public DNS zones for external.
// Deployed to the DNS zone's resource group (cross-RG from the main deployment).

param dnsZoneName string
param isPrivate bool
param staticIp string
param appNames array // [ 'rpi-abc123-deploymentapi', 'rpi-abc123-interactionapi', ... ]

// ── Private DNS Zone (internal ingress) ────────────────────

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = if (isPrivate) {
  name: dnsZoneName
}

resource privateARecords 'Microsoft.Network/privateDnsZones/A@2024-06-01' = [for name in appNames: if (isPrivate) {
  parent: privateDnsZone
  name: name
  properties: {
    ttl: 300
    aRecords: [
      { ipv4Address: staticIp }
    ]
  }
}]

// ── Public DNS Zone (external ingress) ─────────────────────

resource publicDnsZone 'Microsoft.Network/dnsZones@2023-07-01-preview' existing = if (!isPrivate) {
  name: dnsZoneName
}

resource publicARecords 'Microsoft.Network/dnsZones/A@2023-07-01-preview' = [for name in appNames: if (!isPrivate) {
  parent: publicDnsZone
  name: name
  properties: {
    TTL: 300
    ARecords: [
      { ipv4Address: staticIp }
    ]
  }
}]
