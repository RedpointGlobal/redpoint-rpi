{{/*
============================================================
  INTERNAL DEFAULTS - _defaults.tpl
============================================================
  Chart-managed defaults that users should NOT edit directly.
  Override any value directly in your overrides file under
  the matching top-level key (e.g., realtimeapi:, ingress:).

  This file defines the default YAML per component; _helpers.tpl merges
  it with your overrides, and your overrides win.

  Sections:
    1. Cross-cutting defaults (probes, security, topology, ingress)
    2. RPI core services (.NET)
    3. Supporting services (Rebrandly, diagnostics)
    4. Smart Activation services (Java)
    5. Utility jobs
============================================================
*/}}


{{/* ============================================================
     1. CROSS-CUTTING DEFAULTS
     ============================================================ */}}

{{/* ------ Security Context ------ */}}
{{- define "rpi.defaults.securityContext" -}}
enabled: true
runAsUser: 7777
runAsGroup: 7777
fsGroup: 7777
runAsNonRoot: true
readOnlyRootFilesystem: true
privileged: false
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
supplementalGroups:
  - 1000
  - 4000
  - 5000
{{- end -}}

{{/* ------ Liveness Probe ------ */}}
{{- define "rpi.defaults.livenessProbe" -}}
enabled: true
httpGet:
  path: /health/live
  port: 8080
  scheme: HTTP
initialDelaySeconds: 60
periodSeconds: 15
timeoutSeconds: 5
failureThreshold: 5
successThreshold: 1
{{- end -}}

{{/* ------ Readiness Probe ------ */}}
{{- define "rpi.defaults.readinessProbe" -}}
enabled: true
httpGet:
  path: /health/ready
  port: 8080
  scheme: HTTP
initialDelaySeconds: 20
periodSeconds: 30
timeoutSeconds: 5
failureThreshold: 5
successThreshold: 1
{{- end -}}

{{/* ------ Startup Probe ------ */}}
{{- define "rpi.defaults.startupProbe" -}}
enabled: true
httpGet:
  path: /health/live
  port: 8080
  scheme: HTTP
initialDelaySeconds: 10
periodSeconds: 10
timeoutSeconds: 5
failureThreshold: 60
successThreshold: 1
{{- end -}}

{{/* ------ Topology Spread Constraints ------ */}}
{{- define "rpi.defaults.topologySpreadConstraints" -}}
enabled: true
maxSkew: 1
topologyKey: kubernetes.io/hostname
whenUnsatisfiable: ScheduleAnyway
{{- end -}}

{{/* ------ Network Policy ------ */}}
{{- define "rpi.defaults.networkPolicy" -}}
allowDNS: true
{{- end -}}

{{/* ------ Ingress ------ */}}
{{- define "rpi.defaults.ingress" -}}
className: {{ .Release.Namespace }}
internalImageOverride:
  enabled: false
  image: registry.k8s.io/ingress-nginx/controller:v1.14.3@sha256:82917be97c0939f6ada1717bb39aa7e66c229d6cfb10dcfc8f1bd42f9efe0f81
service:
  port: 80
tls:
  - secretName: ingress-tls
{{- end -}}

{{/* ------ Diagnostics Mode ------ */}}
{{- define "rpi.defaults.diagnosticsMode" -}}
dotNetTools:
  enabled: false
  useGcDump: false
  useCounters: false
  path: /app/dotnet-tools
  extractionBaseDir: /tmp
netutils:
  enabled: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 7777
    runAsGroup: 7777
    readOnlyRootFilesystem: true
    allowPrivilegeEscalation: false
    privileged: false
    appArmorProfile: ""
    capabilities:
      drop:
        - ALL
      add: ["NET_ADMIN", "NET_RAW"]
{{- end -}}


{{/* ============================================================
     2. RPI CORE SERVICES (.NET)
     ============================================================ */}}

{{/* ------ Realtime API ------ */}}
{{- define "rpi.defaults.realtimeapi" -}}
podAnnotations: {}
podLabels: {}
multitenant: false
name: rpi-realtimeapi
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
authentication:
  type: basic
  basic:
    standard: false
    forms: true
    listenerQueue: true
    recommendations: true
