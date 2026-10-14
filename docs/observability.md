![redpoint_logo](../chart/images/redpoint.png)
# RPI Observability

[< Back to Home](../README.md)

## Overview

**RPI Observability** is a read-only operating picture over an RPI deployment. It answers whether the platform is coordinated, whether work is flowing, accumulating or failing, whether capacity is available, whether queues and dependencies are healthy, and what needs investigation now.

It reads RPI's operational and tenant databases, the metrics endpoints of the seven RPI services that serve one, the Queue Reader statistics endpoints and the Kubernetes API. It never writes to an RPI database. Everything it keeps is written to its own Observability database on the operational database server.

| Workload | What it is | Setting |
|---|---|---|
| `rpi-observability` | the operating picture and its API | `observability.enabled` |

It runs as one replica and, unless runtime tracing is enabled, needs no telemetry agent, collector or sidecar.

## Before you install

1. **Create the Observability database** on the operational database server, under the name you will set in `observability.databaseName`, and give the identity RPI signs in with the permissions in [Database sign-in](#database-sign-in). Observability creates its own tables on first start; a database it cannot create tables in stops startup with a permission error.
2. **Find the tenant identifier** for `observability.clientId`:
   ```sql
   SELECT ClientID FROM Pulse_<env>.dbo.rpi_Clients
   ```
3. **Choose the image.** The image resolves like every RPI service (`global.deployment.images`). If the Observability image is published under a different registry or tag, set it explicitly:
   ```yaml
   global:
     deployment:
       images:
         overrides:
           rpi-observability: <registry>/rpi-observability:<tag>
   ```

## Enable

```yaml
observability:
  enabled: true
  clientId: <your-rpi-tenant-guid>
  databaseName: <observability-database-name>
```

Rendering fails with a named error when `clientId` or `databaseName` is missing.

## Settings

| Setting | Default | Purpose |
|---|---|---|
| `observability.enabled` | `false` | Deploy RPI Observability |
| `observability.clientId` | | RPI tenant identifier. Required |
| `observability.databaseName` | | Observability database name. Required |
| `observability.schedule.intervalMinutes` | `30` | Minutes between analysis cycles |
| `observability.evidence.coverageStaleAfterMinutes` | `10` | Minutes after which execution failure evidence is reported as stale |
| `observability.tenantFanout.enabled` | `true` | Read each installed tenant's Interaction database |
| `observability.tenantFanout.maxConcurrency` | `4` | Tenants read at the same time |
| `observability.tenantFanout.perTenantTimeoutSeconds` | `10` | Seconds allowed for one tenant's read |
| `observability.tenantFanout.cycleBudgetSeconds` | `120` | Seconds allowed for all tenant reads in one cycle. Tenants not reached are reported as not measured |
| `observability.tenantFanout.staleAfterMinutes` | `90` | Minutes after which a tenant's last read is reported as stale |
| `observability.authentication.enabled` | `false` | Require sign-in through an external identity provider configured in RPI. `false` is anonymous access |
| `observability.authentication.cookieSecure` | `true` | Send the session cookie over HTTPS only |
| `observability.authentication.sessionLifetimeSeconds` | `28800` | Session lifetime |
| `observability.authentication.capabilityMap` | `{}` | Extra capabilities for custom RPI groups |
| `observability.sessionKeyStorage.size` | `1Gi` | Size of the `/data` volume |
| `observability.sessionKeyStorage.storageClassName` | `""` | StorageClass for the `/data` volume. Empty uses the cluster default |
| `observability.resources` | global `resources` | CPU and memory requests and limits |
| `ingress.hosts.observability` | `rpi-observability` | Hostname or subdomain |

`observability.replicaCount` cannot be changed: any value other than `1` fails the render. The analysis scheduler and the database writers run inside the process, so a second replica would run a second writer.

## Secrets

Observability reads the operational database server, username, password and the two operational database names from the same keys every RPI service uses (see [Secrets Management](secrets-management.md)), from the standard RPI Secret in `kubernetes` and `csi` modes, or from the cloud vault in `sdk` mode.

Runtime tracing needs no key: the token the collector sidecar presents to Observability is generated inside the pod at start and never leaves it (see Runtime tracing). Sign-in uses the identity providers already configured in RPI and holds no client secret.

## Database sign-in

Observability signs in to the operational database server exactly as RPI is configured to, for the RPI databases and for its own database alike. It has no database credential or sign-in setting of its own.

| RPI configuration | How Observability signs in |
|---|---|
| `kubernetes` or `csi` secrets | the operational username and password from the RPI Secret |
| `sdk`, `ConnectionSettings--IsUsingCredentials` `true` | the operational username and password from the vault |
| `sdk` on Azure, `ConnectionSettings--IsUsingCredentials` `false` | the managed identity in `cloudIdentity.azure.managedIdentityClientId`, through Azure Workload Identity, as `SQLServerSettings--AzureSQLAuthentication` selects (`Active Directory Default`, or `Active Directory Managed Identity` when unset) |
| `databases.operational.googleWorkloadIdentity: true` | Cloud SQL IAM: the IAM database user in `Operations_Database_Server_Username`, with a GKE Workload Identity token, over TLS |
| `databases.operational.cloudSqlProxy.autoIamAuthn: true` | the IAM database user with an empty password, for which the Cloud SQL Auth Proxy supplies the token |

The server and port are RPI's too. On SQL Server, `Operations_Database_ServerHost` is used exactly as RPI uses it, so a port or instance goes in the value (`host,port` or `host\instance`), and port 1433 applies when it names none. On PostgreSQL, a port in the value (`host:port`) wins, and otherwise the port the chart sets for RPI's Deployment API (5432) applies. A tenant whose Interaction or InteractionAudit connection in RPI is a full connection string is read on the server and port that string names, signing in as above; Observability never uses credentials stored in that string, so that server must accept the operational sign-in. A port that is not a number from 1 to 65535 stops startup with the setting named.

Encryption follows `databases.operational.encrypt`. The server certificate is verified unless `ClusterEnvironment__OperationalDatabase__ConnectionSettings__SQLServerSettings__TrustServerCertificate` is `true`, set in the vault in `sdk` mode or through `commonEnvVars` otherwise. If an identity sign-in fails, Observability reports the failure and never tries a password instead. A missing or unusable setting stops startup with the setting named.

With the managed identity, add a federated credential for the `rpi-observability` service account (see [Secrets Management](secrets-management.md)) and create the identity's user in each database. The identity needs:

| Database | Permission | Used for |
|---|---|---|
| Pulse, Pulse Logging | `db_datareader` | operational state and logs |
| each tenant's Interaction and InteractionAudit | `db_datareader` | tenant reads |
| Observability database | `db_ddladmin` | creating its tables at startup |
| Observability database | `db_datareader`, `db_datawriter` | its records and signed-out sessions |

On SQL Server, sign in as the server's Entra administrator and run in each database, using the managed identity's name:

```sql
CREATE USER [<managed-identity-name>] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [<managed-identity-name>];
-- Observability database only:
ALTER ROLE db_ddladmin ADD MEMBER [<managed-identity-name>];
ALTER ROLE db_datawriter ADD MEMBER [<managed-identity-name>];
```

The identity is the one RPI already uses, so these grants add to what RPI holds; reading the RPI databases needs nothing RPI does not already have. With credentials, the RPI operational login needs the same permissions, and owning the Observability database covers them.

On PostgreSQL, including Cloud SQL with IAM sign-in, Observability reads the same RPI tables in the `public` schema of each RPI database. The operational user, or the IAM database user, needs `CONNECT` and `SELECT` on the RPI databases, which RPI already holds, and `CREATE` on the `public` schema of the Observability database. RPI 7.9 has no Microsoft Entra sign-in for Azure Database for PostgreSQL, and no identity sign-in for Amazon RDS PostgreSQL: its operational database types are SQL Server, PostgreSQL with a username and password, and Google Cloud SQL for PostgreSQL with Workload Identity. Observability supports exactly those, and signs in to Azure and AWS PostgreSQL with the operational username and password.

## Sign-in

Authentication is off by default: the service runs without sign-in, and anyone who can reach the hostname can read the operating picture.

Set `observability.authentication.enabled: true` to require sign-in. Observability then signs users in only through an **external identity provider configured in RPI**: Microsoft Entra ID, or an OpenID Connect provider such as Okta or Keycloak. Sign-in with Redpoint credentials (an RPI user name and password) is not supported by Observability. RPI's own sign-in is unaffected.

- The sign-in page lists the external providers RPI's Interaction API publishes, with RPI's names and in RPI's order. Enabling or disabling a provider in RPI changes the list on the next page load.
- Each provider signs in with the application and settings RPI already uses for it. Observability holds no identity provider settings of its own.
- After sign-in, RPI's Interaction API confirms the user, their groups and their permissions for `observability.clientId`. A user RPI does not accept for that tenant cannot sign in.
- If RPI has no external provider enabled, for example when it uses only Redpoint credentials, the sign-in page says so and nobody can sign in. Configure a provider in RPI, or set `authentication.enabled: false`.

**Before enabling**, add `https://<observability host>/auth/callback` as a redirect URI on each provider's existing RPI application:

| Provider | Application | Where |
|---|---|---|
| Microsoft Entra ID | `MicrosoftEntraID.interaction_client_id` | Mobile and desktop applications platform |
| Okta, Keycloak | `OpenIdProviders.clientID` | the client's allowed redirect URIs |

Authorization comes from RPI's groups. `capabilityMap` grants additional capabilities to custom groups only; it cannot grant `observability.admin` or change the built-in RPI groups, and a map that tries is refused at startup.

```yaml
observability:
  authentication:
    capabilityMap:
      diagnostics.viewSql: ["<custom RPI group>"]
```

**Sign out** ends the Observability session, and it stays ended after a pod restart: the sign out is recorded in the Observability database, and fails rather than appearing to succeed when that database is unavailable. It does not sign the user out of the identity provider, so choosing the same provider again may not prompt for credentials.

Authentication is never turned off by an RPI or provider failure. An unreachable RPI, a missing provider, a provider or token failure, or a user RPI refuses all stop sign-in instead.

## Access

The operating picture is served on the chart's ingress at `ingress.hosts.observability`, under `ingress.domain`, with the same TLS and ingress settings as the other RPI services.

## Network policy

With `networkPolicy.enabled: true` (off by default), the ingress controller is allowed to reach Observability, and two policies cover what Observability itself connects to.

`allow-rpi-observability-egress` allows Observability only:

- the Execution Service, Node Manager, Queue Reader, Interaction API, Integration API, Realtime API and Callback API pods on their pod port 8080, for their metrics and, on the Interaction API, sign-in;
- DNS, when `networkPolicy.allowDNS` is on;
- TCP 443 (identity providers, Azure and Google identity, cloud vaults, AI, the Kubernetes API), 1433 and 5432 (database servers) and the SMTP port;
- every port in `networkPolicy.additionalEgressPorts`;
- TCP 6443 on `selfhosted`, where the Kubernetes API commonly listens;
- TCP 11000 to 11999 for Azure SQL on `azure`: with the Redirect connection policy, the default for clients inside Azure, connections move from the gateway on 1433 to the database node on a port in that range;
- TCP 3307 when the Cloud SQL Auth Proxy runs;
- on Google with `cloudIdentity.enabled`, the GKE metadata server: `169.254.169.252` on 987 and 988, or `169.254.169.254` on 80 and 8080 with GKE Dataplane V2, as Google documents for network policies with Workload Identity; on AWS, the EKS Pod Identity agent.

`allow-rpi-observability-to-rpi` admits Observability, and nothing else, to those same RPI pods on 8080. The chart's `default-deny-ingress` selects every pod, and the other shared policies select only `smartactivation` pods, so without it those services would refuse Observability.

### Database servers on other ports

The chart cannot see the database server: it lives in the RPI Secret or vault, and in each tenant's connection in RPI. The policy therefore allows the standard ports, 1433 and 5432, and any port you list:

```yaml
networkPolicy:
  enabled: true
  additionalEgressPorts:
    - 14330
```

List a port when:

- `Operations_Database_ServerHost` names one other than 1433 on SQL Server (`host,port`), or other than 5432 on PostgreSQL (`host:port`);
- a tenant's Interaction or InteractionAudit connection in RPI is a connection string naming another port;
- an external identity provider is served on a port other than 443.

The list is a network permission only. It does not configure any connection; the servers and ports Observability connects to always come from RPI's settings. It applies to every RPI service's external egress, not only Observability's.

Kubernetes network policies match peers by pod label or IP range, never by host name, so the database rules allow their ports to any address. That is also what lets a tenant database on a separate server work without listing it. Restricting database egress to particular hosts needs your network plugin's DNS-aware policies or a firewall outside the cluster.

Other assumptions: the Kubernetes API is reached on 443 (AKS, EKS, GKE) or 6443 (`selfhosted`); an Azure SQL server reached through a private endpoint uses only 1433; GKE clusters older than 1.21.0-gke.1000 serve the metadata server on `127.0.0.1` and are not covered. Enforcement depends on the cluster's network plugin.

## Session key storage

A `ReadWriteOnce` PersistentVolumeClaim, `rpi-observability-data`, is mounted at `/data`. It holds only the session signing key and, during a rotation, its previous key, so that signed-in sessions survive a pod restart. Nothing else is stored on it.

To rotate the key, copy `session_signing_key` to `session_signing_key.previous` on the volume, delete `session_signing_key` and restart the pod. Sessions signed with the previous key stay valid until they expire.

## Kubernetes permissions

| Scope | Resources | Verbs | Used for |
|---|---|---|---|
| namespace | `pods`, `events` | `list` | pod health, scrape target discovery, events |
| namespace | `pods/log` | `get` | the previous log of a restarted container |
| namespace | `pods.metrics.k8s.io` | `list` | pod resource usage |
| cluster | `nodes`, `nodes.metrics.k8s.io` | `list` | node health and resource usage |

Observability reads pods, events and metrics only in its own namespace, which the chart passes as `POD_NAMESPACE`; it never lists them across the cluster. The cluster-scoped role is named `rpi-observability-<namespace>`. With `cloudIdentity.serviceAccount.mode: shared`, the permissions are bound to the shared service account and so apply to every workload that uses it.

## Connectivity

| Destination | Purpose |
|---|---|
| operational database server | RPI reads, tenant reads, and the Observability database |
| cloud identity | database access tokens when RPI signs in with a managed identity or Cloud SQL IAM |
| Kubernetes API | the permissions above |
| Execution Service pods, port 8080 | executing work, capacity, completion counters and errors per tenant, from `/metrics` |
| Node Manager pods, port 8080 | activities and tasks allocated, triggers fired and errors per tenant, from `/metrics` |
| Queue Reader pods, port 8080 | queue listener messages accepted and rejected, and errors per tenant, from `/metrics` |
| Interaction, Integration, Realtime and Callback API pods, port 8080 | requests served, server errors, requests in progress and waiting, and open connections, from `/metrics` |
| Queue Reader instances | reader statistics, at the address each reader registers in RPI |
| `rpi-interactionapi` Service | sign-in methods and the signed-in user, when sign-in is enabled |
| identity provider | discovery, keys and token exchange, when sign-in is enabled |

The Deployment API serves no metrics endpoint, so Observability shows it through its pod state and readiness only. A service that is disabled, not running or not answering is shown as not measured, never as idle.

## Runtime tracing

Off by default. With `observability.telemetry.enabled: true` the chart:

- supplies the OpenTelemetry .NET automatic instrumentation to each of the nine .NET services itself: an init container, `otel-auto-init`, copies the instrumentation image's `/autoinstrumentation` into an `emptyDir` that the service container mounts read-only at `/otel-auto`, and the service's environment points the .NET host at it (`OTEL_DOTNET_AUTO_HOME`, `DOTNET_STARTUP_HOOKS`, `CORECLR_ENABLE_PROFILING`, `CORECLR_PROFILER`, `CORECLR_PROFILER_PATH`). The RPI images and source are unchanged; each service restarts once. The services export OTLP over HTTP/protobuf, the instrumentation's own default, because its gRPC exporter needs the application to reference `Grpc.Net.Client`;
- adds a collector sidecar to the Observability pod, which receives the services' spans over OTLP on the `rpi-observability` Service (ports 4317 and 4318) and delivers them over the pod's loopback to Observability's `/api/telemetry/v1/traces` with an ingest token; an init step in the same pod generates that token (256 random bits) into a memory backed volume readable only by the two containers, so it appears in no Secret, manifest or values file, and a replacement pod simply generates a new one;
- keeps the spans in the Observability database for `recorder.retentionMinutes`, capped at `recorder.maxSpans`, plus a window of `incidentBeforeMinutes` and `incidentAfterMinutes` around each condition Observability detects, capped at `maxWindows`.

What the spans contain: the service, the call's name and kind, its start, end and duration, whether it failed, the HTTP method, route and status, the database system and database name, and the peer host. What they never contain: query text, request or response bodies, headers, URL query strings or any value shaped like a credential; Observability drops everything else before it stores a span, and the services are configured not to attach statement text.

What this adds: the SQL calls each Execution Service makes and how long they take; the HTTP calls the services make to channel vendors and other dependencies, with their status codes; the requests each API serves, by route. RPI carries no identifier from a span to a workflow run, so Observability places spans beside a run by time and the tenant's database name only, and says so.

Prerequisites and cost:

| Item | Value |
|---|---|
| RPI images | any RPI 7.9 image, unchanged: the chart supplies the instrumentation at pod start. A replacement pod does not start until `otel-auto-init` has pulled its image and copied the files, so a registry that cannot serve the instrumentation image blocks the rollout while tracing is on; the previous replicas keep serving |
| instrumentation image | `ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-dotnet:1.16.0-1@sha256:b382e9abe8cb6e762826d3ca95bf9646651d6a45f03ae9a40d7156e91a55aab7` (OpenTelemetry .NET automatic instrumentation 1.16.0, linux amd64 and arm64, Apache-2.0). Its `/autoinstrumentation` holds `net/` (the startup hook and managed assemblies), `linux-x64/` and `linux-musl-x64/` (the native profiler for glibc and musl). Supports .NET 8, 9 and 10. Mirror it by digest: `<registry>/autoinstrumentation-dotnet:1.16.0-1@sha256:b382e9ab...` resolves to the same content |
| libc | the native profiler is libc specific. Verified on the 7.9 images: Execution Service, Node Manager, Queue Reader, Interaction API, Realtime API and Rebrandly are Ubuntu (glibc); Deployment API, Integration API and Callback API are Alpine (musl) and are the `muslServices` default. Re-verify after an image base change with `kubectl exec <pod> -- cat /etc/os-release` |
| architecture | the instrumentation image serves linux amd64 and arm64; the RPI nodes in use are amd64 |
| images to mirror | the instrumentation image above; the collector sidecar, `otel/opentelemetry-collector` core distribution pinned by digest in `values.yaml` (the same digest is published at `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector`); the agent, only with `network.enabled`, also pinned by digest. Each is a separately sourced image: scan the instrumentation image and the collector, and the agent when enabled, beside the Observability image |
| secret key | none; the token is generated in the pod |
| permissions | none beyond Observability's own. The sidecar runs as the same non-root user as Observability, with no capabilities and a read-only root filesystem |
| network policy | `allow-rpi-telemetry-to-observability` (RPI pods to the Observability pod on 4317 and 4318). The sidecar's delivery to Observability is on loopback and needs no policy |
| health | the sidecar's startup and liveness probes use the collector's `health_check` extension on 13133, which reports the process, not delivery; it has no readiness probe, because a pod is ready only when every container is and a collector that cannot start must not take the Observability UI and API out of the Service. A failing sidecar shows in the pod's container state and log, and Observability reports tracing as waiting or silent until spans arrive again |
| overhead | the profiler adds a few percent of CPU on the instrumented service at `samplingRatio: 0.1`; the collector is bounded by its memory limit; Observability's storage is bounded by the recorder settings |

Confirming a rollout: every instrumented pod shows `otel-auto-init` completed (`kubectl -n <ns> get pod <pod> -o jsonpath='{.status.initContainerStatuses[*].state}'`), the service log carries no `Startup hook assembly` error, and `kubectl -n <ns> logs deploy/rpi-observability -c collector` stays free of exporter errors. Keep tracing disabled until the instrumentation image is reachable from the cluster and the chart carrying `otel-auto-init` is the one deployed: the environment without the init container crash-loops every instrumented service.

Observability reports the state of runtime tracing on its Platform page as disabled, not configured (the token file is missing), waiting, receiving or silent. Installed is never shown as working: receiving means a span arrived in the last two minutes, so a sidecar that cannot start or cannot export is reported as waiting or silent, never as collecting.

### Network and dependency agent

`observability.telemetry.network.enabled: true` adds a DaemonSet, `rpi-observability-network-agent`, that reads the RPI processes' connections, HTTP calls and SQL calls from the kernel and sends them as spans to the collector sidecar on the `rpi-observability` Service. It needs a kernel with eBPF and BTF (Linux 5.8 or later; AKS, EKS and GKE node images qualify), host process visibility (`hostPID`) and the capabilities `BPF`, `CHECKPOINT_RESTORE`, `DAC_READ_SEARCH`, `NET_RAW`, `PERFMON`, `SYS_PTRACE` and `SYS_RESOURCE`. It is not privileged, mounts nothing writable from the host, holds no Kubernetes permission, and looks only for processes run by the .NET host listening on 8080. It never collects headers, bodies or query text. Enable it only when your cluster policy allows those capabilities, and treat it as a separately reviewed component.

## Limitations

- The relationship between a service and the operational database is not measured by the baseline collection. With runtime tracing on, the calls on it are observed and timed; its health is still a conclusion Observability does not draw.
- A runtime span cannot be joined to a workflow run; RPI records no identifier across that boundary. Observability shows the association by time and database name and labels it so.
- The deployment has been validated by rendering the chart. It has not been validated against a live RPI deployment on SQL Server or PostgreSQL.
