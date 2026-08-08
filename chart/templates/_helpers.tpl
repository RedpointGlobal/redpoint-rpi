{{/*
Expand the name of the chart.
*/}}
{{- define "redpoint-rpi.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "redpoint-rpi.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "redpoint-rpi.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redpoint-rpi.labels" -}}
helm.sh/chart: {{ include "redpoint-rpi.chart" . }}
{{ include "redpoint-rpi.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.global.deployment.images.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: rpi
{{- end }}

{{/*
Selector labels.

Contract:
  required:
    .root  -- chart root context (for Release.Name)
    .name  -- service identifier emitted as app.kubernetes.io/name
*/}}
{{- define "redpoint-rpi.selectorLabels" -}}
{{- $root := required "redpoint-rpi.selectorLabels: .root is required" .root -}}
{{- $name := required "redpoint-rpi.selectorLabels: .name is required" .name -}}
app.kubernetes.io/name: {{ $name }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
{{- end }}

{{/*
Common component labels for an RPI resource.
Usage: {{ include "redpoint-rpi.componentLabels" (dict "root" . "name" $name "component" "api") }}

Contract:
  required:
    .root       -- chart root context
    .component  -- component label (e.g. "api", "worker", "intelligence",
                   "observability", "database", "messaging", "storage",
                   "networkutils", "controller", "node-provisioning",
                   "observability-api", "datawarehouse"). Identifier
                   label; missing values silently drift in Argo CD
                   because the API server strips empty-string labels.
  optional:
    .name       -- service identifier. Defaults to the chart's
                   fullname when omitted (only the root chart itself
                   uses the default; per-service templates always
                   pass .name).
*/}}
{{- define "redpoint-rpi.componentLabels" -}}
{{- $root := required "redpoint-rpi.componentLabels: .root is required" .root -}}
{{- $component := required "redpoint-rpi.componentLabels: .component is required" .component -}}
app.kubernetes.io/name: {{ .name | default (include "redpoint-rpi.fullname" $root) }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/part-of: rpi
app.kubernetes.io/component: {{ $component }}
{{- end }}

{{/*
Common component labels for a Smart Activation resource.
Usage: {{ include "smartactivation.componentLabels" (dict "root" . "name" $name) }}

Contract:
  required:
    .root  -- chart root context
  optional:
    .name  -- service identifier. Defaults to the chart's fullname.
*/}}
{{- define "smartactivation.componentLabels" -}}
{{- $root := required "smartactivation.componentLabels: .root is required" .root -}}
app.kubernetes.io/name: {{ .name | default (include "redpoint-rpi.fullname" $root) }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/part-of: smartactivation
{{- end }}

{{/*
Pod-level security context.
Usage: {{- include "rpi.pod.securityContext" (dict "sc" $secCtx) | nindent 6 }}

Contract:
  required:
    .sc  -- merged security context dict from rpi.merged.securityContext
  optional:
    .noFsGroup            -- bool. When true, suppress the fsGroup field
                             (used by services that mount volumes which
                             must not inherit a group ownership change,
                             e.g. RabbitMQ StatefulSets on the rabbit
                             image's reserved UID).
    .noSupplementalGroups -- bool. When true, suppress supplementalGroups.
*/}}
{{- define "rpi.pod.securityContext" -}}
{{- $sc := required "rpi.pod.securityContext: .sc is required" .sc -}}
{{- if $sc.enabled -}}
securityContext:
  runAsUser: {{ $sc.runAsUser }}
  runAsGroup: {{ $sc.runAsGroup }}
  {{- if not .noFsGroup }}
  fsGroup: {{ $sc.fsGroup }}
  {{- end }}
  runAsNonRoot: {{ $sc.runAsNonRoot }}
  {{- if not .noSupplementalGroups }}
  {{- with $sc.supplementalGroups }}
  supplementalGroups:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- end }}
{{- end }}
{{- end -}}

{{/*
Container-level security context.
Usage: {{- include "rpi.container.securityContext" (dict "sc" $secCtx) | nindent 8 }}

Contract:
  required:
    .sc  -- merged security context dict from rpi.merged.securityContext
*/}}
{{- define "rpi.container.securityContext" -}}
{{- $sc := required "rpi.container.securityContext: .sc is required" .sc -}}
{{- if $sc.enabled -}}
securityContext:
  privileged: {{ $sc.privileged }}
  allowPrivilegeEscalation: {{ $sc.allowPrivilegeEscalation }}
  readOnlyRootFilesystem: {{ $sc.readOnlyRootFilesystem }}
  {{- if $sc.appArmorProfile }}
  appArmorProfile:
    type: {{ $sc.appArmorProfile }}
  {{- end }}
  capabilities:
    drop:
    {{- range $sc.capabilities.drop }}
      - {{ . }}
    {{- end }}
{{- end }}
{{- end -}}

{{/*
Topology spread constraints.
Usage: {{ include "redpoint-rpi.topologySpreadConstraints" (dict "root" . "name" "rpi-realtimeapi") }}

Contract:
  required:
    .root  -- chart root context (for the merged topologySpreadConstraints)
    .name  -- service identifier emitted in the matchLabels selector
*/}}
{{- define "redpoint-rpi.topologySpreadConstraints" -}}
{{- $root := required "redpoint-rpi.topologySpreadConstraints: .root is required" .root -}}
{{- $name := required "redpoint-rpi.topologySpreadConstraints: .name is required" .name -}}
{{- $tsc := fromYaml (include "rpi.merged.topologySpreadConstraints" $root) -}}
{{- if $tsc.enabled }}
topologySpreadConstraints:
  - maxSkew: {{ $tsc.maxSkew | default 1 }}
    topologyKey: {{ $tsc.topologyKey | default "topology.kubernetes.io/zone" }}
    whenUnsatisfiable: {{ $tsc.whenUnsatisfiable | default "ScheduleAnyway" }}
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: {{ $name }}
{{- end }}
{{- end }}

{{/*
PreStop lifecycle hook for graceful shutdown
*/}}
{{- define "redpoint-rpi.preStopHook" -}}
lifecycle:
  preStop:
    exec:
      command: ["/bin/sh", "-c", "sleep 10"]
{{- end }}

{{/*
Container probes (liveness, readiness, startup) from merged config.
Usage: {{- include "rpi.block.probes" (dict "liveness" $liveness "readiness" $readiness "startup" $startup "enabled" true) | nindent 8 }}

Contract:
  required:
    .liveness   -- merged liveness probe dict from rpi.merged.livenessProbe
    .readiness  -- merged readiness probe dict from rpi.merged.readinessProbe
    .startup    -- merged startup probe dict from rpi.merged.startupProbe
  optional:
    .enabled    -- bool. When omitted or true, render the probe block.
                   Pass false to suppress all probes for a service
                   (e.g. deploymentapi.enableProbes: false).
*/}}
{{- define "rpi.block.probes" -}}
{{- $_ := required "rpi.block.probes: .liveness is required"  .liveness  -}}
{{- $_ := required "rpi.block.probes: .readiness is required" .readiness -}}
{{- $_ := required "rpi.block.probes: .startup is required"   .startup   -}}
{{- $probesEnabled := true -}}
{{- if hasKey . "enabled" -}}
  {{- if not (kindIs "invalid" .enabled) -}}
    {{- $probesEnabled = not (eq (toString .enabled) "false") -}}
  {{- end -}}
{{- end -}}
{{- if $probesEnabled }}
{{- if .liveness.enabled }}
livenessProbe:
  httpGet:
    path: {{ .liveness.httpGet.path }}
    port: {{ .liveness.httpGet.port }}
    scheme: {{ .liveness.httpGet.scheme }}
  initialDelaySeconds: {{ .liveness.initialDelaySeconds }}
  periodSeconds: {{ .liveness.periodSeconds }}
  timeoutSeconds: {{ .liveness.timeoutSeconds }}
  failureThreshold: {{ .liveness.failureThreshold }}
{{- end }}
{{- if .readiness.enabled }}
readinessProbe:
  httpGet:
    path: {{ .readiness.httpGet.path }}
    port: {{ .readiness.httpGet.port }}
    scheme: {{ .readiness.httpGet.scheme }}
  initialDelaySeconds: {{ .readiness.initialDelaySeconds }}
  periodSeconds: {{ .readiness.periodSeconds }}
  failureThreshold: {{ .readiness.failureThreshold }}
  timeoutSeconds: {{ .readiness.timeoutSeconds }}
{{- end }}
{{- if .startup.enabled }}
startupProbe:
  httpGet:
    path: {{ .startup.httpGet.path }}
    port: {{ .startup.httpGet.port }}
    scheme: {{ .startup.httpGet.scheme }}
  failureThreshold: {{ .startup.failureThreshold }}
  periodSeconds: {{ .startup.periodSeconds }}
  initialDelaySeconds: {{ .startup.initialDelaySeconds }}
  timeoutSeconds: {{ .startup.timeoutSeconds }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Image pull secrets
*/}}
{{- define "redpoint-rpi.imagePullSecrets" -}}
{{- if .Values.global.deployment.images.imagePullSecret.enabled }}
imagePullSecrets:
  - name: {{ .Values.global.deployment.images.imagePullSecret.name }}
{{- end }}
{{- end }}

{{/*
Node selector
*/}}
{{- define "redpoint-rpi.nodeSelector" -}}
{{- if .Values.nodeSelector.enabled }}
nodeSelector:
  {{ .Values.nodeSelector.key }}: {{ .Values.nodeSelector.value }}
{{- end }}
{{- end }}

{{/*
Tolerations
*/}}
{{- define "redpoint-rpi.tolerations" -}}
{{- if .Values.tolerations.enabled }}
tolerations:
  - effect: {{ .Values.tolerations.effect }}
    key: {{ .Values.tolerations.key }}
    operator: {{ .Values.tolerations.operator }}
    value: {{ .Values.tolerations.value }}
{{- end }}
{{- end }}

{{/* DatawarehouseProviders */}}
{{- define "redpoint.DatawarehouseProviders" -}}
{{- $dw := .Values.databases.datawarehouse | default dict -}}
{{- $bigquery := $dw.bigquery | default dict -}}

{{- if ($bigquery.enabled | default false) -}}
true
{{- else -}}
false
{{- end -}}
{{- end }}

{{/* ============================================================
     MERGE HELPERS
     ============================================================
     Each helper merges: defaults + user values (user wins).
     Usage in templates:
       {{- $cfg := fromYaml (include "rpi.merged.service" (dict "root" . "name" "realtimeapi")) -}}
     ============================================================ */}}

{{/* --- Component merge helpers ---
     Merge order: service defaults → global resources → per-service user values.
     Global .Values.resources sets a baseline for all services.
     Per-service overrides (e.g. .Values.interactionapi.resources) win.
*/}}

{{/*
Resolve a service's merged config: per-service defaults from _defaults.tpl,
overlaid with chart-wide resources, overlaid with operator overrides.
Usage: {{- $cfg := fromYaml (include "rpi.merged.service" (dict "root" . "name" "realtimeapi")) -}}

Contract:
  required:
    .root  -- chart root context
    .name  -- service key (matches a top-level .Values.<name> block and a
              "rpi.defaults.<name>" defines block in _defaults.tpl)
*/}}
{{- define "rpi.merged.service" -}}
{{- $root := required "rpi.merged.service: .root is required" .root -}}
{{- $name := required "rpi.merged.service: .name is required" .name -}}
{{- $d := fromYaml (include (printf "rpi.defaults.%s" $name) $root) -}}
{{- $g := $root.Values.resources | default dict -}}
{{- if $g -}}
{{- $_ := set $d "resources" (mustMergeOverwrite ($d.resources | default dict) $g) -}}
{{- end -}}
{{- $u := index $root.Values $name | default dict -}}
{{- toYaml (mustMergeOverwrite $d $u) -}}
{{- end -}}

{{/* --- Shared resource blocks (reduces duplication across deploy-*.yaml files) --- */}}

{{/*
ServiceAccount block for per-service mode. Renders nothing when the
chart is in shared-SA mode or when the service / SA is disabled.
Usage: {{- include "rpi.block.serviceAccount" (dict "root" . "name" $name "component" "api" "cfg" $cfg) }}

Contract:
  required:
    .root       -- chart root context
    .name       -- ServiceAccount metadata.name
    .component  -- component label propagated to componentLabels
                   (empty values silently drift in Argo CD because the
                   Kubernetes API server strips empty-string labels)
    .cfg        -- merged service config dict (provides .serviceAccount.enabled,
                   .enabled)
*/}}
{{- define "rpi.block.serviceAccount" -}}
{{- $root := required "rpi.block.serviceAccount: .root is required" .root -}}
{{- $name := required "rpi.block.serviceAccount: .name is required" .name -}}
{{- $component := required "rpi.block.serviceAccount: .component is required" .component -}}
{{- $cfg := required "rpi.block.serviceAccount: .cfg is required" .cfg -}}
{{- if $cfg.serviceAccount.enabled }}
{{- if $cfg.enabled }}
{{- if ne ($root.Values.cloudIdentity.serviceAccount.mode | default "per-service") "shared" }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $name }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "redpoint-rpi.componentLabels" (dict "root" $root "name" $name "component" $component) | nindent 4 }}
  {{- $saAnnotations := include "rpi.mergedAnnotations" (dict "root" $root "type" "serviceAccount") | trim }}
  {{- $ciAnnotations := include "rpi.cloudidentity.saAnnotations" (dict "root" $root) | trim }}
  {{- if or $saAnnotations $ciAnnotations }}
  annotations:
    {{- if $saAnnotations }}
    {{- $saAnnotations | nindent 4 }}
    {{- end }}
    {{- if $ciAnnotations }}
    {{- $ciAnnotations | nindent 4 }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
PodDisruptionBudget block.
Usage: {{- include "rpi.block.pdb" (dict "root" . "name" $name "component" "api" "cfg" $cfg) }}

Contract:
  required:
    .root       -- chart root context
    .name       -- PDB metadata.name + selector matchLabels identifier
    .component  -- component label propagated to componentLabels
    .cfg        -- merged service config dict (provides
                   .podDisruptionBudget.enabled, .podDisruptionBudget.maxUnavailable)
*/}}
{{- define "rpi.block.pdb" -}}
{{- $root := required "rpi.block.pdb: .root is required" .root -}}
{{- $name := required "rpi.block.pdb: .name is required" .name -}}
{{- $component := required "rpi.block.pdb: .component is required" .component -}}
{{- $cfg := required "rpi.block.pdb: .cfg is required" .cfg -}}
{{- if $cfg.podDisruptionBudget.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ $name }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "redpoint-rpi.componentLabels" (dict "root" $root "name" $name "component" $component) | nindent 4 }}
spec:
  maxUnavailable: {{ $cfg.podDisruptionBudget.maxUnavailable }}
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ $name }}
{{- end }}
{{- end -}}

