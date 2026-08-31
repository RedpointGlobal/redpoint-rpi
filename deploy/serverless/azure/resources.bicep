// ============================================================
// RPI v7.7 - Azure Container Apps Resources Module
// ============================================================
// This module is called from main.bicep. Do not deploy directly.
// ============================================================

// ── Parameters (passed from main.bicep) ─────────────────────

param prefix string
param location string
param tags object
param managedIdentityId string
param managedIdentityClientId string
param managedIdentityPrincipalId string
param imageTag string
param imageRegistry string
param registryServer string
param imageNameOverrides object
param registryUsername string
@secure()
param registryPassword string
param databaseType string
param databaseUsername string
@secure()
param databasePassword string
param useExistingDatabase bool
param existingDatabaseServerFQDN string
param existingPulseDatabaseName string
param existingPulseLoggingDatabaseName string
param ingressDomain string
param certificateKeyVaultName string
param certificateName string
param enableRealtime bool
param enableCallback bool
param enableQueueReader bool
param useExistingLogAnalytics bool
param existingLogAnalyticsWorkspaceId string
param existingLogAnalyticsResourceGroup string
param cacheProvider string
param cacheProviderType string
@secure()
param externalCacheConnectionString string
param queueProvider string
param queueProviderType string
@secure()
param externalQueueConnectionString string
param externalRabbitMQHostname string
@secure()
param externalRabbitMQPassword string
param logRetentionDays int
param cpuCores string
param appMemory string
param execCpuCores string
param execMemory string
param useExistingVnet bool
param existingVnetId string
param existingSubnetId string
param enablePrivateEndpoints bool
param isInternal bool
param peSubnetId string
param useExistingDnsZones bool
param existingDnsZoneResourceGroup string
param existingDnsZoneSubscriptionId string
param subscriptionId string

// Registry credentials for Container Apps
var hasRegistryCreds = !empty(registryUsername) && !empty(registryPassword)
var registries = hasRegistryCreds ? [
  {
    server: registryServer
    username: registryUsername
    passwordSecretRef: 'registry-password'
  }
] : []
var registrySecrets = hasRegistryCreds ? [
  {
    name: 'registry-password'
    value: registryPassword
  }
] : []

// Provider deployment flags
var createManagedRedis = enableRealtime && cacheProvider == 'redis' && cacheProviderType == 'managed'
var createInternalMongoDB = enableRealtime && cacheProvider == 'mongodb' && cacheProviderType == 'internal'
var createInternalRabbitMQ = (enableRealtime || enableCallback) && queueProvider == 'rabbitmq' && queueProviderType == 'internal'
var createManagedServiceBus = (enableRealtime || enableCallback) && queueProvider == 'servicebus' && queueProviderType == 'managed'
var createSqlServer = databaseType == 'sqlserver' && !useExistingDatabase
var createPostgresServer = databaseType == 'postgresql' && !useExistingDatabase

// Resolved database names
var pulseDatabaseName = useExistingDatabase ? existingPulseDatabaseName : '${prefix}-pulse'
var pulseLoggingDatabaseName = useExistingDatabase ? existingPulseLoggingDatabaseName : '${prefix}-pulse-logging'

// Generated passwords for internal containers
var mongoPassword = '${uniqueString(resourceGroup().id, prefix, 'mongodb')}Rp!1'
var rabbitmqPassword = '${uniqueString(resourceGroup().id, prefix, 'rabbitmq')}Rp!1'
var mongoConnectionString = 'mongodb://rpi:${mongoPassword}@${prefix}-mongodb:27017/RPIRealtimeCache?authSource=admin'

// RabbitMQ hostname (resolved for internal vs external)
var rabbitmqHostname = queueProviderType == 'internal' ? '${prefix}-rabbitmq' : externalRabbitMQHostname

// ── Realtime API cache env vars (SDK mode) ─────────────────
// Non-secret settings are env vars. Secret values (ConnectionString, Password)
// are read from Key Vault at runtime via KeyVault__UseForAppSettings + managed identity.
var realtimeCacheEnv = !enableRealtime ? [] : (cacheProvider == 'mongodb' ? [
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Name', value: 'mongodb' }
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Assembly', value: 'RedPoint.Resonance.MongoDBCache' }
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Class', value: 'RedPoint.Resonance.MongoDBCache.MongoDBCacheHandler' }
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Settings__0__Key', value: 'Database' }
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Settings__0__Value', value: 'RPIRealtimeCache' }
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Settings__1__Key', value: 'CollectionName' }
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Settings__1__Value', value: 'RPIRealtimeCache' }
] : (cacheProviderType == 'managed' ? [
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Name', value: 'azureredis' }
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Assembly', value: 'RedPoint.Azure.Server' }
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Class', value: 'RedPoint.Azure.Server.AzureRedisCache.AzureRedisCacheHandler' }
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Settings__0__Key', value: 'Database' }
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Settings__0__Value', value: 'RPIRealtimeCache' }
] : [
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Name', value: 'redis' }
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Assembly', value: 'RedPoint.Resonance.RedisCache' }
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Class', value: 'RedPoint.Resonance.RedisCache.RedisCacheHandler' }
  { name: 'RealtimeAPIConfiguration__CacheSettings__Caches__0__Settings__0__Key', value: 'IPAddress' }
]))

