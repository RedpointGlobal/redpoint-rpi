![redpoint_logo](../chart/images/redpoint.png)
# Upgrading from v7.8 to v7.9

[< Back to Home](../README.md)

This guide covers upgrading an existing RPI v7.8 Helm deployment to v7.9. If you're deploying RPI for the first time, see the [Greenfield Installation](greenfield.md) guide instead.

> **Not ready to upgrade?** The v7.8 chart on the `main` branch remains available for critical fixes. You can stay on v7.8 as long as needed.

---

<details>
<summary><strong style="font-size:1.25em;">What Changed in the Helm Chart</strong></summary>

Most v7.8 overrides carry over unchanged. A small number of settings have moved, changed behavior or been removed. They are listed in the Upgrade Checklist below.

| Area | Change |
|:---|:---|
| Redpoint AI | Restructured into a shared model block plus capabilities enabled on their own. New MCP tool server and agent runtime |
| Twilio Messaging | New opt-in SMS service with its own PostgreSQL store, Redis, and message transport |
| Common environment variables | Set environment variables on every RPI application service from one place |
| Smart Activation | Mail settings come from `SMTPSettings`, Keycloak is reached through its in-cluster service, images can be overridden like RPI images, and the `sdk` secrets provider is refused |
| Keycloak sign-in | With `OpenIdProviders.name: keycloak`, the authorization host is built from `ingress.hosts.smartactivation` |
| `sdk` secrets provider | Whether the Deployment API signs in to the database with a username and password is set in the vault. Rebrandly reads its API key from the Kubernetes Secret |

</details>

<details>
<summary><strong style="font-size:1.25em;">New Chart Features</strong></summary>

### Redpoint AI: separate capabilities, one model configuration

`redpointAI` is now a shared model block plus capabilities that are each enabled on their own. `redpointAI.model` holds the endpoint, API version and deployment that every capability consuming a model reads, with the credential in the shared RPI Secret. Everything a single capability owns lives under that capability.

Natural language rule building is unchanged in behavior and moves to `redpointAI.nlp`. Two capabilities are new:

| Capability | Setting | What it does | Requires |
|:---|:---|:---|:---|
| MCP tool server | `redpointAI.mcp.enabled` | Publishes the RPI Integration API as Model Context Protocol tools for AI clients | Nothing else |
| Agent runtime | `redpointAI.agentRuntime.enabled` | An RPI native agent that reaches RPI through those tools | MCP tool server |

A tool server exposes an API and consumes no model, so `redpointAI.model` is not required for it.

```yaml
redpointAI:
  model:
    ApiBase: https://<your-openai-name>.openai.azure.com/
    ApiVersion: <azure-openai-api-version>
    ChatGptEngine: <chat-model-deployment-name>
  nlp:
    enabled: true
  mcp:
    enabled: true
    defaultClientId: <your-rpi-tenant-guid>
    oauthClientId: <integration-api-oauth-client-id>
```

Enabling a capability also needs its Secret key: `RPI_AI_OAuth_Client_Secret` for the tool server, `RPI_NLP_API_KEY` for the agent runtime and for natural language rule building.

Existing v7.8 Redpoint AI overrides must be rewritten. The Upgrade Checklist below carries the full path mapping. See [Redpoint AI](redpoint-ai.md) and [RPI MCP Server](rpi-mcp-server.md).

The MCP tool server and the agent runtime are new in v7.9, so a v7.8 `overrides.yaml` has nothing to map. If you trialled them on a pre-release chart, these were renamed:

| Pre-release | v7.9 |
|:---|:---|
| `redpointAI.mcpServers.rpi.*` | `redpointAI.mcp.*` |
| `redpointAI.mcpServers.rpi.authRequired` | `redpointAI.mcp.auth.required` |
| `redpointAI.mcpServers.rpi.oauthClientId` | `redpointAI.mcp.oauthClientId` |
| `redpointAI.mcpServers.rpi.proxy.enabled` | `redpointAI.mcp.auth.proxy.enabled` |
| `redpointAI.mcpServers.rpi.proxy.user` | `redpointAI.mcp.auth.proxy.user` |
| `redpointAI.mcpServers.rpi.urlAllowlist` | Removed |
| `redpointAI.agentRuntime.storage.storageClassName` | Removed. The class follows `global.deployment.platform` |
| `redpointAI.aiWeb.*` | Removed |

`serviceAccount`, `replicaCount`, `service.port`, `securityContext`, `resources` and `terminationGracePeriodSeconds` are now chart-owned on both capabilities. Any name in the left column is rejected at install, with the path named.

### Twilio Messaging

A new opt-in SMS service, off by default. It is a separate workload with its own PostgreSQL store, a Redis cache, and a message transport chosen per platform: Azure Event Hubs, AWS SQS and SNS, or Google Pub/Sub.

