![redpoint_logo](../chart/images/redpoint.png)
# Secrets Management

[< Back to Home](../README.md)

RPI supports three secrets management providers. The provider controls how sensitive values (database credentials, connection strings, internal service passwords) are stored and consumed by the chart.

---

## Overview

| Provider | How it works |
|:---------|:-------------|
| **kubernetes** (default) | The CLI (`rpihelmcli/setup.sh secrets`) prompts for your database credentials, connection strings, and other values, then generates a Kubernetes Secret (`redpoint-rpi-secrets`). Internal service passwords (Redis, RabbitMQ) are randomly generated. Apply the secret before deploying. |
| **csi** | The CSI Secrets Store Driver syncs secrets from an external vault (Azure Key Vault, AWS Secrets Manager, GCP Secret Manager) into a Kubernetes Secret. You are responsible for storing ALL required keys in your vault. |
| **sdk** (recommended for cloud) | Each RPI service reads secrets directly from the vault at runtime using cloud identity. No K8s Secret needed for application secrets. |

---

## Kubernetes Provider

### What the kubernetes provider handles

| Item | How it's handled |
|:-----|:----------------|
| Image pull secret | CLI prompts for registry credentials and creates the K8s Secret |
| Ingress TLS certificate | CLI prompts for cert/key files and creates a `kubernetes.io/tls` Secret |
| Snowflake private key (if using Snowflake) | CLI creates a K8s Secret from the `.p8` file, mounted as a volume |
| Custom CA certificate (if required) | CLI prompts for the CA bundle file and creates a K8s Secret |
| RPI application secrets | CLI prompts for database, realtime, SMTP credentials and creates the main K8s Secret |

<details>
<summary><strong>Creating the Application Secret</strong></summary>

The chart does **not** create the `redpoint-rpi-secrets` Kubernetes Secret. You must create it before deploying. Sensitive values should **never** be stored in your overrides file.

#### Recommended: Use the CLI

The CLI reads your overrides file, detects which secrets are required based on your configuration (database provider, realtime cache, queue provider, SMTP, Snowflake, etc.), and prompts for each value interactively:

```bash
rpihelmcli secrets -f overrides.yaml -n redpoint-rpi
```

This generates a `secrets.yaml` file. Apply it:

```bash
kubectl apply -f secrets.yaml -n redpoint-rpi
```

The CLI automatically:
- Builds the correct connection string format for your database provider (SQL Server, PostgreSQL, SQL Server on VM)
- Generates random passwords for internal services (Redis, RabbitMQ)
- Prompts for Snowflake `.p8` key files per tenant
- Prompts for the CA certificate bundle if `customCACerts` is enabled
- Skips sections that aren't enabled in your overrides

#### Manual: Create the Secret with kubectl

If you prefer not to use the CLI (e.g., generating secrets in a CI/CD pipeline), create the secret manually. The secret must contain the keys that your configuration requires.

**Always required:**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: redpoint-rpi-secrets
  namespace: redpoint-rpi
type: Opaque
stringData:
  # Database connection strings (format depends on provider)
  # SQL Server:
  ConnectionString_Logging_Database: "Server=tcp:<host>,1433;Database=<logging-db>;User ID=<user>;Password=<password>;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
  ConnectionString_Operations_Database: "Server=tcp:<host>,1433;Database=<ops-db>;User ID=<user>;Password=<password>;Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
  # PostgreSQL:
  # ConnectionString_Logging_Database: "PostgreSQL:Server=<host>;Database=<logging-db>;User Id=<user>;Password=<password>;"
  # ConnectionString_Operations_Database: "PostgreSQL:Server=<host>;Database=<ops-db>;User Id=<user>;Password=<password>;"

  # Deployment API needs these individually
  Operations_Database_ServerHost: "<host>"
  Operations_Database_Server_Username: "<user>"
  Operations_Database_Server_Password: "<password>"
  Operations_Database_Pulse_Database_Name: "<ops-db>"
  Operations_Database_Pulse_Logging_Database_Name: "<logging-db>"
```

**If Realtime API is enabled** (`realtimeapi.enabled: true`):

```yaml
  # Auth token (generate a random string)
  RealtimeAPI_Auth_Token: "<random-token>"

  # Cache provider connection (depends on cacheProvider.provider)
  # MongoDB:
  RealtimeAPI_MongoCache_ConnectionString: "mongodb+srv://<user>:<password>@<host>/<db>"
  # Redis - EXTERNAL Redis only. With the chart-deployed internal cache
  # (redisSettings.type: internal) the connection string is auto-generated
  # into rpi-internal-services; do not populate it here.
  # RealtimeAPI_RedisCache_ConnectionString: "<host>:6379,password=<password>,abortConnect=False"

  # Queue provider connection (depends on queueProvider.provider)
  # Azure Service Bus:
  RealtimeAPI_ServiceBus_ConnectionString: "Endpoint=sb://<namespace>.servicebus.windows.net/;SharedAccessKeyName=<key-name>;SharedAccessKey=<key>"
  # Azure Event Hubs:
  # RealtimeAPI_EventHub_ConnectionString: "Endpoint=sb://<namespace>.servicebus.windows.net/;..."
  # Azure Storage:
  # RealtimeAPI_AzureStorage_ConnectionString: "DefaultEndpointsProtocol=https;AccountName=..."
  # RabbitMQ - EXTERNAL broker only. The chart-deployed internal broker's
  # password (rabbitmq.type: internal) is auto-generated into
  # rpi-internal-services; do not populate it here.
  # RealtimeAPI_RabbitMQ_Password: "<password>"
```

**Note:** Internal service passwords (every chart-deployed Redis cache and RabbitMQ broker: Realtime API, Queue Reader distributed queues, Rebrandly) are auto-generated by the chart. Do not include them in this secret.

**If SMTP uses credentials** (`SMTPSettings.UseCredentials: true`):

```yaml
  SMTP_Password: "<smtp-password>"
```

**If using AWS with access keys** (`cloudIdentity.amazon.useAccessKeys: true`):

```yaml
  AWS_Access_Key_ID: "<access-key>"
  AWS_Secret_Access_Key: "<secret-key>"
```

**If Redpoint AI is enabled** (`redpointAI.enabled: true`):

```yaml
  RPI_NLP_API_KEY: "<azure-openai-api-key>"
  RPI_NLP_SEARCH_KEY: "<cognitive-search-key>"
  RPI_NLP_MODEL_CONNECTION_STRING: "<model-storage-connection-string>"
```

**If Rebrandly is enabled** (`rebrandly.enabled: true`):

```yaml
  Rebrandly_RedisPassword: "<random-password>"
  Rebrandly_ApiKey: "<rebrandly-api-key>"