// ── Realtime API queue env vars (SDK mode) ─────────────────
var realtimeQueueEnv = queueProvider == 'rabbitmq' ? [
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Assembly', value: 'RedPoint.Resonance.RabbitMQAccess' }
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Type', value: 'RedPoint.Resonance.RabbitMQAccess.RabbitMQFactory' }
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__0__Key', value: 'Hostname' }
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__0__Value', value: rabbitmqHostname }
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__1__Key', value: 'VirtualHost' }
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__1__Value', value: '/' }
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__2__Key', value: 'Username' }
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__2__Value', value: 'rpi' }
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__3__Key', value: 'Password' }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Assembly', value: 'RedPoint.Resonance.RabbitMQAccess' }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Type', value: 'RedPoint.Resonance.RabbitMQAccess.RabbitMQFactory' }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__0__Key', value: 'Hostname' }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__0__Value', value: rabbitmqHostname }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__1__Key', value: 'VirtualHost' }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__1__Value', value: '/' }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__2__Key', value: 'Username' }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__2__Value', value: 'rpi' }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__3__Key', value: 'Password' }
] : [
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Assembly', value: 'RedPoint.Azure.Server' }
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Type', value: 'RedPoint.Azure.Server.AzureQueue.AzureServiceBusQueueFactory' }
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__0__Key', value: 'QueueType' }
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__0__Value', value: 'ServiceBus' }
  { name: 'RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__1__Key', value: 'ConnectionString' }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Assembly', value: 'RedPoint.Azure.Server' }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Type', value: 'RedPoint.Azure.Server.AzureQueue.AzureServiceBusQueueFactory' }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__0__Key', value: 'QueueType' }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__0__Value', value: 'ServiceBus' }
  { name: 'RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__1__Key', value: 'ConnectionString' }
]

// ── Callback API queue env vars (SDK mode) ─────────────────
var callbackQueueEnv = queueProvider == 'rabbitmq' ? [
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Assembly', value: 'RedPoint.Resonance.RabbitMQAccess' }
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Type', value: 'RedPoint.Resonance.RabbitMQAccess.RabbitMQFactory' }
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__0__Key', value: 'Hostname' }
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__0__Value', value: rabbitmqHostname }
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__1__Key', value: 'VirtualHost' }
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__1__Value', value: '/' }
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__2__Key', value: 'Username' }
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__2__Value', value: 'rpi' }
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__3__Key', value: 'Password' }
] : [
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Assembly', value: 'RedPoint.Azure.Server' }
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Type', value: 'RedPoint.Azure.Server.AzureQueue.AzureServiceBusQueueFactory' }
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__0__Key', value: 'QueueType' }
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__0__Value', value: 'ServiceBus' }
  { name: 'CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__1__Key', value: 'ConnectionString' }
]

// Image URIs
// Default image names (can be overridden via imageNameOverrides parameter)
var defaultImageNames = {
  rediscache: 'rediscache'
  rabbitmq: 'rabbitmq'
  mongodb: 'mongodb'
  interactionapi: 'rpi-interactionapi'
  deploymentapi: 'rpi-deploymentapi'
  executionservice: 'rpi-executionservice'
  nodemanager: 'rpi-nodemanager'
  integrationapi: 'rpi-integrationapi'
  realtimeapi: 'rpi-realtimeapi'
  callbackapi: 'rpi-callbackapi'
  queuereader: 'rpi-queuereader'
}
var imgNames = union(defaultImageNames, imageNameOverrides)

var images = {
  rediscache: '${imageRegistry}/${imgNames.rediscache}:${imageTag}'
  rabbitmq: '${imageRegistry}/${imgNames.rabbitmq}:${imageTag}'
  mongodb: '${imageRegistry}/${imgNames.mongodb}:${imageTag}'
  interactionapi: '${imageRegistry}/${imgNames.interactionapi}:${imageTag}'
  deploymentapi: '${imageRegistry}/${imgNames.deploymentapi}:${imageTag}'
  executionservice: '${imageRegistry}/${imgNames.executionservice}:${imageTag}'
  nodemanager: '${imageRegistry}/${imgNames.nodemanager}:${imageTag}'
  integrationapi: '${imageRegistry}/${imgNames.integrationapi}:${imageTag}'
  realtimeapi: '${imageRegistry}/${imgNames.realtimeapi}:${imageTag}'
  callbackapi: '${imageRegistry}/${imgNames.callbackapi}:${imageTag}'
  queuereader: '${imageRegistry}/${imgNames.queuereader}:${imageTag}'
}

// ── Log Analytics Workspace ─────────────────────────────────

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (!useExistingLogAnalytics) {
  name: '${prefix}-logs'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: logRetentionDays
  }
}

resource existingLogAnalyticsRg 'Microsoft.Resources/resourceGroups@2024-03-01' existing = if (useExistingLogAnalytics) {
  name: existingLogAnalyticsResourceGroup
  scope: subscription()
}

resource existingLogAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = if (useExistingLogAnalytics) {
  name: last(split(existingLogAnalyticsWorkspaceId, '/'))
  scope: existingLogAnalyticsRg
}

// ── VNet (created only when not using an existing one) ──────

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = if (!useExistingVnet) {
  name: '${prefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [
      {
        name: 'container-apps'
        properties: {
          addressPrefix: '10.0.0.0/23'
          delegations: [
            { name: 'Microsoft.App.environments', properties: { serviceName: 'Microsoft.App/environments' } }
          ]
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
    ]
  }
}

var containerAppsSubnetId = useExistingVnet ? existingSubnetId : vnet.properties.subnets[0].id
var peSubnetResolved = enablePrivateEndpoints ? (useExistingVnet ? peSubnetId : vnet.properties.subnets[1].id) : ''

// ── Key Vault ───────────────────────────────────────────────

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${prefix}-kv'
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: enablePrivateEndpoints ? 'Disabled' : 'Enabled'
    networkAcls: enablePrivateEndpoints ? { defaultAction: 'Deny', bypass: 'AzureServices' } : { defaultAction: 'Allow' }
  }
}