```yaml
twiliomessaging:
  enabled: true
  accountSid: <twilio-account-sid>
  messaging:
    provider: azureeventhubs      # or amazonsqs, or googlepubsub
  postgres:
    reuseOperational: false
    host: <postgres-host>
    username: <postgres-user>
    database: twilio_messaging
  eventHubs:
    fullyQualifiedNamespace: <namespace>.servicebus.windows.net
    checkpointing:
      blobServiceUri: https://<storage-account>.blob.core.windows.net
```

`postgres.reuseOperational: true` puts the store on the operational database server and reuses its credentials, which requires `databases.operational.provider: postgresql`. The chart says so at render if it does not hold.

With the `kubernetes` or `csi` secrets provider, populate `TwilioMessaging_AuthToken` in the shared Secret, plus `TwilioMessaging_Postgres_Password` when the store is standalone. With `sdk`, the auth token is read from the deployment's vault as `Twilio--Client--AuthToken` (Azure and Google) or `Twilio__Client__AuthToken` (AWS), and PostgreSQL signs in with the pods' managed identity: set `postgres.username` to that identity's PostgreSQL role, which must own the Twilio database. The internal Redis password is generated by the chart.

The transport objects are not created for you. Hubs, queues, topics, subscriptions, and consumer groups must exist before the service starts, and the database schema is applied by a Job that runs before the service rolls. Only the Twilio webhook paths are published. Send and status routes stay in namespace. See [Twilio Messaging](twilio-messaging.md) for the prerequisites and the commands for each platform.

### Common environment variables

`commonEnvVars` provides a centralized way to set custom environment variables on every RPI application container. It is disabled by default and follows the same pattern as `commonAnnotations`.

```yaml
commonEnvVars:
  - name: DT_TAGS
    value: "environment=production"
```

Each entry supports standard Kubernetes environment variable fields, including name and value. This setting is general-purpose and can be used for observability, internal tooling, or other customer-specific integrations.

### Smart Activation image overrides

Smart Activation images are overridden the same way as RPI images, keyed by service: `cdp-authservice`, `cdp-cache`, `cdp-init`, `cdp-keycloak`, `cdp-maintenance`, `cdp-messageq`, `cdp-servicesapi`, `cdp-socketio` and `cdp-ui`.

```yaml
global:
  deployment:
    images:
      overrides:
        cdp-authservice: myregistry.example.com/cdp/authservice:1.2.3
```

`cdp-cache` has its own key. In v7.8 it shared `rpi-redis`, so overriding the RPI Redis image also changed the Smart Activation cache.

</details>

<details>
<summary><strong style="font-size:1.25em;">Upgrade Checklist</strong></summary>

If your deployment uses any of the following, here is what changed and what to do. Each row lists whether leaving the old setting in place blocks the upgrade.

