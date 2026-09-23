![redpoint_logo](../chart/images/redpoint.png)
# RPI MCP Server

[< Back to Home](../README.md)

## Overview

The **RPI MCP Server** exposes the RPI Integration API as Model Context Protocol tools, so AI clients can work through RPI's documented API rather than a bespoke integration. It is read through and never writes to an RPI database.

An optional **agent workspace** adds a chat application on top of the same tools, for users who will not connect an MCP client themselves.

| Workload | What it is | Reached by |
|---|---|---|
| `rpi-mcpserver` | the tool surface | MCP clients |
| `rpi-aiweb` | the chat application | a browser |
| `rpi-aiserver` | the agent behind the chat | nothing directly |

## Enable it

The tool server on its own:

```yaml
mcpServers:
  rpi:
    enabled: true
    oauthClientId: <integration-api-oauth-client-id>
    defaultClientId: <your-rpi-tenant-guid>
```

Add the chat application:

```yaml
redpointAI:
  enabled: true
  agentWorkspace:
    enabled: true
```

One Secret key, in the standard RPI Secret. See [Secrets Management](secrets-management.md).

```yaml
  RPI_MCP_OAuth_Client_Secret: "<integration-api-oauth-client-secret>"
```

That is all. Model configuration comes from `redpointAI`, service addresses are derived, and the session signing key is generated.

`secretsManagement.provider` must be `kubernetes` or `csi`. Anything else fails at render with the reason.

### Values

| Value | Default | Purpose |
|---|---|---|
| `mcpServers.rpi.enabled` | `false` | Deploy the tool server |
| `mcpServers.rpi.oauthClientId` | `""` | Integration API OAuth client. Required when enabled |
| `mcpServers.rpi.defaultClientId` | `""` | RPI tenant GUID. Required when enabled |
| `mcpServers.rpi.authRequired` | `true` | Each caller presents its own RPI token |
| `mcpServers.rpi.proxy.enabled` | `false` | Run every call as one service account instead |
| `mcpServers.rpi.proxy.user` | `""` | Service account username. Required with `proxy.enabled`, password in `RPI_MCP_Proxy_Pass` |
| `redpointAI.agentWorkspace.enabled` | `false` | Deploy the chat application. Requires `redpointAI.enabled` and `mcpServers.rpi.enabled` |
| `ingress.hosts.rpimcpserver` | `rpi-mcpserver` | Tool server hostname |
| `ingress.hosts.rpiaiweb` | `rpi-aiweb` | Chat hostname |

## Endpoints

Both hostnames follow the same rule as every other service: the value in `ingress.hosts` is prepended to `ingress.domain`, unless it contains a dot, in which case it is used as an FQDN.

```
https://<ingress.hosts.rpimcpserver>.<ingress.domain>/mcp
https://<ingress.hosts.rpiaiweb>.<ingress.domain>/
```

Confirm what was published:

```bash
kubectl get ingress -n <namespace>
```

## Using the chat application

Open the chat hostname and sign in with RPI credentials. Each user's own RPI permissions apply for everything the agent does on their behalf, so two people asking the same question see only what their accounts allow.

## Using an MCP client

Works with Claude Code, Cursor, VS Code, or your own agent.

**Check which mode the deployment runs first.**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://<mcp-host>/mcp
```

**401** means each caller brings its own RPI token. **Anything else** means every call runs as the configured service account and no credential is needed.

### Getting a token

Only needed for the 401 case. Your own RPI username and password:

```bash
curl -s -X POST https://<integration-api-host>/connect/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=password \
  --data-urlencode "username=$RPI_USER" \
  --data-urlencode "password=$RPI_PASS" \
  --data-urlencode "client_id=$RPI_OAUTH_CLIENT_ID" \
  --data-urlencode "client_secret=$RPI_CLIENT_SECRET" \
  | sed 's/.*"access_token": *"\([^"]*\)".*/\1/'
```

Use `--data-urlencode`, not `-d`. With `-d` a `+` in a password is sent as a space and the grant fails as though the password were wrong.

Tokens last one hour. Re-run this and update your client when calls report an expired session.

### Client configuration

`.mcp.json` for Claude Code, `.cursor/mcp.json` for Cursor, `.vscode/mcp.json` for VS Code:

```json
{
  "mcpServers": {
    "rpi": {
      "type": "http",
      "url": "https://<mcp-host>/mcp",
      "headers": { "Authorization": "Bearer ${RPI_TOKEN}" }
    }
  }
}
```

Or from the command line:

```bash
claude mcp add --transport http rpi https://<mcp-host>/mcp \
  --header "Authorization: Bearer $RPI_TOKEN"
```

Drop the `headers` block entirely in service account mode. Reference the token through an environment variable rather than pasting it, since these files are usually committed.

The client sends only that header. The tenant comes from the server's configuration, so no tenant or client id travels with a call.

### First call

Run the `verify_connection` tool. It reports whether your token was accepted, whether a tenant is selected, and makes a live API call, which separates a credential problem from a badly phrased question. Then try listing clients or audiences.
