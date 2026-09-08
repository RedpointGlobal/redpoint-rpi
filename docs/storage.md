![redpoint_logo](../chart/images/redpoint.png)
# Storage

[< Back to Home](../README.md)

RPI uses file share storage for storing files such as those exported via interactions or selection rules to a File Output directory, custom plugins, or files shared with Redpoint Data Management (RPDM). The execution service also uses this storage as its filesystem based cache provider for persisting execution state. In Azure, AWS, or Google Cloud, this storage is backed by their respective managed file share services such as Azure Files, Amazon EFS, and Google Filestore.

**File share storage is mandatory for a successful deployment.** Without it, file exports and the execution service cache will not function.

You are responsible for provisioning the storage based on your hosting platform's offering. Once the storage has been provisioned, create a PersistentVolumeClaim (PVC) and reference its name in the overrides file.

---

<details>
<summary><strong style="font-size:1.25em;">Provisioning Modes</strong></summary>

The chart supports two approaches for provisioning storage:

| Mode | How it works | Who creates the PV |
|:-----|:-------------|:-------------------|
| **Static** | Your K8s admin pre-creates the PersistentVolume (PV) and PVC outside the chart. You provide the PVC name in the overrides. | K8s admin |
| **Dynamic** | The chart creates a StorageClass. When a PVC is created, the CSI driver auto-provisions the PV and underlying storage (e.g., EFS access point). | CSI driver (automatic) |

### Platform Reference

| Platform | CSI Driver | Dynamic StorageClass Parameters |
|:---------|:-----------|:-------------------------------|
| **AWS** | `efs.csi.aws.com` | `provisioningMode: efs-ap`, `fileSystemId`, `uid: "7777"`, `gid: "7777"` |
| **Azure** | `file.csi.azure.com` | `skuName: Standard_LRS`, `shareName` |
| **Google** | `filestore.csi.storage.gke.io` | `tier: standard`, `network` |

> RPI containers run as UID 7777. For static provisioning, ensure the admin creates access points or file shares with ownership set to UID/GID 7777. For dynamic provisioning, set `uid` and `gid` in the StorageClass parameters.

### Static provisioning

The approach differs by platform:

**AWS / Google:** Your K8s admin pre-creates the PV and PVC. You just reference the PVC name in the overrides:

```yaml
storage:
  persistentVolumeClaims:
    FileOutputDirectory:
      enabled: true
      claimName: pvc-fileoutputdir          # must match the PVC created by your admin
      mountPath: /rpifileoutputdir
```

That's it. The chart mounts the PVC into the pods. No `storageClass` or `persistentVolumes` section needed.

**Azure:** The PV requires CSI driver configuration (storage account, share name, managed identity client ID, etc.) so the chart creates both the PV and PVC via the `persistentVolumes` section:

```yaml
storage:
  persistentVolumeClaims:
    FileOutputDirectory:
      enabled: true
      claimName: pvc-fileoutputdir
      mountPath: /rpifileoutputdir
  persistentVolumes:
  - name: pv-fileoutputdir
    capacity: 10Gi
    accessModes: [ReadWriteMany]
    storageClassName: azurefile-csi
    reclaimPolicy: Retain
    csi:
      driver: file.csi.azure.com
      volumeHandle: <storageaccount>_<sharename>
      volumeAttributes:
        storageaccount: <your-storage-account>
        shareName: <your-file-share>
        clientID: <managed-identity-client-id>
        resourcegroup: <resource-group>
        subscriptionid: <subscription-id>
    pvc:
      claimName: pvc-fileoutputdir
```

> The `persistentVolumes` section can also be used on AWS/Google if you prefer the chart to create the PV instead of the admin doing it manually.

### Dynamic provisioning

The chart creates a StorageClass and PVCs. The CSI driver auto-provisions the PVs:

```yaml
storage:
  storageClass:
    enabled: true
    name: efs-sc
    provisioner: efs.csi.aws.com
    parameters:
      provisioningMode: efs-ap
      fileSystemId: <your-efs-id>
      directoryPerms: "755"
      uid: "7777"
      gid: "7777"
      basePath: /rpi
  persistentVolumeClaims:
    FileOutputDirectory:
      enabled: true
      claimName: pvc-fileoutputdir
      mountPath: /rpifileoutputdir
```