{{/*
Pod scheduling block: nodeSelector, tolerations, anti-affinity, topology spread.
Usage: {{- include "rpi.block.scheduling" (dict "root" . "name" $name "topo" $topo) | nindent 6 }}

Contract:
  required:
    .root  -- chart root context (provides .Values.nodeSelector,
              .Values.tolerations, .Values.podAntiAffinity)
    .name  -- service identifier emitted in pod-anti-affinity +
              topology-spread matchLabels selectors
    .topo  -- merged topologySpreadConstraints dict
*/}}
{{- define "rpi.block.scheduling" -}}
{{- $root := required "rpi.block.scheduling: .root is required" .root -}}
{{- $name := required "rpi.block.scheduling: .name is required" .name -}}
{{- $topo := required "rpi.block.scheduling: .topo is required" .topo -}}
{{- if $root.Values.nodeSelector.enabled }}
nodeSelector:
  {{ $root.Values.nodeSelector.key }}: {{ $root.Values.nodeSelector.value }}
{{- end }}
{{- if $root.Values.tolerations.enabled }}
tolerations:
  - effect: NoSchedule
    key: {{ $root.Values.nodeSelector.key }}
    operator: Equal
    value: {{ $root.Values.nodeSelector.value }}
{{- end }}
{{- if $root.Values.podAntiAffinity.enabled }}
affinity:
  podAntiAffinity:
    {{- if eq $root.Values.podAntiAffinity.type "preferred" }}
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: {{ $root.Values.podAntiAffinity.weight | default 100 }}
      podAffinityTerm:
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: {{ $name }}
        topologyKey: {{ $root.Values.podAntiAffinity.topologyKey | default "kubernetes.io/hostname" }}
    {{- else }}
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          app.kubernetes.io/name: {{ $name }}
      topologyKey: {{ $root.Values.podAntiAffinity.topologyKey | default "kubernetes.io/hostname" }}
    {{- end }}
{{- end }}
{{- if $topo.enabled }}
topologySpreadConstraints:
- maxSkew: {{ $topo.maxSkew | default 1 }}
  topologyKey: {{ $topo.topologyKey | default "kubernetes.io/hostname" }}
  whenUnsatisfiable: {{ $topo.whenUnsatisfiable | default "ScheduleAnyway" }}
  labelSelector:
    matchLabels:
      app.kubernetes.io/name: {{ $name }}
{{- end }}
{{- end -}}

{{/* --- Cross-cutting merge helpers --- */}}

{{- define "rpi.merged.securityContext" -}}
{{- $d := fromYaml (include "rpi.defaults.securityContext" .) -}}
{{- $u := .Values.securityContext | default dict -}}
{{- toYaml (mustMergeOverwrite $d $u) -}}
{{- end -}}

{{- define "rpi.merged.livenessProbe" -}}
{{- $d := fromYaml (include "rpi.defaults.livenessProbe" .) -}}
{{- $u := .Values.livenessProbe | default dict -}}
{{- toYaml (mustMergeOverwrite $d $u) -}}
{{- end -}}

{{- define "rpi.merged.readinessProbe" -}}
{{- $d := fromYaml (include "rpi.defaults.readinessProbe" .) -}}
{{- $u := .Values.readinessProbe | default dict -}}
{{- toYaml (mustMergeOverwrite $d $u) -}}
{{- end -}}

{{- define "rpi.merged.startupProbe" -}}
{{- $d := fromYaml (include "rpi.defaults.startupProbe" .) -}}
{{- $u := .Values.startupProbe | default dict -}}
{{- toYaml (mustMergeOverwrite $d $u) -}}
{{- end -}}

{{- define "rpi.merged.topologySpreadConstraints" -}}
{{- $d := fromYaml (include "rpi.defaults.topologySpreadConstraints" .) -}}
{{- $u := .Values.topologySpreadConstraints | default dict -}}
{{- toYaml (mustMergeOverwrite $d $u) -}}
{{- end -}}

{{- define "rpi.merged.ingress" -}}
{{- $d := fromYaml (include "rpi.defaults.ingress" .) -}}
{{- $u := .Values.ingress | default dict -}}
{{- toYaml (mustMergeOverwrite $d $u) -}}
{{- end -}}

{{/*
Resolve ingress annotations. If the user sets ingress.annotations, those
are used as-is (full replacement). Otherwise returns sensible defaults.
*/}}
{{- define "rpi.ingress.annotations" -}}
{{- if $ingCfg := fromYaml (include "rpi.merged.ingress" .) -}}
{{- if $ingCfg.annotations -}}
{{- toYaml $ingCfg.annotations -}}
{{- else -}}
nginx.ingress.kubernetes.io/proxy-body-size: 4096m
nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
nginx.ingress.kubernetes.io/enable-access-log: "true"
nginx.ingress.kubernetes.io/ssl-redirect: "true"
nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "rpi.merged.diagnosticsMode" -}}
{{- $d := fromYaml (include "rpi.defaults.diagnosticsMode" .) -}}
{{- $u := .Values.diagnosticsMode | default dict -}}
{{- toYaml (mustMergeOverwrite $d $u) -}}
{{- end -}}

{{- define "rpi.merged.networkPolicy" -}}
{{- $d := fromYaml (include "rpi.defaults.networkPolicy" .) -}}
{{- $u := .Values.networkPolicy | default dict -}}
{{- toYaml (mustMergeOverwrite $d $u) -}}
{{- end -}}

