![redpoint_logo](../chart/images/redpoint.png)
# New Installation (Greenfield)

[< Back to Home](../README.md)

This guide walks through deploying RPI from scratch on a new Kubernetes cluster.

---

## System Requirements

| Component | Requirement |
|:----------|:------------|
| **Kubernetes** | Latest stable version from a [certified provider](https://kubernetes.io/docs/setup/production-environment/turnkey-solutions/). Minimum two nodes (8 vCPU, 32 GB RAM each). |
| **Operational DB** | SQL Server or PostgreSQL (cloud-hosted or VM). Minimum 8 GB RAM, 200 GB disk. |
| **CLI Tools** | `kubectl`, `helm` v3, `python3` (with PyYAML), `git`, `bash` |

**Example node SKUs:**

| Azure | AWS | GCP |
|-------|-----|-----|
| D8s_v5 | m5.2xlarge | n2-standard-8 |

---

<details>
<summary><strong style="font-size:1.25em;">Prerequisites</strong></summary>

Before starting, ensure you have:

- **Redpoint Container Registry access**: open a [Support](mailto:support@redpointglobal.com) ticket requesting access to download RPI images.
- **RPI License**: open a [Support](mailto:support@redpointglobal.com) ticket to obtain your RPI v7 license activation key.
- **Operational database**: provision a SQL Server or PostgreSQL instance and note the hostname, username, and password.
- **Single Sign-On** (optional): if using Microsoft Entra ID or an OIDC provider (Keycloak, Okta), complete the identity provider setup first. See the [Single Sign-On Guide](single-sign-on.md).

### Choose your cloud identity

RPI services need cloud identity to access your vault and storage resources. Configure this when generating overrides:

**Azure:**
```yaml
cloudIdentity:
  enabled: true
  serviceAccount:
    mode: shared
    name: redpoint-rpi
  azure:
    managedIdentityClientId: <your-client-id>
    tenantId: <your-tenant-id>
```

**AWS:**
```yaml
cloudIdentity:
  enabled: true
  serviceAccount:
    mode: shared
    name: redpoint-rpi
  amazon:
    roleArn: arn:aws:iam::<account>:role/<role-name>
    region: us-east-1
```

**Google:**
```yaml
cloudIdentity:
  enabled: true
  serviceAccount:
    mode: shared
  google:
    serviceAccountEmail: <sa>@<project>.iam.gserviceaccount.com
    projectId: <project-id>
```

| Mode | Behavior |
|:-----|:---------|
| `shared` | All pods use one service account. Simplest setup, only one federation credential needed. |
| `per-service` | Each RPI service gets its own service account. Better audit trails and per-service access policies. This is the default. |

### Choose your secrets provider

Decide how RPI will access sensitive values:

| Provider | How it works | Best for |
|:---------|:-------------|:---------|
| **kubernetes** (default) | The [CLI](readme-cli.md) prompts for credentials and generates a K8s Secret | Simple setups, getting started quickly |
| **sdk** (recommended for cloud) | RPI reads secrets directly from your cloud vault at runtime | Azure Key Vault, AWS Secrets Manager, GCP Secret Manager |
| **csi** | CSI Secrets Store driver syncs vault secrets to K8s Secrets | Existing CSI infrastructure, fine-grained vault access policies |

If using **sdk** or **csi**, set up your vault and store the required secrets before deploying. Use the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Automate** tab to generate a vault setup script, or see the [Secrets Management Guide](secrets-management.md) for the full list of required keys.

</details>

See the [Storage Guide](storage.md) for FileOutputDirectory configuration, internal Redis/RabbitMQ provisioning options (dynamic, static BYO, emptyDir), and EFS permission setup.

<details>
<summary><strong style="font-size:1.25em;">Generate Your Overrides</strong></summary>

The overrides file is a small YAML file containing only your customizations. The chart provides sensible defaults for everything else.

### Using the Web UI (recommended)

Go to [rpi-helm-assistant.redpointcdp.com](https://rpi-helm-assistant.redpointcdp.com) and use the **Generate** tab:

1. Click **Start Here** and walk through each step
2. Select your platform, configure databases, cloud identity, secrets, storage, ingress, and services
3. The preview panel on the right shows your overrides in real time
4. Switch to the **Validate** tab to check for errors or warnings
5. Download your `overrides.yaml`

### What goes in the overrides

A typical overrides file is 50-100 lines and covers:

```yaml
global:
  deployment:
    platform: azure              # azure | amazon | google | selfhosted
    images:
      registry: rg1acrpub.azurecr.io/docker/redpointglobal/releases
      tag: "7.7.20260220.1524"

databases:
  operational:
    provider: sqlserver          # sqlserver | postgresql

cloudIdentity:
  enabled: true
  azure:
    managedIdentityClientId: <your-id>
    tenantId: <your-tenant>

secretsManagement:
  provider: sdk
  sdk:
    azure:
      vaultUri: https://myvault.vault.azure.net/

ingress:
  className: nginx
  domain: example.com
  hosts:
    config: rpi-deploymentapi
    client: rpi-interactionapi
```

Everything else (probes, security contexts, resource defaults, rollout strategies, logging) is managed by the chart automatically. Override only what you need.

> **Tip:** The Generate tab covers the most common settings. For additional options (custom annotations, pod anti-affinity, node selectors, tolerations, Karpenter, service mesh, custom CA certs, per-service tuning, etc.), check the **Reference** tab in the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) for the full list of top-level keys you can add to your overrides.

### Container images

All services share a single `repository` and `tag`. The chart builds each image path automatically:

```
{registry}/rpi-interactionapi:{tag}
{registry}/rpi-executionservice:{tag}
...
```

If you mirror images to a private registry (ECR, ACR, GAR), just change the `repository` value. For flat registries where all images share one repo with different tags, use `global.deployment.images.overrides`:

```yaml
global:
  deployment:
    images:
      overrides:
        rpi-interactionapi: 123456789.dkr.ecr.us-east-1.amazonaws.com/rpi:interactionapi-7.7.20260220.1524
```

### Custom CA certificates

If your cluster uses a corporate proxy or self-signed certificates, mount your CA bundle:

```yaml
customCACerts:
  enabled: true
  name: my-ca-bundle
  mountPath: /usr/local/share/ca-certificates/custom
  certFile: ca-bundle.pem
```

When using the SDK secrets provider, the cert can be mounted directly from your vault. See the [Secrets Management Guide](secrets-management.md) for details.

</details>

<details>
<summary><strong style="font-size:1.25em;">Deploy</strong></summary>

### 1. Download the [CLI](https://rpi-helm-assistant.redpointcdp.com/app/static/rpihelmcli.zip)

```bash
unzip rpihelmcli.zip
```

### 2. Pre-flight check

Verify all prerequisites are met before deploying:

```bash
rpihelmcli/setup.sh check -f overrides.yaml
```

This checks: required tools, cluster connectivity, YAML syntax, platform, and secrets provider.

### 3. Create image pull secret (if needed)

If pulling from the Redpoint Container Registry (`rg1acrpub.azurecr.io`) or any private registry that requires credentials, create the pull secret before deploying. This applies regardless of your secrets provider.

```bash
kubectl create secret docker-registry redpoint-rpi \
  --docker-server=rg1acrpub.azurecr.io \
  --docker-username=<username> \
  --docker-password='<password>' \
  -n <namespace>
```

Skip this if your nodes already have access to the registry (e.g., ECR with node IAM roles, ACR with `AcrPull`).

### 4. Prepare secrets

Choose your path based on your secrets provider:

<details>
<summary><strong>kubernetes provider</strong></summary>

The CLI prompts for credentials and generates a K8s Secret:

```bash
rpihelmcli/setup.sh secrets -f overrides.yaml
kubectl apply -f secrets.yaml -n <namespace>
```

This creates the main application secret with database credentials, connection strings, and API tokens. Internal service passwords (Redis, RabbitMQ) are randomly generated.

</details>

<details>
<summary><strong>sdk provider</strong></summary>

RPI reads application secrets directly from your vault at runtime. Before deploying:

1. **Populate your vault** with the required secrets. Use the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Automate** tab to generate a vault setup script for your platform.
2. **Store Snowflake key in vault** (if using Snowflake). The chart mounts it directly into the pod via CSI inline volume.
3. **Store TLS certificate in vault** (if using ingress TLS). The CSI driver syncs it to a `kubernetes.io/tls` K8s Secret for nginx.
4. **Store CA bundle in vault** (if using custom CA certs). The chart mounts it directly into the pod via CSI inline volume.
5. **Ensure CSI Secrets Store driver and cloud provider are installed** on your cluster if using any of the above (Snowflake, TLS, or CA certs). See [AWS ASCP](https://github.com/aws/secrets-store-csi-driver-provider-aws) or [Azure Key Vault provider](https://azure.github.io/secrets-store-csi-driver-provider-azure/).

See the [Secrets Management Guide](secrets-management.md) for the full list of required vault keys per platform.

</details>

<details>
<summary><strong>csi provider</strong></summary>

The CSI Secrets Store Driver syncs secrets from your vault into K8s Secrets. Before deploying:

1. **Populate your vault** with ALL required secrets. Use the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Automate** tab to generate a vault setup script for your platform.
2. **Ensure CSI Secrets Store driver and cloud provider are installed** on your cluster.
3. The chart creates SecretProviderClass resources from your overrides. Validation pods trigger the initial sync before RPI pods start.

See the [Secrets Management Guide](secrets-management.md) for the full list of required vault keys and CSI configuration.

</details>

### 5. Dry run

Preview the rendered manifests without deploying:

```bash
rpihelmcli/setup.sh deploy -f overrides.yaml -n <namespace> --dry-run
```

### 6. Deploy

```bash
rpihelmcli/setup.sh deploy -f overrides.yaml -n <namespace>
```

The CLI auto-clones the chart from GitHub, creates the namespace if needed, and runs `helm install`.

### 7. Verify

```bash
rpihelmcli/setup.sh status -n <namespace>
kubectl get pods -n <namespace>
kubectl get ingress -n <namespace>
```

Wait for all pods to show `Running` and the ingress to get an address (may take several minutes for load balancers).

</details>

<details>
<summary><strong style="font-size:1.25em;">Post-Deployment</strong></summary>

### Activate your license

```bash
DEPLOYMENT_URL=<deploymentapi-host>
ACTIVATION_KEY=<your-license-key>
SYSTEM_NAME=<your-system-name>

curl -X POST "https://$DEPLOYMENT_URL/api/licensing/activatelicense" \
  -H "Content-Type: application/json" \
  -d '{"ActivationKey": "'$ACTIVATION_KEY'", "SystemName": "'$SYSTEM_NAME'"}'
```

### Install databases

```bash
curl -X POST "https://$DEPLOYMENT_URL/api/deployment/installcluster?waitTimeoutSeconds=300" \
  -H "Content-Type: application/json" \
  -d '{"useExistingDatabases": false, "coreUserInitialPassword": "<password>", "systemAdministrator": {"username": "coreuser", "emailAddress": "coreuser@noemail.com"}}'
```

### Download the RPI Client

Download the RPI Client from the Post-release Product Updates section of the [RPI Release Notes](https://docs.redpointglobal.com/rpi/rpi-release-notes). Ensure the version matches your deployed RPI version.

The client requires [Microsoft WebView2 Runtime](https://developer.microsoft.com/en-us/microsoft-edge/webview2/#download-section).

### Configure data warehouse connections

Snowflake, Databricks, and Redshift connections are configured in the RPI client using connection strings, not Helm values. Add them through the client interface after logging in.

</details>

<details>
<summary><strong style="font-size:1.25em;">Troubleshooting</strong></summary>

### Common issues

**Pods stuck in Init or Pending:**
```bash
rpihelmcli/setup.sh troubleshoot -n <namespace> pending
kubectl describe pod <pod-name> -n <namespace>
```

Check for: missing secrets, unresolvable vault endpoints, storage mount failures, or insufficient node resources.

**504 Gateway Timeout on install/upgrade API calls:**

Your ingress proxy timeout may be too low for long-running database operations. The chart's default nginx annotations set a 3600s timeout. If using a custom ingress controller, ensure your timeout annotations are correct for your controller type.

**Image pull errors:**
```bash
rpihelmcli/setup.sh troubleshoot -n <namespace> imagepull
```

Check: registry credentials, image tag format, network access to the registry.

**SecretProviderClass not found:**

The `secretProviderClassName` in your Snowflake or CA cert config must match the `name` of a SecretProviderClass defined under `secretsManagement.csi.secretProviderClasses`.

### Get help

- Use the [Helm Assistant Chat](https://rpi-helm-assistant.redpointcdp.com) to ask questions about configuration or troubleshooting
- Run `rpihelmcli/setup.sh troubleshoot -n <namespace>` for automated diagnosis
- Contact [support@redpointglobal.com](mailto:support@redpointglobal.com) for product issues

</details>


---
<sub>Redpoint Interaction v7.8 | [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) | [Support](mailto:support@redpointglobal.com) | [redpointglobal.com](https://www.redpointglobal.com)</sub>
