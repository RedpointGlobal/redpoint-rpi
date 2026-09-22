![redpoint_logo](../chart/images/redpoint.png)
# Agent Workspace

[< Back to Home](../README.md)

## Overview

The **Agent Workspace** is the chat surface over the MCP tool servers. Users sign in with their RPI credentials and ask questions in plain language; the agent runtime selects tools, calls RPI through the MCP server, and answers.

It is the surface intended for users who are not working at the protocol level. The MCP endpoint itself stays a machine interface.

Two workloads:

| Workload | Role | Port | Published |
|---|---|---|---|
| `rpi-aiweb` | chat web application | 3001 | yes, `ingress.hosts.rpiaiweb` |
| `rpi-aiserver` | agent runtime, MCP client, workspace database | 3000 | no, in namespace only |

The browser only ever reaches `rpi-aiweb`. Its server side routes proxy to `rpi-aiserver`, which reaches `rpi-mcpserver`, which reaches the Integration API. One hostname, one certificate.

## Prerequisites

| Requirement | Why |
|---|---|
| `redpointAI.enabled: true` | The workspace inherits the Azure OpenAI endpoint, API version, deployment and credential from that section and defines none of its own |
| `mcpServers.rpi.enabled: true` | The workspace has no tool surface without it, and inherits its tenant and OAuth client |
| `secretsManagement.provider` is `kubernetes` or `csi` | Credentials arrive as environment bindings; there is no cloud vault client |

Each is enforced at render with a named error.

## What it inherits

Only the values the agent runtime consumes.

| From `redpointAI` | Becomes | Note |
|---|---|---|
| `naturalLanguage.ApiBase` | `AZURE_OPENAI_RESOURCE_NAME` | the first label of the host, since the runtime builds the URL itself |
| `naturalLanguage.ApiVersion` | `AZURE_OPENAI_API_VERSION` | |
| `naturalLanguage.ChatGptEngine` | `AZURE_OPENAI_DEPLOYMENT_ID` | |
| `RPI_NLP_API_KEY` | `AZURE_OPENAI_API_KEY` | the same Secret key, bound to a second name |

`cognitiveSearch`, `modelStorage` and `ChatGptTemp` are **not** inherited. The first two belong to the natural language rule builder, and the runtime pins its own temperature so tool routing is reproducible.

From `mcpServers.rpi` it inherits `defaultClientId` and `oauthClientId`, so the tenant and OAuth client are stated once.

## Configuration

```yaml
redpointAI:
  enabled: true
  agentWorkspace:
    enabled: true
```

Nothing else is required. Service addresses are derived from the names the chart already assigns, and the public URL is built from `ingress.hosts.rpiaiweb` with `ingress.domain`.

### Reference

| Value | Default | Purpose |
|---|---|---|
| `redpointAI.agentWorkspace.enabled` | `false` | Deploy both workloads and the ingress route |
| `redpointAI.agentWorkspace.azureResourceName` | `""` | Override the derived Azure OpenAI resource name. Needed only when the endpoint is not `https://<resource>.openai.azure.com` |
| `redpointAI.agentWorkspace.server.replicaCount` | `1` | Must be `1` |
| `redpointAI.agentWorkspace.server.storage.size` | `5Gi` | Workspace database volume |
| `redpointAI.agentWorkspace.web.replicaCount` | `1` | Web replicas |
| `ingress.hosts.rpiaiweb` | `rpi-aiweb` | Hostname for the workspace |

## Identity

Users sign in on the web application with their RPI credentials, which it exchanges at RPI's token endpoint. The session is signed with a key the chart generates into the internal `rpi-internal-services` Secret, preserved across upgrades so an upgrade does not sign everyone out. It is never an operator populated value. The user's RPI token is forwarded to the agent runtime, which forwards it to the MCP server, which forwards it to the Integration API.

So RPI enforces each user's real permissions for the whole chain. Two people asking the same question see only what their own accounts allow.

The runtime runs with authentication required. It refuses to start when the signing secret is missing, rather than serving with a placeholder.

## Why one replica

The workspace database is SQLite on a single volume, so one writer. The chart fixes the replica count at one and refuses any other value. The web application has no such constraint and can scale.

Moving the database to PostgreSQL removes the constraint. The runtime selects it by `DATABASE_URL`, which this chart does not yet set.

## Verification

```bash
kubectl -n <namespace> get pods -l app.kubernetes.io/component=agentworkspace
kubectl -n <namespace> port-forward svc/rpi-aiserver 3000:3000
curl -s http://localhost:3000/api/v1/health
```

Then open `https://<ingress.hosts.rpiaiweb>.<ingress.domain>` and sign in with an RPI account mapped to the configured tenant.

## Known limitation

The live trace panel in the chat surface opens its event stream directly from the browser, using a value fixed when the web image is built rather than at deploy time. Behind an ingress that address does not resolve, so that one panel stays empty. Everything routed through the application's own proxy handlers, which is the rest of the surface, works normally.