// Key Vault Secrets Officer role for the managed identity
resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, managedIdentityId, 'KeyVaultSecretsOfficer')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: managedIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Store database connection strings in Key Vault
resource secretOpsDb 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'ConnectionString-Operations-Database'
  properties: {
    value: databaseType == 'sqlserver'
      ? 'Server=tcp:${useExistingDatabase ? existingDatabaseServerFQDN : sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=${pulseDatabaseName};User ID=${databaseUsername};Password=${databasePassword};Encrypt=True;TrustServerCertificate=True;'
      : 'Host=${useExistingDatabase ? existingDatabaseServerFQDN : postgresServer.properties.fullyQualifiedDomainName};Port=5432;Database=${pulseDatabaseName};Username=${databaseUsername};Password=${databasePassword};SSL Mode=Require;Trust Server Certificate=true;'
  }
}

resource secretLogDb 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'ConnectionString-Logging-Database'
  properties: {
    value: databaseType == 'sqlserver'
      ? 'Server=tcp:${useExistingDatabase ? existingDatabaseServerFQDN : sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=${pulseLoggingDatabaseName};User ID=${databaseUsername};Password=${databasePassword};Encrypt=True;TrustServerCertificate=True;'
      : 'Host=${useExistingDatabase ? existingDatabaseServerFQDN : postgresServer.properties.fullyQualifiedDomainName};Port=5432;Database=${pulseLoggingDatabaseName};Username=${databaseUsername};Password=${databasePassword};SSL Mode=Require;Trust Server Certificate=true;'
  }
}

resource secretDbPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'Operations-Database-Server-Password'
  properties: { value: databasePassword }
}

resource secretDbUsername 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'Operations-Database-Server-Username'
  properties: { value: databaseUsername }
}

resource secretDbHost 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'Operations-Database-ServerHost'
  properties: {
    value: useExistingDatabase
      ? existingDatabaseServerFQDN
      : (databaseType == 'sqlserver'
        ? sqlServer.properties.fullyQualifiedDomainName
        : postgresServer.properties.fullyQualifiedDomainName)
  }
}

resource secretPulseDb 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'Operations-Database-Pulse-Database-Name'
  properties: { value: pulseDatabaseName }
}

resource secretLoggingDb 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'Operations-Database-Pulse-Logging-Database-Name'
  properties: { value: pulseLoggingDatabaseName }
}

// ── Azure SQL Server (conditional) ──────────────────────────

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = if (createSqlServer) {
  name: '${prefix}-sql'
  location: location
  tags: tags
  properties: {
    administratorLogin: databaseUsername
    administratorLoginPassword: databasePassword
    version: '12.0'
    minimalTlsVersion: '1.2'
  }
}

resource sqlDbPulse 'Microsoft.Sql/servers/databases@2023-08-01-preview' = if (createSqlServer) {
  parent: sqlServer
  name: '${prefix}-pulse'
  location: location
  tags: tags
  sku: { name: 'S2', tier: 'Standard' }
}

resource sqlDbLogging 'Microsoft.Sql/servers/databases@2023-08-01-preview' = if (createSqlServer) {
  parent: sqlServer
  name: '${prefix}-pulse-logging'
  location: location
  tags: tags
  sku: { name: 'S0', tier: 'Standard' }
}

// Allow Azure services
resource sqlFirewall 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (createSqlServer) {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ── PostgreSQL Flexible Server (conditional) ────────────────

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-12-01-preview' = if (createPostgresServer) {
  name: '${prefix}-pg'
  location: location
  tags: tags
  sku: { name: 'Standard_B2ms', tier: 'Burstable' }
  properties: {
    version: '16'
    administratorLogin: databaseUsername
    administratorLoginPassword: databasePassword
    storage: { storageSizeGB: 32 }
    backup: { backupRetentionDays: 7 }
  }
}

resource pgDbPulse 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = if (createPostgresServer) {
  parent: postgresServer
  name: '${prefix}-pulse'
}

resource pgDbLogging 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-12-01-preview' = if (createPostgresServer) {
  parent: postgresServer
  name: '${prefix}-pulse-logging'
}

resource pgFirewall 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-12-01-preview' = if (createPostgresServer) {
  parent: postgresServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ── Storage Account (File Output Directory) ─────────────────

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: replace('${prefix}files', '-', '')
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: enablePrivateEndpoints ? 'Disabled' : 'Enabled'
    networkAcls: enablePrivateEndpoints ? { defaultAction: 'Deny', bypass: 'AzureServices' } : { defaultAction: 'Allow' }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: 'rpifileoutput'
  properties: {
    shareQuota: 50
  }
}

// ── Azure Cache for Redis (Realtime cache provider) ─────────

resource redisCache 'Microsoft.Cache/redis@2024-03-01' = if (createManagedRedis) {
  name: '${prefix}-redis'
  location: location
  tags: tags
  properties: {
    sku: { name: 'Basic', family: 'C', capacity: 1 }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    publicNetworkAccess: enablePrivateEndpoints ? 'Disabled' : 'Enabled'
  }
}

// Store Azure Redis connection string in Key Vault
resource secretManagedRedis 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (createManagedRedis) {
  parent: keyVault
  name: 'RealtimeAPI-RedisCache-ConnectionString'
  properties: {
    value: '${redisCache.properties.hostName}:${redisCache.properties.sslPort},password=${redisCache.listKeys().primaryKey},ssl=True,abortConnect=False'
  }
}