{{- define "rpi.merged.postInstall" -}}
{{- $d := fromYaml (include "rpi.defaults.postInstall" .) -}}
{{- $u := .Values.postInstall | default dict -}}
{{- toYaml (mustMergeOverwrite $d $u) -}}
{{- end -}}

{{- define "rpi.merged.databaseUpgrade" -}}
{{- $d := fromYaml (include "rpi.defaults.databaseUpgrade" .) -}}
{{- $u := .Values.databaseUpgrade | default dict -}}
{{- toYaml (mustMergeOverwrite $d $u) -}}
{{- end -}}

{{/*
Resolve a host entry to an FQDN.
If the host value contains a dot, it is treated as a FQDN and returned as-is.
Otherwise it is treated as a subdomain and appended to the domain.
Usage: {{ include "rpi.ingress.fqdn" (dict "host" $ingCfg.hosts.callbackapi "domain" $ingCfg.domain) }}
*/}}
{{- define "rpi.ingress.fqdn" -}}
{{- if contains "." .host -}}
{{- .host -}}
{{- else -}}
{{- printf "%s.%s" .host .domain -}}
{{- end -}}
{{- end -}}

{{/* ============================================================
     CLOUD IDENTITY HELPERS
     ============================================================
     Shared helpers for pod-to-cloud authentication and secrets.
     Eliminates duplication across all deploy-*.yaml templates.
     ============================================================ */}}

{{/*
Validate that cloudIdentity is enabled when using sdk or csi secrets.
Call this once from any top-level template to catch misconfiguration early.
*/}}
{{- define "rpi.validateConfig" -}}
{{- if or (eq .Values.secretsManagement.provider "sdk") (eq .Values.secretsManagement.provider "csi") -}}
{{- if not .Values.cloudIdentity.enabled -}}
{{- fail "secretsManagement.provider 'sdk' and 'csi' require cloudIdentity.enabled=true (pods must authenticate to the cloud to access the vault)" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Service mesh pod annotations.
When serviceMesh is enabled with Linkerd, merges default annotations with
any user overrides from serviceMesh.podAnnotations. User values win.
Per-service opt-out: set serviceMesh: false on the service to skip mesh annotations.
Usage: {{- include "rpi.serviceMesh.podAnnotations" (dict "root" . "svcServiceMesh" ($cfg.serviceMesh | default true)) | nindent 8 }}
*/}}
{{- define "rpi.serviceMesh.podAnnotations" -}}
{{- $root := . -}}
{{- if hasKey . "root" }}{{- $root = .root -}}{{- end -}}
{{- $svcMesh := true -}}
{{- if hasKey . "svcServiceMesh" }}
{{- if not (kindIs "invalid" .svcServiceMesh) }}{{- $svcMesh = .svcServiceMesh -}}{{- end -}}
{{- end -}}
{{- if and $root.Values.serviceMesh.enabled (ne ($svcMesh | toString) "false") }}
{{- if eq ($root.Values.serviceMesh.provider | default "linkerd") "linkerd" }}
{{- with $root.Values.serviceMesh.podAnnotations }}
{{- toYaml . }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
ServiceAccount annotations for cloud identity.
Renders the appropriate annotation based on global.deployment.platform.
Usage: {{- include "rpi.cloudidentity.saAnnotations" . | nindent 4 }}
*/}}
{{- define "rpi.cloudidentity.saAnnotations" -}}
{{- $root := . -}}
{{- if hasKey . "root" }}{{- $root = .root -}}{{- end -}}
{{- if $root.Values.cloudIdentity.enabled -}}
{{- if eq $root.Values.global.deployment.platform "azure" }}
azure.workload.identity/client-id: {{ $root.Values.cloudIdentity.azure.managedIdentityClientId | quote }}
azure.workload.identity/tenant-id: {{ $root.Values.cloudIdentity.azure.tenantId | quote }}
{{- else if eq $root.Values.global.deployment.platform "google" }}
iam.gke.io/gcp-service-account: {{ $root.Values.cloudIdentity.google.serviceAccountEmail | quote }}
{{- else if eq $root.Values.global.deployment.platform "amazon" }}
eks.amazonaws.com/role-arn: {{ $root.Values.cloudIdentity.amazon.roleArn | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Pod labels for cloud identity (Azure Workload Identity webhook).
In shared mode: always added.
In per-service mode: only added when the service has cloudIdentity: true.
Usage (shared mode or backward compat): {{- include "rpi.cloudidentity.podLabels" . | nindent 8 }}
Usage (per-service):  {{- include "rpi.cloudidentity.podLabels" (dict "root" . "svcCloudIdentity" $cfg.cloudIdentity) | nindent 8 }}
*/}}
{{- define "rpi.cloudidentity.podLabels" -}}
{{- $root := . -}}
{{- if hasKey . "root" }}{{- $root = .root -}}{{- end -}}
{{- if $root.Values.cloudIdentity.enabled -}}
{{- if eq $root.Values.global.deployment.platform "azure" }}
azure.workload.identity/use: "true"
{{- end }}
{{- end }}
{{- end -}}

{{/*
Cloud identity env vars (IRSA for Amazon, Google credentials path).
Usage: {{- include "rpi.cloudidentity.envvars" . | nindent 10 }}
*/}}
{{- define "rpi.cloudidentity.envvars" -}}
{{- if .Values.cloudIdentity.enabled -}}
{{- if eq .Values.global.deployment.platform "amazon" }}
- name: AWS_STS_REGIONAL_ENDPOINTS
  value: "regional"
