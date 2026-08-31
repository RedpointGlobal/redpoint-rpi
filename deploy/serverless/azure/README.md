# RPI v7.7 - Azure Container Apps (Serverless)

Deploy the full Redpoint Interaction (RPI) stack on Azure Container Apps without managing a Kubernetes cluster. This template mirrors the same service architecture as the Helm chart but uses Azure-native serverless infrastructure.

## What gets created

| Resource | Purpose |
|:---------|:--------|
| Resource Group | All resources are created in a single auto-named resource group |
| Container Apps Environment | Hosts all RPI services with built-in service discovery |
| Container Apps (5-10) | Core services + optional Realtime, Callback, Queue Reader, MongoDB, RabbitMQ |
| Key Vault | Stores all connection strings and credentials (RBAC-enabled) |
| User-Assigned Managed Identity | Authentication to Key Vault and database |
| Storage Account + File Share | Shared file output directory (Azure Files) |

Depending on your configuration, the template may also create:

| Resource | Condition |
|:---------|:----------|
| Azure SQL Server or PostgreSQL Flexible Server | When `useExistingDatabase=false` |
| Azure Cache for Redis | When `cacheProvider=redis` and `cacheProviderType=managed` |
| Azure Service Bus (Premium when PEs enabled) | When `queueProvider=servicebus` and `queueProviderType=managed` |
| MongoDB Container App | When `cacheProvider=mongodb` and `cacheProviderType=internal` |
| RabbitMQ Container App | When `queueProvider=rabbitmq` and `queueProviderType=internal` |
| Log Analytics Workspace | When `useExistingLogAnalytics=false` |
| VNet + Subnets | When `useExistingVnet=false` |
| Private Endpoints + DNS Zones | When `enablePrivateEndpoints=true` |

## Prerequisites

- Azure CLI installed (`az --version`)
- An Azure subscription with Contributor access
- Container registry credentials for pulling RPI images

## Quick Start

```bash
az deployment sub create \
  --location eastus2 \
  --template-file main.bicep \
  --parameters parameters.json
```

The `environmentName` parameter drives a deterministic hash that names all resources (e.g., `rpi-a1b2c3-*`). The deployment is **idempotent** -- re-running with the same `environmentName` updates existing resources in place.

## Parameters

### Environment

| Parameter | Required | Default | Description |
|:----------|:---------|:--------|:------------|
| `location` | No | Deployment location | Azure region for all resources |
| `environmentName` | **Yes** | | Unique name for this environment (e.g., `dev`, `test`, `prod`). Different values create isolated resource sets |

### Images and Registry

| Parameter | Required | Default | Description |
|:----------|:---------|:--------|:------------|
| `imageTag` | No | `7.7.20260327.1408` | RPI container image tag |
| `imageRegistry` | No | `rg1acrpub.azurecr.io/docker/redpointglobal/releases` | Container registry path (without image name) |
| `registryServer` | No | `rg1acrpub.azurecr.io` | Registry server hostname (used for authentication) |
| `registryUsername` | No | | Registry pull username |
| `registryPassword` | No | | Registry pull password (secure) |
| `imageNameOverrides` | No | `{}` | Override individual image names (see below) |

**Image name overrides:** By default, images use names like `rpi-interactionapi`, `rpi-deploymentapi`, etc. To use a different registry with different image names, override both the registry and the names:

```json
"imageRegistry": { "value": "myregistry.azurecr.io/my-org/my-repo" },
"registryServer": { "value": "myregistry.azurecr.io" },
"imageNameOverrides": {
  "value": {
    "interactionapi": "redpoint-interaction-api",
    "deploymentapi": "redpoint-deployment-api",
    "executionservice": "redpoint-execution-service",
    "nodemanager": "redpoint-node-manager",
    "integrationapi": "redpoint-integration-api",
    "realtimeapi": "redpoint-realtime-api",
    "callbackapi": "redpoint-callback-api",
    "queuereader": "redpoint-queue-reader"
  }
}
```

Available override keys: `interactionapi`, `deploymentapi`, `executionservice`, `nodemanager`, `integrationapi`, `realtimeapi`, `callbackapi`, `queuereader`, `rediscache`, `rabbitmq`, `mongodb`. Only specify the names you want to change -- unspecified keys keep their defaults.

### Database

| Parameter | Required | Default | Description |
|:----------|:---------|:--------|:------------|
| `databaseType` | No | `sqlserver` | `sqlserver` or `postgresql` |
| `databaseUsername` | **Yes** | | Database admin username |
| `databasePassword` | **Yes** | | Database admin password (secure) |
| `useExistingDatabase` | No | `false` | Use a pre-created database server and databases |
| `existingDatabaseServerFQDN` | If `useExistingDatabase` | | FQDN of the existing server (e.g., `myserver.database.windows.net`) |
| `existingPulseDatabaseName` | If `useExistingDatabase` | `Pulse` | Name of the existing Pulse database |
| `existingPulseLoggingDatabaseName` | If `useExistingDatabase` | `Pulse_Logging` | Name of the existing Pulse Logging database |