// Store internal MongoDB connection string in Key Vault
resource secretInternalMongoDB 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (createInternalMongoDB) {
  parent: keyVault
  name: 'RealtimeAPI-MongoCache-ConnectionString'
  properties: {
    value: mongoConnectionString
  }
}

// Store external cache connection string in Key Vault
resource secretExternalCache 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (enableRealtime && cacheProviderType == 'external') {
  parent: keyVault
  name: cacheProvider == 'mongodb' ? 'RealtimeAPI-MongoCache-ConnectionString' : 'RealtimeAPI-RedisCache-ConnectionString'
  properties: {
    value: externalCacheConnectionString
  }
}

// ── Azure Service Bus (Realtime + Callback queue provider) ──

resource serviceBus 'Microsoft.ServiceBus/namespaces@2024-01-01' = if (createManagedServiceBus) {
  name: '${prefix}-servicebus'
  location: location
  tags: tags
  sku: enablePrivateEndpoints
    ? { name: 'Premium', tier: 'Premium', capacity: 1 }
    : { name: 'Basic', tier: 'Basic' }
}

// Realtime queues
resource queueFormSubmission 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = if (createManagedServiceBus) {
  parent: serviceBus
  name: 'RPIWebFormSubmission'
  properties: { maxDeliveryCount: 10 }
}

resource queueWebEvents 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = if (createManagedServiceBus) {
  parent: serviceBus
  name: 'RPIWebEvents'
  properties: { maxDeliveryCount: 10 }
}

resource queueCacheData 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = if (createManagedServiceBus) {
  parent: serviceBus
  name: 'RPIWebCacheData'
  properties: { maxDeliveryCount: 10 }
}

resource queueRecommendations 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = if (createManagedServiceBus) {
  parent: serviceBus
  name: 'RPIWebRecommendations'
  properties: { maxDeliveryCount: 10 }
}

resource queueListener 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = if (createManagedServiceBus) {
  parent: serviceBus
  name: 'RPIQueueListener'
  properties: { maxDeliveryCount: 10 }
}

resource queueCallback 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = if (createManagedServiceBus) {
  parent: serviceBus
  name: 'RPICallbackApiQueue'
  properties: { maxDeliveryCount: 10 }
}

// Service Bus authorization rule for the connection string
resource sbAuthRule 'Microsoft.ServiceBus/namespaces/AuthorizationRules@2024-01-01' = if (createManagedServiceBus) {
  parent: serviceBus
  name: 'rpi-send-listen'
  properties: {
    rights: ['Send', 'Listen']
  }
}

// Store Service Bus connection string in Key Vault
resource secretManagedServiceBus 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (createManagedServiceBus) {
  parent: keyVault
  name: 'RealtimeAPI-ServiceBus-ConnectionString'
  properties: {
    value: sbAuthRule.listKeys().primaryConnectionString
  }
}

// Store internal RabbitMQ password in Key Vault
resource secretInternalRabbitMQ 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (createInternalRabbitMQ) {
  parent: keyVault
  name: 'RealtimeAPI-RabbitMQ-Password'
  properties: {
    value: rabbitmqPassword
  }
}

// Store external RabbitMQ password in Key Vault
resource secretExternalRabbitMQ 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if ((enableRealtime || enableCallback) && queueProvider == 'rabbitmq' && queueProviderType == 'external') {
  parent: keyVault
  name: 'RealtimeAPI-RabbitMQ-Password'
  properties: {
    value: externalRabbitMQPassword
  }
}

// Store external Service Bus connection string in Key Vault
resource secretExternalServiceBus 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if ((enableRealtime || enableCallback) && queueProvider == 'servicebus' && queueProviderType == 'external') {
  parent: keyVault
  name: 'RealtimeAPI-ServiceBus-ConnectionString'
  properties: {
    value: externalQueueConnectionString
  }
}

// ── Container Apps Environment ──────────────────────────────

resource containerEnv 'Microsoft.App/managedEnvironments@2024-02-02-preview' = {
  name: '${prefix}-env'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${managedIdentityId}': {} }
  }
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: useExistingLogAnalytics ? existingLogAnalytics.properties.customerId : logAnalytics.properties.customerId
        sharedKey: useExistingLogAnalytics ? existingLogAnalytics.listKeys().primarySharedKey : logAnalytics.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: containerAppsSubnetId
      internal: isInternal
    }
    customDomainConfiguration: hasCert ? {
      dnsSuffix: ingressDomain
      certificateKeyVaultProperties: {
        keyVaultUrl: certificateKeyVaultUrl
        identity: managedIdentityId
      }
    } : null
  }
}

// Azure Files storage mount in the environment
resource envStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: containerEnv
  name: 'rpifiles'
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: fileShare.name
      accessMode: 'ReadWrite'
    }
  }
}

// ── TLS Certificate for custom domains ─────────────────────

var hasCert = !empty(ingressDomain) && !empty(certificateKeyVaultName) && !empty(certificateName)
var certificateKeyVaultUrl = hasCert ? 'https://${certificateKeyVaultName}${environment().suffixes.keyvaultDns}/secrets/${certificateName}' : ''

// ── Shared environment variables (all apps) ────────────────

var databaseTypeValue = databaseType == 'sqlserver' ? 'AzureSQLDatabase' : 'PostgreSQL'

