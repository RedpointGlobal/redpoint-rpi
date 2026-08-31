![redpoint_logo](../chart/images/redpoint.png)
# RPI Helm CLI

[< Back to Home](../README.md)

The RPI Helm CLI is a command-line tool for deploying and managing RPI on Kubernetes. It handles pre-flight validation, secrets generation, chart deployment, health checks, and troubleshooting.

---

## Deployment Workflow

The CLI guides you through the complete deployment lifecycle. Each step builds on the previous one.

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  1. Generate │───▶│   2. Check   │───▶│ 3. Secrets   │───▶│  4. Deploy   │───▶│  5. Status   │
│   overrides  │    │ prerequisites│    │  generation  │    │              │    │              │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
   Web UI / CLI        CLI check          CLI secrets       CLI deploy / helm     CLI status
```

### Step 1: Generate overrides

Create your overrides file using the [Helm Assistant Web UI](https://rpi-helm-assistant.redpointcdp.com) **Generate** tab. The overrides file contains **only non-default, non-sensitive values** - no passwords, no connection strings, no API keys. To add settings after the initial generation, find the keys in the **Reference** tab and add them to your existing overrides file.

### Step 2: Check prerequisites

```bash
rpihelmcli/setup.sh check -f overrides.yaml
```

Validates your local tools (kubectl, helm), cluster connectivity, and overrides file structure.

### Step 3: Generate and apply secrets

```bash
rpihelmcli/setup.sh secrets -f overrides.yaml -n my-namespace
```

The CLI reads your overrides, detects which secrets are required based on your configuration (database provider, Snowflake keys, CA certs, SMTP, etc.), and **prompts you for each sensitive value**. It then generates a `secrets.yaml` file containing all required Kubernetes Secrets.

Apply the generated secrets:

```bash
kubectl apply -f secrets.yaml -n my-namespace
```

> **Important:** This step must be completed before deploying. The chart does not create application secrets - it only references them. If you skip this step, the deploy command will detect the missing secrets and warn you.

### Step 4: Deploy

```bash
rpihelmcli/setup.sh deploy -f overrides.yaml -n my-namespace
```

The CLI auto-clones the chart, creates the namespace if needed, validates that required secrets exist, and runs `helm install`. After submitting, it polls pod status until all pods are ready.

### Step 5: Check status

```bash
rpihelmcli/setup.sh status -n my-namespace
```

Shows pod health, services, and ingress endpoints.

---

### Quick Start

Download the [CLI](https://rpi-helm-assistant.redpointcdp.com/app/static/rpihelmcli.zip) from the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com), then:

```bash
unzip rpihelmcli.zip
rpihelmcli/setup.sh check   -f overrides.yaml
rpihelmcli/setup.sh secrets -f overrides.yaml -n my-namespace
kubectl apply -f secrets.yaml -n my-namespace
rpihelmcli/setup.sh deploy  -f overrides.yaml -n my-namespace
rpihelmcli/setup.sh status  -n my-namespace
```

Generate your overrides file at [rpi-helm-assistant.redpointcdp.com](https://rpi-helm-assistant.redpointcdp.com).

---

## Prerequisites

- bash
- kubectl (configured with cluster access)
- helm (v3+)
- python3 with PyYAML (`pip3 install pyyaml`)
- git

---

<details>
<summary><strong style="font-size:1.25em;">Pre-flight Check</strong></summary>

Validates that all required tools are installed, the cluster is reachable, and the overrides file is valid YAML with the expected structure.

```bash
rpihelmcli/setup.sh check -f overrides.yaml
```

**Example output:**

```
RPI Helm CLI -- Pre-flight Check

  Required tools
  ✔ bash ()
  ✔ kubectl (v1.31.2)
  ✔ helm (v3.16.2+g13654a5)
  ✔ python3 (3.13.7)
  ✔ git (2.34.1)
  ✔ PyYAML installed

  Cluster connectivity
  ✔ Cluster reachable (context: eks-engineering)

  Overrides file
  ✔ overrides.yaml (463 lines)
  ✔ Valid YAML syntax
  ✔ Platform: amazon
  ✔ Secrets provider: sdk

  All checks passed. Ready to deploy.

  Next steps:
    rpihelmcli/setup.sh deploy -f overrides.yaml --dry-run  # Preview
    rpihelmcli/setup.sh deploy -f overrides.yaml            # Deploy