```

Apply the secret:

```bash
kubectl apply -f secrets.yaml -n redpoint-rpi
```

</details>

---

## Azure

<details>
<summary><strong>Provider: kubernetes</strong></summary>

When using the `kubernetes` provider on Azure, the CLI generates all secrets. No Azure-specific prerequisites are needed beyond network access to your Azure SQL or PostgreSQL database. See the [Kubernetes Provider](#kubernetes-provider) section above for details on creating the application secret.

</details>

<details>
<summary><strong>Provider: csi</strong></summary>

| Item | How it's handled |
|:-----|:----------------|
| Image pull secret | Create manually with `kubectl` before deploying |
| Ingress TLS certificate | SecretProviderClass syncs from vault into a `kubernetes.io/tls` K8s Secret |
| Snowflake private key (if using Snowflake) | SecretProviderClass syncs from vault into a K8s Secret, mounted as a volume |
| Custom CA certificate (if required) | SecretProviderClass syncs from vault into a K8s Secret |
| RPI application secrets | SecretProviderClass syncs all keys from vault into a K8s Secret |

A validation pod is required to trigger the initial CSI sync before RPI pods can start.

#### Required Vault Keys

See [Required Secret Keys](#required-secret-keys) in Common Reference for the full list of keys per feature. The keys are the same across all platforms - only the vault secret naming format differs (see [Secret Key Naming](#secret-key-naming-by-provider-and-platform)).

#### SecretProviderClass Example: Azure Key Vault

Azure Key Vault uses `--` (double dash) as the separator in secret names since it does not allow underscores. The `objectAlias` maps these to the underscore-based keys the chart expects in the K8s Secret.

```yaml
secretsManagement:
  provider: csi
  csi:
    secretName: redpoint-rpi-secrets
    secretProviderClasses:
    - name: redpoint-rpi-secrets
      provider: azure
      parameters:
        clientID: <managed-identity-client-id>
        keyvaultName: <your-keyvault-name>
        resourceGroup: <your-resource-group>
        subscriptionId: <your-subscription-id>
        tenantId: <your-tenant-id>
        useVMManagedIdentity: "false"
        usePodIdentity: "false"
        syncSecret: "true"
        enable-secret-rotation: "true"
      objects:
      - objectName: ConnectionString-Operations-Database
        objectType: secret
        objectAlias: ConnectionString_Operations_Database
      - objectName: ConnectionString-LoggingDatabase
        objectType: secret
        objectAlias: ConnectionString_Logging_Database
      - objectName: Operations-Database-ServerHost
        objectType: secret
        objectAlias: Operations_Database_ServerHost
      - objectName: Operations-Database-Server-Username
        objectType: secret
        objectAlias: Operations_Database_Server_Username
      - objectName: Operations-Database-Server-Password
        objectType: secret
        objectAlias: Operations_Database_Server_Password
      - objectName: Operations-Database-Pulse-Database-Name
        objectType: secret
        objectAlias: Operations_Database_Pulse_Database_Name
      - objectName: Operations-Database-Pulse-Logging-Database-Name
        objectType: secret
        objectAlias: Operations_Database_Pulse_Logging_Database_Name
      # Add additional keys based on your enabled features (see tables above)
      secretObjects:
      - secretName: redpoint-rpi-secrets
        type: Opaque
        data:
        - objectName: ConnectionString_Operations_Database
          key: ConnectionString_Operations_Database
        - objectName: ConnectionString_Logging_Database
          key: ConnectionString_Logging_Database
        - objectName: Operations_Database_ServerHost
          key: Operations_Database_ServerHost
        - objectName: Operations_Database_Server_Username
          key: Operations_Database_Server_Username
        - objectName: Operations_Database_Server_Password
          key: Operations_Database_Server_Password
        - objectName: Operations_Database_Pulse_Database_Name
          key: Operations_Database_Pulse_Database_Name
        - objectName: Operations_Database_Pulse_Logging_Database_Name
          key: Operations_Database_Pulse_Logging_Database_Name
        # Add additional keys to match the objects list above
```

Use the [Helm Assistant Web UI](https://rpi-helm-assistant.redpointcdp.com) **Automate** tab > **Azure** > **Vault Secrets Setup** to generate a script that creates all required vault secrets.

</details>

<details>
<summary><strong>Provider: sdk</strong></summary>

RPI services authenticate to Azure Key Vault using Workload Identity Federation and read application secrets at runtime. The CSI Secrets Store driver with the Azure Key Vault provider works fully with Workload Identity, so file-based secrets can also be pulled from Key Vault.

| Item | How it's handled |
|:-----|:----------------|
| Image pull secret | Create manually with `kubectl` before deploying |
| Ingress TLS certificate | SecretProviderClass syncs from Key Vault into a `kubernetes.io/tls` K8s Secret |
| Snowflake private key (if using Snowflake) | Mounted directly into the pod from Key Vault via CSI inline volume |
| Custom CA certificate (if required) | Mounted directly into the pod from Key Vault via CSI inline volume |
| RPI application secrets | Read directly from Azure Key Vault at runtime via SDK (no K8s Secret needed) |

No validation pods needed for application secrets. Snowflake keys and CA certs are mounted as files by the pods themselves.

#### Prerequisites

Before deploying:

1. **Create an Azure Key Vault** (or use an existing one) and store the required secrets
2. **Create a Managed Identity** and grant it the required roles
3. **Configure Workload Identity Federation** for each RPI service account

The managed identity needs the following role assignments:

| Scope | Role(s) |
|:------|:--------|
| Key Vault | `Key Vault Secrets Officer` |
| Storage Account (FileOutputDirectory) | `Reader`, `Storage Account Key Operator Service Role`, `Storage Blob Data Contributor`, `Storage File Data SMB Share Contributor` |

The managed identity needs a federated credential for each service account:

| Service Account | Service |
|:----------------|:--------|
| `rpi-interactionapi` | Interaction API |
| `rpi-integrationapi` | Integration API |
| `rpi-executionservice` | Execution Service |
| `rpi-nodemanager` | Node Manager |
| `rpi-realtimeapi` | Realtime API |
| `rpi-callbackapi` | Callback API |
| `rpi-queuereader` | Queue Reader |
| `rpi-deploymentapi` | Deployment API |

Use `cloudIdentity.serviceAccount.mode: per-service` for per-service audit trails, or `mode: shared` for a single federation credential.

For automated setup, use the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Automate** tab > **Azure** > **Vault Secrets Setup**.

#### Required Vault Secrets

Azure Key Vault does not allow `__` in secret names, so `--` is used as the hierarchy separator. The secret names must match exactly.

**Database connections** (always required):

| Vault Secret Name | Description |
|:-------------------|:------------|
| `ConnectionStrings--LoggingDatabase` | Full connection string to the logging database |
| `ConnectionStrings--OperationalDatabase` | Full connection string to the operational database |
| `ClusterEnvironment--OperationalDatabase--PulseDatabaseName` | Operational database name |
| `ClusterEnvironment--OperationalDatabase--LoggingDatabaseName` | Logging database name |
| `ClusterEnvironment--OperationalDatabase--ConnectionSettings--Username` | Database username |
| `ClusterEnvironment--OperationalDatabase--ConnectionSettings--Password` | Database password |
| `ClusterEnvironment--OperationalDatabase--ConnectionSettings--Server` | Database server hostname |

**Realtime API** (if enabled):

| Vault Secret Name | Description |
|:-------------------|:------------|
| `RealtimeAPIConfiguration--AppSettings--RealtimeAPIKey` | Your API key |
| `RealtimeAPIConfiguration--AppSettings--RPIAuthToken` | Your auth token |
| `RealtimeAPIConfiguration--CacheSettings--Caches--0--Settings--1--Key` | `ConnectionString` |
| `RealtimeAPIConfiguration--CacheSettings--Caches--0--Settings--1--Value` | Your cache connection string (MongoDB, Redis, etc.) |

**Queue secrets (Service Bus):**

| Vault Secret Name | Value |
|:-------------------|:------|
| `RealtimeAPIConfiguration--Queues--ClientQueueSettings--Settings--0--Key` | `QueueType` |
| `RealtimeAPIConfiguration--Queues--ClientQueueSettings--Settings--0--Value` | `ServiceBus` |
| `RealtimeAPIConfiguration--Queues--ClientQueueSettings--Settings--1--Key` | `ConnectionString` |
| `RealtimeAPIConfiguration--Queues--ClientQueueSettings--Settings--1--Value` | Your Service Bus connection string |
| `RealtimeAPIConfiguration--Queues--ListenerQueueSettings--Settings--0--Key` | `QueueType` |
| `RealtimeAPIConfiguration--Queues--ListenerQueueSettings--Settings--0--Value` | `ServiceBus` |
| `RealtimeAPIConfiguration--Queues--ListenerQueueSettings--Settings--1--Key` | `ConnectionString` |
| `RealtimeAPIConfiguration--Queues--ListenerQueueSettings--Settings--1--Value` | Your Service Bus connection string |

**Callback API** (if enabled):

| Vault Secret Name | Value |
|:-------------------|:------|
| `CallbackServiceConfig--QueueProvider--CallbackServiceQueueSettings--Settings--0--Key` | `QueueType` |
| `CallbackServiceConfig--QueueProvider--CallbackServiceQueueSettings--Settings--0--Value` | `ServiceBus` |
| `CallbackServiceConfig--QueueProvider--CallbackServiceQueueSettings--Settings--1--Key` | `ConnectionString` |
| `CallbackServiceConfig--QueueProvider--CallbackServiceQueueSettings--Settings--1--Value` | Your Service Bus connection string |

**SMTP** (if sending email):

| Vault Secret Name | Value |
|:-------------------|:------|
| `RPI--SMTP--Password` | Your SMTP password |

**Redpoint AI** (if enabled):

| Vault Secret Name | Value |
|:-------------------|:------|
| `RPI--NLP--ApiKey` | Your Azure OpenAI API key |
| `RPI--NLP--SearchKey` | Your Azure Cognitive Search key |
| `RPI--NLP--ModelConnectionString` | Model storage connection string (Azure Blob) |

**Rebrandly** (if enabled):

| Vault Secret Name | Value |
|:-------------------|:------|
| `Rebrandly--ApiKey` | Your Rebrandly API key |

</details>

<details>
<summary><strong>TLS Certificate</strong></summary>

#### SDK approach

Store the certificate in Key Vault:

```bash
az keyvault certificate import --vault-name <vault> --name my-tls-certificate --file ingress-cert.pem
```

Define a SecretProviderClass to sync from Key Vault into a `kubernetes.io/tls` K8s Secret. Azure Key Vault splits the cert and key automatically from a single imported certificate:

```yaml
- name: ingress-tls-certificate
  provider: azure
  parameters:
    clientID: <managed-identity-client-id>
    keyvaultName: <your-keyvault>
    resourceGroup: <your-rg>
    subscriptionId: <your-sub>
    tenantId: <your-tenant>
  objects:
  - objectName: my-tls-certificate
    objectType: secret
  secretObjects:
  - secretName: ingress-tls
    type: kubernetes.io/tls
    data:
    - objectName: my-tls-certificate
      key: tls.key
    - objectName: my-tls-certificate
      key: tls.crt
