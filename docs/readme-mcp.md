![redpoint_logo](../chart/images/redpoint.png)
# Interaction Helm Assistant

[< Back to Home](../README.md)

## Overview

The **Interaction Helm Assistant** is an AI-powered assistant that helps you configure, deploy, and troubleshoot your RPI installation. It provides two ways to interact with the same set of tools:

- **Web UI:** A browser-based interface with form-based tools, AI chat, and file management. No installation required.
- **Agentic (Claude Code / Claude Desktop):** Connect via the Model Context Protocol. The assistant can plan and drive end-to-end RPI deployments.

Both interfaces access the same underlying tools and search the official [RPI documentation](https://docs.redpointglobal.com/rpi) and the local chart documentation.

<details>
<summary><strong style="font-size:1.25em;">Option A: Web UI</strong></summary>

Use this option for a browser-based experience with forms, file uploads/downloads, and AI chat. No MCP client required.

### Access

The Web UI is hosted by Redpoint. Navigate to:

```
https://rpi-helm-assistant.redpointcdp.com
```

No installation, API keys, or setup required.

### Features

The Web UI includes six tabs:

| Tab | Description |
|-----|-------------|
| **Generate** | Guided overrides builder. Walk through 9 configuration steps with a live YAML preview. |
| **Validate** | Review the generated config for errors and warnings, then download `overrides.yaml`. Also supports uploading existing files. |
| **Deploy** | Step-by-step deployment instructions: download CLI, generate secrets, deploy, verify, retrieve endpoints, activate license. |
| **Automate** | Generate Terraform modules and CI/CD pipeline files (GitHub Actions, Azure DevOps, GitLab CI) from your overrides. |
| **Reference** | Searchable browser for every configurable key in the Helm chart with defaults. |
| **Chat** | Natural language assistant. Ask questions about RPI features, chart configuration, deployment, and troubleshooting. |
| **Agentic** | End-to-end deployment using the RPI Deploy Agent. Provisions Azure infrastructure, deploys the Helm chart, initializes the cluster, and activates the license. Connect Claude Code to get started. |

</details>

<details>
<summary><strong style="font-size:1.25em;">Option B: Agentic (Claude Code)</strong></summary>

Use this option to connect Claude Code (or another MCP-compatible client) to the assistant for agentic deployments, configuration, and troubleshooting.

### Prerequisites

- [Node.js](https://nodejs.org/) v18 or later

### Install Claude Code

Claude Code is a CLI tool from Anthropic that runs in your terminal. Install it with npm:

```bash
npm install -g @anthropic-ai/claude-code
```

Then launch it:

```bash
claude
```

On first run, you'll be prompted to sign in with your Anthropic account. If you don't have one, you can [sign up for a free account at claude.ai](https://claude.ai/signup). Follow the on-screen instructions to authenticate. See the [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code) for more details.

### Connect the Assistant

The Assistant is hosted by Redpoint as a public MCP endpoint. There is nothing to deploy or run in your cluster. Just run:

```bash
claude mcp add rpi-helm --transport http https://rpi-helm-assistant.redpointcdp.com/mcp --scope user
```

This only needs to be done once. The `--scope user` flag saves the server globally so it's available in every project and every future conversation. You can verify it's registered by running:

```bash
claude mcp list
```

You should see the Assistant listed with a connected status:

```
rpi-helm: https://rpi-helm-assistant.redpointcdp.com/mcp (HTTP) - Connected
```

For Claude Desktop, add the following to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "rpi-helm": {
      "type": "http",
      "url": "https://rpi-helm-assistant.redpointcdp.com/mcp"
    }
  }
}
```

</details>

<details>
<summary><strong style="font-size:1.25em;">Agentic Deployment</strong></summary>

The assistant can plan and drive end-to-end RPI deployments. It provisions Azure infrastructure (AKS, SQL, Key Vault, Service Bus, Application Gateway for Containers), generates Helm overrides, and walks you through the deployment without handling your credentials.

### Setup

You only need to do this once. Steps are the same as **Option B: Agentic (Claude Code)** above:

1. **Install Claude Code:** `npm install -g @anthropic-ai/claude-code`, then launch with `claude` and sign in with your Anthropic account.
2. **Register the assistant:**
   ```bash
   claude mcp add rpi-helm --transport http https://rpi-helm-assistant.redpointcdp.com/mcp --scope user
   ```
   Verify with `claude mcp list` — you should see `rpi-helm: ... (HTTP) - Connected`.

### Run a deployment

Tell the agent what you need with the `/deploy-rpi` command. The DSL form is the most reliable:

```
/deploy-rpi cloud=azure tier=azure-standard domain=example.com dw=snowflake db=sqlserver infra=greenfield
```

More examples:

```
/deploy-rpi cloud=azure tier=azure-minimal domain=example.com dw=snowflake db=sqlserver infra=greenfield
/deploy-rpi cloud=azure tier=azure-standard domain=example.com dw=snowflake db=sqlserver infra=existing
```

Natural-language phrasing works too:

```
/deploy-rpi Deploy RPI on Azure in East US 2 using the azure-standard template, SQL Server, Snowflake data warehouse, greenfield infrastructure, ingress domain example.com.
```

### What the agent does

| Phase | Name | What happens |
|:------|:-----|:-------------|
| 0 | **Discover** | Asks for the template choice (azure-standard or azure-minimal) and ingress domain if not in your prompt. |
| 1 | **Plan infra** | Generates a UUID for the environment and produces the Bicep parameter file. |
| 2 | **Run infrastructure** | Submits the Bicep deployment and reports live progress (10-15 min). |
| 3 | **Pre-check** | Verifies cluster connectivity, image pull secret, and TLS cert in Key Vault. |
| 4 | **Generate overrides** | Produces the final Helm overrides from your environment's Bicep outputs. |
| 5 | **Deploy** | `helm install` with the generated overrides. |
| 6 | **Validate** | Calls the deployment API's `installcluster`/`upgrade`/`addclient` flow to seed the database and the first tenant. |
| 7 | **Handoff** | Outputs a structured handoff report containing the access URLs, credentials location, and follow-up steps. |

All commands execute locally on your machine. The Helm Assistant provides the planning and validation logic via MCP but never touches your cluster or credentials.

### Security

All credentials are created during provisioning and stored in Key Vault. The agent never asks for, handles, or logs credential values. All commands execute locally on your machine.

| Concern | How it works |
|---------|-------------|
| App secrets | Stored in Key Vault. Pods read them at runtime via Workload Identity (SDK mode). |
| Database credentials | Created during infrastructure provisioning and stored in Key Vault. Rotate after deployment. |
| Image pull secret | You create it before deploying. The agent verifies it exists. |
| TLS certificate | Stored in Key Vault. Synced to K8s Secret `ingress-tls` via CSI Secret Store driver. |
| Internal passwords (Redis, RabbitMQ) | Auto-generated by the Helm chart. |
| Admin password | Auto-generated. Stored in Key Vault as `RPI-Admin-Password`. Change after first login. |

### Infrastructure (Azure)

The agent can provision new infrastructure or use existing resources. By default it creates everything from scratch, but you can point it at existing infrastructure by specifying `useExistingCluster`, `useExistingDatabase`, or `useExistingServiceBus` during the discovery phase. When using existing resources, the agent stores placeholder values in Key Vault that you update with your actual connection details after deployment.

| Resource | New | Existing |
|----------|-----|----------|
| AKS Automatic | Created with Workload Identity and CSI Secret Store | Provide cluster name and resource group |
| Azure SQL Server | Created with Pulse and Pulse_Logging databases | Provide server FQDN. Update connection strings in Key Vault after deployment. |
| Key Vault | Always created. Stores all secrets (SDK mode). | |
| Service Bus | Created with 6 RPI queues (Standard tier) | Provide connection string. Update in Key Vault after deployment. |
| Application Gateway for Containers | Created with frontend and subnet association | |
| Storage Account | Created with Azure Files share | |
| Managed Identity | Always created. Pod authentication to Key Vault. | |
| Private Endpoints | Created for new resources. Skipped for existing. | |

The Bicep templates are managed by the Helm Assistant and fetched automatically by the agent during deployment -- no files are added to your chart repository.

</details>

<details>
<summary><strong style="font-size:1.25em;">Available Tools</strong></summary>

Both the MCP server and the Web UI expose the same set of tools:

| Tool | Description |
|------|-------------|
| `rpi_validate` | Validates a values file against the chart schema and RPI-specific rules |
| `rpi_generate` | Generates an overrides file for a given platform, identity provider, and feature set |
| `rpi_explain` | Explains what a setting controls, its valid values, defaults, and related keys |
| `rpi_template` | Renders Helm templates with a given values file and returns the Kubernetes manifests |
| `rpi_status` | Shows deployment health, pod status, and recent events from the cluster |
| `rpi_troubleshoot` | Diagnoses issues using pod logs, events, secrets, and ingress configuration |
| `rpi_docs_search` | Searches the official RPI product documentation by keyword |
| `rpi_docs_fetch` | Fetches a specific page from the RPI documentation site |
| `rpi_deploy_plan` | Generates a deployment plan: Bicep bundle `fetchCommand`, `infraCommand` (with `--no-wait`), Helm overrides, vault checklist, and watch commands. Called twice. First pre-infra (infra command + UUID), then post-infra with Bicep outputs (`tenantId`, `managedIdentityClientId`) to produce fully-populated overrides. |
| `rpi_deploy_preflight` | Returns platform-specific preflight checks to run before deploying |
| `rpi_deploy_status` | Summarizes an in-flight Bicep deployment into structured progress (completed / in-progress / failed resources with friendly labels). The agent polls this every ~60s during infra provisioning so the customer sees live status instead of a silent 10-15 minute wait. |
| `rpi_deploy_resume` | Detects the state of an interrupted deployment (session exit, closed terminal) and returns the next phase + recovered values. Used by `/deploy-rpi resume`. Recovers `deploymentUuid` from resource group tags and Bicep outputs, so the customer never has to re-enter anything. |
| `rpi_deploy_diagnose` | Analyzes pod logs and events to diagnose deployment issues with root cause and fix |
| `rpi_deploy_handoff` | Generates a structured deployment handoff report |

For usage examples, run `/rpi-examples` in Claude Code.

</details>

---
<sub>Redpoint Interaction v7.8 | [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) | [Support](mailto:support@redpointglobal.com) | [redpointglobal.com](https://www.redpointglobal.com)</sub>