enableHelpPages: true
enableEventListening: true
realtimeProcessingEnabled: true
ThresholdBetweenSiteVisitsMinutes: 120
ThresholdBetweenPageVisitsMinutes: 1
CacheWebFormData: false
decisionCacheDuration: 60
enableAuditMetricsInHeaders: true
cacheOutputQueueEnabled: true
RealtimeServerCookieEnabled: false
RealtimeServerCookieName: rg-visitor
RealtimeServerCookieExpires: 60
RealtimeServerCookieDomain: ""
RealtimeServerCookieHttpOnly: false
CacheOutputCollectIPAddress: true
HashVisitorID: false
EventListeningLocalCacheDuration: 60
dataMaps:
  visitorProfile:
    DaysToPersist: 365
    CompressData: true
  visitorHistory:
    DaysToPersist: 365
    CompressData: true
  nonVisitorData:
    DaysToPersist: 365
    CompressData: true
  productRecommendation:
    DaysToPersist: 365
    CompressData: true
  offerHistory:
    DaysToPersist: 365
    CompressData: true
  messageHistory:
    DaysToPersist: 365
    CompressData: true
idValidation:
  enableVisitorIDValidation: true
  visitorID:
    minimumLength: 1
    maximumLength: 36
    enableLetters: true
    enableNumbers: true
    permittedCharacters:
      - "-"
      - "_"
      - "/"
      - "."
      - "@"
      - "#"
      - "&"
      - "?"
  enableDeviceIDValidation: true
  deviceID:
    minimumLength: 1
    maximumLength: 36
    enableLetters: true
    enableNumbers: true
    permittedCharacters:
      - "-"
      - "_"
      - "/"
      - "."
      - "@"
      - "#"
      - "&"
      - "?"
service:
  port: 80
customMetrics:
  enabled: false
  prometheus_scrape: true
terminationGracePeriodSeconds: 120
logging:
  realtimeagent:
    default: Error
    database: Error
    rpiTrace: Error
    rpiError: Error
    console: Error
  realtimeapi:
    default: Error
    endpoint: Error
    shared: Error
    plugins: Error
    other: Error
    console: "false"
autoscaling:
  enabled: false
  type: hpa
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
podDisruptionBudget:
  enabled: false
  minAvailable: 1
resources:
  enabled: true
queueProvider:
  amazonsqs:
    visibilityTimeout: "301"
  azurestorage:
    sendVisibilityTimeout: 1
    receiveVisibilityTimeout: 1
  azureeventhubs:
    SendMessageBatchSize: 200
    ReceiveMessageBatchSize: 200
  amazonmsk:
    Acks: None
    CompressionType: Snappy
    MaxRetryAttempt: 10
    BatchSize: "1000000"
    LingerTime: 0
    UseAwsMsk: "True"
  rabbitmq:
    rabbitmqSettings:
      hostname: "rpi-realtimeapi-rabbitmq"
      username: redpointrpi
      virtualhost: /
      resources:
        enabled: true
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: 1
          memory: 1Gi
      volumeClaimTemplates:
        enabled: true
        storage: 100Gi
      volumes:
        enabled: false
        claimName: rpi-realtimeapi-rabbitmq-data
      podDisruptionBudget:
        enabled: false
        minAvailable: 1
cacheProvider:
  redis:
    redisSettings:
      resources:
        enabled: true
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          memory: 3Gi
      volumeClaimTemplates:
        enabled: true
        storage: 50Gi
      podDisruptionBudget:
        enabled: false
        minAvailable: 1
{{- end -}}

{{/* ------ Callback API ------ */}}
{{- define "rpi.defaults.callbackapi" -}}
podAnnotations: {}
podLabels: {}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
service:
  port: 80
customMetrics:
  enabled: false
  prometheus_scrape: true
terminationGracePeriodSeconds: 120
logging:
  default: Error
  database: Error
  rpiTrace: Error
  rpiError: Error
  Console: Error
