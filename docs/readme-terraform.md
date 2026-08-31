# Deploying RPI with Terraform

Manage the RPI Helm release as code with Terraform's Helm provider. Terraform installs and upgrades the chart from a single `helm_release` resource, so your deployment is versioned, reviewable, and repeatable in CI/CD.

## Prerequisites

- Terraform 1.x installed.
- `kubectl` access to the target cluster (a kubeconfig Terraform can read).
- The deployment's **secrets created in the target namespace before you apply**. The chart references application secrets but does not create them. Create them with the RPI Helm CLI (`setup.sh secrets`) or your cloud vault first. See the Secrets Management guide.
- A local copy of the chart so Terraform can reference it by path:
  ```bash
  git clone https://github.com/RedPointGlobal/redpoint-rpi.git
  # check out a release tag for a pinned, reproducible deploy:
  cd redpoint-rpi && git checkout v7.7.0
  ```

## Step 1: Configure the Helm provider

`providers.tf` points the Helm provider at your cluster:

```hcl
terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
    # config_context = "<your-cluster-context>"
  }
}
```

## Step 2: Define the Helm release

`main.tf` installs the chart from your local clone, with the overrides file from the Configure stage:

```hcl
resource "helm_release" "rpi" {
  name             = "rpi"
  namespace        = "redpoint-rpi"
  create_namespace = true

  # Path to the chart directory in your local clone of redpoint-rpi.
  chart = "${path.module}/redpoint-rpi/chart"

  # Your overrides (produced in the Configure stage).
  values = [file("${path.module}/overrides/production.yaml")]

  # Wait for the workloads to become ready before the apply completes.
  wait    = true
  timeout = 600
}
```

## Step 3: Initialize, plan, and apply

```bash
terraform init
terraform plan
terraform apply
```

## Step 4: Verify

```bash
kubectl get pods -n redpoint-rpi
```

The pods should reach `Running`. Terraform records the release in its state, so subsequent applies only roll out what changed.

## Upgrading

1. Pull the new chart version into your clone (`git fetch && git checkout <new-tag>`).
2. Update your overrides if the new version needs them (see the Migration guide).
3. Run `terraform apply` - Terraform diffs the release and rolls out the change.

## Notes

- **Keep secrets out of Terraform and its state.** Create them out-of-band (the RPI Helm CLI or your cloud vault); the `helm_release` only references them, so no credentials live in `.tf` files or state.
- **CI/CD:** run `terraform init` / `apply` in your pipeline with the cluster kubeconfig and any cloud credentials supplied from the pipeline's secret store.