```

A validation pod must mount this SecretProviderClass to trigger the initial sync of the K8s TLS Secret. The RPI pods themselves do not mount TLS certificates.

#### CSI approach

The same SecretProviderClass pattern above applies when using the CSI provider. The only difference is that a validation pod must be used to trigger the sync.

</details>

<details>
<summary><strong>Snowflake Private Key</strong></summary>

With SDK on Azure, the Snowflake `.p8` key is mounted directly from Key Vault via CSI inline volume. No K8s Secret is created and no validation pod is needed.

Define a SecretProviderClass under `secretsManagement.csi` and set `secretProviderClassName` on the Snowflake config:

```yaml
secretsManagement:
  provider: sdk
  sdk:
    azure:
      vaultUri: https://myvault.vault.azure.net/
  csi:
    secretProviderClasses:
    - name: snowflake-creds
      provider: azure
      parameters:
        clientID: <managed-identity-client-id>
        keyvaultName: <your-keyvault>
        resourceGroup: <your-rg>
        subscriptionId: <your-sub>
        tenantId: <your-tenant>
        useVMManagedIdentity: "false"
        usePodIdentity: "false"
      objects:
      - objectName: my-snowflake-private-key
        objectType: secret
        objectAlias: my-snowflake-rsakey.p8

databases:
  datawarehouse:
    snowflake:
      enabled: true
      credentialsType: snowflake_jwt
      mountPath: /app/snowflake-creds
      secretProviderClassName: snowflake-creds
      keys:
      - keyName: my-snowflake-rsakey.p8
```

The `objectAlias` in the SecretProviderClass controls the filename inside the container.

</details>

<details>
<summary><strong>Custom CA Certificate</strong></summary>

With SDK on Azure, CA certificates are mounted directly from Key Vault via CSI inline volume.

Store your CA bundle in Azure Key Vault, define a SecretProviderClass, and set `secretProviderClassName` on the `customCACerts` config:

```yaml
customCACerts:
  enabled: true
  mountPath: /usr/local/share/ca-certificates/custom
  certFile: ca-bundle.pem
  secretProviderClassName: ca-cert-provider

secretsManagement:
  provider: sdk
  sdk:
    azure:
      vaultUri: https://myvault.vault.azure.net/
  csi:
    secretProviderClasses:
    - name: ca-cert-provider
      provider: azure
      parameters:
        clientID: <managed-identity-client-id>
        keyvaultName: <your-keyvault>
        resourceGroup: <your-rg>
        subscriptionId: <your-sub>
        tenantId: <your-tenant>
      objects:
      - objectName: my-ca-bundle
        objectType: secret
        objectAlias: ca-bundle.pem
```

Store the certificate in Key Vault:

```bash
az keyvault secret set --vault-name <vault> --name my-ca-bundle --file ca-bundle.pem
```

</details>

---

## Amazon

<details>
<summary><strong>Provider: kubernetes</strong></summary>

When using the `kubernetes` provider on Amazon, the CLI generates all secrets. The CLI (`rpihelmcli/setup.sh secrets`) prompts for database credentials, connection strings, and AWS access keys, then generates the `redpoint-rpi-secrets` Kubernetes Secret. See the [Kubernetes Provider](#kubernetes-provider) section above for details on creating the application secret.

</details>

<details>
<summary><strong>Provider: csi</strong></summary>

When using the CSI provider on AWS, the AWS Secrets and Configuration Provider (ASCP) syncs secrets from Secrets Manager into Kubernetes Secrets.

| Item | How it's handled |
|:-----|:----------------|
| Image pull secret | Create manually with `kubectl` before deploying |
| Ingress TLS certificate | SecretProviderClass syncs from vault into a `kubernetes.io/tls` K8s Secret |
| Snowflake private key (if using Snowflake) | SecretProviderClass syncs from vault into a K8s Secret, mounted as a volume |
| Custom CA certificate (if required) | SecretProviderClass syncs from vault into a K8s Secret |
| RPI application secrets | SecretProviderClass syncs all keys from vault into a K8s Secret |

A validation pod is required to trigger the initial CSI sync before RPI pods can start.

#### Prerequisites

1. **Install the CSI Secrets Store Driver and ASCP** on your EKS cluster (available as an EKS addon: `aws-secrets-manager`). Enable secret syncing:
   ```json
   {
     "secrets-store-csi-driver": {
       "syncSecret": { "enabled": true },
       "enableSecretRotation": true
     }
   }
   ```

2. **Create a single JSON secret in Secrets Manager** containing all required application keys:

```bash
aws secretsmanager create-secret \
  --name <your-secret-name> \
  --description "RPI Application Secrets" \
  --secret-string '{
    "ConnectionString_Logging_Database": "<connection-string>",
    "ConnectionString_Operations_Database": "<connection-string>",
    "Operations_Database_Server_Password": "<password>",
    "Operations_Database_Pulse_Database_Name": "<db-name>",
    "Operations_Database_Pulse_Logging_Database_Name": "<logging-db-name>",
    "Operations_Database_Server_Username": "<username>",
    "Operations_Database_ServerHost": "<host>",
    "RealtimeAPI_Auth_Token": "<token>",
    "RealtimeAPI_MongoCache_ConnectionString": "<mongodb-connection-string>",
    "SMTP_Password": "<smtp-password>",
    "AWS_Access_Key_ID": "<access-key>",
    "AWS_Secret_Access_Key": "<secret-key>"
  }' \
  --region <your-region>
```

Add optional keys as needed: `Rebrandly_ApiKey`, `Rebrandly_RedisPassword`, `RPI_SMTP_Username`.

> **Important:** CSI on Amazon uses single underscore (`_`) key names mapped via jmesPath objectAlias. Every `jmesPath` path must exist in the Secrets Manager secret. A missing key causes the entire CSI mount to fail.

3. **Create a pod identity association** for the service account that triggers the CSI sync. The ASCP uses EKS Pod Identity to authenticate to Secrets Manager:

```bash
aws eks create-pod-identity-association \
  --cluster-name <cluster> --namespace <namespace> \
  --service-account <sa-name> --role-arn <role-arn>