autoscaling:
  enabled: false
  type: hpa
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
podDisruptionBudget:
  enabled: false
  minAvailable: 1
resources:
  enabled: true
{{- end -}}

{{/* ------ Execution Service ------ */}}
{{- define "rpi.defaults.executionservice" -}}
podAnnotations: {}
podLabels: {}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
service:
  port: 80
customMetrics:
  enabled: false
  prometheus_scrape: false
terminationGracePeriodSeconds: 120
enableRPIAuthentication: true
logging:
  default: Error
  database: Error
  rpiTrace: Error
  rpiError: Error
  Console: Error
autoscaling:
  enabled: false
  type: hpa
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
  kedaScaledObject:
    serverAddress: ""
    useTriggerAuthentication: true
    authenticationRef: rpi-executionservice
    identityId: ""
    metricName: execution_max_thread_count
    query: ""
    threshold: "80"
    pollingInterval: 30
    minReplicaCount: 2
    maxReplicaCount: 10
    fallback:
      failureThreshold: 3
      replicas: 2
    behavior:
      scaleUp:
        stabilizationWindowSeconds: 300
        policies:
          type: Percent
          value: 100
          periodSeconds: 60
      scaleDown:
        stabilizationWindowSeconds: 300
        policies:
          type: Percent
          value: 50
          periodSeconds: 60
    terminationGracePeriodSeconds: 120
podDisruptionBudget:
  enabled: false
  minAvailable: 1
resources:
  enabled: true
jobExecution:
  internalAddress: ""
  auditTaskEvents: true
  maxThreadsPerExecutionService: 100
  executionShutdownWaitForActivity: "00:08:00"
  overrideCustomSQLReservedWords: false
  maxSmartAssetInstancesForOfferCodes: "100000"
  rpdmOApiPrefixUri: /v1/
  rpdmOApiRequestTimeout: "200"
  taskTimeout: 60
  triggerCheckCriteriaInterval: 60
  triggersMaxDaysInactive: 180
  defaultMaintenanceModeBufferTime: "00:05:00"
  workflowPrioritization:
    enabled: true
    maxConcurrentWorkflowActivities: 100
    maximumQueueTime: "24:00:00"
  luxScisendRequestCount: 5
internalCache:
  backupToOpsDBInterval: "00:00:20"
  maxNumberRetries: "100"
  maxRetryDelay: "00:01:00"
  failOnPrimaryDataLoss: true
  failOnCacheConnectionError: true
seedService:
  memoryCacheSize: "10"
  maxNumberRetries: "100"
  maxRetryDelay: "00:01:00"
extraEnvs:
  - name: Plugins__LuxSci__IsSandboxMode
    enabled: false
    value: "true"
  - name: Plugins__SendGrid__EnableSandBoxMode
    enabled: false
    value: "true"
  - name: Plugins__Twilio__DisableSendSMSCampaign
    enabled: false
    value: "true"
  - name: RPI_MPULSE_UPSERT_CONTACT_DEBUG
    enabled: false
    value: "1"
  - name: RPI_MPULSE_EVENT_UPLOAD_DEBUG
    enabled: false
    value: "1"
  - name: LC_ALL
    enabled: false
    value: "en_US.UTF-8"
  - name: LANG
    enabled: false
    value: "en_US.UTF-8"
  - name: LANGUAGE
    enabled: false
    value: "en_US.UTF-8"
  - name: RPI_MPULSE_EVENT_UPLOAD_FAIL_DEBUG
    enabled: false
    value: "0"
  - name: RPI_MPULSE_EVENT_UPLOAD_SCENARIO
    enabled: false
    value: "1,5,2,3,5,7"
  - name: RPI_MPULSE_SAVE_MPULSE_EVENT_CONTENT_DEBUG
    enabled: false
    value: "1"
  - name: RPI_MPULSE_UPSERT_CONTACT_IMPORT_PATH_DEBUG
    enabled: false
    value: "/rpifileoutputdir/mpulse-debug-path"
{{- end -}}