var sharedEnv = [
  // Logging
  { name: 'Logging__LogLevel__Default', value: 'Information' }
  { name: 'Logging__Database__LogLevel__Default', value: 'Information' }
  { name: 'Logging__Database__RPITrace', value: 'Information' }
  { name: 'Logging__Database__RPIError', value: 'Information' }
  { name: 'Logging__Console__LogLevel__Default', value: 'Error' }
  // Database configuration (non-secret)
  { name: 'ClusterEnvironment__OperationalDatabase__DatabaseType', value: databaseTypeValue }
  { name: 'ClusterEnvironment__OperationalDatabase__ConnectionSettings__IsUsingCredentials', value: 'true' }
  { name: 'ClusterEnvironment__OperationalDatabase__ConnectionSettings__DatabaseSchema', value: 'dbo' }
  { name: 'ClusterEnvironment__OperationalDatabase__ConnectionSettings__SQLServerSettings__Encrypt', value: 'true' }
  { name: 'ClusterEnvironment__OperationalDatabase__ConnectionSettings__SQLServerSettings__TrustServerCertificate', value: 'true' }
  // Cloud identity (managed identity on Container Apps)
  { name: 'CloudIdentity__Azure__CredentialType', value: 'AzureIdentity' }
  { name: 'AZURE_CLIENT_ID', value: managedIdentityClientId }
]

// PostgreSQL-specific env vars
var postgresEnv = databaseType == 'postgresql' ? [
  { name: 'ClusterEnvironment__OperationalDatabase__ConnectionSettings__Port', value: '5432' }
] : []

// ── Key Vault secret references (Container Apps equivalent of K8s secretKeyRef) ──

var kvSecretBaseUrl = '${keyVault.properties.vaultUri}secrets'

var sharedSecrets = [
  { name: 'db-pulse-name', keyVaultUrl: '${kvSecretBaseUrl}/Operations-Database-Pulse-Database-Name', identity: managedIdentityId }
  { name: 'db-logging-name', keyVaultUrl: '${kvSecretBaseUrl}/Operations-Database-Pulse-Logging-Database-Name', identity: managedIdentityId }
  { name: 'db-server-host', keyVaultUrl: '${kvSecretBaseUrl}/Operations-Database-ServerHost', identity: managedIdentityId }
  { name: 'db-username', keyVaultUrl: '${kvSecretBaseUrl}/Operations-Database-Server-Username', identity: managedIdentityId }
  { name: 'db-password', keyVaultUrl: '${kvSecretBaseUrl}/Operations-Database-Server-Password', identity: managedIdentityId }
]

// Env vars that reference the KV secrets above
var sharedSecretEnv = [
  { name: 'ClusterEnvironment__OperationalDatabase__PulseDatabaseName', secretRef: 'db-pulse-name' }
  { name: 'ClusterEnvironment__OperationalDatabase__LoggingDatabaseName', secretRef: 'db-logging-name' }
  { name: 'ClusterEnvironment__OperationalDatabase__ConnectionSettings__Server', secretRef: 'db-server-host' }
  { name: 'ClusterEnvironment__OperationalDatabase__ConnectionSettings__Username', secretRef: 'db-username' }
  { name: 'ClusterEnvironment__OperationalDatabase__ConnectionSettings__Password', secretRef: 'db-password' }
]

// ── Container App: Deployment API ───────────────────────────

