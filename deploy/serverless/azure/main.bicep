// ============================================================
// RPI v7.7 - Azure Container Apps (Serverless Deployment)
// ============================================================
// Deploys the full RPI stack on Azure Container Apps with
// managed services for database, cache, queues, and secrets.
//
// Usage:
//   az deployment group create \
//     --resource-group <rg-name> \
//     --template-file main.bicep \
//     --parameters parameters.json
//
// Or use the "Deploy to Azure" button in the README.
// ============================================================

targetScope = 'subscription'

// ── Parameters ──────────────────────────────────────────────

@description('Azure region for deployment (inherited from --location flag)')
param location string = deployment().location

@description('Unique environment name for this deployment (e.g., dev, test, prod). Different values create isolated environments with separate resources.')
param environmentName string

@description('RPI container image tag')
param imageTag string = '7.7.20260327.1408'

@description('Container registry (full path without image name)')
param imageRegistry string = 'rg1acrpub.azurecr.io/docker/redpointglobal/releases'

@description('Container registry server (e.g. rg1acrpub.azurecr.io)')
param registryServer string = 'rg1acrpub.azurecr.io'

@description('Override individual image names. Keys: interactionapi, deploymentapi, executionservice, nodemanager, integrationapi, realtimeapi, callbackapi, queuereader, rediscache, rabbitmq, mongodb. Example: { interactionapi: "redpoint-interaction-api" }')
param imageNameOverrides object = {}

@description('Container registry username')
param registryUsername string = ''

@description('Container registry password')
@secure()
param registryPassword string = ''

@description('Database type: sqlserver or postgresql')
@allowed(['sqlserver', 'postgresql'])
param databaseType string = 'sqlserver'

@description('Database admin username')
param databaseUsername string

@description('Database admin password')
@secure()
param databasePassword string

@description('Use existing pre-created database server and databases instead of creating new ones')
param useExistingDatabase bool = false

@description('FQDN of the existing database server (required when useExistingDatabase=true). Example: myserver.database.windows.net or myserver.postgres.database.azure.com')
param existingDatabaseServerFQDN string = ''

@description('Name of the existing Pulse database (required when useExistingDatabase=true)')
param existingPulseDatabaseName string = 'Pulse'

@description('Name of the existing Pulse Logging database (required when useExistingDatabase=true)')
param existingPulseLoggingDatabaseName string = 'Pulse_Logging'

@description('Ingress domain for external access')
param ingressDomain string = ''

@description('Ingress visibility: external (public) or internal (private, VNet only)')
@allowed(['external', 'internal'])
param ingressMode string = 'external'


@description('Name of the Key Vault containing the TLS certificate for custom domain binding. Leave empty to skip certificate binding.')
param certificateKeyVaultName string = ''

@description('Resource group containing the Key Vault with the TLS certificate')
param certificateKeyVaultResourceGroup string = ''

@description('Subscription ID containing the Key Vault with the TLS certificate (defaults to the deployment subscription)')
param certificateKeyVaultSubscriptionId string = subscription().subscriptionId

@description('Certificate name in the Key Vault (e.g., redpointcdp-com). The latest version is always used.')
param certificateName string = ''

@description('Enable Realtime API')
param enableRealtime bool = false

@description('Enable Callback API')
param enableCallback bool = false

@description('Enable Queue Reader')
param enableQueueReader bool = false

@description('Realtime cache provider')
@allowed(['redis', 'mongodb'])
param cacheProvider string = 'redis'

@description('Cache deployment type: managed (Azure service), internal (container in environment), or external (BYO connection string)')
@allowed(['managed', 'internal', 'external'])
param cacheProviderType string = 'managed'

@description('External cache connection string (required when cacheProviderType=external)')
@secure()
param externalCacheConnectionString string = ''

@description('Realtime queue provider')
@allowed(['servicebus', 'rabbitmq'])
param queueProvider string = 'servicebus'

@description('Queue deployment type: managed (Azure service), internal (container in environment), or external (BYO connection details)')
@allowed(['managed', 'internal', 'external'])
param queueProviderType string = 'managed'

@description('External queue connection string (required when queueProvider=servicebus and queueProviderType=external)')
@secure()
param externalQueueConnectionString string = ''