{{/* ------ Interaction API ------ */}}
{{- define "rpi.defaults.interactionapi" -}}
podAnnotations: {}
podLabels: {}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
authMetaHttpEnabled: true
enableSwagger: true
allowSavingLoginDetails: true
alwaysShowClientsAtLogin: true
useExternalUserManagement: false
service:
  port: 80
customMetrics:
  enabled: false
  prometheus_scrape: false
terminationGracePeriodSeconds: 120
enableRPIAuthentication: true
productUpdateFeed:
  enabled: true 
  url: https://www.redpointglobal.com/feed/productfeed
logging:
  default: Error
  database: Error
  rpiTrace: Error
  rpiError: Error
  Console: Error
autoscaling:
  enabled: false
  type: hpa
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
podDisruptionBudget:
  enabled: false
  minAvailable: 1
resources:
  enabled: true
{{- end -}}

{{/* ------ Integration API ------ */}}
{{- define "rpi.defaults.integrationapi" -}}
podAnnotations: {}
podLabels: {}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
enableSwagger: true
authMetaHttpEnabled: false
read_timeout: "300000"
service:
  port: 80
customMetrics:
  enabled: false
  prometheus_scrape: true
terminationGracePeriodSeconds: 120
enableRPIAuthentication: true
logging:
  default: Error
  database: Error
  rpiTrace: Error
  rpiError: Error
  Console: Error
autoscaling:
  enabled: false
  type: hpa
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
podDisruptionBudget:
  enabled: false
  minAvailable: 1
resources:
  enabled: true
{{- end -}}

{{/* ------ Node Manager ------ */}}
{{- define "rpi.defaults.nodemanager" -}}
podAnnotations: {}
podLabels: {}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
service:
  port: 80
customMetrics:
  enabled: false
  prometheus_scrape: false
terminationGracePeriodSeconds: 120
enableRPIAuthentication: true
logging:
  default: Error
  database: Error
  rpiTrace: Error
  rpiError: Error
  Console: Error
autoscaling:
  enabled: false
  type: hpa
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
podDisruptionBudget:
  enabled: false
  minAvailable: 1
resources:
  enabled: true
{{- end -}}

{{/* ------ Deployment API ------ */}}
{{- define "rpi.defaults.deploymentapi" -}}
podAnnotations: {}
podLabels: {}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
service:
  port: 80
customMetrics:
  enabled: false
  prometheus_scrape: false
terminationGracePeriodSeconds: 120
logging:
  default: Error
  database: Error
  rpiTrace: Error
  rpiError: Error
  Console: Error
resources:
  enabled: true
{{- end -}}

{{/* ------ Queue Reader ------ */}}
{{- define "rpi.defaults.queuereader" -}}
podAnnotations: {}
podLabels: {}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
service:
  port: 80
serviceAccount:
  enabled: true
isFormProcessingEnabled: true
isEventProcessingEnabled: true
isCacheProcessingEnabled: true
queueListenerEnabled: true
isCallbackServiceProcessingEnabled: true
nonActiveQueuePath: listenerQueueNonActive
listenerQueueNonActiveTTLDays: 14
errorQueuePath: listenerQueueError
listenerQueueErrorTTLDays: 14
maintenanceModeBufferTime: "00:01:00"
threadPoolSize: 10
timeoutMinutes: 60
maxBatchSize: 50
useMessageLocks: true
partitionHandler:
  partitionLockDuration: "00:02:00"
  offsetPositionTTL: "23:59:59"
  deduplicationCacheTTL: "01:00:00"
seedService:
  memoryCacheSize: "10"
  maxNumberRetries: "100"
  maxRetryDelay: "00:01:00"
realtimeConfiguration:
  isDistributed: true
internalCache:
  backupToOpsDBInterval: "00:00:20"
  redisSettings:
    replicas: 1
    resources:
      enabled: true
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 3Gi
    volumeClaimTemplates:
      enabled: true
      storage: 100Gi
    podDisruptionBudget:
      enabled: false
      minAvailable: 1
