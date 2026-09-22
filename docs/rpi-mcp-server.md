![redpoint_logo](../chart/images/redpoint.png)
# RPI MCP Server

[< Back to Home](../README.md)

## Overview

The **RPI MCP Server** exposes the RPI Integration API as Model Context Protocol tools, so AI clients and agent runtimes can read and act through RPI's documented API surface rather than a bespoke integration.

It runs as its own deployment, `rpi-mcpserver`, and serves the MCP protocol over streamable HTTP at `/mcp`. It reads the Integration API in cluster and never writes to an RPI database.

| Aspect | Value |
|---|---|
| Service | `rpi-mcpserver` |
| Port | 3002 |
| MCP endpoint | `/mcp` |
| Health endpoint | `/health` |
| Replicas | one, enforced at render |

## Prerequisites

| Requirement | Why |
|---|---|
| `secretsManagement.provider` is `kubernetes` or `csi` | The server reads its credentials from environment bindings and has no cloud vault client. Enabling it under `sdk` fails `helm template` with an explanatory error |
| An Integration API OAuth client | The server authenticates to RPI with a client id and secret you register |
| `rpiMcpServer.defaultClientId` | The RPI tenant this server serves. Required when enabled, with no inference and no default |

## Configuration

Minimum to enable:

```yaml
rpiMcpServer:
  enabled: true
  defaultClientId: <your-rpi-client-guid>
```

Populate the Secret keys in the standard RPI Secret before installing. See [Secrets Management](secrets-management.md).

```yaml
  RPI_MCP_OAuth_Client_Id: "<integration-api-oauth-client-id>"
  RPI_MCP_OAuth_Client_Secret: "<integration-api-oauth-client-secret>"
```

### Reference

| Value | Default | Purpose |
|---|---|---|
| `rpiMcpServer.enabled` | `false` | Enables the deployment, service, service account and ingress |
| `rpiMcpServer.defaultClientId` | `""` | RPI tenant identifier, a GUID. Required when enabled |
| `rpiMcpServer.authRequired` | `true` | Requires a bearer token on the MCP endpoint |
| `rpiMcpServer.replicaCount` | `1` | Must be `1` |
| `rpiMcpServer.proxy.enabled` | `false` | Uses service account proxy credentials from the Secret |
| `rpiMcpServer.urlAllowlist` | `""` | Comma separated host domains a caller may target per request. Empty accepts none |
| `rpiMcpServer.service.port` | `3002` | Service and container port |
| `rpiMcpServer.ingress.enabled` | `true` | Publishes an Ingress for the MCP endpoint |
| `rpiMcpServer.ingress.host` | `rpi-mcpserver` | Subdomain prepended to `ingress.domain`, or an FQDN when it contains a dot |
| `rpiMcpServer.terminationGracePeriodSeconds` | `240` | Shutdown grace period |

## Why one replica

MCP is a session protocol. A client initialises a session, receives a session identifier, and sends it with every later call. The server holds that session in its own process. A second replica has no record of a session another replica created, so a request routed there resolves to a different session partway through a conversation.

The chart therefore fixes the replica count at one and refuses any other value at render. Horizontal scale requires a shared session store in the application, which does not exist today.

## Ingress behaviour

The MCP endpoint streams. A tool call holds its response open until the call completes, and some calls poll for up to several minutes.

Two consequences are handled by the chart:

- Response buffering is disabled on this route only, with `nginx.ingress.kubernetes.io/proxy-buffering: "off"`. With buffering on, nginx holds the stream until the call finishes and the client sees a stall.
- The default proxy read and send timeouts of 3600 seconds comfortably exceed the server's own idle ceiling of 255 seconds. If you override `ingress.annotations`, keep both timeouts above 255 or long running tool calls are cut mid call.

## Degraded mode

When the RPI credentials are absent or invalid the server does not crash. It keeps its listener up, skips tool registration, and reports the condition:

- `/health` returns 200 with `"mcp": "degraded"`, a `reason`, and the list of missing variables.
- `/mcp` returns a structured JSON-RPC error with HTTP 503, so clients fail fast rather than hang.

The probes follow the server's own contract, so a degraded pod stays in the Service and answers 503 on the protocol endpoint. That is deliberate. A pod reporting healthy while serving no tools is visible in one `curl` of `/health` rather than hidden behind a failed probe.

## Verification

```bash
kubectl get pods -l app.kubernetes.io/name=rpi-mcpserver -n <namespace>
kubectl port-forward svc/rpi-mcpserver 3002:3002 -n <namespace>
curl -s http://localhost:3002/health
```

A healthy response names the server and reports its mask and version status. A degraded response names the missing variables.
