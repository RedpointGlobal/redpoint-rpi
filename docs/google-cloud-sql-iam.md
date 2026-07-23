![redpoint_logo](../chart/images/redpoint.png)
# Google Cloud SQL for PostgreSQL with IAM Authentication

[< Back to Home](../README.md)

## Overview

RPI can run against **Google Cloud SQL for PostgreSQL** using **passwordless IAM database authentication**. RPI connects to the Cloud SQL Auth Proxy on `127.0.0.1`, and the proxy authenticates to the instance using the pod's Google service account (GSA) via Workload Identity. No database password is stored anywhere.

This path is SDK-mode only: the Cloud SQL Auth Proxy assumes the same cloud-native security realm as the SDK secret provider (vault-backed, IAM-bound). The chart fails to render if `cloudSqlProxy.enabled=true` and `secretsManagement.provider` is not `sdk`.

### How it works

- The chart injects a **Cloud SQL Auth Proxy** sidecar (native init container, `restartPolicy: Always`) into each database-connecting service.
- The proxy runs with `--auto-iam-authn` and `--private-ip`, listening on `127.0.0.1:5432`.
- RPI connects to `127.0.0.1` with the **IAM database username** and no password. The proxy injects the GSA's IAM OAuth token as the credential.
- The GSA is bound to the pod's Kubernetes service account through **Workload Identity** (keyless, no exported key file).

---

## Chart configuration

The keyless IAM recipe:

```yaml
global:
  deployment:
    platform: google

databases:
  operational:
    provider: postgresql
    cloudSqlProxy:
      enabled: true
      connectionName: <project>:<region>:<instance>   # e.g. rp-engineering:us-central1:rpi-qa-psql
      privateIp: true
      autoIamAuthn: true

cloudIdentity:
  enabled: true
  google:
    serviceAccountEmail: <gsa>@<project>.iam.gserviceaccount.com
    configMapName: ""          # empty = keyless Workload Identity (no key file mounted)

secretsManagement:
  provider: sdk
```

`configMapName: ""` is the keyless switch. When it is non-empty the chart mounts a GCP service-account key file and the proxy uses `--credentials-file` instead of Workload Identity. For IAM authentication leave it empty.

### Vault keys

Store these in your cloud vault (SDK mode reads them at runtime):

| Key | Value |
|:----|:------|
| `Operations_Database_ServerHost` | `127.0.0.1` (the proxy on loopback) |
| `Operations_Database_Server_Username` | the IAM database user: the GSA email **with the `.gserviceaccount.com` suffix removed** (e.g. `redpoint-qa-rpi@rp-engineering.iam`) |
| `Operations_Database_Server_Password` | leave **empty** - the proxy injects the IAM token; any value here is ignored |
| `Operations_Database_Pulse_Database_Name` | the Pulse database name (e.g. `Pulse_qa_380160`) |
| `Operations_Database_Pulse_Logging_Database_Name` | the Pulse Logging database name (e.g. `Pulse_qa_380160_Logging`) |

---

## Google Cloud prerequisites

These are provisioned on the Google side, once per instance and service account. RPI does not create them.

**1. Enable IAM authentication on the instance.** Set the `cloudsql.iam_authentication` flag on:

```
gcloud sql instances patch <instance> --project=<project> \
  --database-flags=cloudsql.iam_authentication=on
```

**2. Grant the GSA the Cloud SQL IAM roles** (project level):

```
gcloud projects add-iam-policy-binding <project> \
  --member="serviceAccount:<gsa>@<project>.iam.gserviceaccount.com" \
  --role="roles/cloudsql.client"
gcloud projects add-iam-policy-binding <project> \
  --member="serviceAccount:<gsa>@<project>.iam.gserviceaccount.com" \
  --role="roles/cloudsql.instanceUser"
```

**3. Bind the Kubernetes service account to the GSA (Workload Identity).** The chart annotates the pod's Kubernetes service account; you create the IAM binding so the GSA trusts it:

```
gcloud iam service-accounts add-iam-policy-binding \
  <gsa>@<project>.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:<project>.svc.id.goog[<namespace>/<ksa-name>]"
```