- name: AWS_DEFAULT_REGION
  value: {{ .Values.cloudIdentity.amazon.region | quote }}
{{- else if eq .Values.global.deployment.platform "google" }}
{{- if .Values.cloudIdentity.google.configMapName }}
- name: GOOGLE_APPLICATION_CREDENTIALS
  value: "{{ .Values.cloudIdentity.google.configMapFilePath }}/{{ .Values.cloudIdentity.google.keyName }}"
{{- end }}
- name: CloudIdentity__Google__ProjectId
  value: {{ .Values.cloudIdentity.google.projectId | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Amazon access key env vars (when using static keys instead of IRSA).
Usage: {{- include "rpi.cloudidentity.awsAccessKeyEnvvars" . | nindent 10 }}
*/}}
{{- define "rpi.cloudidentity.awsAccessKeyEnvvars" -}}
{{- if .Values.cloudIdentity.enabled -}}
{{- if eq .Values.global.deployment.platform "amazon" }}
{{- if .Values.cloudIdentity.amazon.useAccessKeys }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      key: AWS_Access_Key_ID
      name: {{ include "rpi.secrets.secretName" . | quote }}
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      key: AWS_Secret_Access_Key
      name: {{ include "rpi.secrets.secretName" . | quote }}
- name: AWS_REGION
  value: {{ .Values.cloudIdentity.amazon.region | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
RPI native-auth account policy env vars (password policy + account lockout),
shared by the Interaction and Integration APIs (one user store, one policy;
the Interaction API is the identity provider). Password-policy defaults
mirror the application's own; lockout settings emit only when set, so the
application defaults apply otherwise. Operators override under
interactionapi.passwordPolicy / interactionapi.accountLockout.
Usage: {{- include "rpi.auth.accountPolicy.envvars" . | nindent 8 }}
*/}}
{{- define "rpi.auth.accountPolicy.envvars" -}}
{{- $ia := .Values.interactionapi | default dict -}}
{{- $pp := $ia.passwordPolicy | default dict -}}
{{- $lo := $ia.accountLockout | default dict -}}
- name: Authentication__RPIAuthentication__PasswordPolicy__RequiredLength
  value: {{ ternary $pp.requiredLength 6 (hasKey $pp "requiredLength") | quote }}
- name: Authentication__RPIAuthentication__PasswordPolicy__RequiredUniqueChars
  value: {{ ternary $pp.requiredUniqueChars 1 (hasKey $pp "requiredUniqueChars") | quote }}
- name: Authentication__RPIAuthentication__PasswordPolicy__RequireDigit
  value: {{ ternary $pp.requireDigit true (hasKey $pp "requireDigit") | quote }}
- name: Authentication__RPIAuthentication__PasswordPolicy__RequireNonAlphanumeric
  value: {{ ternary $pp.requireNonAlphanumeric true (hasKey $pp "requireNonAlphanumeric") | quote }}
- name: Authentication__RPIAuthentication__PasswordPolicy__RequireLowercase
  value: {{ ternary $pp.requireLowercase true (hasKey $pp "requireLowercase") | quote }}
- name: Authentication__RPIAuthentication__PasswordPolicy__RequireUppercase
  value: {{ ternary $pp.requireUppercase true (hasKey $pp "requireUppercase") | quote }}
{{- if hasKey $lo "maxFailedAccessAttempts" }}
- name: Authentication__RPIAuthentication__MaxFailedAccessAttempts
  value: {{ $lo.maxFailedAccessAttempts | quote }}
{{- end }}
{{- if hasKey $lo "lockoutTimeSpan" }}
- name: Authentication__RPIAuthentication__LockoutTimeSpan
  value: {{ $lo.lockoutTimeSpan | quote }}
{{- end }}
{{- end }}

{{/*
SDK vault env vars. Only when secretsManagement.provider == "sdk".
Configures the app to read secrets from the cloud vault at runtime.
Usage: {{- include "rpi.secrets.sdk.envvars" . | nindent 10 }}
*/}}
{{- define "rpi.secrets.sdk.envvars" -}}
{{- if eq .Values.secretsManagement.provider "sdk" -}}
{{- $sdk := .Values.secretsManagement.sdk | default dict -}}
{{- $useForAppSettings := ternary $sdk.useForAppSettings true (hasKey $sdk "useForAppSettings") -}}
{{- $configPwDefault := ternary false true (eq .Values.global.deployment.platform "google") -}}
{{- $useForConfigPasswords := ternary $sdk.useForConfigPasswords $configPwDefault (hasKey $sdk "useForConfigPasswords") -}}
{{- if eq .Values.global.deployment.platform "azure" }}
- name: CloudIdentity__Azure__CredentialType
  value: "AzureIdentity"
- name: CloudIdentity__Azure__UseADTokenForDatabaseConnection
  value: {{ .Values.secretsManagement.sdk.azure.useADTokenForDatabaseConnection | quote }}
- name: KeyVault__Provider
  value: "Azure"
- name: KeyVault__UseForAppSettings
  value: {{ $useForAppSettings | quote }}
- name: KeyVault__UseForConfigPasswords
  value: {{ $useForConfigPasswords | quote }}
- name: KeyVault__AzureSettings__VaultURI
  value: {{ .Values.secretsManagement.sdk.azure.vaultUri | quote }}
- name: KeyVault__AzureSettings__AppSettingsVaultURI
  value: {{ .Values.secretsManagement.sdk.azure.vaultUri | quote }}
- name: KeyVault__AzureSettings__ConfigurationReloadIntervalSeconds
  value: {{ .Values.secretsManagement.sdk.azure.configurationReloadIntervalSeconds | quote }}
{{- else if eq .Values.global.deployment.platform "google" }}
- name: KeyVault__Provider
  value: "Google"
- name: KeyVault__UseForAppSettings
  value: {{ $useForAppSettings | quote }}
- name: KeyVault__UseForConfigPasswords
  value: {{ $useForConfigPasswords | quote }}
{{- else if eq .Values.global.deployment.platform "amazon" }}
- name: KeyVault__Provider
  value: "Amazon"
- name: KeyVault__UseForAppSettings
  value: {{ $useForAppSettings | quote }}
- name: KeyVault__UseForConfigPasswords
  value: {{ $useForConfigPasswords | quote }}
- name: KeyVault__AmazonSettings__AppSettingsTag
  value: {{ .Values.secretsManagement.sdk.amazon.secretTagKey | quote }}
- name: AWS_REGION
  value: {{ .Values.cloudIdentity.amazon.region | default "us-east-1" | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Resolve the K8s secret name. Each provider reads from its own
secretName field so customers can keep distinct names per mode.
Usage: {{ include "rpi.secrets.secretName" . }}
*/}}
{{- define "rpi.secrets.secretName" -}}
{{- $provider := .Values.secretsManagement.provider | default "kubernetes" -}}
{{- if eq $provider "csi" -}}
{{ .Values.secretsManagement.csi.secretName | default "redpoint-rpi-secrets" }}
{{- else if eq $provider "kubernetes" -}}
{{ .Values.secretsManagement.kubernetes.secretName | default "redpoint-rpi-secrets" }}
{{- else -}}
{{/* sdk or unknown: secretKeyRef bindings are gated off in SDK mode
     so this branch is rarely consumed; fall back to the kubernetes
     name to keep manifests renderable. */}}
{{ .Values.secretsManagement.kubernetes.secretName | default "redpoint-rpi-secrets" }}
{{- end -}}
{{- end -}}

{{/*
Secret name for internal chart-managed services (Redis, RabbitMQ).
Always uses rpi-internal-services - auto-generated by the chart regardless of provider.
Usage: {{ include "rpi.secrets.internalSecretName" . }}
*/}}
{{- define "rpi.secrets.internalSecretName" -}}
rpi-internal-services
{{- end -}}

{{/*
Snowflake volume definition.
For CSI inline mount (secretProviderClassName set): one CSI volume.
For K8s Secret mount: one volume per unique secretName.
  - Per-key secretName: each key entry can have its own secretName
  - Fallback: uses the top-level sf.secretName for keys without their own
Usage: {{- include "rpi.snowflake.volume" . | nindent 8 }}
*/}}
{{- define "rpi.snowflake.volume" -}}
{{- $sf := .Values.databases.datawarehouse.snowflake -}}
{{- if $sf.secretProviderClassName -}}
- name: {{ $sf.secretProviderClassName }}
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: {{ $sf.secretProviderClassName | quote }}
{{- else -}}
{{- $seen := dict -}}
{{- range $sf.keys }}
{{- if not (hasKey $seen .secretName) }}
{{- $_ := set $seen .secretName true }}
- name: sf-{{ .secretName }}
  secret:
    secretName: {{ .secretName }}
{{- end }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
Snowflake volume mount.
For CSI inline mount: mounts the directory (CSI places files by objectAlias).
For K8s Secret mount: mounts each key with subPath from its secret's volume.
Usage: {{- include "rpi.snowflake.volumeMount" . | nindent 10 }}
*/}}
{{- define "rpi.snowflake.volumeMount" -}}
{{- $sf := .Values.databases.datawarehouse.snowflake -}}
{{- if $sf.secretProviderClassName -}}
- name: {{ $sf.secretProviderClassName }}
  mountPath: {{ $sf.mountPath }}
  readOnly: true
{{- else -}}
{{- range $sf.keys }}
- name: sf-{{ .secretName }}
  mountPath: "{{ $sf.mountPath }}/{{ .keyName }}"
  subPath: {{ .keyName }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
Resolve the ServiceAccount name a pod should mount.
Usage: {{ include "rpi.serviceAccountName" (dict "root" . "name" $name "cfg" $cfg) }}

Resolution order:
  1. Per-service override (cfg.serviceAccountName) when set
  2. Shared SA name (cloudIdentity.serviceAccount.name) when mode=shared
  3. The service's own name (per-service mode default)

Contract:
  required:
    .root  -- chart root context (for cloudIdentity.serviceAccount config)
    .name  -- service identifier used as the per-service SA name when
              mode=per-service
  optional:
    .cfg   -- merged service config dict. When provided and it carries
              a .serviceAccountName field, that wins over chart-wide mode.
*/}}
{{- define "rpi.serviceAccountName" -}}
{{- $root := required "rpi.serviceAccountName: .root is required" .root -}}
{{- $name := required "rpi.serviceAccountName: .name is required" .name -}}
{{- if and .cfg (hasKey .cfg "serviceAccountName") .cfg.serviceAccountName -}}
{{ .cfg.serviceAccountName }}
{{- else -}}
{{- $mode := $root.Values.cloudIdentity.serviceAccount.mode | default "per-service" -}}
{{- if eq $mode "shared" -}}
{{ $root.Values.cloudIdentity.serviceAccount.name | default "redpoint-rpi" }}
{{- else -}}
{{ $name }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Google ConfigMap volume mount (for services that need the SA JSON file).
Usage: {{- include "rpi.cloudidentity.googleVolumeMounts" . | nindent 10 }}
*/}}
{{- define "rpi.cloudidentity.googleVolumeMounts" -}}
{{- if .Values.cloudIdentity.enabled -}}
{{- if eq .Values.global.deployment.platform "google" }}
{{- if .Values.cloudIdentity.google.configMapName }}
- name: {{ .Values.cloudIdentity.google.configMapName }}
  mountPath: "{{ .Values.cloudIdentity.google.configMapFilePath }}/{{ .Values.cloudIdentity.google.keyName }}"
  subPath: {{ .Values.cloudIdentity.google.keyName | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Google ConfigMap volume definition.
Usage: {{- include "rpi.cloudidentity.googleVolumes" . | nindent 8 }}
*/}}
{{- define "rpi.cloudidentity.googleVolumes" -}}
{{- if .Values.cloudIdentity.enabled -}}
{{- if eq .Values.global.deployment.platform "google" }}
{{- if .Values.cloudIdentity.google.configMapName }}
- name: {{ .Values.cloudIdentity.google.configMapName | quote }}
  configMap:
    name: {{ .Values.cloudIdentity.google.configMapName | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Platform-specific database connection env var name.
Usage: {{- include "rpi.platform.dbProviderEnvvar" . | nindent 10 }}
*/}}
{{- define "rpi.platform.dbProviderEnvvar" -}}
{{- if eq .Values.global.deployment.platform "azure" }}
- name: RPI__CloudEnvironment
  value: "Azure"
{{- else if eq .Values.global.deployment.platform "amazon" }}
- name: RPI__CloudEnvironment
  value: "Amazon"
{{- else if eq .Values.global.deployment.platform "google" }}
- name: RPI__CloudEnvironment
  value: "Google"
{{- else }}
- name: RPI__CloudEnvironment
  value: "SelfHosted"
{{- end }}
{{- end -}}

{{/*
Resolve the container image for a service.
Priority:
  1. overrides.<name>: full URI used verbatim (no tag appended)
  2. nameOverrides.<name>: constructs {registry}/{nameOverride}:{tag}
  3. default: constructs {registry}/{name}:{tag}
Usage: {{ include "rpi.image" (dict "root" . "name" $name) }}

Contract:
  required:
    .root  -- chart root context (for global.deployment.images config)
    .name  -- service key used to look up overrides / nameOverrides /
              default image name
*/}}
{{- define "rpi.image" -}}
{{- $root := required "rpi.image: .root is required" .root -}}
{{- $name := required "rpi.image: .name is required" .name -}}
{{- $overrides := $root.Values.global.deployment.images.overrides | default dict -}}
{{- $nameOverrides := $root.Values.global.deployment.images.nameOverrides | default dict -}}
{{- $defaultNames := dict "rpi-redis" "rediscache" "rpi-rabbitmq" "rabbitmq" -}}
{{- if hasKey $overrides $name -}}
{{ index $overrides $name }}
{{- else if hasKey $nameOverrides $name -}}
{{ $root.Values.global.deployment.images.registry }}/{{ index $nameOverrides $name }}:{{ $root.Values.global.deployment.images.tag }}
{{- else -}}
{{- $imageName := $name -}}
{{- if hasKey $defaultNames $name -}}
{{- $imageName = index $defaultNames $name -}}
{{- end -}}
{{ $root.Values.global.deployment.images.registry }}/{{ $imageName }}:{{ $root.Values.global.deployment.images.tag }}
{{- end -}}
{{- end -}}

{{/*
Pod anti-affinity block. Renders the full affinity: stanza.
Usage: {{- include "rpi.podAntiAffinity" (dict "root" . "name" $name) | nindent 6 }}

Contract:
  required:
    .root  -- chart root context (for chart-wide podAntiAffinity config)
    .name  -- service identifier emitted in the matchLabels selector
*/}}
{{- define "rpi.podAntiAffinity" -}}
{{- $root := required "rpi.podAntiAffinity: .root is required" .root -}}
{{- $name := required "rpi.podAntiAffinity: .name is required" .name -}}
{{- $aa := $root.Values.podAntiAffinity | default dict -}}
{{- $enabled := ternary $aa.enabled true (hasKey $aa "enabled") -}}
{{- if $enabled }}
affinity:
  podAntiAffinity:
    {{- if eq ($aa.type | default "preferred") "required" }}
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: {{ $name }}
        topologyKey: {{ $aa.topologyKey | default "kubernetes.io/hostname" }}
    {{- else }}
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: {{ $aa.weight | default 100 }}
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: {{ $name }}
          topologyKey: {{ $aa.topologyKey | default "kubernetes.io/hostname" }}
    {{- end }}
{{- end }}
{{- end -}}