resource deploymentApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${prefix}-deploymentapi'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${managedIdentityId}': {} }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: concat(registrySecrets, sharedSecrets)
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
      }
    }
    template: {
      containers: [
        {
          name: 'deploymentapi'
          image: images.deploymentapi
          resources: { cpu: json(cpuCores), memory: appMemory }
          env: concat(sharedEnv, sharedSecretEnv, postgresEnv)
          volumeMounts: [
            { volumeName: 'rpifiles', mountPath: '/rpifileoutputdir' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
      volumes: [
        { name: 'rpifiles', storageName: envStorage.name, storageType: 'AzureFile' }
      ]
    }
  }
}

// ── Container App: Interaction API ──────────────────────────

resource interactionApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${prefix}-interactionapi'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${managedIdentityId}': {} }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: concat(registrySecrets, sharedSecrets)
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
      }
    }
    template: {
      containers: [
        {
          name: 'interactionapi'
          image: images.interactionapi
          resources: { cpu: json(cpuCores), memory: appMemory }
          env: concat(sharedEnv, sharedSecretEnv, postgresEnv, [
            { name: 'Authentication__RPIAuthentication__Enabled', value: 'true' }
            { name: 'Authentication__RPIAuthentication__AuthorizationHost', value: 'http://${prefix}-deploymentapi' }
          ])
          volumeMounts: [
            { volumeName: 'rpifiles', mountPath: '/rpifileoutputdir' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 5 }
      volumes: [
        { name: 'rpifiles', storageName: envStorage.name, storageType: 'AzureFile' }
      ]
    }
  }
}

// ── Container App: Execution Service ────────────────────────

resource executionService 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${prefix}-executionservice'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${managedIdentityId}': {} }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: concat(registrySecrets, sharedSecrets)
    }
    template: {
      containers: [
        {
          name: 'executionservice'
          image: images.executionservice
          resources: { cpu: json(execCpuCores), memory: execMemory }
          env: concat(sharedEnv, sharedSecretEnv, postgresEnv, [
            { name: 'Authentication__RPIAuthentication__Enabled', value: 'true' }
            { name: 'Authentication__RPIAuthentication__AuthorizationHost', value: 'http://${prefix}-deploymentapi' }
            { name: 'ExecutionService__InternalCache__Provider', value: 'filesystem' }
            { name: 'ExecutionService__InternalCache__BackupToOpsDBInterval', value: '00:00:20' }
          ])
          volumeMounts: [
            { volumeName: 'rpifiles', mountPath: '/rpifileoutputdir' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 8 }
      volumes: [
        { name: 'rpifiles', storageName: envStorage.name, storageType: 'AzureFile' }
      ]
    }
  }
}

// ── Container App: Node Manager ─────────────────────────────

resource nodeManager 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${prefix}-nodemanager'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${managedIdentityId}': {} }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: concat(registrySecrets, sharedSecrets)
    }
    template: {
      containers: [
        {
          name: 'nodemanager'
          image: images.nodemanager
          resources: { cpu: json(cpuCores), memory: appMemory }
          env: concat(sharedEnv, sharedSecretEnv, postgresEnv, [
            { name: 'Authentication__RPIAuthentication__Enabled', value: 'true' }
            { name: 'Authentication__RPIAuthentication__AuthorizationHost', value: 'http://${prefix}-deploymentapi' }
          ])
          volumeMounts: [
            { volumeName: 'rpifiles', mountPath: '/rpifileoutputdir' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
      volumes: [
        { name: 'rpifiles', storageName: envStorage.name, storageType: 'AzureFile' }
      ]
    }
  }
}

// ── Container App: Integration API ──────────────────────────

resource integrationApi 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${prefix}-integrationapi'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${managedIdentityId}': {} }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: concat(registrySecrets, sharedSecrets)
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
      }
    }
    template: {
      containers: [
        {
          name: 'integrationapi'
          image: images.integrationapi
          resources: { cpu: json(cpuCores), memory: appMemory }
          env: concat(sharedEnv, sharedSecretEnv, postgresEnv, [
            { name: 'Authentication__RPIAuthentication__Enabled', value: 'true' }
            { name: 'Authentication__RPIAuthentication__AuthorizationHost', value: 'http://${prefix}-deploymentapi' }
          ])
          volumeMounts: [
            { volumeName: 'rpifiles', mountPath: '/rpifileoutputdir' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
      volumes: [
        { name: 'rpifiles', storageName: envStorage.name, storageType: 'AzureFile' }
      ]
    }
  }
}

// ── Container App: MongoDB (internal cache provider) ───────

resource mongoDb 'Microsoft.App/containerApps@2024-03-01' = if (createInternalMongoDB) {
  name: '${prefix}-mongodb'
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: concat(registrySecrets, [
        { name: 'mongodb-password', value: mongoPassword }
      ])
      ingress: {
        external: false
        targetPort: 27017
        transport: 'tcp'
      }
    }
    template: {
      containers: [
        {
          name: 'mongodb'
          image: images.mongodb
          resources: { cpu: json('1'), memory: '2Gi' }
          env: [
            { name: 'MONGO_INITDB_ROOT_USERNAME', value: 'rpi' }
            { name: 'MONGO_INITDB_ROOT_PASSWORD', secretRef: 'mongodb-password' }
            { name: 'MONGO_INITDB_DATABASE', value: 'RPIRealtimeCache' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

// ── Container App: RabbitMQ (internal queue provider) ──────

resource rabbitMq 'Microsoft.App/containerApps@2024-03-01' = if (createInternalRabbitMQ) {
  name: '${prefix}-rabbitmq'
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: concat(registrySecrets, [
        { name: 'rabbitmq-password', value: rabbitmqPassword }
      ])
      ingress: {
        external: false
        targetPort: 5672
        transport: 'tcp'
      }
    }
    template: {
      containers: [
        {
          name: 'rabbitmq'
          image: images.rabbitmq
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'RABBITMQ_DEFAULT_USER', value: 'rpi' }
            { name: 'RABBITMQ_DEFAULT_PASS', secretRef: 'rabbitmq-password' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

// ── Container App: Realtime API (conditional) ───────────────

resource realtimeApi 'Microsoft.App/containerApps@2024-03-01' = if (enableRealtime) {
  name: '${prefix}-realtimeapi'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${managedIdentityId}': {} }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: concat(registrySecrets, sharedSecrets)
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
      }
    }
    template: {
      containers: [
        {
          name: 'realtimeapi'
          image: images.realtimeapi
          resources: { cpu: json(cpuCores), memory: appMemory }
          env: concat(sharedEnv, sharedSecretEnv, postgresEnv, realtimeCacheEnv, realtimeQueueEnv)
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 5 }
    }
  }
}

// ── Container App: Callback API (conditional) ───────────────

resource callbackApi 'Microsoft.App/containerApps@2024-03-01' = if (enableCallback) {
  name: '${prefix}-callbackapi'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${managedIdentityId}': {} }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: concat(registrySecrets, sharedSecrets)
      ingress: {
        external: true
        targetPort: 8080
        transport: 'http'
      }
    }
    template: {
      containers: [
        {
          name: 'callbackapi'
          image: images.callbackapi
          resources: { cpu: json(cpuCores), memory: appMemory }
          env: concat(sharedEnv, sharedSecretEnv, postgresEnv, callbackQueueEnv)
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
}

// ── Container App: Queue Reader (conditional) ───────────────

resource queueReader 'Microsoft.App/containerApps@2024-03-01' = if (enableQueueReader) {
  name: '${prefix}-queuereader'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${managedIdentityId}': {} }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registries
      secrets: concat(registrySecrets, sharedSecrets)
    }
    template: {
      containers: [
        {
          name: 'queuereader'
          image: images.queuereader
          resources: { cpu: json(cpuCores), memory: appMemory }
          env: concat(sharedEnv, sharedSecretEnv, postgresEnv)
          volumeMounts: [
            { volumeName: 'rpifiles', mountPath: '/rpifileoutputdir' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 5 }
      volumes: [
        { name: 'rpifiles', storageName: envStorage.name, storageType: 'AzureFile' }
      ]
    }
  }
}

// ── Private Endpoints (conditional) ─────────────────────────

// Helper: resolve existing DNS zone resource IDs
var existingDnsRg = existingDnsZoneResourceGroup
var dnsZoneIdKv = useExistingDnsZones ? resourceId(existingDnsZoneSubscriptionId, existingDnsRg, 'Microsoft.Network/privateDnsZones', 'privatelink.vaultcore.azure.net') : ''
var dnsZoneIdStorage = useExistingDnsZones ? resourceId(existingDnsZoneSubscriptionId, existingDnsRg, 'Microsoft.Network/privateDnsZones', 'privatelink.file.${environment().suffixes.storage}') : ''
var dnsZoneIdSql = useExistingDnsZones ? resourceId(existingDnsZoneSubscriptionId, existingDnsRg, 'Microsoft.Network/privateDnsZones', 'privatelink${environment().suffixes.sqlServerHostname}') : ''
var dnsZoneIdPg = useExistingDnsZones ? resourceId(existingDnsZoneSubscriptionId, existingDnsRg, 'Microsoft.Network/privateDnsZones', 'privatelink.postgres.database.azure.com') : ''
var dnsZoneIdRedis = useExistingDnsZones ? resourceId(existingDnsZoneSubscriptionId, existingDnsRg, 'Microsoft.Network/privateDnsZones', 'privatelink.redis.cache.windows.net') : ''
var dnsZoneIdServiceBus = useExistingDnsZones ? resourceId(existingDnsZoneSubscriptionId, existingDnsRg, 'Microsoft.Network/privateDnsZones', 'privatelink.servicebus.windows.net') : ''

// ── New DNS Zones (only when NOT using existing) ────────────

resource dnsZoneKv 'Microsoft.Network/privateDnsZones@2024-06-01' = if (enablePrivateEndpoints && !useExistingDnsZones) {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: tags
}

resource dnsZoneKvLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (enablePrivateEndpoints && !useExistingDnsZones) {
  parent: dnsZoneKv
  name: '${prefix}-kv-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: useExistingVnet ? existingVnetId : vnet.id }
    registrationEnabled: false
  }
}

resource dnsZoneStorage 'Microsoft.Network/privateDnsZones@2024-06-01' = if (enablePrivateEndpoints && !useExistingDnsZones) {
  name: 'privatelink.file.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

resource dnsZoneStorageLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (enablePrivateEndpoints && !useExistingDnsZones) {
  parent: dnsZoneStorage
  name: '${prefix}-storage-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: useExistingVnet ? existingVnetId : vnet.id }
    registrationEnabled: false
  }
}

resource dnsZoneSql 'Microsoft.Network/privateDnsZones@2024-06-01' = if (enablePrivateEndpoints && !useExistingDnsZones && createSqlServer) {
  name: 'privatelink${environment().suffixes.sqlServerHostname}'
  location: 'global'
  tags: tags
}

resource dnsZoneSqlLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (enablePrivateEndpoints && !useExistingDnsZones && createSqlServer) {
  parent: dnsZoneSql
  name: '${prefix}-sql-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: useExistingVnet ? existingVnetId : vnet.id }
    registrationEnabled: false
  }
}

resource dnsZonePg 'Microsoft.Network/privateDnsZones@2024-06-01' = if (enablePrivateEndpoints && !useExistingDnsZones && createPostgresServer) {
  name: 'privatelink.postgres.database.azure.com'
  location: 'global'
  tags: tags
}

resource dnsZonePgLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (enablePrivateEndpoints && !useExistingDnsZones && createPostgresServer) {
  parent: dnsZonePg
  name: '${prefix}-pg-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: useExistingVnet ? existingVnetId : vnet.id }
    registrationEnabled: false
  }
}

resource dnsZoneRedis 'Microsoft.Network/privateDnsZones@2024-06-01' = if (enablePrivateEndpoints && !useExistingDnsZones && createManagedRedis) {
  name: 'privatelink.redis.cache.windows.net'
  location: 'global'
  tags: tags
}

resource dnsZoneRedisLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (enablePrivateEndpoints && !useExistingDnsZones && createManagedRedis) {
  parent: dnsZoneRedis
  name: '${prefix}-redis-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: useExistingVnet ? existingVnetId : vnet.id }
    registrationEnabled: false
  }
}

resource dnsZoneServiceBus 'Microsoft.Network/privateDnsZones@2024-06-01' = if (enablePrivateEndpoints && !useExistingDnsZones && createManagedServiceBus) {
  name: 'privatelink.servicebus.windows.net'
  location: 'global'
  tags: tags
}

resource dnsZoneServiceBusLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (enablePrivateEndpoints && !useExistingDnsZones && createManagedServiceBus) {
  parent: dnsZoneServiceBus
  name: '${prefix}-servicebus-link'
  location: 'global'
  properties: {
    virtualNetwork: { id: useExistingVnet ? existingVnetId : vnet.id }
    registrationEnabled: false
  }
}

// ── Private Endpoints ───────────────────────────────────────

resource peKeyVault 'Microsoft.Network/privateEndpoints@2024-01-01' = if (enablePrivateEndpoints) {
  name: '${prefix}-pe-kv'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetResolved }
    privateLinkServiceConnections: [
      { name: '${prefix}-pe-kv', properties: { privateLinkServiceId: keyVault.id, groupIds: ['vault'] } }
    ]
  }
}

resource dnsGroupKv 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = if (enablePrivateEndpoints) {
  parent: peKeyVault
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'config', properties: { privateDnsZoneId: useExistingDnsZones ? dnsZoneIdKv : dnsZoneKv.id } }
    ]
  }
}

resource peStorage 'Microsoft.Network/privateEndpoints@2024-01-01' = if (enablePrivateEndpoints) {
  name: '${prefix}-pe-storage'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetResolved }
    privateLinkServiceConnections: [
      { name: '${prefix}-pe-storage', properties: { privateLinkServiceId: storageAccount.id, groupIds: ['file'] } }
    ]
  }
}