internalQueues:
  rabbitmqSettings:
    virtualhost: /
    hostname: rpi-queuereader-rabbitmq
    username: rabbitmq
    resources:
      enabled: true
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 3Gi
    volumeClaimTemplates:
      enabled: true
      storage: 100Gi
    volumes:
      enabled: false
      claimName: rpi-queuereader-rabbitmq-data
customMetrics:
  enabled: false
  prometheus_scrape: true
terminationGracePeriodSeconds: 120
logging:
  default: Error
  database: Error
  rpiTrace: Error
  rpiError: Error
  Console: Error
autoscaling:
  enabled: false
  type: hpa
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
podDisruptionBudget:
  enabled: false
  minAvailable: 1
resources:
  enabled: true
{{- end -}}


{{/* ============================================================
     3. SUPPORTING SERVICES
     ============================================================ */}}

{{/* ------ Rebrandly (URL Shortener) ------ */}}
{{- define "rpi.defaults.rebrandly" -}}
podAnnotations: {}
podLabels: {}
baseUrl: https://api.rebrandly.com
enterpriseBaseUrl: https://enterprise-api.rebrandly.com
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
replicas: 1
serviceAccount:
  enabled: true
redisSettings:
  resources:
    requests:
      cpu: 50m
      memory: 256Mi
    limits:
      memory: 3Gi
      cpu: 3000m
  volumeClaimTemplates:
    enabled: false
    type: dynamic
    size: 50Gi
    storageClassName: default
    accessModes: ReadWriteOnce
service:
  port: 80
customMetrics:
  enabled: false
  prometheus_scrape: false
terminationGracePeriodSeconds: 120
logging:
  default: Error
  aspNetCore: Error
resources:
  enabled: true
{{- end -}}

{{/* ------ Twilio Messaging ------ */}}
{{- define "rpi.defaults.twiliomessaging" -}}
podAnnotations: {}
podLabels: {}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
replicas: 1
enableProbes: true
serviceAccount:
  enabled: true
service:
  port: 80
messaging:
  provider: EventHub
redisSettings:
  type: internal
  hostname: ""
  port: 6379
  user: ""
  useTls: true
  region: ""
  cacheName: ""
  isServerless: false
  resources:
    requests:
      cpu: 50m
      memory: 256Mi
    limits:
      memory: 3Gi
      cpu: 3000m
  volumeClaimTemplates:
    enabled: false
    type: dynamic
    size: 50Gi
    storageClassName: default
    accessModes: ReadWriteOnce
postgres:
  reuseOperational: true
  host: ""
  port: 5432
  database: twilio_messaging
  username: ""
  sslMode: Require
  maxPoolSize: 20
  minPoolSize: 2
rds:
  region: us-east-1
eventHubs:
  fullyQualifiedNamespace: ""
  inputHub:
    name: twilio-messaging-input
    consumerGroup: twilio-message-input-send
  outputHub:
    name: twilio-messaging-output
  outputInternalHub:
    name: twilio-messaging-output-internal
    deliveryStatusConsumerGroup: twilio-messaging-output-internal-delivery-status
    linkClickConsumerGroup: twilio-messaging-output-internal-link-click
    inboundMessageConsumerGroup: twilio-messaging-output-internal-inbound-reply
  checkpointing:
    blobServiceUri: ""
    blobContainerName: sms-send-checkpoints
sqs:
  region: us-east-1
  inputQueueUrl: ""
  outputTopicArn: ""
  outputInternalTopicArn: ""
  outputDeliveryStatusQueueUrl: ""
  outputLinkClickQueueUrl: ""
  outputInboundMessageQueueUrl: ""
pubsub:
  projectId: ""
  inputTopicId: twilio-messaging-input
  inputSubscriptionId: twilio-messaging-input
  outputTopicId: twilio-messaging-output
  outputInternalTopicId: twilio-messaging-output-internal
  outputDeliveryStatusSubscriptionId: twilio-messaging-output-internal-delivery-status
  outputLinkClickSubscriptionId: twilio-messaging-output-internal-link-click
  outputInboundMessageSubscriptionId: twilio-messaging-output-internal-inbound-reply
