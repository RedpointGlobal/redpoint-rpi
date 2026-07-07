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
Selector labels
*/}}
{{- define "redpoint-rpi.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{/*
Common labels.
Usage:
{{ include "redpoint-rpi.componentLabels" (dict "root" . "component" "api") }}
*/}}
{{- define "redpoint-rpi.componentLabels" -}}
app.kubernetes.io/name: {{ .name | default (include "redpoint-rpi.fullname" .root) }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: rpi
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Common labels.
Usage:
{{ include "smartactivation.componentLabels" (dict "root" . "component" "api") }}
*/}}
{{- define "smartactivation.componentLabels" -}}
app.kubernetes.io/name: {{ .name | default (include "redpoint-rpi.fullname" .root) }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/part-of: smartactivation
{{- end }}

{{/*
Pod-level security context.
Usage: {{- include "rpi.pod.securityContext" (dict "sc" $secCtx) | nindent 6 }}
Options: set "noFsGroup" true or "noSupplementalGroups" true for services that need a minimal context.
*/}}
{{- define "rpi.pod.securityContext" -}}
{{- $sc := .sc -}}
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
*/}}
{{- define "rpi.container.securityContext" -}}
{{- $sc := .sc -}}
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
Topology spread constraints
Usage: {{ include "redpoint-rpi.topologySpreadConstraints" (dict "name" "rpi-realtimeapi" "root" .) }}
*/}}
{{- define "redpoint-rpi.topologySpreadConstraints" -}}
{{- $tsc := fromYaml (include "rpi.merged.topologySpreadConstraints" .) -}}
{{- if $tsc.enabled }}
topologySpreadConstraints:
  - maxSkew: {{ $tsc.maxSkew | default 1 }}
    topologyKey: {{ $tsc.topologyKey | default "topology.kubernetes.io/zone" }}
    whenUnsatisfiable: {{ $tsc.whenUnsatisfiable | default "ScheduleAnyway" }}
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: {{ .name }}
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
Pass "enabled" false to disable all probes for a service (e.g., deploymentapi.enableProbes: false).
*/}}
{{- define "rpi.block.probes" -}}
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
Merge a service's config: chart defaults + global resources + user overrides.
Usage: {{- $cfg := fromYaml (include "rpi.merged.service" (dict "root" . "name" "realtimeapi")) -}}
*/}}
{{- define "rpi.merged.service" -}}
{{- $d := fromYaml (include (printf "rpi.defaults.%s" .name) .root) -}}
{{- $g := .root.Values.resources | default dict -}}
{{- if $g -}}
{{- $_ := set $d "resources" (mustMergeOverwrite ($d.resources | default dict) $g) -}}
{{- end -}}
{{- $u := index .root.Values .name | default dict -}}
{{- toYaml (mustMergeOverwrite $d $u) -}}
{{- end -}}

{{/* --- Shared resource blocks (reduces duplication across deploy-*.yaml files) --- */}}

{{/*
ServiceAccount for per-service mode.
Usage: {{- include "rpi.block.serviceAccount" (dict "root" . "name" $name "component" "api" "cfg" $cfg) }}
*/}}
{{- define "rpi.block.serviceAccount" -}}
{{- if .cfg.serviceAccount.enabled }}
{{- if .cfg.enabled }}
{{- if ne (.root.Values.cloudIdentity.serviceAccount.mode | default "per-service") "shared" }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .name }}
  namespace: {{ .root.Release.Namespace }}
  labels:
    {{- include "redpoint-rpi.componentLabels" (dict "root" .root "name" .name "component" .component) | nindent 4 }}
  {{- $saAnnotations := include "rpi.mergedAnnotations" (dict "root" .root "type" "serviceAccount") | trim }}
  {{- $ciAnnotations := include "rpi.cloudidentity.saAnnotations" (dict "root" .root) | trim }}
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
PodDisruptionBudget.
Usage: {{- include "rpi.block.pdb" (dict "root" . "name" $name "component" "api" "cfg" $cfg) }}
*/}}
{{- define "rpi.block.pdb" -}}
{{- if .cfg.podDisruptionBudget.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .name }}
  namespace: {{ .root.Release.Namespace }}
  labels:
    {{- include "redpoint-rpi.componentLabels" (dict "root" .root "name" .name "component" .component) | nindent 4 }}