@description('External RabbitMQ hostname (required when queueProvider=rabbitmq and queueProviderType=external)')
param externalRabbitMQHostname string = ''

@description('External RabbitMQ password (required when queueProvider=rabbitmq and queueProviderType=external)')
@secure()
param externalRabbitMQPassword string = ''

@description('Use an existing Log Analytics workspace instead of creating a new one')
param useExistingLogAnalytics bool = false

@description('Resource ID of an existing Log Analytics workspace (required when useExistingLogAnalytics=true)')
param existingLogAnalyticsWorkspaceId string = ''

@description('Resource group containing the existing Log Analytics workspace (required when useExistingLogAnalytics=true)')
param existingLogAnalyticsResourceGroup string = ''

@description('Log Analytics workspace retention in days (only used when creating a new workspace)')
param logRetentionDays int = 30

@description('Container app CPU (cores)')
param cpuCores string = '0.5'

@description('Container app memory')
param appMemory string = '1Gi'

@description('Execution service CPU (cores)')
param execCpuCores string = '2'

@description('Execution service memory')
param execMemory string = '4Gi'

// ── Networking ──────────────────────────────────────────────

@description('Use an existing VNet. When true, provide existingVnetId and existingSubnetId.')
param useExistingVnet bool = false

@description('Resource ID of an existing VNet (required when useExistingVnet=true)')
param existingVnetId string = ''

@description('Resource ID of an existing subnet for the Container Apps Environment (required when useExistingVnet=true). Must be delegated to Microsoft.App/environments and at least /23.')
param existingSubnetId string = ''

@description('Enable private endpoints for Key Vault, Storage, and Database. Requires VNet integration.')
param enablePrivateEndpoints bool = false

@description('Resource ID of an existing subnet for private endpoints (can be the same as or different from the Container Apps subnet)')
param privateEndpointSubnetId string = ''

@description('Use existing private DNS zones instead of creating new ones. Set to true if your subscription already has privatelink.* zones linked to the VNet.')
param useExistingDnsZones bool = false

@description('Resource group containing the existing private DNS zones (required when useExistingDnsZones=true)')
param existingDnsZoneResourceGroup string = ''

@description('Subscription ID containing the existing private DNS zones (required when zones are in a different subscription). Defaults to the deployment subscription.')
param existingDnsZoneSubscriptionId string = subscription().subscriptionId

// ── Variables ───────────────────────────────────────────────

// Generate a unique 6-char suffix from the subscription, location, and environment name
var uniqueSuffix = substring(uniqueString(subscription().subscriptionId, location, environmentName), 0, 6)
var prefix = 'rpi-${uniqueSuffix}'
var tags = {
  'redpoint-rpi': 'serverless'
  'rpi-environment-id': uniqueSuffix
  environment: 'production'
  'managed-by': 'bicep'
}

var isInternal = ingressMode == 'internal'
var peSubnetId = enablePrivateEndpoints ? (empty(privateEndpointSubnetId) ? existingSubnetId : privateEndpointSubnetId) : ''

// ── Resource Group ──────────────────────────────────────────

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${prefix}'
  location: location
  tags: tags
}

// ── Managed Identity (created first for cross-RG role assignments) ──

var hasCert = !empty(ingressDomain) && !empty(certificateKeyVaultName) && !empty(certificateName)

module identity 'identity.bicep' = {
  name: 'rpi-identity-${uniqueSuffix}'
  scope: rg
  params: {
    prefix: prefix
    location: location
    tags: tags
  }
}

// ── Certificate Key Vault access (cross-resource-group) ────

module certKvAccess 'cert-kv-access.bicep' = if (hasCert) {
  name: 'cert-kv-access-${uniqueSuffix}'
  scope: resourceGroup(certificateKeyVaultSubscriptionId, certificateKeyVaultResourceGroup)
  params: {
    keyVaultName: certificateKeyVaultName
    principalId: identity.outputs.principalId
  }
}

// ── All resources deployed into the resource group ──────────

