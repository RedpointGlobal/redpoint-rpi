![redpoint_logo](../chart/images/redpoint.png)
# Upgrading from v7.7 to v7.8

[< Back to Home](../README.md)

This guide covers upgrading an existing RPI v7.7 Helm deployment to v7.8. If you're deploying RPI for the first time, see the [Greenfield Installation](greenfield.md) guide instead.

> **Not ready to upgrade?** The `release/v7.7` branch remains available on GitHub for critical fixes. You can stay on v7.7 as long as needed.

---

<details>
<summary><strong style="font-size:1.25em;">What Changed in the Helm Chart</strong></summary>

v7.8 is designed to preserve existing v7.7 configuration. Most existing overrides require no changes. A small number of settings have changed behavior or been removed; these are identified below. In particular, BigQuery service account connections continue to use the existing ConfigMap and key (see Changed in v7.8 and the checklist below).

| Area | Change |
|:---|:---|
| Google Cloud SQL | Passwordless IAM connectivity via the Cloud SQL Auth Proxy |
| BigQuery | Data-warehouse support with keyless Workload Identity |
| Realtime API | Expanded geolocation, identity, profile/ML processing, integration, and operational configuration |
| Interaction API | Expanded auth/security, logging, integration, and operational configuration |
| Queue Reader | Expanded logging, integration, distributed-processing, and operational configuration |
| Redpoint AI | Restructured into a shared model block plus capabilities enabled on their own. New MCP tool server, agent runtime, and chat application |
| RPI NLP | Trace logging for NLP request/response diagnostics |
| Twilio Messaging | New opt-in SMS service with its own PostgreSQL store, Redis, and message transport |
| Common environment variables | Set environment variables on every RPI application service from one place |

</details>

<details>
<summary><strong style="font-size:1.25em;">New Chart Features</strong></summary>

### Google Cloud SQL (PostgreSQL) with IAM authentication