```

If using `syncService: deploymentapi`, create the association for `rpi-deploymentapi`. If using validation pods, create it for `rpi-validationpods`.

4. **IAM role** must have `SecretsManagerReadWrite` policy and a trust policy allowing `pods.eks.amazonaws.com`:

```json
{
  "Effect": "Allow",
  "Principal": { "Service": "pods.eks.amazonaws.com" },
  "Action": ["sts:AssumeRole", "sts:TagSession"]
}
```

#### SecretProviderClass Example

Configure the SecretProviderClass with `usePodIdentity: "true"` and `jmesPath` to extract individual keys from the JSON secret:

```yaml
secretsManagement:
  provider: csi
  csi:
    secretName: redpoint-rpi-secrets
    syncService: deploymentapi   # or: none (use validation pods)
    secretProviderClasses:
    - name: redpoint-rpi-secrets
      provider: aws
      parameters:
        region: us-east-1
        usePodIdentity: "true"
      objects:
      - objectName: <your-secret-name>
        objectType: secretsmanager
        jmesPath:
        - path: ConnectionString_Logging_Database
          objectAlias: ConnectionString_Logging_Database
        - path: ConnectionString_Operations_Database
          objectAlias: ConnectionString_Operations_Database
        - path: Operations_Database_Server_Password
          objectAlias: Operations_Database_Server_Password
        - path: Operations_Database_Pulse_Database_Name
          objectAlias: Operations_Database_Pulse_Database_Name
        - path: Operations_Database_Pulse_Logging_Database_Name
          objectAlias: Operations_Database_Pulse_Logging_Database_Name
        - path: Operations_Database_Server_Username
          objectAlias: Operations_Database_Server_Username
        - path: Operations_Database_ServerHost
          objectAlias: Operations_Database_ServerHost
        - path: RealtimeAPI_Auth_Token
          objectAlias: RealtimeAPI_Auth_Token
        - path: SMTP_Password
          objectAlias: SMTP_Password
        - path: AWS_Access_Key_ID
          objectAlias: AWS_Access_Key_ID
        - path: AWS_Secret_Access_Key
          objectAlias: AWS_Secret_Access_Key
        - path: RealtimeAPI_MongoCache_ConnectionString
          objectAlias: RealtimeAPI_MongoCache_ConnectionString
      secretObjects:
      - secretName: redpoint-rpi-secrets
        type: Opaque
        data:
        - objectName: ConnectionString_Logging_Database
          key: ConnectionString_Logging_Database
        - objectName: ConnectionString_Operations_Database
          key: ConnectionString_Operations_Database
        - objectName: Operations_Database_Server_Password
          key: Operations_Database_Server_Password
        - objectName: Operations_Database_Pulse_Database_Name
          key: Operations_Database_Pulse_Database_Name
        - objectName: Operations_Database_Pulse_Logging_Database_Name
          key: Operations_Database_Pulse_Logging_Database_Name
        - objectName: Operations_Database_Server_Username
          key: Operations_Database_Server_Username
        - objectName: Operations_Database_ServerHost
          key: Operations_Database_ServerHost
        - objectName: RealtimeAPI_Auth_Token
          key: RealtimeAPI_Auth_Token
        - objectName: SMTP_Password
          key: SMTP_Password
        - objectName: AWS_Access_Key_ID
          key: AWS_Access_Key_ID
        - objectName: AWS_Secret_Access_Key
          key: AWS_Secret_Access_Key
        - objectName: RealtimeAPI_MongoCache_ConnectionString
          key: RealtimeAPI_MongoCache_ConnectionString
```

Add optional keys to both `jmesPath` and `secretObjects` as needed: `Rebrandly_ApiKey`, `Rebrandly_RedisPassword`, `RPI_SMTP_Username`.

#### Sync trigger options

- `syncService: deploymentapi` - the Deployment API pod mounts the CSI volume on startup, triggering the sync. No validation pods needed.
- `syncService: none` (default) - use dedicated validation pods to trigger the sync before RPI pods start.

**Additional file-based secrets** (TLS cert, Snowflake keys, CA cert) require separate Secrets Manager secrets and their own SecretProviderClasses. See the sections below.

</details>

<details>
<summary><strong>Provider: sdk</strong></summary>

RPI services authenticate to AWS Secrets Manager using EKS Pod Identity and read application secrets at runtime.

| Item | How it's handled |
|:-----|:----------------|
| Image pull secret | Create manually with `kubectl` before deploying |
| AWS credentials | Store `AWS_Access_Key_ID` and `AWS_Secret_Access_Key` in your vault alongside other application secrets. The IAM user needs read/write access to Amazon SQS and Amazon S3. |
| Ingress TLS certificate | Mounted directly into the pod from Secrets Manager via CSI inline volume |
| Snowflake private key (if using Snowflake) | Mounted directly into the pod from Secrets Manager via CSI inline volume |
| Custom CA certificate (if required) | Mounted directly into the pod from Secrets Manager via CSI inline volume |
| RPI application secrets | Read directly from AWS Secrets Manager at runtime via SDK (no K8s Secret needed) |

No validation pods needed for application secrets. Snowflake keys, TLS certs, and CA certs are mounted as files by the pods themselves via CSI inline volumes defined in the overrides.

#### Prerequisites

RPI on AWS supports multiple authentication methods. Choose based on your EKS configuration:

| Method | How it works | When to use |
|:-------|:-------------|:------------|
| **IRSA** | Service account annotated with IAM role ARN; JWT token injected at `/var/run/secrets/eks.amazonaws.com/serviceaccount/token` | Standard EKS managed/self-managed node groups |
| **Access Keys** | IAM credentials stored in the main K8s Secret (`AWS_Access_Key_ID`, `AWS_Secret_Access_Key`), injected as env vars | When services need direct AWS API access (e.g., SQS, S3) alongside IRSA |

IRSA handles Secrets Manager reads, while access keys provide credentials for services like Amazon SQS and S3.

##### Setup

1. **Create an IAM role** with `SecretsManagerReadWrite` permissions and an OIDC trust policy for your EKS cluster

2. **Store AWS access keys** in your vault. The keys `AWS_Access_Key_ID` and `AWS_Secret_Access_Key` are read from the same K8s Secret as all other application secrets:
   - **SDK provider**: Include them in your Secrets Manager JSON secret
   - **CSI provider**: Add them to your SecretProviderClass jmesPath/secretObjects mapping
   - **kubernetes provider**: The CLI (`rpihelmcli/setup.sh`) prompts for them and writes them into `secrets.yaml`

3. **Create file-based secrets** before deploying. These cannot be read from Secrets Manager at runtime:

```bash
# Ingress TLS certificate (required)
kubectl create secret tls ingress-tls \
  --cert=tls.crt --key=tls.key \
  -n <namespace>

# Snowflake private key (only if using Snowflake as a data warehouse)
kubectl create secret generic snowflake-rsa-private-key \
  --from-file=sf_rpi_usr_private_key.p8 \
  -n <namespace>

# Custom CA certificate (only if required)
kubectl create secret generic custom-ca-cert \
  --from-file=ca-bundle.pem \
  -n <namespace>
```

> **Why K8s Secrets for file-based secrets?** The ingress controller, Snowflake JDBC driver, and CA trust store require secrets mounted as files and cannot call Secrets Manager themselves. These must exist as Kubernetes Secrets before deploying. On Azure, these can be synced from Key Vault via CSI SecretProviderClass instead.

##### Overrides

```yaml
cloudIdentity:
  enabled: true
  serviceAccount:
    mode: per-service
  amazon:
    roleArn: arn:aws:iam::<account>:role/<role-name>
    region: us-east-1
    useAccessKeys: true                    # set to false if not using SQS or other direct AWS APIs