accountSid: ""
isTestCredentials: false
batchIngestion:
  watchDirectory: /rpifileoutputdir/twilio/batch/incoming
  processingDirectory: /rpifileoutputdir/twilio/batch/processing
  completeDirectory: /rpifileoutputdir/twilio/batch/complete
  failedBatchDirectory: /rpifileoutputdir/twilio/batch/failed
  pollIntervalSeconds: 5
  lockTtlMinutes: 10
batchCompletion:
  pollIntervalSeconds: 60
  completionThresholdHours: 12
  parallelMergeDegree: 4
customMetrics:
  enabled: false
  prometheus_scrape: false
terminationGracePeriodSeconds: 120
logging:
  default: Information
  aspNetCore: Warning
resources:
  enabled: true
{{- end -}}


{{/* ============================================================
     4. SMART ACTIVATION SERVICES (Java)
     ============================================================ */}}

{{/* ------ Auth Service ------ */}}
{{- define "rpi.defaults.authservice" -}}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
service:
  port: 80
logging:
  verbosity: DEBUG
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
terminationGracePeriodSeconds: 120
resources:
  enabled: true
  java_opts: "-Xmx1536m"
securityContext:
  enabled: true
  runAsUser: 7777
  runAsGroup: 7777
  fsGroup: 7777
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  privileged: false
  appArmorProfile: ""
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
rollingUpdate:
  maxUnavailable: "25%"
  maxSurge: "25%"
  progressDeadlineSeconds: 600
podDisruptionBudget:
  enabled: false
  minAvailable: 1
{{- end -}}

{{/* ------ Keycloak ------ */}}
{{- define "rpi.defaults.keycloak" -}}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
service:
  port: 80
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
resources:
  enabled: true
securityContext:
  enabled: true
  runAsUser: 1001
  runAsGroup: 1001
  fsGroup: 1001
  runAsNonRoot: true
  readOnlyRootFilesystem: false
  privileged: false
  appArmorProfile: ""
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
rollingUpdate:
  maxUnavailable: "25%"
  maxSurge: "25%"
  progressDeadlineSeconds: 600
podDisruptionBudget:
  enabled: false
  minAvailable: 1
{{- end -}}

{{/* ------ Init Service ------ */}}
{{- define "rpi.defaults.initservice" -}}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
service:
  port: 80
resources:
  enabled: true
  java_opts: "-Xmx2150m"
logging:
  verbosity: DEBUG
securityContext:
  enabled: true
  runAsUser: 7777
  runAsGroup: 7777
  fsGroup: 7777
  runAsNonRoot: true
  readOnlyRootFilesystem: false
  privileged: false
  appArmorProfile: ""
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
rollingUpdate:
  maxUnavailable: "25%"
  maxSurge: "25%"
  progressDeadlineSeconds: 600
podDisruptionBudget:
  enabled: false
  minAvailable: 1
{{- end -}}

{{/* ------ Message Queue ------ */}}
{{- define "rpi.defaults.messageq" -}}
type: StatefulSet
port: 5672
serviceAccount:
  enabled: true
resources:
  enabled: true
securityContext:
  enabled: true
  runAsUser: 7777
  runAsGroup: 7777
  fsGroup: 7777
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  privileged: false
  appArmorProfile: ""
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
podDisruptionBudget:
  enabled: false
  minAvailable: 1
volumeClaimTemplates:
  storage: 100Gi
{{- end -}}

{{/* ------ Maintenance Service ------ */}}
{{- define "rpi.defaults.maintenanceservice" -}}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
port: 80
resources:
  enabled: true
  java_opts: "-Xmx1536m"
logging:
  verbosity: DEBUG
securityContext:
  enabled: true
  runAsUser: 7777
  runAsGroup: 7777
  fsGroup: 7777
  runAsNonRoot: true
  readOnlyRootFilesystem: false
  privileged: false
  appArmorProfile: ""
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
rollingUpdate:
  maxUnavailable: "25%"
  maxSurge: "25%"
  progressDeadlineSeconds: 600
