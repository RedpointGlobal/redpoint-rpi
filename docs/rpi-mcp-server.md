![redpoint_logo](../chart/images/redpoint.png)
# RPI MCP Server

[< Back to Home](../README.md)

## Overview

The **RPI MCP Server** exposes the RPI Integration API as Model Context Protocol tools, so AI clients can work through RPI's documented API rather than a bespoke integration. It reads through the Integration API and never writes to an RPI database.

Two optional workloads build on it. The **agent runtime** is an RPI native agent that reaches RPI only through those tools, and the **chat application** is a browser client for that runtime.

| Workload | What it is | Reached by | Setting |
|---|---|---|---|
| `rpi-mcpserver` | the tool surface | MCP clients | `redpointAI.mcpServers.rpi.enabled` |
| `rpi-aiserver` | the agent runtime | the chat application, or your own client in namespace | `redpointAI.agentRuntime.enabled` |
| `rpi-aiweb` | the chat application | a browser | `redpointAI.aiWeb.enabled` |

Each is enabled on its own, and each one depends only on the one below it. The tool server stands alone, the runtime requires the tool server, and the chat requires the runtime. A deployment that wants tools for its own MCP clients installs one workload and nothing else.

A tool server exposes an API and consumes no model, so it needs no AI configuration at all. The agent runtime does consume a model, and reads `redpointAI.model` plus the `RPI_NLP_API_KEY` Secret key, which is the one model configuration every Redpoint AI capability shares. The search index, blob storage and temperature live under `redpointAI.nlp` because only natural language rule building uses them. This follows the platform rule that AI infrastructure is configured once and inherited.

## Enable it

The tool server on its own:

```yaml
redpointAI:
  mcpServers:
    rpi:
      enabled: true
      oauthClientId: <integration-api-oauth-client-id>
      defaultClientId: <your-rpi-tenant-guid>
```

Add the agent runtime, which needs the shared model settings to be real values:

```yaml
redpointAI:
  model:
    ApiBase: https://<your-openai-name>.openai.azure.com/
    ApiVersion: 2023-07-01-preview
    ChatGptEngine: <chat-model-deployment-name>
  agentRuntime:
    enabled: true
```

Add the chat application:

```yaml
redpointAI:
  aiWeb:
    enabled: true
```

Two Secret keys, in the standard RPI Secret. See [Secrets Management](secrets-management.md).

```yaml
  RPI_MCP_OAuth_Client_Secret: "<integration-api-oauth-client-secret>"
  RPI_NLP_API_KEY: "<azure-openai-api-key>"
```

`RPI_NLP_API_KEY` is the same key natural language rule building uses, and is needed only when the agent runtime is deployed. Service addresses are derived and the session signing key is generated.

`secretsManagement.provider` must be `kubernetes` or `csi`. Anything else fails at render with the reason.

### Choose an identity mode

**Per user**, the default above. Every caller presents its own RPI token and RPI
applies that person's permissions. Use this whenever the caller is a human.

**Service account**, every call runs as one shared RPI user and per user identity
is discarded. Use this only for system automation. The endpoint is unauthenticated,
so publish it accordingly.

```yaml
redpointAI:
  mcpServers:
    rpi:
      authRequired: false
      proxy:
        enabled: true
        user: <service-account-username>
```

with `RPI_MCP_Proxy_Pass` added to the Secret. The chat application always uses
per user identity and is unaffected by this setting.

### Values

| Value | Default | Purpose |
|---|---|---|
| `redpointAI.mcpServers.rpi.enabled` | `false` | Deploy the tool server |
| `redpointAI.mcpServers.rpi.oauthClientId` | `""` | Integration API OAuth client. Required when enabled |
| `redpointAI.mcpServers.rpi.defaultClientId` | `""` | RPI tenant GUID. Required when enabled |
| `redpointAI.mcpServers.rpi.authRequired` | `true` | Each caller presents its own RPI token |
| `redpointAI.mcpServers.rpi.proxy.enabled` | `false` | Run every call as one service account instead |
| `redpointAI.mcpServers.rpi.proxy.user` | `""` | Service account username. Required with `proxy.enabled`, password in `RPI_MCP_Proxy_Pass` |
| `redpointAI.agentRuntime.enabled` | `false` | Deploy the agent runtime. Requires `redpointAI.mcpServers.rpi.enabled` |
| `redpointAI.agentRuntime.azureResourceName` | `""` | Azure OpenAI resource name. Derived from `redpointAI.model.ApiBase` unless that endpoint is not the standard Azure form |
| `redpointAI.agentRuntime.storage.size` | `5Gi` | Volume holding the runtime database |
| `redpointAI.aiWeb.enabled` | `false` | Deploy the chat application. Requires `redpointAI.agentRuntime.enabled` |
| `ingress.hosts.rpimcpserver` | `rpi-mcpserver` | Tool server hostname |
| `ingress.hosts.rpiaiweb` | `rpi-aiweb` | Chat hostname |