```

For automated setup, use the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Automate** tab > **Amazon** > **Vault Secrets Setup**.

#### secretTagKey Configuration

When using SDK on Amazon, secrets are read by tag. Configure `secretTagKey` to match the tag key used in your Secrets Manager secret.

#### Required Vault Secrets

AWS Secrets Manager stores all keys as JSON within a single secret, using `__` (double underscore) as the hierarchy separator to match the .NET configuration hierarchy. The secret names must match exactly.

**Database connections** (always required):

| Vault Secret Name | Description |
|:-------------------|:------------|
| `ConnectionStrings__LoggingDatabase` | Full connection string to the logging database |
| `ConnectionStrings__OperationalDatabase` | Full connection string to the operational database |
| `ClusterEnvironment__OperationalDatabase__PulseDatabaseName` | Operational database name |
| `ClusterEnvironment__OperationalDatabase__LoggingDatabaseName` | Logging database name |
| `ClusterEnvironment__OperationalDatabase__ConnectionSettings__Username` | Database username |
| `ClusterEnvironment__OperationalDatabase__ConnectionSettings__Password` | Database password |
| `ClusterEnvironment__OperationalDatabase__ConnectionSettings__Server` | Database server hostname |

**Realtime API** (if enabled):

| Vault Secret Name | Description |
|:-------------------|:------------|
| `RealtimeAPIConfiguration__AppSettings__RealtimeAPIKey` | Your API key |
| `RealtimeAPIConfiguration__AppSettings__RPIAuthToken` | Your auth token |
| `RealtimeAPIConfiguration__CacheSettings__Caches__0__Settings__1__Key` | `ConnectionString` |
| `RealtimeAPIConfiguration__CacheSettings__Caches__0__Settings__1__Value` | Your cache connection string (MongoDB, Redis, etc.) |

**Queue secrets (Amazon SQS):**

| Vault Secret Name | Value |
|:-------------------|:------|
| `RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__0__Key` | `AccessKey` |
| `RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__0__Value` | Your AWS access key ID |
| `RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__1__Key` | `SecretKey` |
| `RealtimeAPIConfiguration__Queues__ClientQueueSettings__Settings__1__Value` | Your AWS secret access key |
| `RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__0__Key` | `AccessKey` |
| `RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__0__Value` | Your AWS access key ID |
| `RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__1__Key` | `SecretKey` |
| `RealtimeAPIConfiguration__Queues__ListenerQueueSettings__Settings__1__Value` | Your AWS secret access key |

**Callback API** (if enabled):

| Vault Secret Name | Value |
|:-------------------|:------|
| `CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__0__Key` | `AccessKey` |
| `CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__0__Value` | Your AWS access key ID |
| `CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__1__Key` | `SecretKey` |
| `CallbackServiceConfig__QueueProvider__CallbackServiceQueueSettings__Settings__1__Value` | Your AWS secret access key |

**SMTP** (if sending email):

| Vault Secret Name | Value |
|:-------------------|:------|
| `RPI__SMTP__Password` | Your SMTP password |

**AWS Access Keys** (if `useAccessKeys: true`):

| Vault Secret Name | Value |
|:-------------------|:------|
| `AWS_Access_Key_ID` | Your IAM access key ID |
| `AWS_Secret_Access_Key` | Your IAM secret access key |

The IAM user needs read/write access to Amazon SQS and Amazon S3.

**Redpoint AI** (if enabled):

| Vault Secret Name | Value |
|:-------------------|:------|
| `RPI__NLP__ApiKey` | Your Azure OpenAI API key |
| `RPI__NLP__SearchKey` | Your Azure Cognitive Search key |
| `RPI__NLP__ModelConnectionString` | Model storage connection string (Azure Blob) |

**Rebrandly** (if enabled):

| Vault Secret Name | Value |
|:-------------------|:------|
| `Rebrandly__ApiKey` | Your Rebrandly API key |

</details>

<details>
<summary><strong>TLS Certificate</strong></summary>

**SDK provider:** Create the ingress TLS certificate as a Kubernetes Secret directly:

```bash
kubectl create secret tls ingress-tls \
  --cert=tls.crt --key=tls.key \
  -n <namespace>
```

**CSI provider:** Store the cert and key as separate binary secrets in Secrets Manager and define a SecretProviderClass that syncs them into a `kubernetes.io/tls` K8s Secret:

```yaml
secretsManagement:
  csi:
    secretProviderClasses:
    - name: cert-secretprovider
      provider: aws
      parameters:
        region: us-east-1
      objects:
      - objectName: <prefix>-tls-crt
        objectType: secretsmanager
        objectAlias: tls.crt
      - objectName: <prefix>-tls-key
        objectType: secretsmanager
        objectAlias: tls.key
      secretObjects:
      - secretName: ingress-tls
        type: kubernetes.io/tls
        data:
        - objectName: tls.crt
          key: tls.crt
        - objectName: tls.key
          key: tls.key
```

A validation pod must mount this SecretProviderClass to trigger the sync.

</details>

<details>
<summary><strong>Snowflake Private Key</strong></summary>

**SDK provider:** Create the Snowflake private key as a Kubernetes Secret directly:

```bash
kubectl create secret generic snowflake-rsa-private-key \
  --from-file=sf_rpi_usr_private_key.p8 \
  -n <namespace>
```

**CSI provider:** Store the `.p8` key as a binary secret in Secrets Manager and define a SecretProviderClass. The chart mounts it directly via CSI inline volume (no K8s Secret created):

```yaml
databases:
  datawarehouse:
    snowflake:
      enabled: true
      credentialsType: snowflake_jwt
      secretName: <your-spc-name>
      mountPath: /app/snowflake-creds
      secretProviderClassName: <your-spc-name>
      keys:
      - keyName: sf_rpi_usr_private_key.p8

secretsManagement:
  csi:
    secretProviderClasses:
    - name: <your-spc-name>
      provider: aws
      parameters:
        region: us-east-1
      objects:
      - objectName: <prefix>-snowflake-key
        objectType: secretsmanager
        objectAlias: sf_rpi_usr_private_key.p8
```

No validation pod needed. The CSI volume is mounted directly by the RPI pods.

</details>

<details>
<summary><strong>Custom CA Certificate</strong></summary>

**SDK provider:** Create the CA certificate as a Kubernetes Secret directly:

```bash
kubectl create secret generic custom-ca-cert \
  --from-file=ca-bundle.pem \
  -n <namespace>
```

Then reference it in your overrides:

```yaml
customCACerts:
  enabled: true
  mountPath: /usr/local/share/ca-certificates/custom
  certFile: ca-bundle.pem
  secretName: custom-ca-cert
```

**CSI provider:** Store the CA bundle as a binary secret in Secrets Manager and define a SecretProviderClass. The chart mounts it directly via CSI inline volume:

```yaml
customCACerts:
  enabled: true
  mountPath: /usr/local/share/ca-certificates/custom
  certFile: ca-bundle.pem
  secretProviderClassName: <your-ca-spc-name>

secretsManagement:
  csi:
    secretProviderClasses:
    - name: <your-ca-spc-name>
      provider: aws
      parameters:
        region: us-east-1
      objects:
      - objectName: <prefix>-ca-bundle
        objectType: secretsmanager
        objectAlias: ca-bundle.pem
```

No validation pod needed. The CSI volume is mounted directly by the RPI pods.

</details>

---

## Google

<details>
<summary><strong>Provider: kubernetes</strong></summary>

When using the `kubernetes` provider on Google, the CLI generates all secrets. No Google-specific prerequisites are needed beyond network access to your Cloud SQL database. See the [Kubernetes Provider](#kubernetes-provider) section above for details on creating the application secret.

</details>

<details>
<summary><strong>Provider: sdk</strong></summary>

RPI services authenticate to Google Secret Manager using GKE Workload Identity and read application secrets at runtime.

| Item | How it's handled |
|:-----|:----------------|
| Image pull secret | Create manually with `kubectl` before deploying |
| Ingress TLS certificate | Create manually with `kubectl create secret tls` before deploying |
| Snowflake private key (if using Snowflake) | Create manually with `kubectl create secret generic` before deploying |
| Custom CA certificate (if required) | Create manually with `kubectl create secret generic` before deploying |
| RPI application secrets | Read directly from Google Secret Manager at runtime via SDK (no K8s Secret needed) |

No validation pods needed. File-based secrets (TLS cert, Snowflake key, CA cert) must be created as Kubernetes Secrets since the ingress controller and volume mounts cannot read from Secret Manager directly.

#### Prerequisites

**1. Enable the Secret Manager API:**

```bash
gcloud services enable secretmanager.googleapis.com --project <your-project-id>
```

**2. Create a GCP service account for RPI:**

```bash
gcloud iam service-accounts create redpoint-rpi \
  --display-name "Redpoint RPI Workload Identity" \
  --project <your-project-id>
```

**3. Grant Secret Manager access to the service account:**

```bash
# Read secret values
gcloud projects add-iam-policy-binding <your-project-id> \
  --member "serviceAccount:redpoint-rpi@<your-project-id>.iam.gserviceaccount.com" \
  --role "roles/secretmanager.secretAccessor"

# List/discover secrets (required for SDK secret discovery)
gcloud projects add-iam-policy-binding <your-project-id> \
  --member "serviceAccount:redpoint-rpi@<your-project-id>.iam.gserviceaccount.com" \
  --role "roles/secretmanager.viewer"
```

**4. Bind each Kubernetes service account to the GCP service account via Workload Identity:**

```bash
SA_EMAIL="redpoint-rpi@<your-project-id>.iam.gserviceaccount.com"

