![redpoint_logo](../chart/images/redpoint.png)
# Twilio Messaging

[< Back to Home](../README.md)

## Overview

**Twilio Messaging** is an opt-in RPI service that sends and receives SMS through Twilio. It runs an ASP.NET Web API plus background workers in the same cluster and namespace as the rest of RPI, and is enabled with a single flag:

```yaml
twiliomessaging:
  enabled: true
```

When disabled (the default) the chart renders nothing for it.

The service has three backing dependencies:

| Dependency | Role | How the chart wires it |
|:-----------|:-----|:-----------------------|
| **PostgreSQL** | Durable message store (`twilio_messaging` database) | Reuses the operational database when it is PostgreSQL, or points at a database you supply. **SQL Server is not supported.** |
| **Redis** | Distributed locks and de-duplication | Chart-managed StatefulSet (internal), or a Redis you supply (external). |
| **A messaging transport** | Fan-out of send/status/inbound/link-click events | One of Azure Event Hubs, AWS SQS/SNS, or GCP Pub/Sub, authenticated with the deployment's cloud identity. |

Twilio webhooks (delivery status, inbound replies, link clicks) are internet-facing, so the service is exposed through the chart ingress on its own host.

> The Twilio account SID (`twiliomessaging.accountSid`) is configuration; the Twilio **auth token is a secret** and is never placed in values. See [Secrets](#secrets).

---

## PostgreSQL (required)

Twilio Messaging requires PostgreSQL. The database name defaults to `twilio_messaging`; create it (and run the schema) on the target server before enabling the service.

**Reuse the operational database (default).** When `databases.operational.provider` is `postgresql`, the service connects to the same server with the same credentials and uses a separate `twilio_messaging` database:

```yaml
databases:
  operational:
    provider: postgresql
twiliomessaging:
  enabled: true
  postgres:
    reuseOperational: true        # default
    database: twilio_messaging
```

**Bring your own PostgreSQL.** Required when the operational database is SQL Server (Twilio still needs PostgreSQL) and for every `sdk` deployment. Set `reuseOperational: false` and supply host + username:

```yaml
twiliomessaging:
  postgres:
    reuseOperational: false
    host: my-postgres-host
    database: twilio_messaging
    username: twilio_app
    sslMode: Require
```

**Authentication is derived from `secretsManagement.provider` - there is no auth-mode knob:**

| `secretsManagement.provider` | PostgreSQL auth | Where the credential comes from |
|:-----------------------------|:----------------|:--------------------------------|
| `kubernetes` / `csi` | Password (Basic) | Shared Secret key `TwilioMessaging_Postgres_Password` (or `Operations_Database_Server_Password` when `reuseOperational: true`) |
| `sdk` on `platform: azure` | Azure Entra managed identity | Workload Identity (no password) |
| `sdk` on `platform: amazon` | AWS RDS IAM | IRSA / Pod Identity (no password) |
| `sdk` on `platform: google` | Cloud SQL IAM | Workload Identity (no password) |

`helm template` fails fast when:
- `reuseOperational: true` and the operational database is not PostgreSQL;
- `reuseOperational: true` and `secretsManagement.provider: sdk` (the operational host/username are vault-resolved, so set `reuseOperational: false` and give Twilio its own host/username);
- `reuseOperational: false` without `postgres.host` / `postgres.username`;
- `secretsManagement.provider: sdk` on a platform other than azure / amazon / google.

On Google Cloud SQL the service connects through the same Cloud SQL Auth Proxy as the operational database (`databases.operational.cloudSqlProxy`); when that proxy is enabled the host is set to `127.0.0.1` automatically.

---

## Redis

**Internal (default).** The chart deploys a single-pod Redis StatefulSet (`rpi-twiliomessaging-cache`) and auto-generates its password into the chart-managed `rpi-internal-services` Secret. Nothing to configure:

```yaml
twiliomessaging:
  redisSettings:
    type: internal
```

**External (BYO cloud Redis).** Point at a managed Redis - Azure Cache for Redis, AWS ElastiCache, or GCP Memorystore. Supply only the endpoint; **auth is derived from `secretsManagement.provider` + `global.deployment.platform`**, exactly like PostgreSQL - there is no auth-mode knob:

| `secretsManagement.provider` + `platform` | Redis auth | Credential |
|:------------------------------------------|:-----------|:-----------|
| `kubernetes` / `csi` (any platform) | Access key / password | Shared Secret key `TwilioMessaging_Redis_Password` |
| `sdk` on `azure` | Azure Entra managed identity | Workload Identity (`cloudIdentity.azure.managedIdentityClientId`) |
| `sdk` on `amazon` | ElastiCache IAM | IRSA (`cloudIdentity.amazon.roleArn`) + `region` + `cacheName` |
| `sdk` on `google` | Memorystore IAM | Workload Identity (`cloudIdentity.google.serviceAccountEmail`) |

```yaml
# kubernetes/csi - access key from the shared Secret
twiliomessaging:
  redisSettings:
    type: external
    hostname: my-redis.redis.cache.windows.net
    useTls: true
```

```yaml
# sdk on Azure - managed identity, no key
secretsManagement:
  provider: sdk
cloudIdentity:
  enabled: true
  azure:
    managedIdentityClientId: <your-workload-identity-client-id>
twiliomessaging:
  redisSettings:
    type: external
    hostname: my-redis.redis.cache.windows.net
    useTls: true
```

`helm template` fails fast when `type: external` has no `hostname`, when AWS ElastiCache (sdk on amazon) is missing `region` / `cacheName`, or when `sdk` is used without `cloudIdentity.enabled`.

---

## Messaging transport

Select the transport with `messaging.provider` (`EventHub`, `SQS`, or `PubSub`). The chart emits only the selected transport's settings.

**Azure Event Hubs.** The app authenticates to Event Hubs **and** the checkpoint blob store through `DefaultAzureCredential` = the pod's **Azure Workload Identity**, wired by `cloudIdentity`. This is independent of `secretsManagement.provider` (it works under `kubernetes`, `csi`, or `sdk`) - no connection string, no access key, no service principal:

```yaml
cloudIdentity:
  enabled: true
  azure:
    managedIdentityClientId: <workload-identity-client-id>
    tenantId: <azure-tenant-id>
twiliomessaging:
  messaging:
    provider: EventHub
  eventHubs:
    fullyQualifiedNamespace: my-ehns.servicebus.windows.net
    checkpointing:
      blobServiceUri: https://mystorage.blob.core.windows.net
```

The chart puts `azure.workload.identity/use: "true"` on the pod and the `azure.workload.identity/client-id` annotation on its ServiceAccount; the Azure WI webhook injects the federated-token credential, which `DefaultAzureCredential` uses for both Event Hubs and the checkpoint blob.

**AWS SQS/SNS:**

```yaml
twiliomessaging:
  messaging:
    provider: SQS
  sqs:
    region: us-east-1
    inputQueueUrl: https://sqs.us-east-1.amazonaws.com/<acct>/twilio-messaging-input
    outputTopicArn: arn:aws:sns:us-east-1:<acct>:twilio-messaging-output
    outputInternalTopicArn: arn:aws:sns:us-east-1:<acct>:twilio-messaging-output-internal
    outputDeliveryStatusQueueUrl: https://sqs.us-east-1.amazonaws.com/<acct>/twilio-messaging-output-internal-delivery-status
    outputLinkClickQueueUrl: https://sqs.us-east-1.amazonaws.com/<acct>/twilio-messaging-output-internal-link-click
    outputInboundMessageQueueUrl: https://sqs.us-east-1.amazonaws.com/<acct>/twilio-messaging-output-internal-inbound-reply
```

**GCP Pub/Sub:**

```yaml
twiliomessaging:
  messaging:
    provider: PubSub
  pubsub:
    projectId: my-gcp-project
```

Topic and subscription names default to the standard `twilio-messaging-*` set (override under `pubsub.*` if needed).

---

## Batch ingestion

Bulk send files are read from the shared File Output Directory PVC. Enable it (`storage.persistentVolumeClaims.FileOutputDirectory.enabled: true`) and the service watches `/rpifileoutputdir/twilio/batch/incoming` by default (paths are configurable under `twiliomessaging.batchIngestion.*`).

---

## Ingress (webhook paths only)

Only the Twilio **webhook** paths are exposed publicly - these are secured by Twilio signature validation. The send, status, and messaging-service routes are **never** published; they remain reachable only inside the cluster through the `ClusterIP` Service. This is enforced by path-scoping the ingress rule (not by exposing the whole host).

```yaml
ingress:
  domain: example.com
  hosts:
    twiliomessaging: rpi-twiliomessaging   # -> rpi-twiliomessaging.example.com
twiliomessaging:
  ingress:
    publicPaths:
      - /api/v1/webhook        # covers /status, /inbound, /link-click; default
```

`publicPaths` is the complete public surface for the host: every listed prefix routes to the Twilio Service, and any other path on that host returns 404 at the ingress. Add the version-less alias (`/api/webhook`) if Twilio is pointed at it. Set `publicPaths: []` to expose nothing publicly (fully cluster-internal). Because the Service is `ClusterIP`, in-cluster callers still reach every route directly via `rpi-twiliomessaging.<namespace>.svc`.

---

## Secrets

No secret is ever placed in values. The service reads:

| Secret key | When needed | Where it lives |
|:-----------|:------------|:---------------|
| `TwilioMessaging_AuthToken` | Always | Shared RPI Secret (`redpoint-rpi-secrets`) |
| `TwilioMessaging_Postgres_Password` | `reuseOperational: false` on `kubernetes` / `csi` (not `sdk`) | Shared RPI Secret |
| `TwilioMessaging_Redis_Password` | External Redis on `kubernetes` / `csi` (not `sdk`) | Shared RPI Secret |
| `TwilioMessaging_RedisCache_Password` | Internal Redis | Auto-generated by the chart into `rpi-internal-services` |

For `secretsManagement.provider: kubernetes` the `rpihelmcli secrets` command prompts for the required keys and writes them into the shared Secret. For `csi`, declare them in `secretsManagement.csi.secretProviderClasses`. For `sdk`, PostgreSQL authenticates with cloud managed identity (no password); only `TwilioMessaging_AuthToken` (and an external-Redis password, if used) are read from your cloud vault.

---

## Minimal example (Azure, kubernetes secrets, reuse operational PostgreSQL, internal Redis, Event Hubs)

```yaml
secretsManagement:
  provider: kubernetes
databases:
  operational:
    provider: postgresql
twiliomessaging:
  enabled: true
  messaging:
    provider: EventHub
  postgres:
    reuseOperational: true       # kubernetes -> Basic auth, operational DB password reused
  eventHubs:
    fullyQualifiedNamespace: my-ehns.servicebus.windows.net
    checkpointing:
      blobServiceUri: https://mystorage.blob.core.windows.net
  accountSid: ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
ingress:
  hosts:
    twiliomessaging: rpi-twiliomessaging
```

Populate `TwilioMessaging_AuthToken` in the shared Secret, then `helm upgrade`.