When `useExistingDatabase=false`, the template creates an Azure SQL Server or PostgreSQL Flexible Server with two databases. When `true`, it uses your existing server and skips database/firewall/PE creation for the database tier.

### Realtime Services

| Parameter | Required | Default | Description |
|:----------|:---------|:--------|:------------|
| `enableRealtime` | No | `false` | Deploy the Realtime API |
| `enableCallback` | No | `false` | Deploy the Callback API |
| `enableQueueReader` | No | `false` | Deploy the Queue Reader |

### Cache Provider

Required when `enableRealtime=true`. The cache provider is used by the Realtime API for visitor data caching.

| Parameter | Required | Default | Description |
|:----------|:---------|:--------|:------------|
| `cacheProvider` | No | `redis` | Cache technology: `redis` or `mongodb` |
| `cacheProviderType` | No | `managed` | How the cache is deployed: `managed`, `internal`, or `external` |
| `externalCacheConnectionString` | If `external` | | BYO cache connection string (secure) |

**Cache provider combinations:**

| `cacheProvider` | `cacheProviderType` | What happens |
|:----------------|:--------------------|:-------------|
| `redis` | `managed` | Creates Azure Cache for Redis (Basic C1). Private endpoint created when `enablePrivateEndpoints=true` |
| `redis` | `external` | You provide a Redis connection string via `externalCacheConnectionString` |
| `mongodb` | `internal` | Deploys a MongoDB container in the environment using the Redpoint MongoDB image |
| `mongodb` | `external` | You provide a MongoDB connection string via `externalCacheConnectionString` (e.g., MongoDB Atlas) |

### Queue Provider

Required when `enableRealtime=true` or `enableCallback=true`. The queue provider handles message passing between the Realtime API, Callback API, and Queue Reader.

| Parameter | Required | Default | Description |
|:----------|:---------|:--------|:------------|
| `queueProvider` | No | `servicebus` | Queue technology: `servicebus` or `rabbitmq` |
| `queueProviderType` | No | `managed` | How the queue is deployed: `managed`, `internal`, or `external` |
| `externalQueueConnectionString` | If Service Bus `external` | | BYO Service Bus connection string (secure) |
| `externalRabbitMQHostname` | If RabbitMQ `external` | | Hostname of your RabbitMQ server |
| `externalRabbitMQPassword` | If RabbitMQ `external` | | RabbitMQ password (secure) |

**Queue provider combinations:**

| `queueProvider` | `queueProviderType` | What happens |
|:----------------|:--------------------|:-------------|
| `servicebus` | `managed` | Creates Azure Service Bus namespace with all RPI queues. Upgrades to Premium SKU when `enablePrivateEndpoints=true` |
| `servicebus` | `external` | You provide a Service Bus connection string via `externalQueueConnectionString` |
| `rabbitmq` | `internal` | Deploys a RabbitMQ container in the environment using the Redpoint RabbitMQ image |
| `rabbitmq` | `external` | You provide hostname and password. Username defaults to `rpi`, virtual host to `/` |

### Ingress

| Parameter | Required | Default | Description |
|:----------|:---------|:--------|:------------|
| `ingressDomain` | No | | Custom domain for ingress (leave empty for auto-generated Azure FQDNs) |
| `ingressMode` | No | `external` | `external` (public) or `internal` (VNet only) |

### Networking

| Parameter | Required | Default | Description |
|:----------|:---------|:--------|:------------|
| `useExistingVnet` | No | `false` | Use an existing VNet instead of creating one |
| `existingVnetId` | If `useExistingVnet` | | Resource ID of the existing VNet |
| `existingSubnetId` | If `useExistingVnet` | | Subnet for Container Apps (must be delegated to `Microsoft.App/environments`, at least /23) |
| `enablePrivateEndpoints` | No | `false` | Create private endpoints for Key Vault, Storage, and managed services |
| `privateEndpointSubnetId` | No | | Subnet for private endpoints (defaults to Container Apps subnet) |
| `useExistingDnsZones` | No | `false` | Use existing `privatelink.*` DNS zones instead of creating new ones |
| `existingDnsZoneResourceGroup` | If `useExistingDnsZones` | | Resource group containing the DNS zones |
| `existingDnsZoneSubscriptionId` | No | Deployment subscription | Subscription containing the DNS zones (if different from deployment subscription) |

### Observability

