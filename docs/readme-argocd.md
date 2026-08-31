# Deploying RPI with ArgoCD

This is the recommended GitOps setup for RPI: a single ArgoCD Application that renders the chart and continuously reconciles your cluster to match Git. You host the chart and your overrides together in one repository, so the Application has a single source.

## Prerequisites

- ArgoCD installed in the cluster (namespace `argocd`) with the `argocd` CLI or UI available.
- Cluster access for ArgoCD to your target namespace.
- The deployment's **secrets created in the target namespace before the first sync**. ArgoCD renders the chart but does not create application secrets. The chart only references them. Create them with the RPI Helm CLI (`setup.sh secrets`) or your cloud vault first. See the Secrets Management guide.

## Step 1: Set up your repository

Mirror the RPI chart repository into your own Git server, then add your overrides alongside the chart. The repository keeps this structure:

```
redpoint-rpi/                  (your mirror)
├── chart/                     <- the chart: Chart.yaml, templates/, values.yaml
└── deploy/
    └── values/
        └── production.yaml     <- your overrides (from the Configure stage)
```

Mirror the chart once:

```bash
git clone --mirror https://github.com/RedPointGlobal/redpoint-rpi.git
cd redpoint-rpi.git
git remote set-url origin https://git.yourorg.com/platform/redpoint-rpi.git
git push --mirror
```

Then commit your overrides to `deploy/values/production.yaml` in that repository.

## Step 2: Create the ArgoCD Application

One Application, one source: it points at your repository, renders the chart at `chart/`, and applies your overrides from `deploy/values/`. Automated sync keeps the cluster reconciled; Secrets are excluded from diffs so they don't show as out-of-sync.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rpi
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://git.yourorg.com/platform/redpoint-rpi.git
    targetRevision: main           # pin to a release tag (e.g. v7.7.0) in production
    path: chart
    helm:
      valueFiles:
        - ../deploy/values/production.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: redpoint-rpi
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
  ignoreDifferences:
    - group: ""
      kind: Secret
      jsonPointers:
        - /data
```

Save it as `rpi-application.yaml`. The `valueFiles` path is relative to the chart directory: `../` steps up to the repo root, then into `deploy/values/`.

## Step 3: Apply and sync

```bash
kubectl apply -f rpi-application.yaml -n argocd
argocd app sync rpi
```

With `automated` sync enabled, ArgoCD also reconciles on every commit to the repository.

## Step 4: Verify

```bash
argocd app get rpi
kubectl get pods -n redpoint-rpi
```

The Application should report `Synced` and `Healthy`, and the RPI pods should reach `Running`.

## Upgrading

1. Pull the new chart version into your mirror:
   ```bash
   git remote add upstream https://github.com/RedPointGlobal/redpoint-rpi.git
   git fetch upstream
   git push origin --tags
   ```
2. Update your overrides if the new version needs them (see the Migration guide).
3. Bump `targetRevision` to the new release tag and commit.

ArgoCD detects the change and reconciles. To promote deliberately, review `argocd app diff rpi`, then `argocd app sync rpi`.

## Troubleshooting

- **`helm template failed` on sync:** ensure `path` is `chart` (where `Chart.yaml` lives), not the repo root.
- **Values file not found:** the `valueFiles` path is relative to the chart directory. `../deploy/values/production.yaml` steps up to the repo root, then into `deploy/values/`.
- **Pods fail to start / `CreateContainerConfigError`:** the namespace is missing the secrets the chart references. Create them (see Prerequisites) before syncing.
- **Secrets show as out-of-sync every cycle:** confirm the `ignoreDifferences` block for `Secret` is present.