spec:
  maxUnavailable: {{ .cfg.podDisruptionBudget.maxUnavailable }}
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ .name }}
{{- end }}
{{- end -}}

{{/*
Pod scheduling: nodeSelector, tolerations, topology spread, anti-affinity.
Usage: {{- include "rpi.block.scheduling" (dict "root" . "name" $name "cfg" $cfg "topo" $topo) | nindent 6 }}
*/}}
{{- define "rpi.block.scheduling" -}}
{{- if .root.Values.nodeSelector.enabled }}
nodeSelector:
  {{ .root.Values.nodeSelector.key }}: {{ .root.Values.nodeSelector.value }}
{{- end }}
{{- if .root.Values.tolerations.enabled }}
tolerations:
  - effect: NoSchedule
    key: {{ .root.Values.nodeSelector.key }}
    operator: Equal
    value: {{ .root.Values.nodeSelector.value }}
{{- end }}
{{- if .root.Values.podAntiAffinity.enabled }}
affinity:
  podAntiAffinity:
    {{- if eq .root.Values.podAntiAffinity.type "preferred" }}
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: {{ .root.Values.podAntiAffinity.weight | default 100 }}
      podAffinityTerm:
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: {{ .name }}
        topologyKey: {{ .root.Values.podAntiAffinity.topologyKey | default "kubernetes.io/hostname" }}
    {{- else }}
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          app.kubernetes.io/name: {{ .name }}
      topologyKey: {{ .root.Values.podAntiAffinity.topologyKey | default "kubernetes.io/hostname" }}
    {{- end }}
{{- end }}
{{- if .topo.enabled }}
topologySpreadConstraints:
- maxSkew: {{ .topo.maxSkew | default 1 }}
  topologyKey: {{ .topo.topologyKey | default "kubernetes.io/hostname" }}
  whenUnsatisfiable: {{ .topo.whenUnsatisfiable | default "ScheduleAnyway" }}
  labelSelector:
    matchLabels:
      app.kubernetes.io/name: {{ .name }}
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
SDK vault env vars — only when secretsManagement.provider == "sdk".
Configures the app to read secrets from the cloud vault at runtime.
Usage: {{- include "rpi.secrets.sdk.envvars" . | nindent 10 }}
*/}}
{{- define "rpi.secrets.sdk.envvars" -}}
{{- if eq .Values.secretsManagement.provider "sdk" -}}
{{- if eq .Values.global.deployment.platform "azure" }}
- name: CloudIdentity__Azure__CredentialType
  value: "AzureIdentity"
- name: CloudIdentity__Azure__UseADTokenForDatabaseConnection
  value: {{ .Values.secretsManagement.sdk.azure.useADTokenForDatabaseConnection | quote }}
- name: KeyVault__Provider
  value: "Azure"
- name: KeyVault__UseForAppSettings
  value: "true"
- name: KeyVault__UseForConfigPasswords
  value: "true"
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
  value: "true"
- name: KeyVault__UseForConfigPasswords
  value: "true"
{{- else if eq .Values.global.deployment.platform "amazon" }}
- name: KeyVault__Provider
  value: "Amazon"
- name: KeyVault__UseForAppSettings
  value: {{ .Values.secretsManagement.sdk.amazon.useForAppSettings | default "true" | quote }}
- name: KeyVault__UseForConfigPasswords
  value: {{ .Values.secretsManagement.sdk.amazon.useForConfigPasswords | default "true" | quote }}
- name: KeyVault__AmazonSettings__AppSettingsTag
  value: {{ .Values.secretsManagement.sdk.amazon.secretTagKey | quote }}
