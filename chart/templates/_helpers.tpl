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
Common component labels for an RPI resource.
Usage: {{ include "redpoint-rpi.componentLabels" (dict "root" . "name" $name "component" "api") }}

Contract:
  required:
    .root       -- chart root context
    .component  -- component label (e.g. "api", "worker", "intelligence",
                   "database", "messaging", "storage",
                   "networkutils", "controller", "node-provisioning",
                   "datawarehouse"). Identifier
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
                   .podDisruptionBudget.enabled, .podDisruptionBudget.minAvailable)
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
  minAvailable: {{ $cfg.podDisruptionBudget.minAvailable }}
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
{{- $root := .root -}}
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
{{- $root := .root -}}
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
{{- else -}}
{{- /* kubernetes, plus sdk or unknown: secretKeyRef bindings are gated off
       in SDK mode so that branch is rarely consumed; it falls back to the
       kubernetes name to keep manifests renderable. */ -}}
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
{{- if hasKey $overrides $name -}}
{{ index $overrides $name }}
{{- else if hasKey $nameOverrides $name -}}
{{ $root.Values.global.deployment.images.registry }}/{{ index $nameOverrides $name }}:{{ $root.Values.global.deployment.images.tag }}
{{- else -}}
{{- $imageName := $name -}}
{{- if eq $name "rpi-redis" -}}
{{- $imageName = "rediscache" -}}
{{- else if eq $name "rpi-rabbitmq" -}}
{{- $imageName = "rabbitmq" -}}
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
{{- else }}
{{- fail "customCACerts.enabled=true requires customCACerts.name (the Secret containing the CA bundle) or customCACerts.secretProviderClassName." }}
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
{{- if and (eq (.Values.global.deployment.platform | default "") "google") ($cfg.enabled | default false) (or (eq $provider "postgresql") (eq $provider "sqlserver")) -}}
{{- if not .Values.cloudIdentity.enabled -}}
{{- fail "databases.operational.cloudSqlProxy.enabled=true requires cloudIdentity.enabled=true. The Cloud SQL Auth Proxy authenticates to Cloud SQL with the pod's Google identity (Workload Identity, or a mounted service account key under cloudIdentity.google). The secret provider (kubernetes, csi, or sdk) is independent of the proxy." -}}
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
Effective RabbitMQ username for the Realtime queue provider. The
operator-set realtimeapi.queueProvider.rabbitmq.rabbitmqSettings.username
wins; otherwise the release namespace applies (matching the generated
internal-services credential convention).
*/}}
{{- define "rpi.realtime.rabbitmqUsername" -}}
{{- $rtCfg := fromYaml (include "rpi.merged.service" (dict "root" . "name" "realtimeapi")) -}}
{{- $rtCfg.queueProvider.rabbitmq.rabbitmqSettings.username | default .Release.Namespace -}}
{{- end -}}

{{/*
Effective internal-queue (RabbitMQ) username for the queue reader. The
operator-set queuereader.internalQueues.rabbitmqSettings.username wins;
otherwise the release namespace applies (matching the generated
internal-services credential convention).
*/}}
{{- define "rpi.queuereader.internalQueueUsername" -}}
{{- $qrCfg := fromYaml (include "rpi.merged.service" (dict "root" . "name" "queuereader")) -}}
{{- $qrCfg.internalQueues.rabbitmqSettings.username | default .Release.Namespace -}}
{{- end -}}

{{/*
Effective Realtime cache provider. The operator-set
realtimeapi.cacheProvider.provider wins; when unset, the platform default
applies (google: googlebigtable; azure, amazon, selfhosted: mongodb).
Every template that branches on the cache provider consumes this helper,
so a DataMap cache always resolves to a concrete provider.
*/}}
{{- define "rpi.realtime.cacheProvider" -}}
{{- $rtCfg := fromYaml (include "rpi.merged.service" (dict "root" . "name" "realtimeapi")) -}}
{{- if $rtCfg.cacheProvider.provider -}}
{{- $rtCfg.cacheProvider.provider -}}
{{- else if eq .Values.global.deployment.platform "google" -}}
googlebigtable
{{- else -}}
mongodb
{{- end -}}
{{- end -}}

{{/*
Effective Realtime queue provider. The operator-set
realtimeapi.queueProvider.provider wins; when unset, the platform default
applies (azure: azureservicebus; amazon: amazonsqs; google: googlepubsub;
selfhosted: rabbitmq).
*/}}
{{- define "rpi.realtime.queueProvider" -}}
{{- $rtCfg := fromYaml (include "rpi.merged.service" (dict "root" . "name" "realtimeapi")) -}}
{{- if $rtCfg.queueProvider.provider -}}
{{- $rtCfg.queueProvider.provider -}}
{{- else if eq .Values.global.deployment.platform "azure" -}}
azureservicebus
{{- else if eq .Values.global.deployment.platform "amazon" -}}
amazonsqs
{{- else if eq .Values.global.deployment.platform "google" -}}
googlepubsub
{{- else -}}
rabbitmq
{{- end -}}
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
