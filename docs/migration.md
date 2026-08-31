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
| Realtime API | Geolocation, identity settings, and client address overrides |
| Interaction API | Password policy and account lockout |

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
        # Keyless: uses Application Default Credentials from the pod's Workload
        # Identity service account (no key file mounted). OAuthMechanism 3 = ADC.
        - name: gbq-tenant1
          projectId: my-google-project
          credentialsType: workloadIdentity
          OAuthMechanism: 3
```

### Realtime API: geolocation, identity settings, and client address overrides

New Realtime API configuration blocks, all optional and off by default:

- `realtimeapi.geolocation` - geolocation and IP-lookup plugin settings (provider, weather units, GeoIP lookup).
- `realtimeapi.identitySettings` - identity resolution (master key, alternative keys, parameter and CAL attribute merge with exclusions).
- `realtimeapi.clientAddressOverrides` - client address overrides.
- `realtimeapi.authentication.enabled` - a per-service authentication toggle (also available on `deploymentapi`).

### Interaction API: password policy and account lockout

Native-authentication controls for the Interaction API:

- `interactionapi.passwordPolicy` - required length plus digit, case, and non-alphanumeric requirements.
- `interactionapi.accountLockout` - account lockout settings.

</details>

<details>
<summary><strong style="font-size:1.25em;">Removed in v7.8</strong></summary>

### RedpointAI vector search values

`redpointAI.VectorSearchProfile` and `redpointAI.VectorSearchConfig` have been removed. RPI now creates the search index, vector profile, and algorithm dynamically at runtime, so these values are no longer needed. See [Redpoint AI](redpoint-ai.md).

</details>

<details>
<summary><strong style="font-size:1.25em;">Upgrade Checklist</strong></summary>

1. Remove `redpointAI.VectorSearchProfile` and `redpointAI.VectorSearchConfig` if present.
2. Review the new optional features (Cloud SQL IAM, BigQuery, Realtime geolocation, Interaction API password policy) and adopt as needed. All are opt-in and default off.
3. Apply the upgrade with your existing `helm upgrade` command and overrides file.

</details>

---

## Next Steps

Use the [Helm Assistant Web UI](https://rpi-helm-assistant.redpointcdp.com) **Reference** and **Chat** tabs to browse configuration and ask questions.

---
<sub>Redpoint Interaction v7.8 | [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) | [Support](mailto:support@redpointglobal.com) | [redpointglobal.com](https://www.redpointglobal.com)</sub>