podDisruptionBudget:
  enabled: false
  minAvailable: 1
{{- end -}}

{{/* ------ Services API ------ */}}
{{- define "rpi.defaults.servicesapi" -}}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
service:
  port: 80
resources:
  enabled: true
  java_opts: "-Xmx2150m"
logging:
  verbosity: DEBUG
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
securityContext:
  enabled: true
  runAsUser: 7777
  runAsGroup: 7777
  fsGroup: 7777
  runAsNonRoot: true
  readOnlyRootFilesystem: false
  privileged: false
  appArmorProfile: ""
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
podDisruptionBudget:
  enabled: false
  minAvailable: 1
{{- end -}}

{{/* ------ Socket.IO ------ */}}
{{- define "rpi.defaults.socketio" -}}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
keycloak_realm: "redpoint-mercury"
service:
  port: 80
resources:
  enabled: true
  java_opts: "-Xmx1536m"
logging:
  verbosity: DEBUG
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
securityContext:
  enabled: true
  runAsUser: 7777
  runAsGroup: 7777
  fsGroup: 7777
  runAsNonRoot: true
  readOnlyRootFilesystem: false
  privileged: false
  appArmorProfile: ""
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
podDisruptionBudget:
  enabled: false
  minAvailable: 1
{{- end -}}

{{/* ------ UI Service ------ */}}
{{- define "rpi.defaults.uiservice" -}}
type: deployment
rollout:
  autoPromotionEnabled: true
  revisionHistoryLimit: 3
serviceAccount:
  enabled: true
service:
  port: 80
resources:
  enabled: true
  java_opts: "-Xmx2150m"
logging:
  verbosity: DEBUG
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
securityContext:
  enabled: true
  runAsUser: 7777
  runAsGroup: 7777
  fsGroup: 7777
  runAsNonRoot: true
  readOnlyRootFilesystem: false
  privileged: false
  appArmorProfile: ""
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
podDisruptionBudget:
  enabled: false
  minAvailable: 1
{{- end -}}

{{/* ------ CDP Cache ------ */}}
{{- define "rpi.defaults.cdpcache" -}}
type: StatefulSet
serviceAccount:
  enabled: true
service:
  port: 6379
resources:
  enabled: true
securityContext:
  enabled: true
  runAsUser: 7777
  runAsGroup: 7777
  fsGroup: 7777
  runAsNonRoot: true
  readOnlyRootFilesystem: false
  privileged: false
  appArmorProfile: ""
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
podDisruptionBudget:
  enabled: false
  minAvailable: 1
volumeClaimTemplates:
  storage: 100Gi
{{- end -}}

{{/* ============================================================
     5. UTILITY JOBS
     ============================================================ */}}

{{/* ------ Post-Install Job ------ */}}
{{- define "rpi.defaults.postInstall" -}}
enabled: false
existingSecret: ""
activationKey: ""
systemName: ""
adminUsername: coreuser
adminPassword: ""
adminEmail: ""
deploymentapiHost: rpi-deploymentapi
deploymentapiPort: "80"
waitTimeout: "360"
maxReadyWaitSeconds: "600"
pollIntervalSeconds: "15"
backoffLimit: 3
tenant:
  enabled: false
  name: ""
  existingSecret: ""
  dataWarehouse:
    provider: SQLServer
    server: ""
    database: ""
    username: ""
    password: ""
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
{{- end -}}

{{/* ------ Database Upgrade Job ------ */}}
{{- define "rpi.defaults.databaseUpgrade" -}}
enabled: false
deploymentapiHost: rpi-deploymentapi
deploymentapiPort: "80"
healthPath: /health/ready
upgradePath: /api/deployment/upgrade
waitTimeoutSeconds: "360"
maxReadyWaitSeconds: "600"
pollIntervalSeconds: "15"
backoffLimit: 3
ttlSecondsAfterFinished: 3600
activeDeadlineSeconds: 900
notification:
  enabled: false
  recipientEmail: ""
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
{{- end -}}