{{/*
Custom CA certificate volume mount.
Usage: {{- include "rpi.customCACerts.volumeMount" . | nindent 10 }}
*/}}
{{- define "rpi.customCACerts.volumeMount" -}}
{{- if and .Values.customCACerts .Values.customCACerts.enabled }}
{{- if or .Values.customCACerts.name .Values.customCACerts.secretProviderClassName }}
- name: custom-ca-certs
  mountPath: {{ .Values.customCACerts.mountPath | default "/usr/local/share/ca-certificates/custom" }}
  readOnly: true
{{- end }}
{{- end }}
{{- end -}}

{{/*
Custom CA certificate volume definition.
Usage: {{- include "rpi.customCACerts.volume" . | nindent 8 }}
*/}}
{{- define "rpi.customCACerts.volume" -}}
{{- if and .Values.customCACerts .Values.customCACerts.enabled }}
{{- if .Values.customCACerts.secretProviderClassName }}
- name: custom-ca-certs
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: {{ .Values.customCACerts.secretProviderClassName | quote }}
{{- else if .Values.customCACerts.name }}
- name: custom-ca-certs
  secret:
    secretName: {{ .Values.customCACerts.name }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Custom CA certificate env var (SSL_CERT_FILE).
Usage: {{- include "rpi.customCACerts.envVar" . | nindent 8 }}
*/}}
{{- define "rpi.customCACerts.envVar" -}}
{{- if and .Values.customCACerts .Values.customCACerts.enabled .Values.customCACerts.certFile }}
- name: SSL_CERT_FILE
  value: "{{ .Values.customCACerts.mountPath | default "/usr/local/share/ca-certificates/custom" }}/{{ .Values.customCACerts.certFile }}"
{{- end }}
{{- end -}}

{{/*
Render merged annotations for a specific resource type.
Merges commonAnnotations + type-specific overrides (serviceAccountAnnotations,
serviceAnnotations) and emits the YAML map.
Usage: {{- include "rpi.mergedAnnotations" (dict "root" . "type" "serviceAccount") }}

Contract:
  required:
    .root  -- chart root context
    .type  -- "serviceAccount" or "service". An unknown type emits only
              the common annotations (no per-type overlay).
*/}}
{{- define "rpi.mergedAnnotations" -}}
{{- $root := required "rpi.mergedAnnotations: .root is required" .root -}}
{{- $type := required "rpi.mergedAnnotations: .type is required" .type -}}
{{- $common := $root.Values.commonAnnotations | default dict -}}
{{- $extra := dict -}}
{{- if eq $type "serviceAccount" -}}
{{- $extra = $root.Values.serviceAccountAnnotations | default dict -}}
{{- else if eq $type "service" -}}
{{- $extra = $root.Values.serviceAnnotations | default dict -}}
{{- end -}}
{{- $merged := mustMergeOverwrite (dict) $common $extra -}}
{{- if $merged -}}
{{- toYaml $merged -}}
{{- end -}}
{{- end -}}

{{/*
KEY_VAULT_NAME env var for CDP services.
When smartActivation is enabled and secretsManagement provider is sdk,
extracts the vault name from the vaultUri (e.g. https://myvault.vault.azure.net/ -> myvault).
Usage: {{- include "rpi.cdp.keyVaultEnv" . | nindent 8 }}
*/}}
{{- define "rpi.cdp.keyVaultEnv" -}}
{{- if and .Values.smartActivation.enabled (eq .Values.secretsManagement.provider "sdk") -}}
{{- $uri := .Values.secretsManagement.sdk.azure.vaultUri | default "" -}}
{{- $name := regexReplaceAll "^https://" $uri "" -}}
{{- $name = regexReplaceAll "\\.vault\\.azure\\.net/?$" $name "" -}}
{{- if $name }}
- name: KEY_VAULT_NAME
  value: {{ $name | quote }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Cloud SQL Auth Proxy (GKE / PostgreSQL only).
Sidecar + env-var override activate only when all of:
  - global.deployment.platform equals "google"
  - databases.operational.cloudSqlProxy.enabled equals true
  - databases.operational.provider equals "postgresql"
Otherwise every helper in this family renders empty and the sidecar is inert.
*/}}

{{- define "rpi.cloudSqlProxy.enabled" -}}
{{- $cfg := (.Values.databases.operational.cloudSqlProxy | default dict) -}}
{{- $provider := .Values.databases.operational.provider | default "" -}}
{{- $secretsProvider := .Values.secretsManagement.provider | default "" -}}
{{- if and (eq (.Values.global.deployment.platform | default "") "google") ($cfg.enabled | default false) (or (eq $provider "postgresql") (eq $provider "sqlserver")) -}}
{{- if ne $secretsProvider "sdk" -}}
{{- fail "databases.operational.cloudSqlProxy.enabled=true requires secretsManagement.provider=sdk. The Cloud SQL Auth Proxy assumes the same cloud-native security realm as the SDK secret provider (vault-backed, IAM-bound). It is not supported with secretsManagement.provider=kubernetes." -}}
{{- end -}}
true
{{- end -}}
{{- end -}}

{{/*
Native K8s sidecar container spec for Cloud SQL Auth Proxy. Emitted as an
element of initContainers[] with restartPolicy: Always (K8s >= 1.29 native
sidecar pattern with clean startup/shutdown ordering relative to the main app).
Usage: {{- include "rpi.block.cloudSqlProxy.sidecar" . | nindent 6 }}
*/}}
{{- define "rpi.block.cloudSqlProxy.sidecar" -}}
{{- if eq (include "rpi.cloudSqlProxy.enabled" .) "true" -}}
{{- $cfg := .Values.databases.operational.cloudSqlProxy -}}
{{- $provider := .Values.databases.operational.provider -}}
{{- $port := $cfg.port | default (eq $provider "sqlserver" | ternary 1433 5432) -}}
{{- $useGoogleSaKey := and .Values.cloudIdentity.enabled (eq .Values.global.deployment.platform "google") (.Values.cloudIdentity.google.configMapName | toString | ne "") -}}
{{- $googleSaKey := .Values.cloudIdentity.google.keyName -}}
{{- $googleSaPath := printf "%s/%s" (.Values.cloudIdentity.google.configMapFilePath | default "/app/google-creds") ($googleSaKey | default "service_account.json") -}}
- name: cloud-sql-proxy
  image: {{ $cfg.image | quote }}
  imagePullPolicy: IfNotPresent
  restartPolicy: Always
  args:
  - "--port={{ $port }}"
  {{- if $cfg.privateIp | default false }}
  - "--private-ip"
  {{- end }}
  {{- if $cfg.autoIamAuthn | default false }}
  - "--auto-iam-authn"
  {{- end }}
  {{- if $useGoogleSaKey }}
  - "--credentials-file={{ $googleSaPath }}"
  {{- end }}
  - "--max-sigterm-delay={{ $cfg.terminationGracePeriod | default "30s" }}"
  {{- range $cfg.additionalArgs | default (list) }}
  - {{ . | quote }}
  {{- end }}
  - {{ required "databases.operational.cloudSqlProxy.connectionName is required when cloudSqlProxy.enabled=true" $cfg.connectionName | quote }}
  ports:
  - name: cloudsql
    containerPort: {{ $port }}
    protocol: TCP
  resources:
    {{- toYaml ($cfg.resources | default dict) | nindent 4 }}
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: ["ALL"]
  {{- if $useGoogleSaKey }}
  volumeMounts:
  - name: {{ .Values.cloudIdentity.google.configMapName | quote }}
    mountPath: {{ $googleSaPath | quote }}
    subPath: {{ $googleSaKey | default "service_account.json" | quote }}
    readOnly: true
  {{- end }}
{{- end -}}
{{- end -}}

{{/* ============================================================
     OBSERVABILITY SERVICE HELPERS
     ============================================================
     Env-var emission for the Intelligence Runtime topology. Four
     cloud-integration provider categories (local / azure / google /
     aws); the observability service constructs each enabled provider
     at lifespan startup and routes capability requests via the
     configured pool -> provider mapping.
     ============================================================ */}}

{{/*
Returns "true" when observability is enabled. Used by templates and
the ingress-routes file to gate observability-specific output.
*/}}
{{- define "rpi.observability.enabled" -}}
{{- if (.Values.observability | default dict).enabled -}}
true
{{- end -}}
{{- end -}}

{{/*
Intelligence env vars. The AI surface is disabled by default; when
observability.intelligence.enabled=true the administrator must select
a managed cloud AI provider explicitly (azure | aws) - there is no
default provider and no fallback. Only the active provider's config
block is emitted.

The observability service owns the AI workflows; provider-specific
authentication and SDK integration live in the service's provider
adapters behind a common interface. The chart's job is only to name
the provider and pass its connection facts.

Usage: {{- include "rpi.observability.intelligenceEnvvars" . | nindent 8 }}
*/}}
{{- define "rpi.observability.intelligenceEnvvars" -}}
{{- $cfg := .Values.observability | default dict -}}
{{- $intel := $cfg.intelligence | default dict -}}
{{- $enabled := $intel.enabled | default false -}}
{{- $azure := $intel.azure | default dict -}}
{{- $aws := $intel.aws | default dict -}}
{{- $secret := include "rpi.secrets.secretName" . -}}
{{- $secretsProvider := .Values.secretsManagement.provider | default "kubernetes" -}}
{{- $isSdk := eq $secretsProvider "sdk" -}}
- name: OBSERVABILITY__INTELLIGENCE__ENABLED
  value: {{ $enabled | quote }}
{{- if $enabled }}
{{- $provider := lower (default "" $intel.provider) -}}
{{- if not (has $provider (list "azure" "aws")) }}
{{- fail (printf "observability.intelligence.provider=%q is invalid. observability.intelligence.enabled=true requires an explicit provider: azure | aws. There is no default provider." (default "" $intel.provider)) }}
{{- end }}
- name: OBSERVABILITY__INTELLIGENCE__PROVIDER
  value: {{ $provider | quote }}
{{- if $intel.timeoutSeconds }}
- name: OBSERVABILITY__INTELLIGENCE__TIMEOUT_SECONDS
  value: {{ $intel.timeoutSeconds | quote }}
{{- end }}
{{- if eq $provider "azure" }}
# Azure cloud-integration provider (AI Foundry or Azure OpenAI).
- name: OBSERVABILITY__INTELLIGENCE__AZURE__SERVICE
  value: {{ $azure.service | default "foundry" | quote }}
