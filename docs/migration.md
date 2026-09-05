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
| RPI NLP | Trace logging for NLP request/response diagnostics |

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

### RPI NLP trace logging

RPI NLP now supports verbose request/response trace logging for diagnostics on the services that use the NLP integration (Interaction API, Execution Service, Node Manager, Queue Reader, Integration API). It is off by default; enable it with `redpointAI.logging.enableTrace`.

```yaml
redpointAI:
  logging:
    enableTrace: true   # verbose NLP request/response tracing (default false); requires redpointAI.enabled: true
```

</details>

<details>
<summary><strong style="font-size:1.25em;">Changed in v7.8</strong></summary>

### BigQuery service account credentials

In v7.7 a BigQuery `serviceAccount` connection could set `ConfigMapFilePath` to control where its credential file was placed. In v7.8 the chart manages that location, and `ConfigMapFilePath` no longer applies.

- Your connection's `configMapName` and `keyName` are unchanged and still identify the same Kubernetes ConfigMap and data key. Do not recreate or rename your BigQuery ConfigMaps or service accounts.
- No `overrides.yaml` change is required. `ConfigMapFilePath`, if still set on a connection, is ignored.
- Platform Google credentials (`cloudIdentity.google`) are unchanged.
- The credential file the chart mounts for BigQuery moved to a new location. This matters only if a process outside the chart reads that file directly; see the checklist for the path.

</details>

<details>
<summary><strong style="font-size:1.25em;">Removed in v7.8</strong></summary>

### RedpointAI vector search values

`redpointAI.VectorSearchProfile` and `redpointAI.VectorSearchConfig` have been removed. RPI now creates the search index, vector profile, and algorithm at runtime. The chart rejects these keys at render, so remove them from your overrides if present (see the checklist). See [Redpoint AI](https://docs.redpointglobal.com/rpi/admin-basic-selection-rule-ai-integration).

### Internal cache OpsDB failover

OpsDB backed cache failover was removed in 7.8. On the Execution Service and Queue Reader, `internalCache.backupToOpsDBInterval` and `internalCache.failOnPrimaryDataLoss` no longer apply and are ignored if still present in your overrides. No action is required.

### Swagger on the Interaction API

The Interaction API no longer exposes Swagger, so `interactionapi.enableSwagger` has no effect and is ignored if set. `integrationapi.enableSwagger` is unchanged. No action is required.

### LuxSci send cap renamed

The Execution Service LuxSci per-account send cap moved from `executionservice.jobExecution.luxScisendRequestCount` to `executionservice.jobExecution.luxSci.maxConcurrentApiRequestsPerAccount` (default 5 in both). If you left it at the default, no action is required. If you customized the 7.7 value, set your value on the new key to carry it over; the old key is ignored.

</details>

<details>
<summary><strong style="font-size:1.25em;">Upgrade Checklist</strong></summary>

1. If your overrides set `redpointAI.VectorSearchProfile` or `redpointAI.VectorSearchConfig`, remove them. The chart rejects them at render (RPI creates the search index at runtime).
2. If your overrides set `internalCache.statePersistenceProvider: DefaultCache` on the Execution Service or Queue Reader, change it to `FileSystem` or `AzureBlobStorage`. `DefaultCache` is no longer a valid value, and those services fail to start if it is set.
3. If anything outside the chart reads the old BigQuery credential path `/app/google-creds/<keyName>`, update it to `/app/google-creds/bigquery/<connection name>.json`. The chart and its generated ODBC DSN already use the new path.
4. Apply the upgrade with your existing `helm upgrade` command and overrides file.

Everything else in v7.8 is handled by the chart. Renamed or removed settings left in your overrides are ignored, not rejected, so no other cleanup is required. New features (Cloud SQL IAM, BigQuery Workload Identity, Realtime geolocation, Interaction API password policy, per-tenant Realtime API address, LuxSci throughput controls) are opt-in and default off.

</details>

---

## Next Steps

Use the [Helm Assistant Web UI](https://rpi-helm-assistant.redpointcdp.com) **Reference** and **Chat** tabs to browse configuration and ask questions.

---
<sub>Redpoint Interaction v7.8 | [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) | [Support](mailto:support@redpointglobal.com) | [redpointglobal.com](https://www.redpointglobal.com)</sub>
