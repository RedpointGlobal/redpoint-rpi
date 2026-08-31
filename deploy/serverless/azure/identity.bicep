// Creates the User-Assigned Managed Identity used by all Container Apps.
// Deployed before the main resources module so it can be used for cross-RG role assignments.

param prefix string
param location string
param tags object

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-identity'
  location: location
  tags: tags
}

output id string = managedIdentity.id
output clientId string = managedIdentity.properties.clientId
output principalId string = managedIdentity.properties.principalId
