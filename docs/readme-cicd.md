# CI/CD Pipelines

Automate RPI deployments by running `helm upgrade --install` from your CI/CD pipeline, so every change to your overrides deploys RPI. The same flow works on any runner: GitHub Actions, Azure DevOps, or GitLab CI.

## Supported pipelines

| Tool | Pipeline file |
|:-----|:--------------|
| GitHub Actions | `.github/workflows/rpi-deploy.yml` |
| Azure DevOps | `azure-pipelines.yml` |
| GitLab CI | `.gitlab-ci.yml` |

## What the pipeline does

Each pipeline performs the same four steps:

1. **Checkout** the chart repository (or your internal mirror) and your overrides file.
2. **Authenticate** to your cloud (Azure, AWS, or GCP) and to the cluster.
3. **Helm upgrade/install** with your overrides file.
4. **Verify** the rollout completes and the pods are healthy.

Create the deployment's secrets in the target namespace before the pipeline runs - the chart references application secrets but does not create them. See the Secrets Management guide.

## GitHub Actions

```yaml
name: Deploy RPI
on:
  push:
    paths:
      - "overrides/**"
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: azure/setup-helm@v4
      - name: Authenticate to the cluster
        run: az aks get-credentials --resource-group ${{ vars.RG }} --name ${{ vars.CLUSTER }}
      - name: Deploy
        run: |
          helm upgrade --install rpi ./chart \
            -f overrides/production.yaml \
            -n redpoint-rpi --create-namespace
      - name: Wait for rollout
        run: kubectl rollout status deploy -n redpoint-rpi --timeout=10m
```

## Azure DevOps

```yaml
trigger:
  paths:
    include:
      - overrides/*
pool:
  vmImage: ubuntu-latest
steps:
  - task: HelmInstaller@1
    inputs:
      helmVersionToInstall: latest
  - script: az aks get-credentials --resource-group $(rg) --name $(cluster)
    displayName: Authenticate to the cluster
  - script: |
      helm upgrade --install rpi ./chart \
        -f overrides/production.yaml \
        -n redpoint-rpi --create-namespace
    displayName: Deploy
  - script: kubectl rollout status deploy -n redpoint-rpi --timeout=10m
    displayName: Wait for rollout
```

## GitLab CI

```yaml
deploy:
  image: alpine/helm:latest
  rules:
    - changes:
        - overrides/*
  script:
    - helm upgrade --install rpi ./chart -f overrides/production.yaml -n redpoint-rpi --create-namespace
    - kubectl rollout status deploy -n redpoint-rpi --timeout=10m
```

## Optional: image mirroring

For air-gapped environments or organizations that require all images to come from an internal registry, add a step that mirrors the RPI container images from the Redpoint Container Registry into your own registry before the Helm step, and set `global.deployment.images.registry` in your overrides to that registry.

## Notes

- **Credentials** (cluster kubeconfig, cloud service principal) live in your CI system's secret store, never in the repository.
- **Application secrets** are created out-of-band (the RPI Helm CLI or your cloud vault) before the pipeline runs; the pipeline only installs the chart that references them.
- For a declarative alternative that reconciles continuously instead of running on each commit, see the ArgoCD / GitOps guide.