module resources 'resources.bicep' = {
  name: 'rpi-resources-${uniqueSuffix}'
  scope: rg
  dependsOn: hasCert ? [certKvAccess] : []
  params: {
    prefix: prefix
    location: location
    tags: tags
    managedIdentityId: identity.outputs.id
    managedIdentityClientId: identity.outputs.clientId
    managedIdentityPrincipalId: identity.outputs.principalId
    imageTag: imageTag
    imageRegistry: imageRegistry
    registryServer: registryServer
    imageNameOverrides: imageNameOverrides
    registryUsername: registryUsername
    registryPassword: registryPassword
    databaseType: databaseType
    databaseUsername: databaseUsername
    databasePassword: databasePassword
    useExistingDatabase: useExistingDatabase
    existingDatabaseServerFQDN: existingDatabaseServerFQDN
    existingPulseDatabaseName: existingPulseDatabaseName
    existingPulseLoggingDatabaseName: existingPulseLoggingDatabaseName
    ingressDomain: ingressDomain
    certificateKeyVaultName: certificateKeyVaultName
    certificateName: certificateName
    enableRealtime: enableRealtime
    enableCallback: enableCallback
    enableQueueReader: enableQueueReader
    cacheProvider: cacheProvider
    cacheProviderType: cacheProviderType
    externalCacheConnectionString: externalCacheConnectionString
    queueProvider: queueProvider
    queueProviderType: queueProviderType
    externalQueueConnectionString: externalQueueConnectionString
    externalRabbitMQHostname: externalRabbitMQHostname
    externalRabbitMQPassword: externalRabbitMQPassword
    useExistingLogAnalytics: useExistingLogAnalytics
    existingLogAnalyticsWorkspaceId: existingLogAnalyticsWorkspaceId
    existingLogAnalyticsResourceGroup: existingLogAnalyticsResourceGroup
    logRetentionDays: logRetentionDays
    cpuCores: cpuCores
    appMemory: appMemory
    execCpuCores: execCpuCores
    execMemory: execMemory
    useExistingVnet: useExistingVnet
    existingVnetId: existingVnetId
    existingSubnetId: existingSubnetId
    enablePrivateEndpoints: enablePrivateEndpoints
    isInternal: isInternal
    peSubnetId: peSubnetId
    useExistingDnsZones: useExistingDnsZones
    existingDnsZoneResourceGroup: existingDnsZoneResourceGroup
    existingDnsZoneSubscriptionId: existingDnsZoneSubscriptionId
    subscriptionId: subscription().subscriptionId
  }
}

// ── DNS CNAME records (cross-resource-group) ───────────────

var createDnsRecords = !empty(ingressDomain) && !empty(existingDnsZoneResourceGroup)
var baseAppNames = [
  resources.outputs.deploymentApiName
  resources.outputs.interactionApiName
  resources.outputs.integrationApiName
]
var realtimeAppName = enableRealtime ? [resources.outputs.realtimeApiName] : []
var callbackAppName = enableCallback ? [resources.outputs.callbackApiName] : []

module dnsRecords 'dns-records.bicep' = if (createDnsRecords) {
  name: 'dns-records-${uniqueSuffix}'
  scope: resourceGroup(existingDnsZoneSubscriptionId, existingDnsZoneResourceGroup)
  params: {
    dnsZoneName: ingressDomain
    isPrivate: isInternal
    staticIp: resources.outputs.environmentStaticIp
    appNames: concat(baseAppNames, realtimeAppName, callbackAppName)
  }
}

// ── Outputs ─────────────────────────────────────────────────

output resourceGroupName string = rg.name
output environmentId string = uniqueSuffix
output interactionApiUrl string = resources.outputs.interactionApiUrl
output deploymentApiUrl string = resources.outputs.deploymentApiUrl
output integrationApiUrl string = resources.outputs.integrationApiUrl
output realtimeApiUrl string = resources.outputs.realtimeApiUrl
output callbackApiUrl string = resources.outputs.callbackApiUrl
output keyVaultName string = resources.outputs.keyVaultName
output keyVaultUri string = resources.outputs.keyVaultUri
output managedIdentityClientId string = resources.outputs.managedIdentityClientId
output managedIdentityPrincipalId string = resources.outputs.managedIdentityPrincipalId
output databaseServer string = resources.outputs.databaseServer