<table style="width:100%;border-collapse:collapse;table-layout:fixed;line-height:1.4">
<colgroup><col style="width:31%"><col style="width:37%"><col style="width:20%"><col style="width:12%"></colgroup>
<thead>
<tr>
<th align="left">Setting</th>
<th align="left">7.9 change</th>
<th align="left">Action</th>
<th align="left">Breaking</th>
</tr>
</thead>
<tbody>
<tr>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>redpointAI:</code><br><code>&nbsp;&nbsp;enabled</code><br><code>&nbsp;&nbsp;naturalLanguage</code><br><code>&nbsp;&nbsp;cognitiveSearch</code><br><code>&nbsp;&nbsp;modelStorage</code><br><code>&nbsp;&nbsp;logging</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Restructured. Each Redpoint AI capability is now enabled on its own. <code>redpointAI.model</code> holds the model every capability shares, and everything only natural-language rule building uses moved under <code>redpointAI.nlp</code>. See the mapping below</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Rewrite the block using the mapping below</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><strong>Yes</strong> - the chart rejects the old setting and the upgrade will not render</td>
</tr>
<tr style="background:#fafbfc">
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>secretsManagement:</code><br><code>&nbsp;&nbsp;provider: sdk</code><br>(Deployment API database sign-in)</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">The chart no longer tells the Deployment API to sign in with a username and password. Under <code>sdk</code> this is read from the vault entry <code>ClusterEnvironment--OperationalDatabase--ConnectionSettings--IsUsingCredentials</code> (<code>__</code> separators on AWS)</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Add the vault entry: <code>true</code> for a SQL login, <code>false</code> for the managed identity. See <a href="secrets-management.md">Secrets Management</a></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><strong>Yes</strong> - without it, the database upgrade fails to sign in</td>
</tr>
<tr>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>secretsManagement:</code><br><code>&nbsp;&nbsp;provider: sdk</code><br>with <code>smartActivation.enabled</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Smart Activation supports the <code>kubernetes</code> and <code>csi</code> secrets providers only</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Use <code>kubernetes</code> or <code>csi</code>, or disable Smart Activation</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><strong>Yes</strong> - the chart refuses to render</td>
</tr>
<tr style="background:#fafbfc">
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>rebrandly:</code><br><code>&nbsp;&nbsp;enabled: true</code><br>with <code>secretsManagement.provider: sdk</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Rebrandly cannot read a cloud vault. Its API key now comes from the shared Kubernetes Secret in every secrets mode</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Add <code>Rebrandly_ApiKey</code> to the shared Secret</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No - but Rebrandly does not start without it</td>
</tr>
<tr>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>smtp:</code><br><code>&nbsp;&nbsp;hostname</code><br><code>&nbsp;&nbsp;port</code><br><code>&nbsp;&nbsp;username</code><br><code>&nbsp;&nbsp;from_address</code><br><code>&nbsp;&nbsp;from_display_name</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No longer read. Smart Activation takes its mail settings from <code>SMTPSettings</code>, the same as RPI, and always signs in to the mail server</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Set the values in <code>SMTPSettings</code>, make sure <code>SMTP_Password</code> is in the shared Secret, and remove <code>smtp</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No - ignored if left</td>
</tr>
<tr style="background:#fafbfc">
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>keycloak:</code><br><code>&nbsp;&nbsp;hostname</code><br><code>&nbsp;&nbsp;port</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No longer read. Smart Activation services reach Keycloak through its in-cluster service, <code>cdp-keycloak</code>, on that service's port</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Remove them</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No - ignored if left</td>
</tr>
<tr>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>authservice:</code><br><code>&nbsp;&nbsp;resources:</code><br><code>&nbsp;&nbsp;&nbsp;&nbsp;java_options</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No longer read. The Auth Service now uses the documented setting<br><code>authservice:</code><br><code>&nbsp;&nbsp;resources:</code><br><code>&nbsp;&nbsp;&nbsp;&nbsp;java_opts</code><br>like the other Smart Activation services</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Move your value to the new setting and remove the old one</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No - the old setting is ignored</td>
</tr>
<tr style="background:#fafbfc">
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>databases:</code><br><code>&nbsp;&nbsp;operational:</code><br><code>&nbsp;&nbsp;&nbsp;&nbsp;mongodb:</code><br><code>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;database_name</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No longer read by Smart Activation. Every Smart Activation service uses <code>initservice.database.operational.name</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Set <code>initservice.database.operational.name</code> if your database is not named <code>smart_activation_db</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No - ignored if left</td>
</tr>
<tr>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere"><code>OpenIdProviders:</code><br><code>&nbsp;&nbsp;authorizationHost</code><br>with <code>name: keycloak</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Not used for Keycloak. The Interaction API and Integration API sign in through <code>https://&lt;ingress.hosts.smartactivation&gt;.&lt;ingress.domain&gt;/auth/realms/redpoint-mercury</code>. Other providers still use <code>authorizationHost</code></td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">Check that <code>ingress.hosts.smartactivation</code> is the host your users sign in through</td>
<td style="padding:8px 12px;vertical-align:top;border-bottom:1px solid #eaecef;overflow-wrap:anywhere">No - but sign-in fails if the host is wrong</td>
</tr>
</tbody>
</table>

**Redpoint AI mapping**

| 7.8 | 7.9 |
|:---|:---|
| `redpointAI.enabled` | `redpointAI.nlp.enabled` |
| `redpointAI.naturalLanguage.ApiBase` | `redpointAI.model.ApiBase` |
| `redpointAI.naturalLanguage.ApiVersion` | `redpointAI.model.ApiVersion` |
| `redpointAI.naturalLanguage.ChatGptEngine` | `redpointAI.model.ChatGptEngine` |
| `redpointAI.naturalLanguage.ChatGptTemp` | `redpointAI.nlp.ChatGptTemp` |
| `redpointAI.cognitiveSearch.SearchEndpoint` | `redpointAI.nlp.cognitiveSearch.SearchEndpoint` |
| `redpointAI.modelStorage.*` | `redpointAI.nlp.modelStorage.*` |
| `redpointAI.logging.enableTrace` | `redpointAI.nlp.logging.enableTrace` |

The environment the RPI services receive is unchanged, so this is an overrides edit only. Secret keys are unchanged.

1. Resolve the breaking rows from the table above that apply to your deployment.
2. Apply the upgrade with your existing `helm upgrade` command and overrides file.
3. Optionally, complete the non-breaking cleanup from the table above. This can be done before or after the upgrade.

New v7.9 features (the MCP tool server, the agent runtime, Twilio Messaging and common environment variables) are opt-in and default off.

</details>

---

## Next Steps

Use the [Helm Assistant Web UI](https://rpi-helm-assistant.redpointcdp.com) **Reference** and **Chat** tabs to browse configuration and ask questions.

---
<sub>Redpoint Interaction v7.9 | [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) | [Support](mailto:support@redpointglobal.com) | [redpointglobal.com](https://www.redpointglobal.com)</sub>