- name: OBSERVABILITY__INTELLIGENCE__AZURE__ENDPOINT
  value: {{ required "observability.intelligence.azure.endpoint is required when intelligence.provider=azure" $azure.endpoint | quote }}
- name: OBSERVABILITY__INTELLIGENCE__AZURE__DEPLOYMENT
  value: {{ required "observability.intelligence.azure.deployment is required when intelligence.provider=azure" $azure.deployment | quote }}
{{- if $azure.apiVersion }}
- name: OBSERVABILITY__INTELLIGENCE__AZURE__API_VERSION
  value: {{ $azure.apiVersion | quote }}
{{- end }}
{{- if and (not $isSdk) $azure.apiKeySecretKey }}
- name: AZURE_INTELLIGENCE_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secret | quote }}
      key: {{ $azure.apiKeySecretKey | quote }}
{{- end }}
{{- else if eq $provider "aws" }}
# AWS cloud-integration provider (Bedrock).
- name: OBSERVABILITY__INTELLIGENCE__AWS__REGION
  value: {{ required "observability.intelligence.aws.region is required when intelligence.provider=aws" $aws.region | quote }}
- name: OBSERVABILITY__INTELLIGENCE__AWS__MODEL_ID
  value: {{ required "observability.intelligence.aws.modelId is required when intelligence.provider=aws" $aws.modelId | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Budget + schedule + database + storage env vars. Always emitted when
observability is enabled.

The observability service rides the chart's existing connection-string
convention -- same env var name, same secret key, same secret name --
as the rest of the RPI services (callbackapi, executionservice, etc.):

  env var:  CONNECTIONSTRINGS__LOGGINGDATABASE
  secret key: ConnectionString_Logging_Database
  secret name: rpi.secrets.secretName

In kubernetes / csi mode the chart binds that env var via secretKeyRef.
In sdk mode the observability service fetches the same logical value
from the cloud vault under the .NET-style entry name
`ConnectionStrings--LoggingDatabase` (matches what the rest of RPI's
SDK provider expects).

Usage: {{- include "rpi.observability.runtimeEnvvars" . | nindent 8 }}
*/}}


{{/*
Authentication env vars for the observability container. Two modes:
Anonymous (observability.authentication.enabled=false, the default -
only OBSERVABILITY__AUTH__ENABLED=false is emitted) and RPI
Authentication (enabled=true - Observability participates in the
authentication model the RPI deployment already uses).

RPI is the source of truth for the identity provider. The provider
vars are the SAME Authentication__* contract, sourced from the SAME
chart-wide values blocks, that the RPI services consume - never a
parallel Observability copy:

  MicrosoftEntraID enabled     -> Authentication__Microsoft__Enable
                                  Authentication__Microsoft__TenantID
                                  Authentication__Microsoft__ClientApplicationID
                                  Authentication__Microsoft__APIApplicationID
  OpenIdProviders enabled      -> Authentication__OpenIdProviders__0__Name
     (Okta | Keycloak)            Authentication__OpenIdProviders__0__AuthorizationHost
                                  Authentication__OpenIdProviders__0__ClientID
                                  Authentication__OpenIdProviders__0__MetadataHost (Keycloak)
  neither                      -> no provider vars; the service runs anonymous

Session + authorization vars emitted when enabled:
  OBSERVABILITY__AUTH__COOKIE_SECURE
  OBSERVABILITY__AUTH__SESSION_LIFETIME_SECONDS
  OBSERVABILITY__AUTH__AUTHZ_CACHE_TTL_SECONDS
  OBSERVABILITY__AUTH__INGRESS_HOST
  OBSERVABILITY__AUTH__CAPABILITY_MAP

Secret binding (non-SDK modes; from the chart's standard RPI Secret,
resolved via rpi.secrets.secretName): OIDC_Client_Secret, bound with
optional=true. RPI's provider registrations are public clients (the
OIDC exchange uses PKCE, no secret); organizations whose registration
is confidential populate the key with the registration's EXISTING
client secret. In SDK mode the service fetches the same key from the
cloud vault.

The session signing key is generated on first start and persisted on
the pod's PVC at /data/session_signing_key - no K8s Secret entry, no
env var. Rotation: write the existing file to
/data/session_signing_key.previous and delete
/data/session_signing_key so a new one is generated.

Usage: {{- include "rpi.observability.authEnvvars" . | nindent 8 }}
*/}}
{{- define "rpi.observability.authEnvvars" -}}
{{- $cfg := .Values.observability | default dict -}}
{{- $authn := $cfg.authentication | default dict -}}
{{- $enabled := $authn.enabled | default false -}}
- name: OBSERVABILITY__AUTH__ENABLED
  value: {{ $enabled | quote }}
{{- if $enabled -}}
{{- $secretName := include "rpi.secrets.secretName" . -}}
{{- $secretsProvider := .Values.secretsManagement.provider | default "kubernetes" -}}
{{- $isSdk := eq $secretsProvider "sdk" -}}
{{- $ingCfg := fromYaml (include "rpi.merged.ingress" .) -}}
{{- $observabilityHost := include "rpi.ingress.fqdn" (dict "host" $ingCfg.hosts.observability "domain" $ingCfg.domain) -}}
{{- $ingressHost := $authn.ingressHost | default $observabilityHost }}
- name: OBSERVABILITY__AUTH__COOKIE_SECURE
  value: {{ ternary $authn.cookieSecure true (hasKey $authn "cookieSecure") | quote }}
- name: OBSERVABILITY__AUTH__SESSION_LIFETIME_SECONDS
  value: {{ $authn.sessionLifetimeSeconds | default 28800 | quote }}
- name: OBSERVABILITY__AUTH__AUTHZ_CACHE_TTL_SECONDS
  value: {{ $authn.authorizationCacheTtlSeconds | default 60 | quote }}
- name: OBSERVABILITY__AUTH__INGRESS_HOST
  value: {{ $ingressHost | quote }}
- name: OBSERVABILITY__AUTH__CAPABILITY_MAP
  value: {{ $authn.capabilityMap | default dict | toJson | quote }}
{{- if .Values.MicrosoftEntraID.enabled }}
- name: Authentication__Microsoft__Enable
  value: "true"
- name: Authentication__Microsoft__TenantID
  value: {{ .Values.MicrosoftEntraID.tenant_id | quote }}
- name: Authentication__Microsoft__ClientApplicationID
  value: {{ .Values.MicrosoftEntraID.interaction_client_id | quote }}
- name: Authentication__Microsoft__APIApplicationID
  value: {{ .Values.MicrosoftEntraID.interaction_api_id | quote }}
{{- else if .Values.OpenIdProviders.enabled }}
{{- if eq .Values.OpenIdProviders.name "Okta" }}
- name: Authentication__OpenIdProviders__0__Name
  value: "Okta"
- name: Authentication__OpenIdProviders__0__AuthorizationHost
  value: {{ .Values.OpenIdProviders.authorizationHost | quote }}
- name: Authentication__OpenIdProviders__0__ClientID
  value: {{ .Values.OpenIdProviders.clientID | quote }}
{{- end }}
{{- if eq .Values.OpenIdProviders.name "keycloak" }}
- name: Authentication__OpenIdProviders__0__Name
  value: "Keycloak"
- name: Authentication__OpenIdProviders__0__AuthorizationHost
  value: {{ .Values.OpenIdProviders.authorizationHost | quote }}
- name: Authentication__OpenIdProviders__0__ClientID
  value: {{ .Values.OpenIdProviders.clientID | quote }}
- name: Authentication__OpenIdProviders__0__MetadataHost
  value: "http://cdp-keycloak/auth/realms/redpoint-mercury"
{{- end }}
{{- end }}
{{- if not $isSdk }}
- name: OIDC_Client_Secret
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: OIDC_Client_Secret
      optional: true
{{- end }}
{{- end }}
{{- end -}}


{{- define "rpi.observability.runtimeEnvvars" -}}
{{- $cfg := .Values.observability | default dict -}}
{{- $budget := $cfg.budget | default dict -}}
{{- $schedule := $cfg.schedule | default dict -}}
{{- $secretName := include "rpi.secrets.secretName" . -}}
{{- $secretsProvider := .Values.secretsManagement.provider | default "kubernetes" -}}
{{- $provider := .Values.databases.operational.provider | default "sqlserver" -}}
- name: OBSERVABILITY__CLOUD_PLATFORM
  value: {{ .Values.global.deployment.platform | default "" | quote }}
{{/* Canonical RPI ClientID (rpi_Clients lookup key). REQUIRED.
     observability.clientId is the only source of tenant identity: no
     fallback, no inference, no auto-detection. Helm fails the render
     when observability is enabled and it is empty. */}}
- name: OBSERVABILITY__CLIENT_ID
  value: {{ required "observability.clientId is required when observability.enabled=true. Set it to the ClientID GUID from Pulse_<env>.dbo.rpi_Clients (e.g. 9A39D66C-111C-408E-AE5B-D97880BAC496). There is no fallback or auto-detection." $cfg.clientId | quote }}
- name: OBSERVABILITY__BUDGET__MAX_TOKENS_PER_HOUR
  value: {{ $budget.maxTokensPerHour | default 200000 | quote }}
- name: OBSERVABILITY__BUDGET__MAX_REQUESTS_PER_HOUR
  value: {{ $budget.maxRequestsPerHour | default 60 | quote }}