| Parameter | Required | Default | Description |
|:----------|:---------|:--------|:------------|
| `useExistingLogAnalytics` | No | `false` | Use an existing Log Analytics workspace |
| `existingLogAnalyticsWorkspaceId` | If `useExistingLogAnalytics` | | Resource ID of the existing workspace |
| `existingLogAnalyticsResourceGroup` | If `useExistingLogAnalytics` | | Resource group containing the existing workspace |
| `logRetentionDays` | No | `30` | Retention in days (only when creating a new workspace) |

### Resource Sizing

| Parameter | Default | Description |
|:----------|:--------|:------------|
| `cpuCores` | `0.5` | CPU cores for standard services |
| `appMemory` | `1Gi` | Memory for standard services |
| `execCpuCores` | `2` | CPU cores for Execution Service |
| `execMemory` | `4Gi` | Memory for Execution Service |

## Deployment Scenarios

### Minimal (public, new database)

Creates everything from scratch with public access. Good for evaluation.

```bash
az deployment sub create \
  --location eastus2 \
  --template-file main.bicep \
  --parameters \
    environmentName=demo \
    databaseUsername=rpiadmin \
    databasePassword='<password>'
```

### Enterprise (private, existing infrastructure)

Uses existing VNet, database, DNS zones, and Log Analytics. Deploys Realtime stack with internal MongoDB and RabbitMQ containers.

```bash
az deployment sub create \
  --location eastus2 \
  --template-file main.bicep \
  --parameters \
    environmentName=prod \
    databaseUsername=rpiadmin \
    databasePassword='<password>' \
    registryUsername='<acr-user>' \
    registryPassword='<acr-token>' \
    ingressMode=internal \
    enableRealtime=true \
    enableCallback=true \
    enableQueueReader=true \
    cacheProvider=mongodb \
    cacheProviderType=internal \
    queueProvider=rabbitmq \
    queueProviderType=internal \
    useExistingDatabase=true \
    existingDatabaseServerFQDN='myserver.database.windows.net' \
    existingPulseDatabaseName=Pulse \
    existingPulseLoggingDatabaseName=Pulse_Logging \
    useExistingVnet=true \
    existingVnetId='/subscriptions/.../virtualNetworks/my-vnet' \
    existingSubnetId='/subscriptions/.../subnets/snet-containerapps' \
    enablePrivateEndpoints=true \
    privateEndpointSubnetId='/subscriptions/.../subnets/snet-pe' \
    useExistingDnsZones=true \
    existingDnsZoneResourceGroup=rg-hub \
    existingDnsZoneSubscriptionId='<hub-subscription-id>' \
    useExistingLogAnalytics=true \
    existingLogAnalyticsResourceGroup=rg-shared \
    existingLogAnalyticsWorkspaceId='/subscriptions/.../workspaces/my-workspace'
```

### External providers (BYO MongoDB Atlas + CloudAMQP)

Use fully managed external services for cache and queues.

```bash
az deployment sub create \
  --location eastus2 \
  --template-file main.bicep \
  --parameters \
    environmentName=prod \
    databaseUsername=rpiadmin \
    databasePassword='<password>' \
    enableRealtime=true \
    enableCallback=true \
    cacheProvider=mongodb \
    cacheProviderType=external \
    externalCacheConnectionString='mongodb+srv://user:pass@cluster.mongodb.net/RPIRealtimeCache' \
    queueProvider=rabbitmq \
    queueProviderType=external \
    externalRabbitMQHostname='my-rabbit.cloudamqp.com' \
    externalRabbitMQPassword='<password>'
```

### Custom registry and image names

Pull images from a private registry with different image naming conventions.

```json
{
  "imageTag": { "value": "7.7.20260410.1700" },
  "imageRegistry": { "value": "myregistry.azurecr.io/my-org/qa" },
  "registryServer": { "value": "myregistry.azurecr.io" },
  "registryUsername": { "value": "my-user" },
  "registryPassword": { "value": "<token>" },
  "imageNameOverrides": {
    "value": {
      "interactionapi": "redpoint-interaction-api",
      "deploymentapi": "redpoint-configuration-editor"
    }
  }
}
```

This produces image URIs like `myregistry.azurecr.io/my-org/qa/redpoint-interaction-api:7.7.20260410.1700`. Services without overrides keep their default names (e.g., `rpi-executionservice`).

## After Deployment

### 1. Get deployment outputs

```bash
az deployment sub show \
  --location eastus2 \
  --name main \
  --query properties.outputs
```

Key outputs: `resourceGroupName`, `environmentId`, `interactionApiUrl`, `deploymentApiUrl`, `integrationApiUrl`, `realtimeApiUrl`, `callbackApiUrl`, `keyVaultName`, `keyVaultUri`, `managedIdentityClientId`, `databaseServer`.

### 2. Run the database schema upgrade