```

If any check fails, fix the issue before proceeding. Common fixes:
- `kubectl not found`: install kubectl and configure your kubeconfig
- `PyYAML not installed`: run `pip3 install pyyaml`
- `Cannot reach Kubernetes cluster`: check your kubeconfig context with `kubectl config current-context`
- `Invalid YAML syntax`: check for indentation errors or missing colons in your overrides file

</details>

<details>
<summary><strong style="font-size:1.25em;">Generate Secrets</strong></summary>

Reads your overrides file, detects which secrets are needed based on your configuration, and prompts for credentials. Only required when `secretsManagement.provider` is `kubernetes`.

```bash
rpihelmcli/setup.sh secrets -f overrides.yaml
```

**Example output:**

```
Interaction CLI -- Secrets Generator
Reading configuration from: overrides.yaml

  Detected configuration:
    Mode:             standard
    Database:         postgresql
    Secrets provider: kubernetes
    Realtime API:     true
    Cache provider:   mongodb
    Queue provider:   amazonsqs

  Database credentials
    Server host: my-db.cluster.us-east-1.rds.amazonaws.com (from overrides)
    Username: admin (from overrides)
    Password: ********

  Realtime cache connection
    mongodb connection string: ********

  ✔ Secrets written to: secrets.yaml
```

The generated `secrets.yaml` contains a Kubernetes Secret manifest. Apply it before deploying:

```bash
kubectl apply -f secrets.yaml -n my-namespace
```

**When to skip:** If using the `sdk` or `csi` secrets provider, secrets come from your cloud vault. The CLI will confirm this and point you to the [Secrets Management Guide](https://github.com/RedPointGlobal/redpoint-rpi/blob/main/docs/secrets-management.md) and the [Helm Assistant Automate tab](https://rpi-helm-assistant.redpointcdp.com) for vault setup scripts.

**Example output (SDK/CSI provider):**

```
Interaction CLI -- Secrets Generator
Reading configuration from: overrides.yaml

  Secrets provider is 'sdk'. RPI secrets are managed by the cloud vault.
  No Kubernetes secret will be generated by this command.

  Ensure your vault contains the required secrets before deploying.

  References:
    Secrets guide:    https://github.com/RedPointGlobal/redpoint-rpi/.../secrets-management.md
    Vault setup:      https://rpi-helm-assistant.redpointcdp.com (Automate tab)
```

</details>

<details>
<summary><strong style="font-size:1.25em;">Deploy</strong></summary>

Auto-clones the chart from GitHub (or reuses an existing clone), creates the namespace if needed, and runs `helm install` or `helm upgrade`. After submitting, the CLI polls pod status every 10 seconds until all pods are ready or timeout (10 minutes). Pods in error states show the reason from cluster events.

```bash
rpihelmcli/setup.sh deploy -f overrides.yaml -n my-namespace
```

**Example output:**

```
Interaction CLI -- Deploy

  Pre-flight checks
  ✔ kubectl found
  ✔ helm found
  ✔ Cluster reachable
  ✔ Chart found at ./redpoint-rpi/chart (existing clone)
  ✔ Namespace exists: my-namespace

  Running helm install...

  ✔ Helm install submitted

  Waiting for pods to be ready...

  01:23:45 Pod status:
    ◌ rpi-deploymentapi-79bfb9d884-rxnqd   0/1  ContainerCreating
    ◌ rpi-interactionapi-8558b7fbc6-kqrq8  0/1  Pending
    ◌ rpi-executionservice-8ffc9797b-t8xhj  0/1  ContainerCreating

  01:23:55 Pod status:
    ✔ rpi-deploymentapi-79bfb9d884-rxnqd   1/1  Running
    ● rpi-interactionapi-8558b7fbc6-kqrq8  0/1  ContainerCreating
      MountVolume.SetUp failed for volume "custom-ca-certs": provider "aws" not found
    ◌ rpi-executionservice-8ffc9797b-t8xhj  0/1  Init:0/1

  01:24:05 Pod status:
    ✔ rpi-deploymentapi-79bfb9d884-rxnqd   1/1  Running
    ✔ rpi-interactionapi-8558b7fbc6-kqrq8  1/1  Running
    ✔ rpi-executionservice-8ffc9797b-t8xhj  1/1  Running

  ✔ All pods ready
