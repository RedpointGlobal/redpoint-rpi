![redpoint_logo](chart/images/redpoint.png)
## Interaction (RPI) | Deployment on Kubernetes

With Redpoint® Interaction you can define your audience and execute highly personalized, cross-channel campaigns – all from a single visual interface. This simplified environment frees you up to create the compelling experiences that will keep your customers actively engaged with your brand.

This chart deploys RPI on Kubernetes using Helm.

![architecture](chart/images/diagram.png)

## Choose Your Path

| | New Installation | Upgrading from v7.7 | AI-Assisted |
|:---|:---|:---|:---|
| **Guide** | [Greenfield Installation](docs/greenfield.md) | [Upgrade Guide](docs/migration.md) | [Helm Assistant](docs/readme-mcp.md) |
| **When to use** | New cluster, databases, cache, and queue providers | Existing v7.7 deployment with existing infrastructure | Any scenario. Validates configs, generates overrides, diagnoses issues, and answers questions in plain English |
| **Databases** | Created from scratch | Existing databases are reused | Generates the correct database configuration for your platform |

---

## Additional Guides

| Guide | Description |
|:------|:------------|
| [Secrets&nbsp;Management](docs/secrets-management.md) | Kubernetes, CSI, and SDK providers |
| [Single Sign-On](docs/single-sign-on.md) | Microsoft Entra ID, Okta, Keycloak |
| [Ingress](docs/ingress.md) | Chart managed nginx, BYO controller, AWS ALB, Azure AGC |
| [Storage](docs/storage.md) | Static and dynamic provisioning - EFS, Azure Files, Filestore |
| [Google&nbsp;Cloud&nbsp;SQL&nbsp;(IAM)](docs/google-cloud-sql-iam.md) | PostgreSQL with passwordless IAM |
| [RPI Helm CLI](docs/readme-cli.md) | Pre-flight checks, secrets generation, deployment, troubleshooting |
| [Custom Plugins](docs/plugins.md) | Realtime API plugins: decision, event, form, visitor profile, geolocation |
| [Redpoint AI](docs/redpoint-ai.md) | Natural-language basic selection rules - Azure OpenAI, AI Search, Blob Storage |
| [Automation](docs/readme-terraform.md) | CI/CD, vault setup, ArgoCD, Flux |

## Resources

- [RPI Product Documentation](https://docs.redpointglobal.com/rpi/)
- [Support](mailto:support@redpointglobal.com) (RPI application issues)
- [www.redpointglobal.com](https://www.redpointglobal.com)

---
<sub>Redpoint Interaction v7.8 | [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) | [Support](mailto:support@redpointglobal.com) | [redpointglobal.com](https://www.redpointglobal.com)</sub>
