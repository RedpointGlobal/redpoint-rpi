![redpoint_logo](../chart/images/redpoint.png)
# Single Sign-On (SSO)

[< Back to Home](../README.md)

RPI supports single sign-on through two authentication methods:

- **Microsoft Entra ID** (formerly Azure AD): recommended for Azure customers. Native integration with Microsoft identity for secure access and single sign-on.
- **OpenID Connect (OIDC)**: for organizations using an external identity provider such as Keycloak or Okta.

For a full reference of all configurable keys, see the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Reference** tab.

---

<details>
<summary><strong style="font-size:1.25em;">Microsoft Entra ID</strong></summary>

### Prerequisites

Before enabling Entra ID in the Helm chart, you need to register two applications in Microsoft Entra ID. You can do this via the **Azure CLI** (recommended) or manually through the **Azure Portal**.

### Option A: Azure CLI (Recommended)

Use the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Automate** tab > **Entra ID Setup** to generate and download a setup script. The script creates both app registrations using the Azure CLI and outputs the exact Helm values at the end.

### Option B: Azure Portal

#### 1. Register the Interaction Client

1. In the Azure Portal, navigate to **Microsoft Entra ID** > **App registrations**
2. Click **New registration**
3. Name the app `interaction-client` and note the **Client ID** and **Tenant ID**
4. Go to the **Authentication** section
5. Under **Redirect URIs**, add a new entry of type **Mobile & Desktop** with the value:
   ```
   ms-appx-web://Microsoft.AAD.BrokerPlugin/{Client ID}
   ```
   Replace `{Client ID}` with the Application ID from the `interaction-client` app registration.

#### 2. Register the Interaction API

1. Create another **New registration**
2. Name the app `interaction-api` and note the **Client ID** and **Tenant ID**
3. Select **Add Application ID URI**, then create a custom scope named `Interaction.Clients`:
   - **Name/Description:** Access RPI
   - **Who can consent:** Admins and users
4. Under **Authorized client applications**, add the Interaction Client's **Client ID**

### Generate Your Overrides

Once you have the Client ID, API ID, and Tenant ID from either method above, go to the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Generate** tab > **Step 8: Services** > **Microsoft Entra ID** and enter these values. They will be included in your generated `overrides.yaml` automatically.

> **Important:** Complete the Entra ID app registrations **before** generating your overrides so you have the required IDs ready.

> **Note:** To sign in with Microsoft Entra ID, each RPI user account must use the same email address as their Entra ID username (e.g., `first.last@example.com`).

For all available `MicrosoftEntraID` configuration keys, see the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Reference** tab.


</details>

<details>
<summary><strong style="font-size:1.25em;">OpenID Connect (OIDC)</strong></summary>

RPI supports any OpenID Connect-compliant identity provider. The chart includes built-in templates for **Keycloak** and **Okta**.

### Prerequisites

Before generating your overrides, set up your OIDC provider and gather the following values:

| Value | Where to find it |
|-------|-----------------|
| **Authorization Host** | Keycloak: `https://<host>/realms/<realm>`. Okta: `https://<domain>/oauth2/default` |
| **Client ID** | The application/client ID from your identity provider's app registration |
| **Audience** | Usually the same as Client ID (Keycloak) or `api://<client-id>` (Okta) |
| **Redirect URL** | Your RPI Interaction API URL, e.g. `https://rpi-interactionapi.example.com` |
| **Custom Scopes** | Keycloak: `openid`, `profile`. Okta: `api://<client-id>/Interaction.Clients` |

> **Important:** Complete your identity provider setup so you have the required values ready before configuring the chart.

### Add to Your Overrides

**New deployment:** Use the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Generate** tab > **Step 8: Services** > **OpenID Connect** to include SSO in your initial overrides.

**Existing deployment:** Add the `openIdProviders` block to your existing overrides file and run `helm upgrade`. No need to regenerate the full file. Use the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Reference** tab to find the available `openIdProviders` keys and copy them into your overrides.

```yaml
# Add to your existing overrides file
interactionapi:
  openIdProviders:
    - name: <your-provider-name>
      authority: <your-authority-url>
      clientId: <your-client-id>
      scopes: openid profile email
```

Then apply:

```bash
helm upgrade redpoint-rpi ./chart -f overrides.yaml -n redpoint-rpi
```


</details>

<details>
<summary><strong style="font-size:1.25em;">Observability</strong></summary>

Observability supports two authentication modes:

- **Anonymous** (default): no login, no authentication middleware. Suitable for development, demos, labs, and deployments that do not require authentication.
- **RPI Authentication**: Observability participates in the authentication model your RPI deployment already uses. If RPI is configured for Microsoft Entra ID, Observability signs users in with Entra ID. If RPI uses Okta or Keycloak, Observability uses that provider. There is nothing to configure twice: no tenant IDs, authority URLs, or provider settings are re-entered for Observability. If RPI has no identity provider configured, Observability runs anonymous.

### Enable RPI Authentication

```yaml
observability:
  authentication:
    enabled: true
```

Then complete one identity-provider-side step: add Observability's redirect URI to the **existing** RPI client registration (all supported providers accept multiple redirect URIs on one registration; do not create a second registration):

```
https://<observability host>/auth/callback
```

| Provider | Where to add it |
|-------|-----------------|
| **Microsoft Entra ID** | On the `interaction-client` app registration > **Authentication** > **Mobile and desktop applications** platform. Do not add it under the Web platform (requires a client secret) or the Single-page application platform (cannot be redeemed by Observability's backend). |
| **Okta** | On the RPI app integration > **Sign-in redirect URIs**. |
| **Keycloak** | On the RPI client > **Valid redirect URIs**. |

There is no login page. An unauthenticated visit to Observability redirects to your identity provider and returns signed in. Signed-in users are matched to RPI user accounts; authorization (which dashboards and diagnostics a user may access) is resolved through RPI's user groups and the `observability.authentication.capabilityMap` overlay.

### Confidential client registrations

RPI's provider registrations are public clients, so no client secret is needed. Some organizations register confidential OIDC clients. In those environments, Observability supports an optional Kubernetes Secret key containing the existing client secret. This reuses your existing application registration rather than creating a second one. Add the key `OIDC_Client_Secret` to the chart's standard RPI Secret (default `redpoint-rpi-secrets`) with the registration's existing client secret as the value.

</details>


---
<sub>Redpoint Interaction v7.7 | [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) | [Support](mailto:support@redpointglobal.com) | [redpointglobal.com](https://www.redpointglobal.com)</sub>