resource dnsGroupStorage 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = if (enablePrivateEndpoints) {
  parent: peStorage
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'config', properties: { privateDnsZoneId: useExistingDnsZones ? dnsZoneIdStorage : dnsZoneStorage.id } }
    ]
  }
}

resource peSql 'Microsoft.Network/privateEndpoints@2024-01-01' = if (enablePrivateEndpoints && createSqlServer) {
  name: '${prefix}-pe-sql'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetResolved }
    privateLinkServiceConnections: [
      { name: '${prefix}-pe-sql', properties: { privateLinkServiceId: sqlServer.id, groupIds: ['sqlServer'] } }
    ]
  }
}

resource dnsGroupSql 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = if (enablePrivateEndpoints && createSqlServer) {
  parent: peSql
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'config', properties: { privateDnsZoneId: useExistingDnsZones ? dnsZoneIdSql : dnsZoneSql.id } }
    ]
  }
}

resource pePg 'Microsoft.Network/privateEndpoints@2024-01-01' = if (enablePrivateEndpoints && createPostgresServer) {
  name: '${prefix}-pe-pg'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetResolved }
    privateLinkServiceConnections: [
      { name: '${prefix}-pe-pg', properties: { privateLinkServiceId: postgresServer.id, groupIds: ['postgresqlServer'] } }
    ]
  }
}