- name: OBSERVABILITY__SCHEDULE__INTERVAL_MINUTES
  value: {{ $schedule.intervalMinutes | default 30 | quote }}
{{- if $schedule.lookbackMinutes }}
- name: OBSERVABILITY__SCHEDULE__LOOKBACK_MINUTES
  value: {{ $schedule.lookbackMinutes | quote }}
{{- end }}
{{- if $schedule.dailyAtUtc }}
- name: OBSERVABILITY__SCHEDULE__DAILY_AT_UTC
  value: {{ $schedule.dailyAtUtc | quote }}
{{- end }}
- name: OBSERVABILITY__SQLITE_PATH
  value: "/data/reports.db"
{{/* Diagnostics-tab DB names (Interaction + InteractionAudit) are NOT
     emitted as env vars. The observability service resolves them at
     startup from Pulse_<env>.dbo.rpi_Clients via ClientResolver, using
     OBSERVABILITY__CLIENT_ID (set above from observability.clientId)
     as the lookup key. No fallback, no inference. */}}
{{- with $cfg.diagnostics }}
{{- with .fileOutput }}
- name: OBSERVABILITY__DIAGNOSTICS__FILE_OUTPUT_ENABLED
  value: {{ .enabled | toString | quote }}
{{- end }}
{{- end }}
{{/* Custom Metrics (T4 telemetry). The observability service scrapes
     Prometheus-style /metrics endpoints from configured RPI services.
     Service list is JSON-encoded so operators can override DNS names
     without code changes; defaults baked in values.yaml cover the
     standard deployment shape. See reference/rpi-metrics-catalog.md
     and principles/discovery-authority.md.

     The services list is filtered by each entry's corresponding
     top-level .enabled flag. Convention: strip the "rpi-" prefix
     from dnsName to map to the values key (rpi-realtimeapi ->
     .Values.realtimeapi.enabled). When the customer disables a
     service via overrides (e.g. realtimeapi.enabled=false), the
     entry is dropped from the emitted env var so the observability
     service never tries to scrape it. Operator-added scrape targets that
     don't correspond to a chart-managed service default to
     enabled=true so they always pass through. */}}
{{- with $cfg.metrics }}
- name: OBSERVABILITY__METRICS__ENABLED
  value: {{ .enabled | toString | quote }}
- name: OBSERVABILITY__METRICS__SCRAPE_INTERVAL
  value: {{ .scrapeIntervalSeconds | default 15 | quote }}
- name: OBSERVABILITY__METRICS__TIMEOUT_SECONDS
  value: {{ .timeoutSeconds | default 5 | quote }}
- name: OBSERVABILITY__METRICS__BUFFER_SIZE
  value: {{ .bufferSize | default 240 | quote }}
{{- $otelEnabled := eq (include "rpi.telemetry.mode" $) "advanced" -}}
{{- $enabledSvcs := list -}}
{{- range $svc := (.services | default list) -}}
{{-   $shortName := trimPrefix "rpi-" ($svc.dnsName | default "") -}}
{{-   $svcCfg := get $.Values $shortName -}}
{{-   $isEnabled := true -}}
{{-   if $svcCfg -}}
{{-     if hasKey $svcCfg "enabled" -}}
{{-       $isEnabled = $svcCfg.enabled -}}
{{-     end -}}
{{-   end -}}
{{-   if $isEnabled -}}
{{-     if and $otelEnabled (eq ($svc.dnsName | default "") "rpi-interactionapi") -}}
{{-       $swapped := dict "name" $svc.name "dnsName" $svc.dnsName "port" 8889 "path" "/metrics" -}}
{{-       $enabledSvcs = append $enabledSvcs $swapped -}}
{{-     else -}}
{{-       $enabledSvcs = append $enabledSvcs $svc -}}
{{-     end -}}
{{-   end -}}
{{- end }}
- name: OBSERVABILITY__METRICS__SERVICES
  value: {{ $enabledSvcs | toJson | quote }}
{{- end }}
{{/* Database Queries (read-only). Sourced directly from
     rpi_ExecutionQueries via the same shared RPI operational-database
     connection every other RPI service uses -- no dedicated env vars,
     secrets, or chart values. When the operational-database connection
     is not bound on this pod, the provider reports "unbound" and the
     UI renders the standard "not configured" diagnostics state. */}}
# SMTP transport for the email digest. Always emitted; consumed only
# when email is enabled.
- name: RPI__SMTP__EmailSenderAddress
  value: {{ .Values.SMTPSettings.SMTP_SenderAddress | quote }}
- name: RPI__SMTP__EmailSenderName
  value: {{ .Values.SMTPSettings.SMTP_SenderName | quote }}
- name: RPI__SMTP__Address
  value: {{ .Values.SMTPSettings.SMTP_Address | quote }}
- name: RPI__SMTP__Port
  value: {{ .Values.SMTPSettings.SMTP_Port | quote }}
- name: RPI__SMTP__EnableSSL
  value: {{ .Values.SMTPSettings.EnableSSL | quote }}
- name: RPI__SMTP__UseCredentials
  value: {{ .Values.SMTPSettings.UseCredentials | quote }}
{{- if .Values.SMTPSettings.UseCredentials }}
{{- if ne $secretsProvider "sdk" }}
- name: RPI__SMTP__Username
  value: {{ .Values.SMTPSettings.SMTP_Username | quote }}
- name: RPI__SMTP__Password
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: SMTP_Password
{{- end }}
{{- end }}
{{- /* Incident-intelligence notifications. Delivery is decided by the
       deterministic lifecycle engine, never by AI. email + teams are
       CHANNELS nested under notifications (notifications.email /
       notifications.teams). Only the master gate + explicitly-set tunables
       are emitted; the app supplies matching defaults for everything
       omitted. hasKey is used for booleans/numerics so an explicit
       false / 0 is honored (default would mask it). The app still consumes
       the OBSERVABILITY__EMAIL__ and __TEAMS__ env names - an internal
       contract; operators configure the channels under notifications. */ -}}
{{- $notif := $cfg.notifications | default dict }}
{{- if $notif.enabled }}
- name: OBSERVABILITY__NOTIFICATIONS__ENABLED
  value: "true"
{{- $email := $notif.email | default dict }}
{{- if $email.enabled }}
- name: OBSERVABILITY__EMAIL__ENABLED
  value: "true"
{{- $ingCfg := .Values.ingress | default dict }}
{{- if and ($ingCfg.hosts).observability $ingCfg.domain }}
- name: OBSERVABILITY__EMAIL__INGRESS_URL
  value: {{ printf "https://%s.%s" $ingCfg.hosts.observability $ingCfg.domain | quote }}
{{- end }}
{{- end }}
{{- $teams := $notif.teams | default dict }}
{{- if $teams.enabled }}
- name: OBSERVABILITY__TEAMS__ENABLED
  value: "true"