for KSA in rpi-interactionapi rpi-integrationapi rpi-executionservice \
           rpi-nodemanager rpi-realtimeapi rpi-callbackapi \
           rpi-queuereader rpi-deploymentapi; do
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:<your-project-id>.svc.id.goog[<namespace>/$KSA]"
done
```

If using `mode: shared`, only one binding is needed for the shared SA name instead of the loop above.

For automated setup, use the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Automate** tab > **Google** > **Vault Secrets Setup**.

#### Required Vault Secrets

Google Secret Manager uses `--` (double dash) as the hierarchy separator. The secret names must match exactly. This differs from Azure Key Vault (`--`) and AWS Secrets Manager (tag-based, flat JSON keys).

**Database connections** (always required):

| Vault Secret Name | Description |
|:-------------------|:------------|
| `ConnectionStrings--LoggingDatabase` | Full connection string to the logging database |
| `ConnectionStrings--OperationalDatabase` | Full connection string to the operational database |
| `ClusterEnvironment--OperationalDatabase--PulseDatabaseName` | Operational database name |
| `ClusterEnvironment--OperationalDatabase--LoggingDatabaseName` | Logging database name |
| `ClusterEnvironment--OperationalDatabase--ConnectionSettings--Username` | Database username |
| `ClusterEnvironment--OperationalDatabase--ConnectionSettings--Password` | Database password |
| `ClusterEnvironment--OperationalDatabase--ConnectionSettings--Server` | Database server hostname |

**Realtime API** (if enabled):

| Vault Secret Name | Description |
|:-------------------|:------------|
| `RealtimeAPIConfiguration--AppSettings--RealtimeAPIKey` | Your API key |
| `RealtimeAPIConfiguration--AppSettings--RPIAuthToken` | Your auth token |
| `RealtimeAPIConfiguration--CacheSettings--Caches--0--Settings--1--Key` | `ConnectionString` |
| `RealtimeAPIConfiguration--CacheSettings--Caches--0--Settings--1--Value` | Your cache connection string (MongoDB, Redis, etc.) |

**Queue secrets (Pub/Sub):**

| Vault Secret Name | Value |
|:-------------------|:------|
| `RealtimeAPIConfiguration--Queues--ClientQueueSettings--Settings--0--Key` | `QueueType` |
| `RealtimeAPIConfiguration--Queues--ClientQueueSettings--Settings--0--Value` | `GooglePubSub` |
| `RealtimeAPIConfiguration--Queues--ClientQueueSettings--Settings--1--Key` | `ConnectionString` |
| `RealtimeAPIConfiguration--Queues--ClientQueueSettings--Settings--1--Value` | Your GCP project ID |
| `RealtimeAPIConfiguration--Queues--ListenerQueueSettings--Settings--0--Key` | `QueueType` |
| `RealtimeAPIConfiguration--Queues--ListenerQueueSettings--Settings--0--Value` | `GooglePubSub` |
| `RealtimeAPIConfiguration--Queues--ListenerQueueSettings--Settings--1--Key` | `ConnectionString` |
| `RealtimeAPIConfiguration--Queues--ListenerQueueSettings--Settings--1--Value` | Your GCP project ID |

**Callback API** (if enabled):

| Vault Secret Name | Value |
|:-------------------|:------|
| `CallbackServiceConfig--QueueProvider--CallbackServiceQueueSettings--Settings--0--Key` | `QueueType` |
| `CallbackServiceConfig--QueueProvider--CallbackServiceQueueSettings--Settings--0--Value` | `GooglePubSub` |
| `CallbackServiceConfig--QueueProvider--CallbackServiceQueueSettings--Settings--1--Key` | `ConnectionString` |
| `CallbackServiceConfig--QueueProvider--CallbackServiceQueueSettings--Settings--1--Value` | Your GCP project ID |

**SMTP** (if sending email):

| Vault Secret Name | Value |
|:-------------------|:------|
| `RPI--SMTP--Password` | Your SMTP password |

**Redpoint AI** (if enabled):

| Vault Secret Name | Value |
|:-------------------|:------|
| `RPI--NLP--ApiKey` | Your Azure OpenAI API key |
| `RPI--NLP--SearchKey` | Your Azure Cognitive Search key |
| `RPI--NLP--ModelConnectionString` | Model storage connection string (Azure Blob) |

**Rebrandly** (if enabled):

| Vault Secret Name | Value |
|:-------------------|:------|
| `Rebrandly--ApiKey` | Your Rebrandly API key |

</details>

<details>
<summary><strong>TLS Certificate</strong></summary>

On Google with the SDK provider, create the ingress TLS certificate as a Kubernetes Secret directly:

```bash
kubectl create secret tls ingress-tls \
  --cert=tls.crt --key=tls.key \
  -n <namespace>
```

The ingress controller reads the TLS cert from this K8s Secret.

</details>

<details>
<summary><strong>Snowflake Private Key</strong></summary>

On Google with the SDK provider, create the Snowflake private key as a Kubernetes Secret directly:

```bash
kubectl create secret generic snowflake-rsa-private-key \
  --from-file=sf_rpi_usr_private_key.p8 \
  -n <namespace>
```

Then reference it in your overrides:

```yaml
databases:
  datawarehouse:
    snowflake:
      enabled: true
      credentialsType: snowflake_jwt
      mountPath: /app/snowflake-creds
      keys:
      - keyName: sf_rpi_usr_private_key.p8
        secretName: snowflake-rsa-private-key
```

</details>

<details>
<summary><strong>Custom CA Certificate</strong></summary>

On Google with the SDK provider, create the CA certificate as a Kubernetes Secret directly:

```bash
kubectl create secret generic custom-ca-cert \
  --from-file=ca-bundle.pem \
  -n <namespace>
```

Then reference it in your overrides:

```yaml
customCACerts:
  enabled: true
  mountPath: /usr/local/share/ca-certificates/custom
  certFile: ca-bundle.pem
  secretName: custom-ca-cert