- name: AWS_REGION
  value: {{ .Values.cloudIdentity.amazon.region | default "us-east-1" | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Resolve the K8s secret name — works for kubernetes and csi modes.
Usage: {{ include "rpi.secrets.secretName" . }}
*/}}
{{- define "rpi.secrets.secretName" -}}
{{- if eq .Values.secretsManagement.provider "csi" -}}
{{ .Values.secretsManagement.csi.secretName | default "redpoint-rpi-secrets" }}
{{- else -}}
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
Resolve which ServiceAccount name a pod should use.
Usage: {{ include "rpi.serviceAccountName" (dict "root" . "name" $name "cfg" $cfg) }}
  - root: the top-level context (.)
  - name: the per-service SA name (e.g., "rpi-realtimeapi")
  - cfg:  the merged service config (optional)
Priority:
  1. Per-service override: cfg.serviceAccountName (if set)
  2. Mode=shared: uses the shared SA name
  3. Mode=per-service or both: uses the per-service SA name
*/}}
{{- define "rpi.serviceAccountName" -}}
{{- if and .cfg (hasKey .cfg "serviceAccountName") .cfg.serviceAccountName -}}
{{ .cfg.serviceAccountName }}
{{- else -}}
{{- $mode := .root.Values.cloudIdentity.serviceAccount.mode | default "per-service" -}}
{{- if eq $mode "shared" -}}
{{ .root.Values.cloudIdentity.serviceAccount.name | default "redpoint-rpi" }}
{{- else -}}
{{ .name }}
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
*/}}
{{- define "rpi.image" -}}
{{- $overrides := .root.Values.global.deployment.images.overrides | default dict -}}
{{- $nameOverrides := .root.Values.global.deployment.images.nameOverrides | default dict -}}
{{- $defaultNames := dict "rpi-redis" "rediscache" "rpi-rabbitmq" "rabbitmq" -}}
{{- if hasKey $overrides .name -}}
{{ index $overrides .name }}
{{- else if hasKey $nameOverrides .name -}}
{{ .root.Values.global.deployment.images.registry }}/{{ index $nameOverrides .name }}:{{ .root.Values.global.deployment.images.tag }}
{{- else -}}
{{- $imageName := .name -}}
{{- if hasKey $defaultNames .name -}}
{{- $imageName = index $defaultNames .name -}}
{{- end -}}
{{ .root.Values.global.deployment.images.registry }}/{{ $imageName }}:{{ .root.Values.global.deployment.images.tag }}
{{- end -}}
{{- end -}}

{{/*
Pod anti-affinity block. Renders the full affinity: stanza.
Usage: {{- include "rpi.podAntiAffinity" (dict "root" . "name" $name) | nindent 6 }}
*/}}
{{- define "rpi.podAntiAffinity" -}}
{{- $aa := .root.Values.podAntiAffinity | default dict -}}
{{- $enabled := ternary $aa.enabled true (hasKey $aa "enabled") -}}
{{- if $enabled }}
affinity:
  podAntiAffinity:
    {{- if eq ($aa.type | default "preferred") "required" }}
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: {{ .name }}
        topologyKey: {{ $aa.topologyKey | default "kubernetes.io/hostname" }}
    {{- else }}
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: {{ $aa.weight | default 100 }}
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: {{ .name }}
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
Usage: {{- include "rpi.mergedAnnotations" (dict "root" . "type" "serviceAccount") }}
Merges commonAnnotations + type-specific overrides (serviceAccountAnnotations, serviceAnnotations).
*/}}
{{- define "rpi.mergedAnnotations" -}}
{{- $common := .root.Values.commonAnnotations | default dict -}}
{{- $extra := dict -}}
{{- if eq .type "serviceAccount" -}}
{{- $extra = .root.Values.serviceAccountAnnotations | default dict -}}
{{- else if eq .type "service" -}}
{{- $extra = .root.Values.serviceAnnotations | default dict -}}
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