resource dnsGroupPg 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = if (enablePrivateEndpoints && createPostgresServer) {
  parent: pePg
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'config', properties: { privateDnsZoneId: useExistingDnsZones ? dnsZoneIdPg : dnsZonePg.id } }
    ]
  }
}

resource peRedis 'Microsoft.Network/privateEndpoints@2024-01-01' = if (enablePrivateEndpoints && createManagedRedis) {
  name: '${prefix}-pe-redis'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetResolved }
    privateLinkServiceConnections: [
      { name: '${prefix}-pe-redis', properties: { privateLinkServiceId: redisCache.id, groupIds: ['redisCache'] } }
    ]
  }
}

resource dnsGroupRedis 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = if (enablePrivateEndpoints && createManagedRedis) {
  parent: peRedis
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'config', properties: { privateDnsZoneId: useExistingDnsZones ? dnsZoneIdRedis : dnsZoneRedis.id } }
    ]
  }
}

resource peServiceBus 'Microsoft.Network/privateEndpoints@2024-01-01' = if (enablePrivateEndpoints && createManagedServiceBus) {
  name: '${prefix}-pe-servicebus'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetResolved }
    privateLinkServiceConnections: [
      { name: '${prefix}-pe-servicebus', properties: { privateLinkServiceId: serviceBus.id, groupIds: ['namespace'] } }
    ]
  }
}

resource dnsGroupServiceBus 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = if (enablePrivateEndpoints && createManagedServiceBus) {
  parent: peServiceBus
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'config', properties: { privateDnsZoneId: useExistingDnsZones ? dnsZoneIdServiceBus : dnsZoneServiceBus.id } }
    ]
  }
}
// ── Outputs ─────────────────────────────────────────────────

output interactionApiUrl string = !empty(ingressDomain) ? 'https://${prefix}-interactionapi.${ingressDomain}' : 'https://${interactionApi.properties.configuration.ingress.fqdn}'
output deploymentApiUrl string = !empty(ingressDomain) ? 'https://${prefix}-deploymentapi.${ingressDomain}' : 'https://${deploymentApi.properties.configuration.ingress.fqdn}'
output integrationApiUrl string = !empty(ingressDomain) ? 'https://${prefix}-integrationapi.${ingressDomain}' : 'https://${integrationApi.properties.configuration.ingress.fqdn}'
output realtimeApiUrl string = enableRealtime ? (!empty(ingressDomain) ? 'https://${prefix}-realtimeapi.${ingressDomain}' : 'https://${realtimeApi.properties.configuration.ingress.fqdn}') : 'not deployed'
output callbackApiUrl string = enableCallback ? 'https://${callbackApi.properties.configuration.ingress.fqdn}' : 'not deployed'
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output managedIdentityClientId string = managedIdentityClientId
output managedIdentityPrincipalId string = managedIdentityPrincipalId
output managedIdentityId string = managedIdentityId
output databaseServer string = useExistingDatabase ? existingDatabaseServerFQDN : (databaseType == 'sqlserver' ? sqlServer.properties.fullyQualifiedDomainName : postgresServer.properties.fullyQualifiedDomainName)

// Environment static IP (used for DNS A records)
output environmentStaticIp string = containerEnv.properties.staticIp

// Container app names (used for DNS A record names)
output deploymentApiName string = deploymentApi.name
output deploymentApiFqdn string = deploymentApi.properties.configuration.ingress.fqdn
output interactionApiName string = interactionApi.name
output interactionApiFqdn string = interactionApi.properties.configuration.ingress.fqdn
output integrationApiName string = integrationApi.name
output integrationApiFqdn string = integrationApi.properties.configuration.ingress.fqdn
output realtimeApiName string = enableRealtime ? realtimeApi.name : ''
output realtimeApiFqdn string = enableRealtime ? realtimeApi.properties.configuration.ingress.fqdn : ''
output callbackApiName string = enableCallback ? callbackApi.name : ''
output callbackApiFqdn string = enableCallback ? callbackApi.properties.configuration.ingress.fqdn : ''