The tool server and the agent runtime are each fixed at one replica and refuse any other value at render. The tool server holds protocol sessions in process, and the runtime owns a database on a single volume.

## Endpoints

The tool server and the chat application are published. The agent runtime is reached in namespace and has no ingress.

Both published hostnames follow the same rule as every other service: the value in `ingress.hosts` is prepended to `ingress.domain`, unless it contains a dot, in which case it is used as an FQDN.

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

What you send depends on the identity mode the deployment was installed with.
On a **service account** deployment, send nothing: point the client at the URL
and skip the rest of this section. On a **per user** deployment, which is the
default, send one header carrying your own RPI token.

How you obtain that token depends on how the deployment signs users in. Use
Microsoft Entra ID where the deployment federates to Entra, and RPI credentials
otherwise.

### Microsoft Entra ID

The deployment must already federate to Entra, which means `MicrosoftEntraID`
is configured and the API registration exposes the `Interaction.Clients` scope.
See [Single Sign-On](single-sign-on.md) for that setup. Nothing in the chart
changes for MCP clients and no override is added.

MCP clients run on a workstation rather than in a browser, so they need their
own public client registration. Register it once per environment and give the
identifier to everyone who connects.

1. Go to **Microsoft Entra ID** > **App registrations** > **New registration**.
2. Name it for the environment, for example `rpi-<environment>-mcp-client`.
3. Set **Supported account types** to single tenant.
4. Under **Redirect URI**, choose the **Public client/native (mobile & desktop)** platform and enter `http://localhost`. The Web platform rejects the token exchange for a public client.
5. Register, then open **Authentication** and confirm **Allow public client flows** is enabled.
6. Open **API permissions** > **Add a permission** > **APIs my organization uses**. Search for the Application ID URI of your RPI API registration, choose **Delegated permissions** and select `Interaction.Clients`. The **My APIs** tab lists only registrations you own, so it is usually empty here.
7. Add **Microsoft Graph** delegated `openid`, `profile`, `email` and `offline_access`. The last one is what returns refresh tokens.
8. Grant admin consent so nobody is prompted on first use.
9. Record the **Application (client) ID** and **Directory (tenant) ID** from **Overview**.

Leave **Certificates and secrets** empty. A public client has none by design.

Optionally add this registration under **Authorized client applications** on the
RPI API registration, alongside the interaction client that is already listed
there.

#### Getting a token

Device code sign in needs no local listener, so it works over SSH and inside a
container. Start it:

```bash
TENANT=<directory-tenant-id>
CLIENT=<mcp-client-application-id>
API=api://<interaction-api-application-id>

DC=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/devicecode" \
  --data-urlencode "client_id=$CLIENT" \
  --data-urlencode "scope=$API/Interaction.Clients offline_access openid profile")

DEVICE_CODE=$(echo "$DC" | jq -r .device_code)
echo "$DC" | jq -r .message
```

Follow the printed instruction in a browser, then exchange the code:

```bash
RESP=$(curl -s -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
  --data-urlencode "client_id=$CLIENT" \
  --data-urlencode "device_code=$DEVICE_CODE")

RPI_TOKEN=$(echo "$RESP" | jq -r .access_token)
RPI_REFRESH=$(echo "$RESP" | jq -r .refresh_token)
```

The access token lasts about an hour. Renew it without signing in again:

```bash
curl -s -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
  --data-urlencode "grant_type=refresh_token" \
  --data-urlencode "client_id=$CLIENT" \
  --data-urlencode "refresh_token=$RPI_REFRESH" | jq -r .access_token
```

Each user signs in as themselves, so RPI applies that person's own permissions.

### RPI credentials

Your own RPI username and password:

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