RPI can connect to a Google Cloud SQL for PostgreSQL instance using passwordless IAM authentication through the Cloud SQL Auth Proxy, which runs as a sidecar. With `autoIamAuthn` enabled, pods connect over loopback using the IAM database user and no stored password. The proxy requires `cloudIdentity.enabled: true` (it authenticates with the pod's Google identity); the secret provider is independent, so `kubernetes`, `csi`, or `sdk` may all be used.

```yaml
databases:
  operational:
    provider: postgresql
    databaseSchema: dbo
    cloudSqlProxy:
      enabled: true
      connectionName: my-project:us-central1:my-instance
      autoIamAuthn: true
      privateIp: true
```

See [Google Cloud SQL (IAM)](google-cloud-sql-iam.md) for the full setup, including the required Workload Identity binding.

### BigQuery data warehouse with keyless Workload Identity

The chart renders an ODBC DSN ConfigMap for the Simba BigQuery driver when `databases.datawarehouse.bigquery.enabled` is true, with one DSN per connection. Each connection chooses how it authenticates:

| `credentialsType` | Authentication |
|:---|:---|
| `serviceAccount` | Service account key file (`serviceAccountEmail` plus a mounted key) |
| `workloadIdentity` | Keyless, via the pod's GCP Workload Identity (Application Default Credentials). No key file is mounted. |

For `serviceAccount` connections, `configMapName` names the Kubernetes ConfigMap and `keyName` its data key. BigQuery credentials are managed independently of the platform Google credential (`cloudIdentity.google`); a connection and the platform may reference the same ConfigMap or different ones.

```yaml
databases:
  datawarehouse:
    bigquery:
      enabled: true
      connections:
        - name: gbq-tenant1
          projectId: my-google-project
          credentialsType: workloadIdentity
          OAuthMechanism: 3
```

### Realtime API: expanded configuration

Expanded configuration support for geolocation, identity resolution, visitor and profile processing, logging, integrations, and operational settings, including geolocation and IP-lookup, identity and profile-merge controls, RedPoint ML scoring, file output, and SMTP.

```yaml
realtimeapi:
  geolocation:
    enabled: true
    provider: Azure
    weatherUnits: imperial
  RedPointMLServiceAddress: "https://<your-ml-service>"   # address of the RedPoint ML scoring service
  RedPointMLClientID: "<client-id>"                        # client identifier for the ML service
```

### Interaction API: expanded configuration

Expanded configuration support for authentication/security, logging, integrations, and operational settings, including password policies, account lockout, token lifetimes, logging providers, Azure services, and client service credentials.

```yaml
interactionapi:
  passwordPolicy:
    requiredLength: 12
    requireDigit: true
    requireUppercase: true
    requireLowercase: true
    requireNonAlphanumeric: true
```

### Queue Reader: expanded configuration

Expanded configuration support for logging, integrations, distributed processing, and operational settings, including logging providers (New Relic, Loggly), NLP, SMTP, file output, operational database retry, and the chart managed internal cache and queue for distributed processing.

```yaml
queuereader:
  # Operational database retry
  operationalDatabase:
    maxRetryCount: 12
    maxRetryDelay: "00:01:00"
  # Distributed processing: deploys the chart-managed Redis and RabbitMQ
  realtimeConfiguration:
    isDistributed: true
```

### Per-tenant Realtime API address override

The cluster wide Realtime API address can be overridden per client (tenant). Each entry pairs a client GUID with the Realtime API base address for that client; the override is consumed by the Interaction API and Execution Service. Requires `realtimeapi.multitenant: true`.

```yaml
realtimeapi:
  multitenant: true
  clientAddressOverrides:
    - clientId: <client-guid>
      address: https://realtimeapi-tenant1.example.com
```

### LuxSci send throughput controls

Two independent concurrency caps for large LuxSci sends on the Execution Service: a per-account API rate guard and the per-activity send parallelism.

```yaml
executionservice:
  jobExecution:
    luxSci:
      maxConcurrentApiRequestsPerAccount: 5   # per-account LuxSci API rate guard
      maxDegreeOfParallelism: 10              # concurrent sends within an activity
```

### Redpoint AI: separate capabilities, one model configuration

`redpointAI` is now a shared model block plus capabilities that are each enabled on their own. `redpointAI.model` holds the endpoint, API version and deployment that every capability consuming a model reads, with the credential in the shared RPI Secret. Everything a single capability owns lives under that capability.

Natural language rule building is unchanged in behavior and moves to `redpointAI.nlp`. Three capabilities are new:

| Capability | Setting | What it does | Requires |
|:---|:---|:---|:---|
| MCP tool server | `redpointAI.mcpServers.rpi.enabled` | Publishes the RPI Integration API as Model Context Protocol tools for AI clients | Nothing else |
| Agent runtime | `redpointAI.agentRuntime.enabled` | An RPI native agent that reaches RPI through those tools | MCP tool server |
| Chat application | `redpointAI.aiWeb.enabled` | A browser client for the agent runtime | Agent runtime |

A tool server exposes an API and consumes no model, so `redpointAI.model` is not required for it.

```yaml
redpointAI:
  model:
    ApiBase: https://<your-openai-name>.openai.azure.com/
    ApiVersion: 2023-07-01-preview
    ChatGptEngine: <chat-model-deployment-name>
  nlp:
    enabled: true
  mcpServers:
    rpi:
      enabled: true
      oauthClientId: <integration-api-oauth-client-id>
      defaultClientId: <your-rpi-tenant-guid>
```

Existing v7.7 overrides must be rewritten. The Upgrade Checklist below carries the full path mapping. See [Redpoint AI](redpoint-ai.md) and [RPI MCP Server](rpi-mcp-server.md).

### RPI NLP trace logging

RPI NLP now supports verbose request/response trace logging for diagnostics on the services that use the NLP integration (Interaction API, Execution Service, Node Manager, Queue Reader, Integration API). It is off by default. Enable it with `redpointAI.nlp.logging.enableTrace`.

```yaml
redpointAI:
  nlp:
    enabled: true
    logging:
      enableTrace: true   # verbose NLP request/response tracing, default false
```

### Twilio Messaging

A new opt-in SMS service, off by default. It is a separate workload with its own PostgreSQL store, a Redis cache, and a message transport chosen per platform: Azure Event Hubs, AWS SQS and SNS, or Google Pub/Sub.

```yaml
twiliomessaging:
  enabled: true
  accountSid: <twilio-account-sid>
  messaging:
    provider: azureeventhubs      # or amazonsqs, or googlepubsub
  postgres:
    reuseOperational: false
    host: <postgres-host>
    username: <postgres-user>
    database: twilio_messaging
  eventHubs:
    fullyQualifiedNamespace: <namespace>.servicebus.windows.net
    checkpointing:
      blobServiceUri: https://<storage-account>.blob.core.windows.net
```

`postgres.reuseOperational: true` puts the store on the operational database server and reuses its credentials, which requires `databases.operational.provider: postgresql`. The chart says so at render if it does not hold.

Customer-populated Secret keys: `TwilioMessaging_AuthToken`, plus `TwilioMessaging_Postgres_Password` when the store is standalone. The internal Redis password is generated by the chart.

The transport objects are not created for you. Hubs, queues, topics, subscriptions, and consumer groups must exist before the service starts, and the database schema is applied by a Job that runs before the service rolls. Only the Twilio webhook paths are published. Send and status routes stay in namespace. See [Twilio Messaging](twilio-messaging.md) for the prerequisites and the commands for each platform.

### Common environment variables

`commonEnvVars` sets environment variables on every RPI application service from one place, following the same pattern as `commonAnnotations`. It is empty by default and inert when empty.

```yaml
commonEnvVars:
  - name: DT_TAGS
    value: "environment=production"
```

Name and value only. The variables are emitted on the Interaction API, Integration API, Deployment API, Callback API, Realtime API, Execution Service, Node Manager, Queue Reader, Rebrandly, and Twilio Messaging. They are not emitted on chart deployed infrastructure such as the Redis and RabbitMQ workloads, on Smart Activation, or on the Redpoint AI workloads.

If your v7.7 overrides already carried a `commonEnvVars` block it had no effect, because the setting did not exist. Confirm the values are the ones you want before upgrading, because they now reach the pods.

</details>

<details>
<summary><strong style="font-size:1.25em;">Upgrade Checklist</strong></summary>

If your `overrides.yaml` sets any of the following, here is what changed and what to do. Each row lists whether leaving the old setting in place blocks the upgrade.

<table style="width:100%;border-collapse:collapse;table-layout:fixed;line-height:1.4">
<colgroup><col style="width:31%"><col style="width:37%"><col style="width:20%"><col style="width:12%"></colgroup>
<thead>
<tr>
<th align="left">Setting</th>
<th align="left">7.8 change</th>
<th align="left">Action</th>
<th align="left">Breaking</th>
</tr>
</thead>
<tbody>
<tr>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>redpointAI:</code><br><code>&nbsp;&nbsp;VectorSearchProfile</code><br><code>&nbsp;&nbsp;VectorSearchConfig</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Removed; RPI builds the search index at runtime</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Remove them</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><strong>Yes</strong> - the chart rejects them and the upgrade will not render</td>
</tr>
<tr style="background:#fafbfc">
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>redpointAI:</code><br><code>&nbsp;&nbsp;enabled</code><br><code>&nbsp;&nbsp;naturalLanguage</code><br><code>&nbsp;&nbsp;cognitiveSearch</code><br><code>&nbsp;&nbsp;modelStorage</code><br><code>&nbsp;&nbsp;logging</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Restructured. Each Redpoint AI capability is now enabled on its own. <code>redpointAI.model</code> holds the model every capability shares, and everything only natural-language rule building uses moved under <code>redpointAI.nlp</code>. See the mapping below</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Rewrite the block using the mapping below</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><strong>Yes</strong> - the chart rejects the old setting and the upgrade will not render</td>
</tr>
<tr>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>executionservice:</code><br><code>&nbsp;&nbsp;jobExecution:</code><br><code>&nbsp;&nbsp;&nbsp;&nbsp;luxScisendRequestCount</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Renamed to<br><code>executionservice:</code><br><code>&nbsp;&nbsp;jobExecution:</code><br><code>&nbsp;&nbsp;&nbsp;&nbsp;luxSci:</code><br><code>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;maxConcurrentApiRequestsPerAccount</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Move your value to the new setting and remove the old one</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No - the old setting is ignored</td>
</tr>
<tr style="background:#fafbfc">
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>executionservice:</code><br><code>&nbsp;&nbsp;internalCache:</code><br><code>&nbsp;&nbsp;&nbsp;&nbsp;backupToOpsDBInterval</code><br><code>&nbsp;&nbsp;&nbsp;&nbsp;failOnPrimaryDataLoss</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Removed; OpsDB cache failover removed</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Remove them</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No - ignored if left</td>
</tr>
<tr>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>interactionapi:</code><br><code>&nbsp;&nbsp;enableSwagger</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">The Interaction API no longer exposes Swagger (<code>integrationapi.enableSwagger</code> unchanged)</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Remove it</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No - ignored if left</td>
</tr>
<tr style="background:#fafbfc">
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>databases:</code><br><code>&nbsp;&nbsp;datawarehouse:</code><br><code>&nbsp;&nbsp;&nbsp;&nbsp;bigquery:</code><br><code>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;connections:</code><br><code>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;- ConfigMapFilePath</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No longer applies; the chart manages the credential file location</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Remove it</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No - ignored if left</td>
</tr>
</tbody>
</table>

**Redpoint AI mapping**

| 7.7 | 7.8 |
|:---|:---|
| `redpointAI.enabled` | `redpointAI.nlp.enabled` |
| `redpointAI.naturalLanguage.ApiBase` | `redpointAI.model.ApiBase` |
| `redpointAI.naturalLanguage.ApiVersion` | `redpointAI.model.ApiVersion` |
| `redpointAI.naturalLanguage.ChatGptEngine` | `redpointAI.model.ChatGptEngine` |
| `redpointAI.naturalLanguage.ChatGptTemp` | `redpointAI.nlp.ChatGptTemp` |
| `redpointAI.cognitiveSearch.SearchEndpoint` | `redpointAI.nlp.cognitiveSearch.SearchEndpoint` |
| `redpointAI.modelStorage.*` | `redpointAI.nlp.modelStorage.*` |
| `redpointAI.logging.enableTrace` | `redpointAI.nlp.logging.enableTrace` |

The environment contract the RPI services consume is unchanged, so this is an overrides edit only. Secret keys are unchanged.

BigQuery `serviceAccount` connections keep working with no credential change: your `configMapName` and `keyName` still point at the same ConfigMap and data key, and `cloudIdentity.google` is unchanged. The chart now manages where the credential file is placed, which matters only if a process outside the chart reads that file directly (see step 2).

1. Resolve any breaking rows from the table above that appear in your `overrides.yaml` (the RedpointAI vector search values).
2. If a process outside the chart reads the BigQuery credential file directly, update its path to `/app/google-creds/bigquery/<connection name>.json` (v7.7 used `/app/google-creds/<keyName>`). The chart already uses the new path.
3. Apply the upgrade with your existing `helm upgrade` command and overrides file.
4. Optionally, complete the non-breaking cleanup from the table above. This can be done before or after the upgrade.

New v7.8 features (Cloud SQL IAM, BigQuery Workload Identity, Realtime geolocation, Interaction API password policy, per-tenant Realtime API address, LuxSci throughput controls) are opt-in and default off.

</details>

---

## Next Steps

Use the [Helm Assistant Web UI](https://rpi-helm-assistant.redpointcdp.com) **Reference** and **Chat** tabs to browse configuration and ask questions.

---
<sub>Redpoint Interaction v7.8 | [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) | [Support](mailto:support@redpointglobal.com) | [redpointglobal.com](https://www.redpointglobal.com)</sub>