```bash
DEPLOYMENT_URL=$(az deployment sub show --location eastus2 --name main \
  --query properties.outputs.deploymentApiUrl.value -o tsv)

curl -X GET "$DEPLOYMENT_URL/api/deployment/upgrade?waitTimeoutSeconds=360" \
  -H 'accept: text/plain'
```

### 3. Access the Interaction API

```bash
az deployment sub show --location eastus2 --name main \
  --query properties.outputs.interactionApiUrl.value -o tsv
```

## Configuration

All application configuration is stored in Key Vault. The Bicep template seeds the required secrets automatically. Each Container App has a Managed Identity with Key Vault Secrets Officer role -- no Workload Identity federation, no CSI driver, no service account annotations.

### How it works

1. The template creates a Key Vault and populates it with database connection strings and provider credentials
2. Each Container App has a Managed Identity assigned directly
3. The app reads all configuration from Key Vault at startup via `KeyVault__UseForAppSettings=true`
4. To change a setting, add or update a Key Vault secret and restart the container

### Secrets seeded by the template

**Always created:**

| Key Vault Secret | Description |
|:-----------------|:------------|
| `ConnectionString-Operations-Database` | Full connection string to the operational database |
| `ConnectionString-Logging-Database` | Full connection string to the logging database |
| `Operations-Database-Server-Password` | Database password |
| `Operations-Database-Server-Username` | Database username |
| `Operations-Database-ServerHost` | Database server hostname |
| `Operations-Database-Pulse-Database-Name` | Operational database name |
| `Operations-Database-Pulse-Logging-Database-Name` | Logging database name |

**Created based on provider selection:**

| Key Vault Secret | Condition | Description |
|:-----------------|:----------|:------------|
| `RealtimeAPI-RedisCache-ConnectionString` | Managed or external Redis | Azure Redis or BYO Redis connection string |
| `RealtimeAPI-MongoCache-ConnectionString` | Internal or external MongoDB | MongoDB connection string |
| `RealtimeAPI-ServiceBus-ConnectionString` | Managed or external Service Bus | Service Bus connection string |
| `RealtimeAPI-RabbitMQ-Password` | Internal or external RabbitMQ | RabbitMQ password |

### Restarting after config changes

After adding or updating Key Vault secrets, restart the affected containers:

```bash
RG_NAME=$(az deployment sub show --location eastus2 --name main \
  --query properties.outputs.resourceGroupName.value -o tsv)

# Restart a specific service
az containerapp revision restart --resource-group $RG_NAME --app <prefix>-interactionapi

# Restart all RPI services
for app in $(az containerapp list --resource-group $RG_NAME --query "[].name" -o tsv); do
  az containerapp revision restart --resource-group $RG_NAME --app $app
done
```

## Scaling

Container Apps auto-scale based on HTTP traffic. Default limits:

| Service | Min | Max |
|:--------|:----|:----|
| Deployment API | 1 | 1 |
| Interaction API | 1 | 5 |
| Execution Service | 1 | 8 |
| Node Manager | 1 | 3 |
| Integration API | 1 | 3 |
| Realtime API | 1 | 5 |
| Callback API | 1 | 3 |
| Queue Reader | 1 | 5 |
| MongoDB (internal) | 1 | 1 |
| RabbitMQ (internal) | 1 | 1 |

Scale to zero is supported but disabled by default (`minReplicas=1`) to avoid cold start latency.

## Cleanup

Delete the entire environment:

```bash
RG_NAME=$(az deployment sub show --location eastus2 --name main \
  --query properties.outputs.resourceGroupName.value -o tsv)

az group delete --name $RG_NAME --yes --no-wait
```

**Note:** Key Vault soft-delete retains the vault for 7 days after deletion. If you redeploy with the same `environmentName` before it purges, you'll get a naming conflict. Purge manually if needed:

```bash
az keyvault purge --name <vault-name> --no-wait
```

## Comparison: Container Apps vs Kubernetes (AKS)

| | Container Apps (Serverless) | AKS (Helm Chart) |
|:--|:--------------|:------------------|
| Cluster management | None | You manage the cluster |
| Identity/Auth | Managed Identity assigned to app (no federation) | Workload Identity federation + SA annotations |
| Configuration | Key Vault secrets (add/update, restart) | Helm values file (`helm upgrade`) |
| Scaling | Auto, can scale to zero | HPA, manual, or Karpenter |
| Secrets | Key Vault native via SDK | CSI driver, SDK, or K8s Secret |
| Storage | Azure Files mount | PVC (Azure Files, Azure Disk) |
| Networking | Built-in service discovery, optional VNet + PE | ClusterIP + Ingress, VNet integration |
| Cache/Queue | Managed Azure services, internal containers, or BYO | Internal containers or BYO |
| Cost model | Pay per vCPU-second + memory-second | Fixed node cost |
| Best for | Fast onboarding, teams without K8s, cost-sensitive | Enterprise production, custom plugins, multi-tenant |