With `cloudIdentity.serviceAccount.mode: shared` there is one Kubernetes service account (`redpoint-rpi`). With `per-service` (the default) each RPI service has its own; add a binding per service account.

**4. Create the IAM database user** on the instance:

```
gcloud sql users create <gsa>@<project>.iam.gserviceaccount.com \
  --instance=<instance> --project=<project> \
  --type=cloud_iam_service_account
```

Cloud SQL registers this as the PostgreSQL role `<gsa>@<project>.iam` (the email minus `.gserviceaccount.com`). This is the value that goes in `Operations_Database_Server_Username`.

**5. Grant the IAM user the ability to create databases and extensions.** This step is easy to miss and produces the most common first-install failure.

Cloud SQL creates **IAM** database users with a minimal privilege set. Unlike built-in password users, they are **not** members of the `cloudsqlsuperuser` role, so they cannot `CREATE DATABASE`, `CREATE ROLE`, or `CREATE EXTENSION`. RPI's install scripts do all three. Grant the role once, from a privileged login:

```sql
GRANT cloudsqlsuperuser TO "<gsa>@<project>.iam";
```

Run this as a user that is already a `cloudsqlsuperuser` (the built-in `postgres` user qualifies). Because the instance is private-IP, the simplest privileged connection is **Cloud SQL Studio** in the Google Cloud console (Instance -> Cloud SQL Studio -> sign in as `postgres`). To use the `postgres` user, set its password first:

```
gcloud sql users set-password postgres --instance=<instance> --project=<project> --prompt-for-password
```

Quote the IAM role name exactly - it contains `@` and `.`.

> Least-privilege alternative: `ALTER ROLE "<gsa>@<project>.iam" CREATEDB;` clears the `CREATE DATABASE` step, but the installer will then fail at `CREATE EXTENSION` (Cloud SQL gates allowlisted extensions behind `cloudsqlsuperuser`). For a clean first install, grant `cloudsqlsuperuser`. You may revoke it after install if your security posture requires, but re-installs and upgrades may need it again.

---

## First install and verification

After the prerequisites are in place, deploy the chart. RPI's install runs from the deployment service and creates the Pulse and Pulse Logging databases. A successful install log reads:

```
Operational Database Type: PostgreSQL
Database Host: 127.0.0.1
Creating the databases
... (no permission errors) ...
Install complete
```

If the databases were already created by a prior attempt, restart the installer pod to re-run:

```
kubectl -n <namespace> rollout restart deploy/rpi-deploymentapi
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|:--------|:------|:----|
| `42501: permission denied to create database` during install | The IAM database user lacks `CREATE DATABASE` - it is not a `cloudsqlsuperuser` | Prerequisite 5: `GRANT cloudsqlsuperuser TO "<gsa>@<project>.iam";` |
| `permission denied to create extension` or `permission denied for schema` after the databases exist | Same missing privilege at a later install step | Same grant (prerequisite 5) |
| `password authentication failed` / `role "…" does not exist` | The IAM database user was not created, or `Operations_Database_Server_Username` does not match the role name | Prerequisite 4; the username is the GSA email **without** `.gserviceaccount.com` |
| Cloud SQL Auth Proxy sidecar in `CrashLoopBackOff` / never Ready | `connectionName` wrong, missing `roles/cloudsql.client`, private IP unreachable from the cluster, or the Workload Identity binding is missing | Verify `connectionName` (`<project>:<region>:<instance>`), prerequisites 2 and 3, and that the GKE cluster has a route to the instance's private IP |
| Proxy up but `FATAL: Cloud SQL IAM ... is not enabled` | The instance flag is off | Prerequisite 1 (`cloudsql.iam_authentication=on`) |

The connection itself is proven the moment the install log reaches "Creating the databases" over `Database Host: 127.0.0.1` - at that point the proxy, Workload Identity, and IAM authentication are all working, and any remaining error is a PostgreSQL privilege (prerequisite 5), not a chart or connectivity problem.

---

[< Back to Home](../README.md)
