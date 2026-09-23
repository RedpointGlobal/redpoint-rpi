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

## Prerequisites

The chart deploys the service and wires its configuration. It never creates cloud resources. Everything below must exist before you enable Twilio Messaging, and the names in your values must match what you provisioned. A missing entity is reported at runtime, not at render, and the pod stops rather than retries.

**Always required**

| Item | Notes |
|:-----|:------|
| Twilio account | `accountSid` in values, auth token in the shared Secret as `TwilioMessaging_AuthToken` |
| PostgreSQL database | Reused from the operational database, or supplied by you. See [PostgreSQL](#postgresql-required) |
| Cloud identity | `cloudIdentity.enabled: true` with the platform binding, since the transport authenticates with workload identity |
| DNS for the webhook host | `ingress.hosts.twiliomessaging` must resolve, because Twilio calls it |
| Database schema | The chart runs the schema installer as a pre-install and pre-upgrade hook. The one time `bootstrap` step that creates the role and database is manual, see below |

Redis is chart managed by default and needs nothing. Provision it only when `redisSettings.type: external`.

**Wire format.** Payloads are binary Avro with routing metadata in message attributes. The transport must deliver the body unchanged and preserve those attributes, so do not enable payload wrapping, transformation, or schema validation on any of these resources. Per transport that means raw message delivery on SNS to SQS subscriptions, nothing to configure on Event Hubs, and schemaless topics with pull subscriptions on Pub/Sub.

### Database schema

The schema is applied by a separate installer image, never by the service. Two steps:

1. **Bootstrap, once per environment.** Run the installer's `bootstrap` command with admin credentials to create the role, database and schema. This is manual and is not part of a release.
2. **Install, every release.** The chart runs this for you as `rpi-twiliomessaging-installer`, a pre-install and pre-upgrade hook Job with its own ServiceAccount so it has an identity on a first install. It authenticates the same way the service does, so it needs the same PostgreSQL grant.

Set `twiliomessaging.installer.enabled: false` only if you apply the schema out of band.

### Azure Event Hubs

Three hubs in one namespace, with consumer groups on each. Defaults are shown; override the values keys if you name them differently.

| Hub, values key | Default name | Consumer groups, values key | Default name |
|:---|:---|:---|:---|
| `eventHubs.inputHub.name` | `twilio-messaging-input` | `eventHubs.inputHub.consumerGroup` | `twilio-message-input-send` |
| `eventHubs.outputHub.name` | `twilio-messaging-output` | `twilioPlugin.eventHubs.deliveryStatusConsumerGroup`<br>`.sendResultConsumerGroup`<br>`.linkClickConsumerGroup`<br>`.inboundMessageConsumerGroup` | `twilio-messaging-output-delivery-status`<br>`-send-result`<br>`-link-click`<br>`-inbound-reply` |
| `eventHubs.outputInternalHub.name` | `twilio-messaging-output-internal` | `eventHubs.outputInternalHub.deliveryStatusConsumerGroup`<br>`.linkClickConsumerGroup`<br>`.inboundMessageConsumerGroup` | `twilio-messaging-output-internal-delivery-status`<br>`-link-click`<br>`-inbound-reply` |

The output hub consumer groups are read by the Execution Service plugin. The input and output internal ones are read by this service.

Two blob containers are also required, in the account given by `eventHubs.checkpointing.blobServiceUri`:

| Values key | Default | Used by |
|:---|:---|:---|
| `eventHubs.checkpointing.blobContainerName` | `sms-send-checkpoints` | Twilio Messaging |
| `twilioPlugin.eventHubs.checkpointing.blobContainerName` | `rpi-twilio-checkpoints` | Execution Service plugin |

```bash
RG="<resource-group>"
NS="<eventhubs-namespace>"
SA="<storage-account>"

for hub in twilio-messaging-input twilio-messaging-output twilio-messaging-output-internal; do
  az eventhubs eventhub create --resource-group "$RG" --namespace-name "$NS" --name "$hub"
done

az eventhubs eventhub consumer-group create --resource-group "$RG" --namespace-name "$NS" \
  --eventhub-name twilio-messaging-input --name twilio-message-input-send

for cg in delivery-status send-result link-click inbound-reply; do
  az eventhubs eventhub consumer-group create --resource-group "$RG" --namespace-name "$NS" \
    --eventhub-name twilio-messaging-output --name "twilio-messaging-output-${cg}"
done

for cg in delivery-status link-click inbound-reply; do
  az eventhubs eventhub consumer-group create --resource-group "$RG" --namespace-name "$NS" \
    --eventhub-name twilio-messaging-output-internal --name "twilio-messaging-output-internal-${cg}"
done

az storage container create --account-name "$SA" --name sms-send-checkpoints --auth-mode login
az storage container create --account-name "$SA" --name rpi-twilio-checkpoints --auth-mode login
```

Partition count on each hub bounds consumer parallelism, so size it for your throughput before creating them.

Grant the workload identity **Azure Event Hubs Data Receiver** and **Azure Event Hubs Data Sender** on the namespace, and **Storage Blob Data Contributor** on the storage account. The Execution Service identity needs the same, because the plugin consumes the output hub.

### AWS SQS and SNS

One input queue, two topics, and seven queues subscribed to them. All queue URLs and topic ARNs are required in values, there are no defaults.

| Values key | Role |
|:---|:---|
| `sqs.inputQueueUrl` | Send requests into the service |
| `sqs.outputTopicArn` | Fan-out consumed by the Execution Service plugin |
| `sqs.outputInternalTopicArn` | Fan-out consumed by this service |
| `sqs.outputDeliveryStatusQueueUrl`<br>`sqs.outputLinkClickQueueUrl`<br>`sqs.outputInboundMessageQueueUrl` | Subscribed to the output internal topic |
| `twilioPlugin.sqs.outputDeliveryStatusQueueUrl`<br>`.outputSendResultQueueUrl`<br>`.outputLinkClickQueueUrl`<br>`.outputInboundMessageQueueUrl` | Subscribed to the output topic |

```bash
REGION="<region>"
ACCT="<account-id>"

aws sqs create-queue --queue-name twilio-messaging-input --region "$REGION"

for t in twilio-messaging-output twilio-messaging-output-internal; do
  aws sns create-topic --name "$t" --region "$REGION"
done

for q in output-internal-delivery-status output-internal-link-click output-internal-inbound-reply \
         output-delivery-status output-send-result output-link-click output-inbound-reply; do
  aws sqs create-queue --queue-name "twilio-messaging-${q}" --region "$REGION"
done
```

Subscribe each queue to its topic with `RawMessageDelivery` set to true. Without it the service receives the SNS envelope instead of the message body.

```bash
aws sns subscribe --region "$REGION" \
  --topic-arn "arn:aws:sns:${REGION}:${ACCT}:twilio-messaging-output-internal" \
  --protocol sqs \
  --notification-endpoint "arn:aws:sqs:${REGION}:${ACCT}:twilio-messaging-output-internal-delivery-status" \
  --attributes RawMessageDelivery=true
```

Grant the IRSA role send and receive on the queues and publish on the topics.

### GCP Pub/Sub

Three topics and eight subscriptions. Only `pubsub.projectId` is required in values; the names below are defaults.

| Topic | Subscriptions |
|:---|:---|
| `twilio-messaging-input` | `twilio-messaging-input` |
| `twilio-messaging-output` | `twilio-messaging-output-delivery-status`, `-send-result`, `-link-click`, `-inbound-reply` |
| `twilio-messaging-output-internal` | `twilio-messaging-output-internal-delivery-status`, `-link-click`, `-inbound-reply` |

```bash
PROJECT="<gcp-project>"

for t in twilio-messaging-input twilio-messaging-output twilio-messaging-output-internal; do
  gcloud pubsub topics create "$t" --project "$PROJECT"
done

gcloud pubsub subscriptions create twilio-messaging-input \
  --topic twilio-messaging-input --project "$PROJECT"

for s in delivery-status send-result link-click inbound-reply; do
  gcloud pubsub subscriptions create "twilio-messaging-output-${s}" \
    --topic twilio-messaging-output --project "$PROJECT"
done

for s in delivery-status link-click inbound-reply; do
  gcloud pubsub subscriptions create "twilio-messaging-output-internal-${s}" \
    --topic twilio-messaging-output-internal --project "$PROJECT"
done
```

Leave the topics schemaless and use pull subscriptions. A Pub/Sub schema or message encoding validation rejects the service's own Avro framing, and push delivery with payload unwrapping breaks attribute based routing.

Grant the Workload Identity Federation service account `roles/pubsub.publisher` and `roles/pubsub.subscriber` on the project.

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

Select the transport with `messaging.provider` (`azureeventhubs`, `amazonsqs`, or `googlepubsub` - the chart-standard transport vocabulary, also used by the Realtime API queue provider). The chart emits only the selected transport's settings and maps the value to each application's own configuration enum.

**Azure Event Hubs.** The app authenticates to Event Hubs **and** the checkpoint blob store through `DefaultAzureCredential` = the pod's **Azure Workload Identity**, wired by `cloudIdentity`. This is independent of `secretsManagement.provider` (it works under `kubernetes`, `csi`, or `sdk`) - no connection string, no access key, no service principal:

```yaml
cloudIdentity:
  enabled: true
  azure:
    managedIdentityClientId: <workload-identity-client-id>
    tenantId: <azure-tenant-id>
twiliomessaging:
  messaging:
    provider: azureeventhubs
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
    provider: amazonsqs
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
    provider: googlepubsub
  pubsub:
    projectId: my-gcp-project
```

Topic and subscription names default to the standard `twilio-messaging-*` set (override under `pubsub.*` if needed).

---

## RPI integration (Execution Service / Interaction API)

When `twiliomessaging.enabled=true`, the chart also configures the RPI Twilio plugin to talk
to this service: the Execution Service receives the full `Plugins__Twilio__*` block and the
Interaction API receives `Plugins__Twilio__TmsBaseUrl` (used by the channel-admin
messaging-service picker, offline configuration, and the connectivity test). When the service
is disabled, none of this renders - a non-Twilio deployment carries zero Twilio configuration.

`TmsBaseUrl` is always the in-cluster address `http://rpi-twiliomessaging`; there is nothing
to configure.

Shared transport identifiers (Event Hubs namespace and hub names, SQS region and input queue,
Pub/Sub project and input topic) are emitted from the same `twiliomessaging` values the
service itself uses, so the two sides cannot drift. The resources RPI owns are configured
under `twiliomessaging.twilioPlugin`:

- **Event Hubs**: RPI consumes the shared output hub with one consumer group per event type
  (delivery status, send result, link click, inbound message) and checkpoints into its own
  blob container (`rpi-twilio-checkpoints` by default) in the `eventHubs.checkpointing`
  storage account. Consumer groups are not auto-created; all four must be provisioned on the
  output hub, and `inboundMessageConsumerGroup` must match the provisioned name. Never point
  RPI at the service's checkpoint container.
- **AWS**: four RPI-owned queues (`twilioPlugin.sqs.*`, all required with `amazonsqs`), each
  subscribed to the matching service SNS topic with `RawMessageDelivery=true`.
- **GCP**: four RPI-owned subscription ids on the output topic (`twilioPlugin.pubsub.*`),
  composed with `pubsub.projectId` into full resource names.

Broker credentials are never configured: the Execution Service authenticates with the pod's
cloud identity on every provider (Azure Workload Identity, AWS IRSA, GCP Workload Identity).
On Azure that identity needs the same data-plane RBAC as the service (Event Hubs data access
on the namespace, Storage Blob Data Contributor on the checkpoint account) plus a federated
identity credential for the `rpi-executionservice` ServiceAccount subject.

---

## Batch ingestion

Bulk send files are read from the shared File Output Directory PVC. Enable it (`storage.persistentVolumeClaims.FileOutputDirectory.enabled: true`) and the service watches `/rpifileoutputdir/twilio/batch/incoming` by default (paths are configurable under `twiliomessaging.batchIngestion.*`).

---

## Ingress (webhook paths only)

The proxy must forward `X-Forwarded-Proto`, `X-Forwarded-Host` and `X-Forwarded-For`. Twilio signature validation rebuilds the public URL from them, and validation fails if they are missing or rewritten. The bundled nginx ingress sets them by default.

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

For `secretsManagement.provider: kubernetes`, add the keys above to the shared Secret. For `csi`, declare them in `secretsManagement.csi.secretProviderClasses`. For `sdk`, PostgreSQL authenticates with cloud managed identity (no password); only `TwilioMessaging_AuthToken` (and an external-Redis password, if used) are read from your cloud vault.

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
    provider: azureeventhubs
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