- name: Observability_Teams_Webhook
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: {{ $teams.webhookSecretKey | default "Observability_Teams_Webhook" | quote }}
{{- end }}
{{- with $notif.defaultRecipients }}
- name: OBSERVABILITY__NOTIFICATIONS__DEFAULT_RECIPIENTS
  value: {{ join "," . | quote }}
{{- end }}
{{- $db := $notif.dailyBrief | default dict }}
{{- if hasKey $db "enabled" }}
- name: OBSERVABILITY__NOTIFICATIONS__DAILY_BRIEF__ENABLED
  value: {{ $db.enabled | quote }}
{{- end }}
{{- with $db.atUtc }}
- name: OBSERVABILITY__NOTIFICATIONS__DAILY_BRIEF__AT_UTC
  value: {{ . | quote }}
{{- end }}
{{- with $db.recipients }}
- name: OBSERVABILITY__NOTIFICATIONS__DAILY_BRIEF__RECIPIENTS
  value: {{ join "," . | quote }}
{{- end }}
{{- $ws := $notif.weeklySummary | default dict }}
{{- if hasKey $ws "enabled" }}
- name: OBSERVABILITY__NOTIFICATIONS__WEEKLY_SUMMARY__ENABLED
  value: {{ $ws.enabled | quote }}
{{- end }}
{{- if hasKey $ws "dayOfWeek" }}
- name: OBSERVABILITY__NOTIFICATIONS__WEEKLY_SUMMARY__DAY_OF_WEEK
  value: {{ $ws.dayOfWeek | quote }}
{{- end }}
{{- with $ws.atUtc }}
- name: OBSERVABILITY__NOTIFICATIONS__WEEKLY_SUMMARY__AT_UTC
  value: {{ . | quote }}
{{- end }}
{{- with $ws.recipients }}
- name: OBSERVABILITY__NOTIFICATIONS__WEEKLY_SUMMARY__RECIPIENTS
  value: {{ join "," . | quote }}
{{- end }}
{{- $ni := $notif.newIncident | default dict }}
{{- if hasKey $ni "enabled" }}
- name: OBSERVABILITY__NOTIFICATIONS__NEW_INCIDENT__ENABLED
  value: {{ $ni.enabled | quote }}
{{- end }}
{{- if hasKey $ni "significanceThreshold" }}
- name: OBSERVABILITY__NOTIFICATIONS__NEW_INCIDENT__SIGNIFICANCE_THRESHOLD
  value: {{ $ni.significanceThreshold | quote }}
{{- end }}
{{- if hasKey $ni "cooldownMinutes" }}
- name: OBSERVABILITY__NOTIFICATIONS__NEW_INCIDENT__COOLDOWN_MINUTES
  value: {{ $ni.cooldownMinutes | quote }}
{{- end }}
{{- with $ni.recipients }}
- name: OBSERVABILITY__NOTIFICATIONS__NEW_INCIDENT__RECIPIENTS
  value: {{ join "," . | quote }}
{{- end }}
{{- $esc := $notif.escalation | default dict }}
{{- if hasKey $esc "enabled" }}
- name: OBSERVABILITY__NOTIFICATIONS__ESCALATION__ENABLED
  value: {{ $esc.enabled | quote }}
{{- end }}
{{- with $esc.minBand }}
- name: OBSERVABILITY__NOTIFICATIONS__ESCALATION__MIN_BAND
  value: {{ . | quote }}
{{- end }}
{{- if hasKey $esc "scoreDelta" }}
- name: OBSERVABILITY__NOTIFICATIONS__ESCALATION__SCORE_DELTA
  value: {{ $esc.scoreDelta | quote }}
{{- end }}
{{- if hasKey $esc "tenantDelta" }}
- name: OBSERVABILITY__NOTIFICATIONS__ESCALATION__TENANT_DELTA
  value: {{ $esc.tenantDelta | quote }}
{{- end }}
{{- if hasKey $esc "sustainCycles" }}
- name: OBSERVABILITY__NOTIFICATIONS__ESCALATION__SUSTAIN_CYCLES
  value: {{ $esc.sustainCycles | quote }}
{{- end }}
{{- if hasKey $esc "cooldownMinutes" }}
- name: OBSERVABILITY__NOTIFICATIONS__ESCALATION__COOLDOWN_MINUTES
  value: {{ $esc.cooldownMinutes | quote }}
{{- end }}
{{- with $esc.recipients }}
- name: OBSERVABILITY__NOTIFICATIONS__ESCALATION__RECIPIENTS
  value: {{ join "," . | quote }}
{{- end }}
{{- $res := $notif.resolution | default dict }}
{{- if hasKey $res "enabled" }}
- name: OBSERVABILITY__NOTIFICATIONS__RESOLUTION__ENABLED
  value: {{ $res.enabled | quote }}
{{- end }}
{{- if hasKey $res "absentCycles" }}
- name: OBSERVABILITY__NOTIFICATIONS__RESOLUTION__ABSENT_CYCLES
  value: {{ $res.absentCycles | quote }}
{{- end }}
{{- with $res.recipients }}
- name: OBSERVABILITY__NOTIFICATIONS__RESOLUTION__RECIPIENTS
  value: {{ join "," . | quote }}
{{- end }}
{{- end }}
# Operational SQL database type. Drives the observability service's
# connection string. Always emitted (not a secret).
{{- $platform := .Values.global.deployment.platform -}}
{{- if eq $provider "postgresql" }}
- name: ClusterEnvironment__OperationalDatabase__DatabaseType
  value: "PostgreSQL"
{{- else if eq $provider "sqlserver" }}
{{- if eq $platform "amazon" }}
- name: ClusterEnvironment__OperationalDatabase__DatabaseType
  value: "AmazonRDSSQL"
{{- else if eq $platform "azure" }}
- name: ClusterEnvironment__OperationalDatabase__DatabaseType
  value: "AzureSQLDatabase"
{{- else if eq $platform "google" }}
- name: ClusterEnvironment__OperationalDatabase__DatabaseType
  value: "GoogleCloudSQL"
{{- end }}
{{- else if eq $provider "sqlserveronvm" }}
- name: ClusterEnvironment__OperationalDatabase__DatabaseType
  value: "SQLServerOnVM"
{{- end }}
{{- if ne $secretsProvider "sdk" }}
# Operational DB connection components for the Pulse Logging client.
# SDK mode reads these from the cloud vault directly via rpi.secrets.sdk.envvars.
- name: ClusterEnvironment__OperationalDatabase__ConnectionSettings__Server
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: Operations_Database_ServerHost
- name: ClusterEnvironment__OperationalDatabase__ConnectionSettings__Username
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: Operations_Database_Server_Username
- name: ClusterEnvironment__OperationalDatabase__ConnectionSettings__Password
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: Operations_Database_Server_Password
- name: ClusterEnvironment__OperationalDatabase__LoggingDatabaseName
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: Operations_Database_Pulse_Logging_Database_Name
- name: ClusterEnvironment__OperationalDatabase__PulseDatabaseName
  valueFrom:
    secretKeyRef:
      name: {{ $secretName | quote }}
      key: Operations_Database_Pulse_Database_Name
{{- end }}
{{- end -}}

{{- define "rpi.telemetry.mode" -}}
{{- $tel := (.Values.observability).telemetry | default dict -}}
{{- $mode := $tel.mode | default "basic" -}}
{{- if not (or (eq $mode "basic") (eq $mode "advanced")) -}}
{{- fail (printf "observability.telemetry.mode must be one of: basic | advanced. Got: %q" $mode) -}}
{{- end -}}
{{- $mode -}}
{{- end -}}

{{/* True when advanced telemetry is selected: the OTel auto-instrumentation
     + shared Collector path. */}}
{{- define "rpi.telemetry.mode.otel" -}}
{{- if eq (include "rpi.telemetry.mode" .) "advanced" -}}true{{- end -}}
{{- end -}}

{{/* OTLP gRPC endpoint of the bundled telemetry bridge: a second
     container in the Observability pod, reachable through the
     Observability Service. */}}
{{- define "rpi.otel.bridge.endpoint" -}}
http://rpi-observability-api.{{ .Release.Namespace }}.svc.cluster.local:4317
{{- end -}}

{{/*
OTel auto-instrumentation env for a participating service reporting to
the telemetry bridge bundled with the Observability pod. Call as
(dict "root" $ "svc" "rpi-executionservice").
Metrics-only: native SqlClient db.client.* metrics ride the OTLP metrics
pipeline; traces stay off (no spans, no spanmetrics).
*/}}
{{- define "rpi.otel.envvars.shared" -}}
{{- /* The instrumentation files ship inside the RPI service images at
       /otel-auto; these env vars are the only activation mechanism. The
       native CLR profiler is libc-specific: glibc images load the
       linux-x64 build; musl (Alpine) images need linux-musl-x64, else the
       profiler fails to load and NO telemetry is emitted. The musl image
       set is operator-declared (observability.telemetry.muslServices). */ -}}
{{- $musl := .root.Values.observability.telemetry.muslServices | default (list "rpi-integrationapi" "rpi-callbackapi" "rpi-deploymentapi") -}}
{{- $arch := ternary "linux-musl-x64" "linux-x64" (has .svc $musl) -}}
- name: CORECLR_ENABLE_PROFILING
  value: "1"
- name: CORECLR_PROFILER
  value: "{918728DD-259F-4A6A-AC2B-B85E1B658318}"
- name: CORECLR_PROFILER_PATH
  value: /otel-auto/{{ $arch }}/OpenTelemetry.AutoInstrumentation.Native.so
- name: DOTNET_ADDITIONAL_DEPS
  value: /otel-auto/AdditionalDeps
- name: DOTNET_SHARED_STORE
  value: /otel-auto/store
- name: DOTNET_STARTUP_HOOKS
  value: /otel-auto/net/OpenTelemetry.AutoInstrumentation.StartupHook.dll
- name: OTEL_DOTNET_AUTO_HOME
  value: /otel-auto
- name: OTEL_SERVICE_NAME
  value: {{ .svc }}
- name: OTEL_METRICS_EXPORTER
  value: otlp
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ include "rpi.otel.bridge.endpoint" .root | quote }}
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: grpc
- name: OTEL_TRACES_EXPORTER
  value: none
- name: OTEL_LOGS_EXPORTER
  value: none
{{- end -}}

{{/*
Operational database type consumed by the RPI services. SQL Server is the
product default and emits nothing. PostgreSQL emits PostgreSQL, or
GoogleCloudSQLPostgreSQL when databases.operational.googleWorkloadIdentity
selects Cloud SQL authentication via GKE Workload Identity (Application
Default Credentials). The Workload Identity path requires platform=google,
cloudIdentity enabled, and no Cloud SQL Auth Proxy: the proxy and native
ADC authentication are alternative ways to reach the same instance.
*/}}
{{- define "rpi.operationalDatabaseType.envvar" -}}
{{- $db := .Values.databases.operational -}}
{{- $wi := default false $db.googleWorkloadIdentity -}}
{{- if $wi -}}
{{- if ne $db.provider "postgresql" -}}
{{- fail "databases.operational.googleWorkloadIdentity requires databases.operational.provider=postgresql" -}}
{{- end -}}
{{- if ne .Values.global.deployment.platform "google" -}}
{{- fail "databases.operational.googleWorkloadIdentity requires global.deployment.platform=google" -}}
{{- end -}}
{{- if not .Values.cloudIdentity.enabled -}}
{{- fail "databases.operational.googleWorkloadIdentity requires cloudIdentity.enabled=true (the pods authenticate with Application Default Credentials)" -}}
{{- end -}}
{{- if ($db.cloudSqlProxy).enabled -}}
{{- fail "databases.operational.googleWorkloadIdentity cannot be combined with databases.operational.cloudSqlProxy.enabled - use the proxy or native Workload Identity authentication, not both" -}}
{{- end -}}
{{- end -}}
{{- if eq $db.provider "postgresql" }}
- name: RPI__OperationalDatabaseType
  value: {{ $wi | ternary "GoogleCloudSQLPostgreSQL" "PostgreSQL" | quote }}
{{- end }}
{{- end -}}

{{/*
Per-client Realtime API address overrides (RealtimeAPIClientOverrides__<n>__*),
consumed by the Interaction API and Execution Service. Each entry routes one
client (tenant) GUID to a specific Realtime API base address. Only meaningful
when multiple Realtime API instances exist, so emission requires
realtimeapi.multitenant=true; a populated list on a single-tenant deployment
fails at render rather than being silently ignored. Empty list emits nothing.
*/}}
{{- define "rpi.realtime.clientOverrides" -}}
{{- $rtCfg := fromYaml (include "rpi.merged.service" (dict "root" . "name" "realtimeapi")) -}}
{{- $overrides := default (list) .Values.realtimeapi.clientAddressOverrides -}}
{{- if and $overrides (not $rtCfg.multitenant) -}}
{{- fail "realtimeapi.clientAddressOverrides requires realtimeapi.multitenant=true - per-client addresses only apply when multiple Realtime API instances exist" -}}
{{- end -}}
{{- if $rtCfg.multitenant -}}
{{- range $i, $o := $overrides }}
- name: RealtimeAPIClientOverrides__{{ $i }}__ClientID
  value: {{ required "realtimeapi.clientAddressOverrides entries require clientId" $o.clientId | quote }}
- name: RealtimeAPIClientOverrides__{{ $i }}__Address
  value: {{ required "realtimeapi.clientAddressOverrides entries require address" $o.address | quote }}
{{- end }}
{{- end -}}
{{- end -}}