No `persistentVolumes` section needed. The CSI driver creates the PV and access point automatically when the PVC is created.

> For EFS dynamic provisioning, use `uid: "7777"` and `gid: "7777"` to match the UID that RPI containers run as. This ensures the auto-created access points have correct file ownership.

</details>

---

<details>
<summary><strong style="font-size:1.25em;">FileOutputDirectory</strong></summary>

A shared volume mounted by execution service, node manager, and queue reader pods for file based processing output (CSV exports, reports, data imports).

| Platform | Recommended driver |
|:---------|:------------------|
| Azure | `file.csi.azure.com` |
| AWS | `efs.csi.aws.com` |
| Google | `filestore.csi.storage.gke.io` |

### Configuring storage

**New deployment:** Use the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Generate** tab > **Step 5: Storage** to include storage in your initial overrides.

**Existing deployment:** Add the `storage` block to your existing overrides file using the keys from the [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Reference** tab, then run `helm upgrade`.

### Example: AWS EFS

Your K8s admin creates the EFS filesystem, access points, StorageClass, PVs, and PVCs. You reference the PVC claim names in the overrides:

```yaml
storage:
  persistentVolumeClaims:
    FileOutputDirectory:
      enabled: true
      claimName: pvc-fileoutputdir
      mountPath: /rpifileoutputdir
```

> **Need help setting up EFS?** The [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) **Automate** tab > **Amazon** > **Storage Setup (EFS)** generates a ready-to-use script that creates the EFS filesystem, access points with correct UID/GID 7777 ownership, and all the Kubernetes manifests (StorageClass, PVs, PVCs). Download it and repurpose it for your environment.

### Example: Azure Files

```yaml
storage:
  persistentVolumeClaims:
    FileOutputDirectory:
      enabled: true
      claimName: rpifileoutputdir
      mountPath: /rpifileoutputdir
  persistentVolumes:
  - name: pv-rpi-files
    capacity: 10Gi
    accessModes:
    - ReadWriteMany
    storageClassName: azurefile-csi
    reclaimPolicy: Retain
    csi:
      driver: file.csi.azure.com
      volumeHandle: <storageAccount>-<shareName>
      volumeAttributes:
        storageaccount: <your-storage-account>
        shareName: <your-file-share>
        clientID: <managed-identity-client-id>
        resourcegroup: <resource-group>
        subscriptionid: <subscription-id>
    pvc:
      claimName: rpifileoutputdir
```

</details>

<details>
<summary><strong style="font-size:1.25em;">Internal Redis and RabbitMQ</strong></summary>

When `queuereader.realtimeConfiguration.isDistributed: true`, the chart deploys internal Redis and RabbitMQ StatefulSets. These need writable storage. Three options:

<details>
<summary><strong>Dynamic provisioning (recommended for AWS EFS)</strong></summary>

Create a StorageClass that auto-provisions EFS access points with correct permissions:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: sc-rpi-efs
parameters:
  directoryPerms: "755"
  ensureUniqueDirectory: "true"
  fileSystemId: <your-efs-filesystem-id>
  gidRangeStart: "7000"
  gidRangeEnd: "8000"
  provisioningMode: efs-ap
  reuseAccessPoint: "false"
  subPathPattern: ${.PVC.namespace}/${.PVC.name}
provisioner: efs.csi.aws.com
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
```

The GID range `7000-8000` covers UID 7777 used by RPI pods. Each PVC gets its own EFS access point with correct ownership.

In your overrides:

```yaml
queuereader:
  internalCache:
    provider: redis
    type: internal
    redisSettings:
      volumeClaimTemplates:
        enabled: true
        storageClassName: sc-rpi-efs
        storage: 10Gi
  internalQueues:
    provider: rabbitmq
    type: internal
    rabbitmqSettings:
      volumeClaimTemplates:
        enabled: true
        storageClassName: sc-rpi-efs
        storage: 10Gi
```

</details>

<details>
<summary><strong>Static BYO (pre-created PV/PVC)</strong></summary>

When using EFS, Redis and RabbitMQ need EFS access points with POSIX ownership matching UID/GID 7777 (the user RPI pods run as). Create one access point per volume:

```bash
# Redis
aws efs create-access-point \
  --file-system-id <your-efs-id> \
  --posix-user Uid=7777,Gid=7777 \
  --root-directory "Path=/<namespace>/redis,CreationInfo={OwnerUid=7777,OwnerGid=7777,Permissions=755}" \
  --region us-east-1

# RabbitMQ
aws efs create-access-point \
  --file-system-id <your-efs-id> \
  --posix-user Uid=7777,Gid=7777 \
  --root-directory "Path=/<namespace>/rabbitmq,CreationInfo={OwnerUid=7777,OwnerGid=7777,Permissions=755}" \
  --region us-east-1
```

Note the access point IDs from the output (e.g., `fsap-0abc123...`).

Define the PVs in your overrides using the `<efs-id>::<access-point-id>` format for volumeHandle. A simple StorageClass is needed (no dynamic provisioning parameters required for static BYO):

```yaml
storage:
  storageClass:
    enabled: true
    name: my-efs-sc
    provisioner: efs.csi.aws.com
  persistentVolumes:
  - name: pv-redis
    capacity: 10Gi
    accessModes:
    - ReadWriteMany
    storageClassName: my-efs-sc
    reclaimPolicy: Retain
    csi:
      driver: efs.csi.aws.com
      volumeHandle: <efs-id>::<redis-access-point-id>
    pvc:
      claimName: pvc-redis
  - name: pv-rabbitmq
    capacity: 10Gi
    accessModes:
    - ReadWriteMany
    storageClassName: my-efs-sc
    reclaimPolicy: Retain
    csi:
      driver: efs.csi.aws.com
      volumeHandle: <efs-id>::<rabbitmq-access-point-id>
    pvc:
      claimName: pvc-rabbitmq

queuereader:
  internalCache:
    provider: redis
    type: internal
    redisSettings:
      existingClaim: pvc-redis
      volumeClaimTemplates:
        enabled: false
  internalQueues:
    provider: rabbitmq
    type: internal
    rabbitmqSettings:
      existingClaim: pvc-rabbitmq
      volumeClaimTemplates:
        enabled: false
```

The chart creates the PVs and PVCs from the `persistentVolumes` block. The `existingClaim` on the queue reader tells it to use those PVCs instead of dynamic provisioning.

</details>

### Permissions

RPI pods run as UID 7777 / GID 7777 by default. Storage volumes must be writable by this user. Key points:

- **Dynamic provisioning with EFS**: use `provisioningMode: efs-ap` with `gidRangeStart: 7000` / `gidRangeEnd: 8000` to auto-create access points with correct ownership
- **Static BYO with EFS**: create EFS access points with `Uid=7777,Gid=7777`
- **Azure Files**: the managed identity needs `Storage File Data SMB Share Contributor` role

</details>

<details>
<summary><strong style="font-size:1.25em;">StorageClass</strong></summary>

The chart can create a StorageClass resource from your overrides. This is useful when your cluster doesn't already have a StorageClass for your storage driver.

```yaml
storage:
  storageClass:
    enabled: true
    name: sc-rpi-efs
    provisioner: efs.csi.aws.com
```

For dynamic provisioning with EFS access points, add the full parameters:

```yaml
storage:
  storageClass:
    enabled: true
    name: sc-rpi-efs
    provisioner: efs.csi.aws.com
    reclaimPolicy: Retain
    volumeBindingMode: Immediate
    allowVolumeExpansion: true
    parameters:
      directoryPerms: "755"
      ensureUniqueDirectory: "true"
      fileSystemId: <your-efs-filesystem-id>
      gidRangeStart: "7000"
      gidRangeEnd: "8000"
      provisioningMode: efs-ap
      reuseAccessPoint: "false"
      subPathPattern: ${.PVC.namespace}/${.PVC.name}
```

Skip this if your cluster already has a StorageClass you want to use.

</details>

---
<sub>Redpoint Interaction v7.8 | [Helm Assistant](https://rpi-helm-assistant.redpointcdp.com) | [Support](mailto:support@redpointglobal.com) | [redpointglobal.com](https://www.redpointglobal.com)</sub>