```

Pod status indicators:
- ✔ Green: all containers ready
- ● Yellow: running but not all containers ready
- ✘ Red: crash or error (shows reason from events)
- ◌ Circle: still starting (shows reason if stuck)

**Dry run** (preview without deploying):

```bash
rpihelmcli/setup.sh deploy -f overrides.yaml -n my-namespace --dry-run
```

This renders all Kubernetes manifests to stdout so you can review them before they hit the cluster.

**Options:**

| Flag | Description |
|------|-------------|
| `-f <file>` | Overrides file (required) |
| `-n <namespace>` | Kubernetes namespace (default: `redpoint-rpi`) |
| `-r <name>` | Helm release name (default: `rpi`). Use different names for multiple environments, e.g. `rpi-dev`, `rpi-prod` |
| `-c <path>` | Chart path (default: auto-clone from GitHub) |
| `--dry-run` | Render templates without deploying |

</details>

<details>
<summary><strong style="font-size:1.25em;">Status</strong></summary>

Shows the current state of your RPI deployment: pods, services, ingress, and recent events.

```bash
rpihelmcli/setup.sh status -n my-namespace
```

**Example output:**

```
RPI Cluster Status -- my-namespace

  Pods
  ✔ rpi-deploymentapi-79bfb9d884-rxnqd    Running  (2/2)
  ✔ rpi-interactionapi-8558b7fbc6-kqrq8    Running  (2/2)
  ✔ rpi-integrationapi-578dbd4d45-rxwdt    Running  (2/2)
  ✔ rpi-executionservice-8ffc9797b-t8xhj   Running  (2/2)
  ✔ rpi-nodemanager-79d44f6989-nwpwx       Running  (2/2)
  ✔ rpi-callbackapi-86677c4854-bzbxt       Running  (2/2)
  ✔ rpi-realtimeapi-5549c48d64-glrgq       Running  (2/2)
  ✔ rpi-queuereader-69675cb796-p6hkg       Running  (2/2)

  Services
  rpi-deploymentapi    ClusterIP  172.20.29.24    8080/TCP
  rpi-interactionapi   ClusterIP  172.20.192.176  8080/TCP
  rpi-integrationapi   ClusterIP  172.20.103.48   8080/TCP
  ...

  Ingress
  redpoint-rpi  alb  rpi-interactionapi.example.com  internal-k8s-xxx.elb.amazonaws.com
```

</details>

<details>
<summary><strong style="font-size:1.25em;">Troubleshoot</strong></summary>

Diagnoses common deployment issues by checking pod states, events, and logs.

```bash
rpihelmcli/setup.sh troubleshoot -n my-namespace
```

You can also pass a specific symptom to narrow the diagnosis:

```bash
rpihelmcli/setup.sh troubleshoot -n my-namespace crashloop
rpihelmcli/setup.sh troubleshoot -n my-namespace pending
rpihelmcli/setup.sh troubleshoot -n my-namespace imagepull
```

| Symptom | What it checks |
|---------|---------------|
| `crashloop` | Pods in CrashLoopBackOff, recent restart logs |
| `pending` | Unschedulable pods, resource constraints, node availability |
| `imagepull` | Image pull errors, registry auth, image names |
| (none) | Full scan of all common issues |

</details>

---

## Command Reference

```
rpihelmcli/setup.sh check [-f overrides.yaml]
rpihelmcli/setup.sh secrets -f <overrides> [-o secrets.yaml] [-n namespace]
rpihelmcli/setup.sh deploy -f <overrides> [-n namespace] [-r release-name] [-c chart-path] [--dry-run]
rpihelmcli/setup.sh status [-n namespace]
rpihelmcli/setup.sh troubleshoot [-n namespace] [symptom]
```

| Flag | Applies to | Description |
|:-----|:-----------|:------------|
| `-f <file>` | check, secrets, deploy | Overrides file |
| `-n <namespace>` | secrets, deploy, status, troubleshoot | Kubernetes namespace (default: `redpoint-rpi`) |
| `-r <name>` | deploy | Helm release name (default: `rpi`) |
| `-o <file>` | secrets | Output file name (default: `secrets.yaml`) |
| `-c <path>` | deploy | Chart directory path (default: auto-clone from GitHub) |
| `--dry-run` | deploy | Render manifests without deploying |

---
<sub>Redpoint Interaction v7.8 | [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) | [Support](mailto:support@redpointglobal.com) | [redpointglobal.com](https://www.redpointglobal.com)</sub>