```

</details>

<details>
<summary><strong>Cloud SQL Auth Proxy (GKE + PostgreSQL or SQL Server)</strong></summary>

For deployments on **GKE with PostgreSQL or SQL Server on Cloud SQL**, the chart can inject a [Cloud SQL Auth Proxy](https://cloud.google.com/sql/docs/mysql/connect-kubernetes-engine) sidecar next to every pod that talks to the operational database. The proxy establishes an mTLS-encrypted tunnel to Cloud SQL and exposes a local endpoint (`127.0.0.1:<port>`) that the app connects to like a normal database instance. This removes the need to put credentials in the connection string or expose Cloud SQL to the public internet.

The Cloud SQL Auth Proxy is supported only when **secrets management is in `sdk` mode**. The proxy and the SDK secret provider share the same cloud-native security realm (vault-backed, IAM-bound), so the chart enforces this with a `helm` validation. The activation gate requires **all** of the following:

- `global.deployment.platform: google`
- `databases.operational.provider: postgresql` **or** `sqlserver`
- `databases.operational.cloudSqlProxy.enabled: true`
- `secretsManagement.provider: sdk` (chart fails with a clear error otherwise)

If any condition is false the proxy is not injected and the chart behaves exactly as it does today for every other platform and provider.

#### How it works

When active, the chart does two things:

1. **Injects a native Kubernetes sidecar** (`initContainers[*].restartPolicy: Always`, requires K8s 1.29+) running the `cloud-sql-proxy` binary in every RPI pod that talks to the operational DB: `rpi-deploymentapi`, `rpi-interactionapi`, `rpi-integrationapi`, `rpi-executionservice`, `rpi-nodemanager`, `rpi-queuereader`, `rpi-realtimeapi`, and `rpi-callbackapi`.
2. **Mounts the Google SA key file into the proxy sidecar** when `cloudIdentity.google.configMapName` is set (otherwise Workload Identity). The mount path matches the value of `GOOGLE_APPLICATION_CREDENTIALS` the app already reads, reusing the same ConfigMap and avoiding a duplicate volume.

The chart does **not** inject any database connection-string env vars. In `sdk` mode the .NET app reads them directly from your vault. **You configure your vault entries** so the connection points at `127.0.0.1` and the matching proxy port:

| Vault key (Google Secret Manager: `--` instead of `:`) | Value when proxy is active |
|---|---|
| `ClusterEnvironment--OperationalDatabase--ConnectionSettings--Server` | `tcp:127.0.0.1,1433` (SQL Server) **or** `127.0.0.1` (PostgreSQL). **No `Server=` prefix in this field**, just the host value; the .NET app composes it into the connection string. |
| `ClusterEnvironment--OperationalDatabase--ConnectionSettings--Username` | DB user (or the GCP SA email when using IAM DB auth on PostgreSQL) |
| `ClusterEnvironment--OperationalDatabase--ConnectionSettings--Password` | DB password (or empty when using IAM DB auth on PostgreSQL) |
| `ClusterEnvironment--OperationalDatabase--PulseDatabaseName` | Pulse DB name |
| `ClusterEnvironment--OperationalDatabase--LoggingDatabaseName` | Pulse logging DB name |
| `ConnectionStrings--OperationalDatabase` | `PostgreSQL:Server=127.0.0.1;Port=5432;Database=<pulse>;User Id=<user>;Password=<pass>;` (PostgreSQL) **or** `Server=tcp:127.0.0.1,1433;Database=<pulse>;User ID=<user>;Password=<pass>;Encrypt=False;TrustServerCertificate=True;` (SQL Server) |
| `ConnectionStrings--LoggingDatabase` | Same shape, different DB name |

#### SQL Server gotchas

A few things specific to SQL Server + cloudSqlProxy that bite people:

1. **`databases.operational.encrypt: false` is required** in your overrides. The chart's default is `true`, which emits `ClusterEnvironment__OperationalDatabase__ConnectionSettings__SQLServerSettings__Encrypt=true`. With that, `Microsoft.Data.SqlClient` v4+ tries to negotiate TLS during pre-login. The loopback proxy has no inbound cert and the handshake fails (`A connection was successfully established with the server, but then an error occurred during the pre-login handshake`). Encryption on the wire is still handled by the proxy → Cloud SQL leg via mTLS - the loopback hop just needs to stay plaintext.
2. **Server syntax must use a comma, not a colon** - `tcp:127.0.0.1,1433`. SqlClient accepts `Server=tcp:host,port` (comma) but `Server=tcp:host:port` (colon) is not standard syntax and will silently fail to open a TCP connection. Symptom: deployment hangs at "Executing SQL for database 'Pulse'" and the `cloud-sql-proxy` log shows zero connection events after "ready for new connections".
3. **No IAM database authentication.** Cloud SQL for SQL Server doesn't expose IAM DB auth via the proxy; `autoIamAuthn: true` is silently ignored on the proxy side. You need a real SQL Server login + password in the vault. Set `autoIamAuthn: false` to be explicit.
4. **Add `Encrypt=False;TrustServerCertificate=True;`** to the `ConnectionStrings--*` entries. Same reason as #1 - the loopback hop is plaintext; the proxy handles encryption upstream.

#### Authentication modes

Two modes are supported. Workload Identity is recommended for production; the service-account key file mode exists for dev/non-prod scenarios where Workload Identity is impractical.

**Workload Identity (default):** the pod's Kubernetes service account is federated to a GCP service account that has `roles/cloudsql.client` on the Cloud SQL instance. The proxy authenticates via the IMDS metadata server. No credentials are ever mounted into the pod.

**Service-account key file:** the proxy reads a JSON key file from the same ConfigMap RPI uses for the rest of the Google SDK stack. Set `cloudIdentity.enabled: true` with `cloudIdentity.google.configMapName`, `cloudIdentity.google.keyName`, and `cloudIdentity.google.configMapFilePath` pointing at the ConfigMap and target path. The chart mounts that ConfigMap into the proxy sidecar at the **same path** the app containers see it (`${configMapFilePath}/${keyName}`, the value of `GOOGLE_APPLICATION_CREDENTIALS`) and passes `--credentials-file=${configMapFilePath}/${keyName}`. No separate Cloud SQL Proxy ConfigMap or path is needed; the platform-wide Google SA JSON is reused.

#### Values schema

```yaml
databases:
  operational:
    provider: postgresql

    cloudSqlProxy:
      enabled: true
      # Required: "<project>:<region>:<instance>"
      connectionName: my-project:us-central1:rpi-primary
      image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.11.2
      # Port the proxy exposes locally; chart sets ConnectionSettings__Port to this value.
      # Leave unset to let the chart pick the engine default (5432 for PostgreSQL, 1433 for SQL Server).
      port: 5432
      # Use the instance's private IP (requires VPC peering between GKE and Cloud SQL)
      privateIp: true
      # Use IAM database authentication (PostgreSQL only). When true, the chart uses
      # cloudIdentity.google.serviceAccountEmail as the DB user and omits the password
      # from the connection string; the proxy injects an IAM token at connection time.
      # Requires the SA email to be registered as a Cloud SQL IAM user.
      autoIamAuthn: false
      terminationGracePeriod: "30s"
      # Auth: Workload Identity is the default. To use a SA key file instead,
      # set cloudIdentity.google.configMapName and cloudIdentity.google.keyName
      # at the top level; the proxy mounts that same ConfigMap automatically.
      resources:
        requests: { cpu: 50m, memory: 64Mi }
        limits:   { cpu: 200m, memory: 256Mi }
      additionalArgs: []     # e.g. ["--structured-logs"] for JSON logs
