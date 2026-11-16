![redpoint_logo](../chart/images/redpoint.png)
# Twilio Messaging

[< Back to Home](../README.md)

**Twilio Messaging** sends and receives RPI SMS through Twilio. It is off by default and runs in the RPI namespace.

A Kubernetes administrator deploys the service. A network administrator publishes its webhook so Twilio can reach it. RPI administrators then set the webhook addresses in Twilio.

---

<details>
<summary><strong style="font-size:1.25em;">Deploy the service (Kubernetes administrators)</strong></summary>

### 1. Have these ready

| Item | Notes |
|---|---|
| Twilio account | The account SID and auth token |
| PostgreSQL | The operational server when it is PostgreSQL, or a separate server from the one hosting the operational databases. SQL Server is not supported. With `sdk` secrets, use a separate server. Run the installer's `bootstrap` command once per environment to create the database and role |
| Messaging | Azure Event Hubs, AWS SQS and SNS, or GCP Pub/Sub. Names are in the [values reference](values_reference.yaml). On AWS, subscribe each queue to its topic with raw message delivery on |
| Identity | `cloudIdentity.enabled: true`. Grant this service and the Execution Service read and write on the transport. With `sdk` secrets, also let this service read its secret in the vault |

On AKS, add a federated credential for the `rpi-twiliomessaging` service account. The installer uses the same one. A new credential takes a few minutes to work.

### 2. Enable the service

Add this to your overrides, then fill in the block for your transport: `eventHubs`, `sqs` or `pubsub`.

```yaml
twiliomessaging:
  enabled: true
  accountSid: <twilio-account-sid>
  messaging:
    provider: <azureeventhubs | amazonsqs | googlepubsub>

ingress:
  hosts:
    twiliomessaging: <webhook-host>
```

With a PostgreSQL server separate from the one hosting the operational databases, also set `postgres.reuseOperational: false`, `postgres.host` and `postgres.username`. With your own Redis, set `redisSettings.type: external` and `redisSettings.hostname`.

### 3. Add the secrets

With `kubernetes` or `csi` secrets, add these keys to the standard RPI Secret. See [Secrets Management](secrets-management.md).

| Key | Value |
|---|---|
| `TwilioMessaging_AuthToken` | The Twilio auth token |
| `TwilioMessaging_Postgres_Password` | The PostgreSQL password, when the database is on a separate server from the one hosting the operational databases |
| `TwilioMessaging_Redis_Password` | The Redis password, when you use your own Redis |

With `sdk` secrets, add the auth token to the vault instead. PostgreSQL and your own Redis sign in with the pod's identity. On AWS ElastiCache, also set the `redisSettings` fields the [values reference](values_reference.yaml) lists for it.

| Vault secret | Value |
|---|---|
| `Twilio--Client--AuthToken` | The Twilio auth token. On AWS Secrets Manager, `Twilio__Client__AuthToken` |

The secret is read when the pod starts. Restart `rpi-twiliomessaging` after changing it.

### 4. Hand over

```bash
kubectl get ingress redpoint-rpi -n <namespace> \
  -o jsonpath='{range .spec.rules[*]}{.host}{"\n"}{end}' | grep twilio
```

Give the network administrator the webhook host from the command above and the internal load balancer in front of the ingress controller.

Give the RPI administrators these addresses to set in Twilio:

- `https://<webhook-host>/api/v1/webhook/status`
- `https://<webhook-host>/api/v1/webhook/inbound`
- `https://<webhook-host>/api/v1/webhook/link-click`

**Troubleshooting**

| Symptom | Fix |
|---|---|
| `helm upgrade` fails naming a value | Set the value named in the message |
| With `sdk` secrets the pod exits with `Value cannot be null. (Parameter 'name')` | The image is too old to read the vault. Use a current Twilio Messaging image |
| `ClientAssertionCredential authentication failed` or `AADSTS700213` | Add a federated credential for `rpi-twiliomessaging`. Wait a few minutes, then restart |
| The pod never becomes ready on AWS | A queue is set as an ARN. Use the queue URL |
| The pod logs an authorization error on a topic or queue | Grant the identity access to the resource named in the log |
| The pod stays not ready after an upgrade | Read the `rpi-twiliomessaging-installer` Job log |

</details>

<details>
<summary><strong style="font-size:1.25em;">Publish the webhook (network administrators)</strong></summary>

The ingress stays internal. Put a public edge in front of it that passes only `/api/v1/webhook` and blocks everything else. The edge must send the original host name to the ingress, or Twilio's signature check fails.

You need the webhook host and the internal load balancer from the Kubernetes administrator, and a certificate for the webhook host.

<details>
<summary><strong>AWS: CloudFront</strong></summary>

1. Create a CloudFront VPC origin for the internal load balancer, HTTPS on 443. The load balancer's security group must allow 443 from inside the VPC.
2. Import the certificate into ACM in `us-east-1`.
3. Create a distribution with the webhook host as its alternate domain name.
   - Add a behavior for `/api/v1/webhook*` to the VPC origin, with caching off, all methods allowed and all viewer headers forwarded.
   - Point the default behavior at the same origin, with a CloudFront Function that returns 403.
4. Point the webhook host's public DNS record at the distribution.

</details>

<details>
<summary><strong>Azure: Front Door</strong></summary>

1. Create a Front Door Premium profile.
2. Add the internal load balancer as an origin over Private Link, HTTPS on 443, with the webhook host as the origin host header. Approve the private endpoint connection on the load balancer's Private Link service.
3. Add the webhook host as a custom domain with its certificate.
4. Add a route for `/api/v1/webhook/*` to that origin, with caching off. Front Door rejects any path without a route.
5. Point the webhook host's public DNS record at the Front Door endpoint.

</details>

### Check it

```bash
curl -si -X POST https://<webhook-host>/api/v1/webhook/status | head -1
curl -si https://<webhook-host>/ | head -1
```

The first call returns 400 to 403 from the service, because the request is unsigned. The second is blocked: 403 on CloudFront, 404 on Front Door. When both look right, tell the RPI administrators the webhook is live.

**Troubleshooting**

| Symptom | Fix |
|---|---|
| 502 | The certificate on the ingress does not cover the webhook host |
| 504 | The edge cannot reach the load balancer. Check the security group on AWS, or the Private Link approval on Azure |
| 404 on `/api/v1/webhook` alone | Expected. Use the full addresses ending in `/status`, `/inbound` or `/link-click` |
| Twilio reports signature failures | The edge rewrites the host name. Forward the original host |

</details>
