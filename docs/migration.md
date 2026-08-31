![redpoint_logo](../chart/images/redpoint.png)
# Upgrading from v7.7 to v7.8

[< Back to Home](../README.md)

This guide covers upgrading an existing RPI v7.7 Helm deployment to v7.8. If you're deploying RPI for the first time, see the [Greenfield Installation](greenfield.md) guide instead.

> **Not ready to upgrade?** The `release/v7.7` branch remains available on GitHub for critical fixes. You can stay on v7.7 as long as needed.

---

<details>
<summary><strong style="font-size:1.25em;">What Changed in the Helm Chart</strong></summary>

v7.8 is an additive release. It introduces Google Cloud data-plane support (Cloud SQL and BigQuery) and new Realtime API and Interaction API configuration. Existing v7.7 overrides continue to work unchanged (see the checklist below).

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

RPI can connect to a Google Cloud SQL for PostgreSQL instance using passwordless IAM authentication through the Cloud SQL Auth Proxy, which runs as a sidecar. With `autoIamAuthn` enabled, pods connect over loopback using the IAM database user and no stored password. This path is SDK secrets mode only (`secretsManagement.provider: sdk`).

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
| `serviceAccount` | Service-account key file (`serviceAccountEmail` plus a mounted key) |
| `workloadIdentity` | Keyless, via the pod's GCP Workload Identity (Application Default Credentials). No key file is mounted. |

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

Expanded configuration support for geolocation, identity resolution, visitor and profile processing, logging, integrations, and operational settings, including geolocation and IP-lookup, identity and profile-merge controls, RedPoint ML scoring, file output, SMTP, and service host settings.

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

Expanded configuration support for logging, integrations, distributed processing, and operational settings, including logging providers (New Relic, Loggly), NLP, SMTP, file output, operational database retry, and the chart-managed internal cache and queue for distributed processing.

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

The cluster-wide Realtime API address can be overridden per client (tenant). Each entry pairs a client GUID with the Realtime API base address for that client; the override is consumed by the Interaction API and Execution Service. Requires `realtimeapi.multitenant: true`.

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

RPI NLP now supports verbose request/response trace logging for diagnostics, emitted as `RPI__NLP__EnableTrace` on every service that uses the NLP integration (Interaction API, Execution Service, Node Manager, Queue Reader, Integration API). Off by default; enable it through the shared RedpointAI logging setting.

```yaml
redpointAI:
  logging:
    enableTrace: true   # verbose NLP request/response tracing (default false); requires redpointAI.enabled: true
```

</details>

<details>
<summary><strong style="font-size:1.25em;">Removed in v7.8</strong></summary>

### RedpointAI vector search values

`redpointAI.VectorSearchProfile` and `redpointAI.VectorSearchConfig` have been removed. RPI now creates the search index, vector profile, and algorithm dynamically at runtime, so these values are no longer needed. See [Redpoint AI](https://docs.redpointglobal.com/rpi/admin-basic-selection-rule-ai-integration).

### Internal cache OpsDB failover

`InternalCache__BackupToOpsDBInterval` and `InternalCache__FailOnPrimaryDataLoss` have been removed - OpsDB-backed cache failover was removed in 7.8. Remove them from your overrides if set (Execution Service and Queue Reader).

### Swagger on the Interaction API

The Interaction API no longer emits `EnableSwagger`. The setting remains valid and unchanged for the Integration API.

### LuxSci SendRequestCount renamed

`Plugins__LuxSci__SendRequestCount` was renamed to `Plugins__LuxSci__MaxConcurrentApiRequestsPerAccount`. The old key binds to nothing and is silently ignored, so update any override that sets it.

</details>

<details>
<summary><strong style="font-size:1.25em;">Upgrade Checklist</strong></summary>

1. Remove `redpointAI.VectorSearchProfile` and `redpointAI.VectorSearchConfig` if present.
2. Check for silent breaks: rename the LuxSci `SendRequestCount` cap to `maxConcurrentApiRequestsPerAccount`, and stop setting `InternalCache__StatePersistence__Provider: DefaultCache` (removed from the provider enum - use `FileSystem` or `AzureBlobStorage`). Both are ignored rather than rejected if left in place.
3. Review the new optional features (Cloud SQL IAM, BigQuery, Realtime geolocation, Interaction API password policy, per-tenant Realtime API address, LuxSci throughput) and adopt as needed. All are opt-in and default off.
4. Apply the upgrade with your existing `helm upgrade` command and overrides file.

</details>

---

## Next Steps

Use the [Helm Assistant Web UI](https://rpi-helm-assistant.redpointcdp.com) **Reference** and **Chat** tabs to browse configuration and ask questions.

---
<sub>Redpoint Interaction v7.8 | [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) | [Support](mailto:support@redpointglobal.com) | [redpointglobal.com](https://www.redpointglobal.com)</sub>