```

#### Customer-side GCP IAM setup (Workload Identity path)

1. **Create a GCP service account** with Cloud SQL client permissions:
   ```bash
   gcloud iam service-accounts create rpi-cloudsql-client --project <your-project>
   gcloud projects add-iam-policy-binding <your-project> \
     --member "serviceAccount:rpi-cloudsql-client@<your-project>.iam.gserviceaccount.com" \
     --role "roles/cloudsql.client"
   ```

2. **Bind each RPI Kubernetes service account** to that GCP SA via Workload Identity:
   ```bash
   for sa in rpi-deploymentapi rpi-interactionapi rpi-integrationapi rpi-executionservice \
             rpi-nodemanager rpi-queuereader rpi-realtimeapi rpi-callbackapi; do
     gcloud iam service-accounts add-iam-policy-binding \
       rpi-cloudsql-client@<your-project>.iam.gserviceaccount.com \
       --role "roles/iam.workloadIdentityUser" \
       --member "serviceAccount:<your-project>.svc.id.goog[<your-namespace>/$sa]"
   done
   ```

3. **Annotate each K8s SA** with `iam.gke.io/gcp-service-account: rpi-cloudsql-client@<your-project>.iam.gserviceaccount.com`. The chart adds this annotation automatically when `cloudIdentity.google.workloadIdentity.enabled=true`, so just set it in your overrides.

#### Requirements

- **GKE version:** K8s 1.29+ (native sidecar with `restartPolicy: Always`)
- **Cloud SQL instance:** PostgreSQL with private IP enabled (or set `privateIp: false` to use public IP + IAM allow-list)
- **Network:** VPC peering between the GKE cluster's VPC and the Cloud SQL VPC (when using private IP)

#### What does NOT render when disabled

Nothing. With `cloudSqlProxy.enabled: false` (or the platform/provider gates not matching), the helper emits empty strings, no initContainers block appears, no volume is added, and the existing connection-string env vars flow through unchanged. Verified via `helm template` diff: output for Azure, AWS, and selfhosted deployments is byte-for-byte unchanged from before this feature landed.

</details>

---

## Common Reference

<details>
<summary><strong>Required Secret Keys</strong></summary>

The chart templates reference specific keys from the `redpoint-rpi-secrets` K8s Secret via `secretKeyRef`. These key names must match exactly regardless of platform or provider. Add keys based on which features are enabled.

**Always required:**

| Key | Description |
|:----|:------------|
| `ConnectionString_Operations_Database` | Full connection string to the operational database |
| `ConnectionString_Logging_Database` | Full connection string to the logging database |
| `Operations_Database_ServerHost` | Database server hostname |
| `Operations_Database_Server_Username` | Database username |
| `Operations_Database_Server_Password` | Database password |
| `Operations_Database_Pulse_Database_Name` | Operational database name |
| `Operations_Database_Pulse_Logging_Database_Name` | Logging database name |

**Realtime API** (if `realtimeapi.enabled: true`):

| Key | Description |
|:----|:------------|
| `RealtimeAPI_Auth_Token` | Authentication token for API access |
| `ConnectionString_RealtimeApi_OAuth` | OAuth database connection string (if using OAuth auth type) |
| `RealtimeAPI_MongoCache_ConnectionString` | MongoDB connection string (if mongodb cache) |
| `RealtimeAPI_MongoCache_ConnectionKey` | MongoDB connection key (if mongodb cache) |
| `RealtimeAPI_ServiceBus_ConnectionString` | Service Bus connection string (if azureservicebus queue) |
| `RealtimeAPI_EventHub_ConnectionString` | Event Hub connection string (if azureeventhubs queue) |
| `RealtimeAPI_AzureStorage_ConnectionString` | Azure Storage connection string (if azurestorage queue) |
| `RealtimeAPI_RabbitMQ_Password` | RabbitMQ password (if rabbitmq queue, **external** broker only - internal is auto-generated) |
| `RealtimeAPI_RedisCache_ConnectionString` | Redis connection string (if redis cache, **external** Redis only - internal is auto-generated) |
| `AWS_Access_Key_ID` | AWS access key (if amazonsqs queue) |
| `AWS_Secret_Access_Key` | AWS secret key (if amazonsqs queue) |

**SMTP** (if `SMTPSettings.UseCredentials: true`): `SMTP_Password`

**Redpoint AI** (if `redpointAI.enabled: true`):

| Key | Description |
|:----|:------------|
| `RPI_NLP_API_KEY` | Azure OpenAI API key |
| `RPI_NLP_SEARCH_KEY` | Azure Cognitive Search key |
| `RPI_NLP_MODEL_CONNECTION_STRING` | Model storage connection string (Azure Blob) |

**Rebrandly** (if `rebrandly.enabled: true`):

| Key | Description |
|:----|:------------|
| `Rebrandly_ApiKey` | Rebrandly API key |

> **Internal service passwords** (Redis, RabbitMQ, Rebrandly Redis) are auto-generated by the chart into the `rpi-internal-services` K8s Secret regardless of provider. You do NOT need to store these in your vault, CLI, or SecretProviderClass. This includes: `QueueService_RedisCache_Password`, `QueueService_RedisCache_ConnectionString`, `QueueService_RabbitMQ_Password`, `RealtimeAPI_RedisCache_Password`, `RealtimeAPI_RedisCache_ConnectionString`, `RealtimeAPI_RabbitMQ_Password`, `Rebrandly_RedisPassword`. The same-named keys belong in your vault ONLY when the service points at an EXTERNAL Redis/RabbitMQ.

</details>

<details>
<summary><strong>Secret Key Naming by Provider and Platform</strong></summary>

| Provider | Platform | Format | Example |
|:---------|:---------|:-------|:--------|
| **CSI** | Amazon | Single underscore (mapped via jmesPath objectAlias) | `ConnectionString_Logging_Database` |
| **CSI** | Azure | Hyphenated (Key Vault doesn't allow underscores, mapped via objectAlias) | `ConnectionString-LoggingDatabase` |
| **SDK** | Amazon | Double underscore `__` matching .NET config hierarchy | `ClusterEnvironment__OperationalDatabase__LoggingDatabaseName` |
| **SDK** | Azure | Double dash `--` matching .NET config hierarchy (Key Vault doesn't allow underscores) | `ClusterEnvironment--OperationalDatabase--ConnectionSettings--Password` |

CSI keys are synced into a K8s Secret and consumed via `secretKeyRef` - the alias names must match what the chart templates expect. SDK keys are read directly into the .NET configuration system at runtime - the names must match the .NET environment variable hierarchy.

</details>

<details>
<summary><strong>Internal Service Passwords (Redis, RabbitMQ)</strong></summary>

The chart deploys internal Redis and RabbitMQ StatefulSets for several services: the Realtime API's cache and queue broker (when their `type` is `internal`), the Queue Reader's distributed queues (`queuereader.realtimeConfiguration.isDistributed: true`), and Rebrandly. These are chart-managed infrastructure: their credentials come from `rpi-internal-services` in every secrets mode, and the servers always run with authentication regardless of your secrets provider.

#### The `rpi-internal-services` Secret

The chart automatically creates a Kubernetes Secret called `rpi-internal-services` with chart-generated passwords for all chart-managed internal services. This is created **regardless of secrets provider** (kubernetes, csi, or sdk) at install time and preserved across upgrades (`helm.sh/resource-policy: keep`).

You do NOT need to store these passwords in your vault, CLI, or SecretProviderClass.

| Key | Description | Created when |
|:----|:------------|:-------------|
| `QueueService_RedisCache_Password` | Queue reader internal Redis password | `queuereader.realtimeConfiguration.isDistributed: true` |
| `QueueService_RedisCache_ConnectionString` | Queue reader Redis connection string | `queuereader.realtimeConfiguration.isDistributed: true` |
| `QueueService_RabbitMQ_Password` | Queue reader internal RabbitMQ password | `queuereader.realtimeConfiguration.isDistributed: true` |
| `RealtimeAPI_RedisCache_Password` | Realtime API internal Redis password | Realtime API with internal Redis cache |
| `RealtimeAPI_RedisCache_ConnectionString` | Realtime API internal Redis connection string | Realtime API with internal Redis cache |
| `RealtimeAPI_RabbitMQ_Password` | Realtime API internal RabbitMQ password | Realtime API with internal RabbitMQ queue |
| `Rebrandly_RedisPassword` | Rebrandly internal Redis password | `rebrandly.enabled: true` |

To inspect the auto-generated passwords after deployment:

```bash
kubectl get secret rpi-internal-services -n <namespace> -o jsonpath='{.data.QueueService_RedisCache_Password}' | base64 -d
```

</details>

<details>
<summary><strong>Snowflake Configuration</strong></summary>

Snowflake JWT authentication requires the `.p8` RSA private key file to be mounted in the container. The connection string in the RPI client is always:

```
User=<user>;Db=<database>;Host=<host>;Account=<account>;AUTHENTICATOR=snowflake_jwt;PRIVATE_KEY_FILE=/app/snowflake-creds/my-snowflake-rsakey.p8
```

#### kubernetes Provider

The CLI (`rpihelmcli/setup.sh secrets`) creates a Kubernetes Secret from your `.p8` file. Configure the Snowflake section in your overrides:

```yaml
databases:
  datawarehouse:
    snowflake:
      enabled: true
      credentialsType: snowflake_jwt
      mountPath: /app/snowflake-creds
      keys:
      - keyName: my-snowflake-rsakey.p8
        secretName: snowflake-rsa-private-key
```

#### csi Provider

Store the `.p8` private key in your vault. Define a SecretProviderClass and set `secretProviderClassName` on the Snowflake config. The key is mounted directly via CSI inline volume - no K8s Secret is created and no validation pod is needed.

```yaml
databases:
  datawarehouse:
    snowflake:
      enabled: true
      credentialsType: snowflake_jwt
      mountPath: /app/snowflake-creds
      secretProviderClassName: snowflake-creds
      keys:
      - keyName: my-snowflake-rsakey.p8

secretsManagement:
  provider: csi
  csi:
    secretProviderClasses:
    - name: snowflake-creds
      provider: azure
      parameters:
        clientID: <managed-identity-client-id>
        keyvaultName: <your-keyvault>
        resourceGroup: <your-rg>
        subscriptionId: <your-sub>
        tenantId: <your-tenant>
      objects:
      - objectName: my-snowflake-private-key
        objectType: secret
        objectAlias: my-snowflake-rsakey.p8
```

For multi-tenant, add multiple objects to the same SecretProviderClass:

```yaml
      objects:
      - objectName: vault-tenant1-key
        objectType: secret
        objectAlias: tenant1-private-key.p8
      - objectName: vault-tenant2-key
        objectType: secret
        objectAlias: tenant2-private-key.p8
```

</details>

<details>
<summary><strong>Image Pull Secrets</strong></summary>

Image pull secrets cannot be managed through your vault (SDK or CSI). The pod needs the pull secret to download its container image before it starts, so the secret must exist as a Kubernetes Secret in the namespace before deployment.

**When you need one:**
- Pulling directly from the Redpoint Container Registry (`rg1acrpub.azurecr.io`), which requires credentials from Redpoint Support
- Pulling from an internal registry that requires Docker credentials (Artifactory, Harbor, etc.)

**When you don't need one:**
- Your nodes already have access to the registry (e.g., EKS node IAM roles for ECR, AKS with `AcrPull` role). Set `imagePullSecret.enabled: false`.
- You mirror images to a registry your nodes can access natively.

**How to create it:**

When using `secretsManagement.provider: kubernetes`, the CLI (`rpihelmcli/setup.sh secrets`) will prompt for registry credentials and generate the pull secret automatically.

When using `sdk` or `csi`, the CLI skips the secrets flow. Create the pull secret manually before deploying:

```bash
kubectl create secret docker-registry redpoint-rpi \
  --docker-server=rg1acrpub.azurecr.io \
  --docker-username=<username> \
  --docker-password='<password>' \
  -n <namespace>
```

Then in your overrides:
```yaml
global:
  deployment:
    images:
      imagePullSecret:
        enabled: true
        name: redpoint-rpi
```

</details>

---
<sub>Redpoint Interaction v7.8 | [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) | [Support](mailto:support@redpointglobal.com) | [redpointglobal.com](https://www.redpointglobal.com)</sub>
