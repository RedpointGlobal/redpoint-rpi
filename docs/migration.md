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
<summary><strong style="font-size:1.25em;">Settings changed or removed in v7.8</strong></summary>

If your `overrides.yaml` sets any of the following, here is what changed and what to do. Each row lists whether leaving the old setting in place blocks the upgrade.

| Setting in your `overrides.yaml` | 7.8 change | Action | Breaking if left? |
|:---|:---|:---|:---|
| `redpointAI.VectorSearchProfile`, `redpointAI.VectorSearchConfig` | Removed; RPI builds the search index at runtime | Remove them | **Yes** - the chart rejects them and the upgrade will not render |
| `executionservice.internalCache.statePersistenceProvider: DefaultCache` (also `queuereader.internalCache.statePersistenceProvider`) | `DefaultCache` is no longer a supported provider | Change it to `FileSystem` or `AzureBlobStorage` | **Yes** - the Execution Service and Queue Reader fail to start |
| `executionservice.jobExecution.luxScisendRequestCount` | Renamed to `executionservice.jobExecution.luxSci.maxConcurrentApiRequestsPerAccount` (default 5 in both) | Move your value to the new setting and remove the old one | No - the old setting is ignored |
| `executionservice.internalCache.backupToOpsDBInterval`, `executionservice.internalCache.failOnPrimaryDataLoss` (also Queue Reader) | Removed; OpsDB cache failover removed | Remove them | No - ignored if left |
| `interactionapi.enableSwagger` | The Interaction API no longer exposes Swagger (`integrationapi.enableSwagger` unchanged) | Remove it | No - ignored if left |
| `databases.datawarehouse.bigquery.connections[].ConfigMapFilePath` | No longer applies; the chart manages the credential file location | Remove it | No - ignored if left |

The rows marked **Yes** must be resolved before you upgrade. The rest are cleanup you can do before or after the upgrade: if you leave the old setting in place, the chart ignores it and the upgrade proceeds normally.

BigQuery `serviceAccount` connections keep working with no credential change: your `configMapName` and `keyName` still point at the same ConfigMap and data key, and `cloudIdentity.google` is unchanged. The chart now manages where the credential file is placed, which matters only if a process outside the chart reads that file directly (see the checklist).

</details>

<details>
<summary><strong style="font-size:1.25em;">Upgrade Checklist</strong></summary>

1. Resolve any breaking rows from the table above that appear in your `overrides.yaml` (the RedpointAI vector search values, and `DefaultCache`).
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
