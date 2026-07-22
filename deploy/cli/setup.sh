#!/usr/bin/env bash
# ============================================================
# Redpoint Interaction CLI
# ============================================================
# Interactive deployment generator for RPI on Kubernetes.
#
# Generates three files:
#   1. overrides.yaml    — Helm values (no secrets)
#   2. secrets.yaml      — Kubernetes Secret manifest
#   3. prereqs.sh        — kubectl commands for namespace, registry, TLS
#
# Usage:
#   rpihelmcli
#   rpihelmcli -o my-overrides.yaml
# ============================================================

set -euo pipefail

# --- Defaults ---
OUTPUT_FILE="overrides.yaml"
SECRETS_FILE="secrets.yaml"
PREREQS_FILE="prereqs.sh"
DEFAULT_TAG="7.7.20260220.1524"
DEFAULT_NAMESPACE="redpoint-rpi"
DEFAULT_REGISTRY="rg1acrpub.azurecr.io/docker/redpointglobal/releases"
SECRET_NAME="redpoint-rpi-secrets"

# --- Parse arguments ---
ADD_MODE=false
ADD_FEATURE=""
FILE_MODE=false
INPUT_FILE="inputs.yaml"

# --- Handle positional commands (status, troubleshoot, secrets, deploy) ---
# These run before getopts since they are standalone commands, not flags.
if [ "${1:-}" = "check" ] || [ "${1:-}" = "status" ] || [ "${1:-}" = "troubleshoot" ] || \
   [ "${1:-}" = "secrets" ] || [ "${1:-}" = "deploy" ]; then
  CLI_COMMAND="$1"
  shift
  # Parse command-specific flags
  CLI_NAMESPACE="${DEFAULT_NAMESPACE}"
  CLI_SYMPTOM=""
  CLI_OVERRIDES=""
  CLI_SECRETS_OUT="secrets.yaml"
  CLI_CHART="./chart"
  CLI_RELEASE="rpi"
  CLI_DRY_RUN=false
  while getopts "n:f:o:c:r:-:" _cmd_opt 2>/dev/null; do
    case "$_cmd_opt" in
      n) CLI_NAMESPACE="$OPTARG" ;;
      f) CLI_OVERRIDES="$OPTARG" ;;
      o) CLI_SECRETS_OUT="$OPTARG" ;;
      c) CLI_CHART="$OPTARG" ;;
      r) CLI_RELEASE="$OPTARG" ;;
      -)
        case "$OPTARG" in
          dry-run) CLI_DRY_RUN=true ;;
        esac ;;
      *) ;;
    esac
  done
  shift $((OPTIND - 1))
  # Remaining positional arg is symptom (for troubleshoot)
  CLI_SYMPTOM="${1:-}"
fi

while getopts "o:a:fh" opt; do
  case $opt in
    o) OUTPUT_FILE="$OPTARG" ;;
    a) ADD_MODE=true; ADD_FEATURE="$OPTARG" ;;
    f) FILE_MODE=true ;;
    h)
      echo "Usage: rpihelmcli/setup.sh check [-f overrides.yaml]"
      echo "       rpihelmcli/setup.sh secrets -f <overrides> [-o secrets.yaml] [-n namespace]"
      echo "       rpihelmcli/setup.sh deploy -f <overrides> [-n namespace] [-c chart-path] [-r release-name] [--dry-run]"
      echo "       rpihelmcli/setup.sh status [-n namespace]"
      echo "       rpihelmcli/setup.sh troubleshoot [-n namespace] [symptom]"
      echo ""
      echo "  Commands:"
      echo "    check            Pre-flight checks (tools, cluster, overrides validation)"
      echo "    secrets          Generate secrets.yaml from an overrides file"
      echo "    deploy           Deploy RPI (auto-clones chart, creates namespace, runs helm install/upgrade)"
      echo "    status           Show RPI pod, service, and ingress status"
      echo "    troubleshoot     Diagnose common deployment issues"
      echo ""
      echo "  Options for secrets:"
      echo "    -f <file>        Overrides file to read configuration from (required)"
      echo "    -o <file>        Output secrets file (default: secrets.yaml)"
      echo "    -n <namespace>   Kubernetes namespace (default: ${DEFAULT_NAMESPACE})"
      echo ""
      echo "  Options for deploy:"
      echo "    -f <file>        Overrides file (required)"
      echo "    -n <namespace>   Kubernetes namespace (default: ${DEFAULT_NAMESPACE})"
      echo "    -c <path>        Chart path (default: auto-clone from GitHub)"
      echo "    --dry-run        Render templates without deploying"
      echo ""
      echo "  Options for status/troubleshoot:"
      echo "    -n <namespace>   Kubernetes namespace (default: ${DEFAULT_NAMESPACE})"
      echo "    [symptom]        Troubleshoot hint: crashloop, pending, imagepull"
      echo ""
      echo "  Generate your overrides at: https://rpi-helm-assistant.redpointcdp.com"
      echo ""
      echo "  Examples:"
      echo "    rpihelmcli/setup.sh check -f overrides.yaml   # Pre-flight checks"
      echo "    rpihelmcli/setup.sh secrets -f overrides.yaml # Generate secrets"
      echo "    rpihelmcli/setup.sh deploy -f overrides.yaml --dry-run  # Preview"
      echo "    rpihelmcli/setup.sh deploy -f overrides.yaml  # Deploy to cluster"
      echo "    rpihelmcli/setup.sh status -n my-namespace    # Cluster status"
      echo "    rpihelmcli/setup.sh troubleshoot -n my-namespace crashloop"
      exit 0
      ;;
    *) echo "Unknown option: -$opt" >&2; exit 1 ;;
  esac
done

# --- Colors & Symbols ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
YAML_HELPER="${SCRIPT_DIR}/lib/yaml_helpers.py"

ICON_CHECK="${GREEN}✔${RESET}"
ICON_WARN="${YELLOW}⚠${RESET}"
ICON_FILE="${CYAN}📄${RESET}"
ICON_KEY="${YELLOW}🔑${RESET}"
ICON_ROCKET="${GREEN}🚀${RESET}"

# --- Helpers ---
section() {
  echo ""
  echo "${CYAN}${BOLD}━━━ $1 ━━━${RESET}"
}

prompt() {
  local var_name=$1 prompt_text=$2 default=$3
  local value
  if [ -n "$default" ]; then
    read -rp "  ${prompt_text} ${DIM}[${default}]${RESET}: " value
    value="${value:-$default}"
  else
    read -rp "  ${prompt_text}: " value
  fi
  eval "$var_name=\"\$value\""
}

prompt_choice() {
  local var_name=$1 prompt_text=$2 options=$3 default=$4
  local value
  while true; do
    read -rp "  ${prompt_text} ${DIM}(${options}) [${default}]${RESET}: " value
    value="${value:-$default}"
    if echo "$options" | tr '|' '\n' | grep -qx "$value"; then
      break
    fi
    echo "  ${RED}Invalid choice. Options: ${options}${RESET}" >&2
  done
  eval "$var_name=\"\$value\""
}

prompt_yesno() {
  local var_name=$1 prompt_text=$2 default=$3
  local value
  while true; do
    read -rp "  ${prompt_text} ${DIM}(y/n) [${default}]${RESET}: " value
    value="${value:-$default}"
    case "$value" in
      y|Y|yes) eval "$var_name=true"; break ;;
      n|N|no)  eval "$var_name=false"; break ;;
      *) echo "  ${RED}Please enter y or n${RESET}" >&2 ;;
    esac
  done
}

prompt_secret() {
  local var_name=$1 prompt_text=$2
  local value
  read -rsp "  ${prompt_text}: " value
  echo "" >&2
  eval "$var_name=\"\$value\""
}

# Append a key-value pair to the secrets file.
# Creates the secrets file if it does not exist (for --add mode).
append_secret() {
  local key=$1 value=$2
  if [ ! -f "$SECRETS_FILE" ]; then
    cat > "$SECRETS_FILE" << SECRETS_INIT
# ============================================================
# RPI Kubernetes Secret — Generated by Interaction CLI
# $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# ============================================================
# Apply BEFORE helm install:
#   kubectl apply -f ${SECRETS_FILE}
#
# WARNING: This file contains sensitive values.
#          Do NOT commit this file to version control.
# ============================================================
apiVersion: v1
kind: Secret
metadata:
  name: redpoint-rpi
  namespace: ${DEFAULT_NAMESPACE}
  annotations:
    helm.sh/resource-policy: keep
type: Opaque
stringData:
SECRETS_INIT
  fi
  echo "  ${key}: \"${value}\"" >> "$SECRETS_FILE"
}

# ============================================================
# Utility: generate a random password
# ============================================================
gen_password() {
  if command -v openssl &> /dev/null; then
    openssl rand -hex 16
  else
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

gen_uuid() {
  local hex
  if command -v openssl &> /dev/null; then
    hex=$(openssl rand -hex 16)
  else
    hex=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
  printf '%s-%s-%s-%s-%s' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

# ============================================================
# File mode: read values from YAML input instead of prompting
# ============================================================
if [ "$FILE_MODE" = "true" ]; then
  if [ "$ADD_MODE" = "true" ]; then
    echo "${RED}Error: -f and -a cannot be used together.${RESET}" >&2; exit 1
  fi
  if [ ! -f "$INPUT_FILE" ]; then
    echo "${RED}Error: ${INPUT_FILE} not found.${RESET}" >&2
    echo "  Copy the template and fill in your values:" >&2
    echo "    cp deploy/values/input-template.yaml ${INPUT_FILE}" >&2
    exit 1
  fi

  # Auto-install yq if not present
  if ! command -v yq &>/dev/null; then
    echo "  ${CYAN}Installing yq...${RESET}"
    _yq_version="v4.44.6"
    _yq_arch=$(uname -m)
    case "$_yq_arch" in
      x86_64)  _yq_arch="amd64" ;;
      aarch64) _yq_arch="arm64" ;;
    esac
    _yq_os=$(uname -s | tr '[:upper:]' '[:lower:]')
    _yq_url="https://github.com/mikefarah/yq/releases/download/${_yq_version}/yq_${_yq_os}_${_yq_arch}"
    if curl -fsSL "$_yq_url" -o /usr/local/bin/yq 2>/dev/null && chmod +x /usr/local/bin/yq; then
      echo "  ${ICON_CHECK} yq installed to /usr/local/bin/yq"
    elif curl -fsSL "$_yq_url" -o "${HOME}/.local/bin/yq" 2>/dev/null && chmod +x "${HOME}/.local/bin/yq"; then
      export PATH="${HOME}/.local/bin:${PATH}"
      echo "  ${ICON_CHECK} yq installed to ${HOME}/.local/bin/yq"
    else
      echo "${RED}Error: Failed to install yq. Install manually:${RESET}" >&2
      echo "  https://github.com/mikefarah/yq#install" >&2
      exit 1
    fi
  fi

  # Helper: read a value from the input YAML with a default fallback
  cfg() {
    local val
    val=$(yq eval "$1" "$INPUT_FILE" 2>/dev/null)
    if [ "$val" = "null" ] || [ -z "$val" ]; then echo "${2:-}"; else echo "$val"; fi
  }

  # Associative array holding all config values keyed by shell variable name
  declare -A _CFG=()

  # --- Core settings ---
  _CFG[PLATFORM]=$(cfg '.platform' 'azure')
  _CFG[MODE]=$(cfg '.mode' 'standard')
  _CFG[TAG]=$(cfg '.image_tag' "$DEFAULT_TAG")
  _CFG[NAMESPACE]=$(cfg '.namespace' "$DEFAULT_NAMESPACE")

  # --- Ingress ---
  _CFG[DOMAIN]=$(cfg '.ingress.domain' 'example.com')
  _CFG[HOST_PREFIX]=$(cfg '.ingress.host_prefix' 'rpi')
  _CFG[DEPLOY_CONTROLLER]=$(cfg '.ingress.deploy_controller' 'true')
  _CFG[INGRESS_MODE]=$(cfg '.ingress.mode' 'public')
  _CFG[INGRESS_SUBNET]=$(cfg '.ingress.subnet_name' '')

  # --- Database ---
  _CFG[DB_PROVIDER]=$(cfg '.database.provider' 'sqlserver')
  _CFG[DB_HOST]=$(cfg '.database.host' '')
  _CFG[DB_USER]=$(cfg '.database.username' '')
  _CFG[DB_PASS]=$(cfg '.database.password' '')
  _CFG[DB_PULSE]=$(cfg '.database.pulse_database' 'Pulse')
  _CFG[DB_LOGGING]=$(cfg '.database.logging_database' 'Pulse_Logging')

  # --- Data warehouse ---
  _dw_provider=$(cfg '.data_warehouse.provider' '')
  if [ -n "$_dw_provider" ]; then
    _CFG[DW_ENABLED]="true"
  else
    _CFG[DW_ENABLED]="false"
  fi

  # --- Cloud identity ---
  _CFG[CLOUD_IDENTITY_ENABLED]=$(cfg '.cloud_identity.enabled' 'false')
  _CFG[SA_MODE]=$(cfg '.cloud_identity.service_account_mode' 'per-service')
  _CFG[AZURE_CLIENT_ID]=$(cfg '.cloud_identity.azure.client_id' '')
  _CFG[AZURE_TENANT_ID]=$(cfg '.cloud_identity.azure.tenant_id' '')
  _CFG[AMAZON_ROLE_ARN]=$(cfg '.cloud_identity.amazon.role_arn' '')
  _CFG[AMAZON_REGION]=$(cfg '.cloud_identity.amazon.region' 'us-east-1')
  _CFG[GOOGLE_SA_EMAIL]=$(cfg '.cloud_identity.google.service_account_email' '')

  # --- Realtime ---
  _CFG[REALTIME_ENABLED]=$(cfg '.realtime.enabled' 'true')
  _CFG[RT_CACHE_PROVIDER]=$(cfg '.realtime.cache.provider' 'mongodb')
  _CFG[RT_CACHE_CONNSTR]=$(cfg '.realtime.cache.connection_string' '')
  _CFG[RT_CACHE_BIGTABLE_PROJECT]=$(cfg '.realtime.cache.bigtable_project' '')
  _CFG[RT_CACHE_BIGTABLE_INSTANCE]=$(cfg '.realtime.cache.bigtable_instance' '')
  _CFG[RT_QUEUE_PROVIDER]=$(cfg '.realtime.queue.provider' 'rabbitmq')
  _CFG[RT_QUEUE_CONNSTR]=$(cfg '.realtime.queue.connection_string' '')
  _CFG[RT_EVENTHUB_NAME]=$(cfg '.realtime.queue.event_hub_name' 'RPIQueueListener')
  _CFG[RT_EVENTHUB_NAMESPACE]=$(cfg '.realtime.queue.namespace' '')
  _CFG[RT_PUBSUB_PROJECT]=$(cfg '.realtime.queue.pubsub_project' '')

  # --- Feature: SMTP ---
  _CFG[server]=$(cfg '.features.smtp.host' '')
  _CFG[port]=$(cfg '.features.smtp.port' '')
  _CFG[from_addr]=$(cfg '.features.smtp.from' '')
  _CFG[sender_name]=$(cfg '.features.smtp.sender_name' '')
  _CFG[enable_ssl]=$(cfg '.features.smtp.enable_ssl' '')
  _CFG[use_creds]=$(cfg '.features.smtp.use_credentials' '')
  _CFG[username]=$(cfg '.features.smtp.username' '')
  _CFG[smtp_password]=$(cfg '.features.smtp.password' '')

  # --- Feature: Entra ID ---
  _CFG[client_id]=$(cfg '.features.entra_id.client_id' '')
  _CFG[api_id]=$(cfg '.features.entra_id.api_id' '')
  _CFG[tenant_id]=$(cfg '.features.entra_id.tenant_id' '')

  # --- Feature: OIDC ---
  _CFG[provider_name]=$(cfg '.features.oidc.provider' '')
  _CFG[auth_host]=$(cfg '.features.oidc.authority' '')
  # client_id already mapped from entra_id — will be overwritten per feature context
  _CFG[audience]=$(cfg '.features.oidc.audience' '')
  _CFG[redirect_url]=$(cfg '.features.oidc.redirect_url' '')
  _CFG[enable_refresh]=$(cfg '.features.oidc.enable_refresh' '')
  _CFG[validate_issuer]=$(cfg '.features.oidc.validate_issuer' '')
  _CFG[validate_audience]=$(cfg '.features.oidc.validate_audience' '')
  _CFG[logout_param]=$(cfg '.features.oidc.logout_param' '')
  _CFG[supports_user_mgmt]=$(cfg '.features.oidc.supports_user_management' '')
  _CFG[add_scope]="false"   # custom scopes not supported in file mode

  # --- Feature: Redpoint AI ---
  _CFG[api_base]=$(cfg '.features.redpoint_ai.endpoint' '')
  _CFG[api_version]=$(cfg '.features.redpoint_ai.api_version' '')
  _CFG[engine]=$(cfg '.features.redpoint_ai.deployment' '')
  _CFG[temp]=$(cfg '.features.redpoint_ai.temperature' '')
  _CFG[search_endpoint]=$(cfg '.features.redpoint_ai.search_endpoint' '')
  _CFG[embeddings_model]=$(cfg '.features.redpoint_ai.embeddings_model' '')
  _CFG[model_dims]=$(cfg '.features.redpoint_ai.model_dimensions' '')
  _CFG[container_name]=$(cfg '.features.redpoint_ai.container_name' '')
  _CFG[blob_folder]=$(cfg '.features.redpoint_ai.blob_folder' '')
  _CFG[nlp_api_key]=$(cfg '.features.redpoint_ai.nlp_api_key' '')
  _CFG[nlp_search_key]=$(cfg '.features.redpoint_ai.search_key' '')
  _CFG[nlp_model_connstr]=$(cfg '.features.redpoint_ai.blob_connection_string' '')

  # --- Feature: Queue Reader ---
  _CFG[tenant_id_qr]=$(cfg '.features.queue_reader.tenant_id' '')
  _CFG[distributed]=$(cfg '.features.queue_reader.distributed' '')

  # --- Feature: Data Warehouse (from top-level data_warehouse section) ---
  _CFG[provider]="$_dw_provider"
  _CFG[sf_configmap]=$(cfg '.data_warehouse.snowflake.configmap_name' '')
  _CFG[sf_keyname]=$(cfg '.data_warehouse.snowflake.key_name' '')
  _CFG[bq_name]=$(cfg '.data_warehouse.bigquery.connection_name' '')
  _CFG[bq_configmap]=$(cfg '.data_warehouse.bigquery.configmap_name' '')
  _CFG[bq_sa_email]=$(cfg '.data_warehouse.bigquery.service_account_email' '')
  _CFG[bq_project]=$(cfg '.data_warehouse.bigquery.project_id' '')

  # --- Feature: Autoscaling ---
  _CFG[svc]=$(cfg '.features.autoscaling.service' '')
  _CFG[type]=$(cfg '.features.autoscaling.type' '')
  _CFG[min_r]=$(cfg '.features.autoscaling.min_replicas' '')
  _CFG[max_r]=$(cfg '.features.autoscaling.max_replicas' '')
  _CFG[cpu_pct]=$(cfg '.features.autoscaling.target_cpu' '')

  # --- Feature: Database Upgrade ---
  _CFG[notify]=$(cfg '.features.database_upgrade.notification' '')
  _CFG[email]=$(cfg '.features.database_upgrade.notification_email' '')

  # --- Feature: Storage ---
  _CFG[storage_type]=$(cfg '.features.storage.type' '')
  _CFG[claim]=$(cfg '.features.storage.pvc_claim_name' '')
  _CFG[mount_path]=$(cfg '.features.storage.mount_path' '')

  # Helper: check if a feature is enabled in the input file
  _feature_enabled() {
    local val
    val=$(yq eval ".features.$1" "$INPUT_FILE" 2>/dev/null)
    case "$val" in
      true) return 0 ;;
      false|null|"") return 1 ;;
      *) return 0 ;;   # it's a map/object, so feature is enabled
    esac
  }

  # Override prompt functions — read from _CFG silently
  prompt() {
    local var_name=$1 prompt_text=$2 default=$3
    local value="${_CFG[$var_name]:-}"
    eval "$var_name=\"\${value:-\$default}\""
  }

  prompt_choice() {
    local var_name=$1 prompt_text=$2 options=$3 default=$4
    local value="${_CFG[$var_name]:-}"
    eval "$var_name=\"\${value:-\$default}\""
  }

  prompt_yesno() {
    local var_name=$1 prompt_text=$2 default=$3
    local value="${_CFG[$var_name]:-}"
    if [ -n "$value" ]; then
      case "$value" in
        true|y|Y|yes) eval "$var_name=true" ;;
        *) eval "$var_name=false" ;;
      esac
    else
      case "$default" in
        y|Y) eval "$var_name=true" ;;
        *) eval "$var_name=false" ;;
      esac
    fi
  }

  prompt_secret() {
    local var_name=$1 prompt_text=$2
    local value="${_CFG[$var_name]:-}"
    eval "$var_name=\"\$value\""
  }

  # Quieter section headers in file mode
  _orig_section=$(declare -f section)
  section() { echo "  ${CYAN}▸${RESET} $1"; }
fi

# ============================================================
# --add mode: append a feature block to an existing overrides
# ============================================================

has_block() {
  local file=$1 key=$2
  grep -qE "^[[:space:]]*${key}:" "$file" 2>/dev/null
}

# Remove a YAML block and its heading comment from a file.
# Two-pass: first find the key line, then work backwards to find heading
# and forwards to find end of block.
remove_block() {
  local file=$1 key=$2
  python3 -c "
import sys, re
lines = open(sys.argv[1]).readlines()
key = sys.argv[2]
# Find the line with the top-level key
key_line = -1
for i, l in enumerate(lines):
    if re.match(r'^' + re.escape(key) + r':', l):
        key_line = i
        break
if key_line < 0:
    sys.exit(0)
# Find start: look backwards for heading comment block (3 lines of # ---)
start = key_line
# Check for blank line before key
if start > 0 and lines[start - 1].strip() == '':
    start -= 1
# Check for heading comment (3 lines: dashes, title, dashes)
if start >= 3:
    l1 = lines[start - 3].rstrip()
    l2 = lines[start - 2].rstrip()
    l3 = lines[start - 1].rstrip()
    if (l1.startswith('# -----') and l3.startswith('# -----')
            and l2.startswith('#')):
        start -= 3
elif start >= 2:
    l1 = lines[start - 2].rstrip()
    l2 = lines[start - 1].rstrip()
    if l1.startswith('# -----') and l2.startswith('#'):
        start -= 2
# Also consume a blank line before the heading
if start > 0 and lines[start - 1].strip() == '':
    start -= 1
# Find end: everything after key_line that is indented or blank
# Stop at comment lines that look like a heading (# ----)
end = key_line + 1
while end < len(lines):
    l = lines[end]
    stripped = l.rstrip()
    if stripped == '':
        end += 1
    elif l[0] == ' ':
        end += 1
    elif stripped.startswith('# -----'):
        break
    elif stripped.startswith('#'):
        end += 1
    else:
        break
# Remove trailing blank lines from the deletion range
while end > key_line + 1 and lines[end - 1].strip() == '':
    end -= 1
open(sys.argv[1], 'w').writelines(lines[:start] + lines[end:])
" "$file" "$key"
}

# Check if a block exists and offer to replace it.
# Returns 0 (continue) if the block does not exist or the user chose to replace.
# Returns 1 (skip) if the block exists and the user chose not to replace.
check_replace_block() {
  local file=$1 key=$2 label=$3
  if has_block "$file" "$key"; then
    local replace=""
    prompt_yesno replace "${label} already exists. Replace it?" "n"
    if [ "$replace" = "true" ]; then
      remove_block "$file" "$key"
      echo "  ${ICON_CHECK} Removed existing ${label} block"
      return 0
    else
      echo "  ${DIM}Skipped — keeping existing ${label} configuration${RESET}"
      return 1
    fi
  fi
  return 0
}

append_block() {
  local file=$1 block=$2 heading=$3
  echo "" >> "$file"
  if [ -n "$heading" ]; then
    echo "# ----------------------------------------------------------" >> "$file"
    echo "#  ${heading}" >> "$file"
    echo "# ----------------------------------------------------------" >> "$file"
  fi
  echo "$block" >> "$file"
}

# Append indented content under an existing top-level key, or create the key if missing.
# Usage: append_under_key <file> <key> <indented_content> [heading]
#   indented_content must be indented at 2 spaces (child level of key).
#   Example: append_under_key "$file" "realtimeapi" "  autoscaling:\n    enabled: true" "Autoscaling"
append_under_key() {
  local file=$1 key=$2 content=$3 heading=$4
  if grep -q "^${key}:" "$file" 2>/dev/null; then
    # Key exists — find end of its block and insert content there
    local tmp_file="${file}.tmp.$$"
    awk -v key="$key" -v content="$content" '
      BEGIN { found=0; inserted=0; blanks=0 }
      $0 ~ "^" key ":" { found=1; print; next }
      found && !inserted {
        if (/^$/) { blanks++; next }
        if (/^#/) {
          # Unindented comment = next section heading — insert before it
          print content
          print ""
          inserted=1
          for (i=0; i<blanks; i++) print ""
          blanks=0
          print; next
        }
        if (/^[^ ]/) {
          # Reached a new top-level key — insert content, then blank line, then this line
          print content
          print ""
          inserted=1
          for (i=0; i<blanks; i++) print ""
          blanks=0
          print; next
        }
        # Still inside the block — flush any buffered blank lines
        for (i=0; i<blanks; i++) print ""
        blanks=0
      }
      { print }
      END {
        if (found && !inserted) {
          print content
        }
      }
    ' "$file" > "$tmp_file" && mv "$tmp_file" "$file"
  else
    # Key doesn't exist — create it with heading
    append_block "$file" "$(printf '%s:\n%s' "$key" "$content")" "$heading"
  fi
}

# Append a datawarehouse block under an existing databases: key, or create both.
# Usage: append_dw_block <file> <dw_content> <heading>
#   dw_content should be indented at 2 spaces (the datawarehouse: level), e.g.:
#     "  datawarehouse:\n    snowflake:\n      enabled: true"
append_dw_block() {
  local file=$1 dw_content=$2 heading=$3
  if grep -q "^databases:" "$file" 2>/dev/null; then
    # databases: already exists — find its last contiguous indented line and insert after it
    local tmp_file="${file}.tmp.$$"
    awk -v content="$dw_content" -v heading="$heading" '
      /^databases:/ { in_db=1; print; next }
      in_db && /^[^ #]/ && !/^$/ {
        # Reached next top-level key — flush buffered lines, insert DW before them
        if (heading != "") {
          print "# ----------------------------------------------------------"
          print "#  " heading
          print "# ----------------------------------------------------------"
        }
        print content
        print ""
        # Print any buffered blank/comment lines that were between the block and here
        for (k=1; k<=buf_n; k++) print buf[k]
        buf_n=0
        in_db=0
      }
      in_db && (/^$/ || /^#/) {
        # Buffer blank lines and comments — they might belong to the next section
        buf[++buf_n]=$0
        next
      }
      in_db { buf_n=0 }
      { print }
      END {
        if (in_db) {
          if (heading != "") {
            print "# ----------------------------------------------------------"
            print "#  " heading
            print "# ----------------------------------------------------------"
          }
          print content
          for (k=1; k<=buf_n; k++) print buf[k]
        }
      }
    ' "$file" > "$tmp_file" && mv "$tmp_file" "$file"
  else
    # No databases: key yet — write the full block
    append_block "$file" "databases:
${dw_content}" "$heading"
  fi
}

add_database_upgrade() {
  local file=$1
  check_replace_block "$file" "databaseUpgrade" "Database Upgrade" || return 0
  local notify email
  prompt_yesno notify "Send email notifications on upgrade?" "n"
  if [ "$notify" = "true" ]; then
    prompt email "Notification email address" ""
    append_block "$file" "$(cat <<BLOCK
databaseUpgrade:
  enabled: true
  notification:
    enabled: true
    recipientEmail: ${email}
BLOCK
)" "Database Upgrade"
  else
    append_block "$file" "$(cat <<'BLOCK'
databaseUpgrade:
  enabled: true
BLOCK
)" "Database Upgrade"
  fi
  echo "  ${ICON_CHECK} Added databaseUpgrade to ${file}"
}

add_queue_reader() {
  local file=$1
  check_replace_block "$file" "queuereader" "Queue Reader" || return 0
  local tenant_id distributed
  prompt tenant_id "RPI Client (Tenant) ID" ""
  prompt_yesno distributed "Enable distributed mode?" "n"
  if [ "$distributed" = "true" ]; then
    local cache_type queue_type
    prompt_choice cache_type "Internal cache Redis type" "internal|external" "internal"
    prompt_choice queue_type "Internal queue RabbitMQ type" "internal|external" "internal"
    local cache_block="" queue_block=""
    if [ "$cache_type" = "external" ]; then
      local redis_conn
      prompt redis_conn "External Redis connection string" "my-redis-host:6379,password=<password>,abortConnect=False"
      cache_block="      redisSettings:
        connectionString: \"${redis_conn}\""
    fi
    if [ "$queue_type" = "external" ]; then
      local rmq_host rmq_user
      prompt rmq_host "External RabbitMQ hostname" ""
      prompt rmq_user "RabbitMQ username" "rabbitmq"
      queue_block="      rabbitmqSettings:
        hostname: \"${rmq_host}\"
        username: ${rmq_user}"
    fi
    append_block "$file" "$(cat <<BLOCK
queuereader:
  enabled: true
  realtimeConfiguration:
    isDistributed: true
    internalCache:
      provider: redis
      type: ${cache_type}
${cache_block}
    distributedQueue:
      provider: rabbitmq
      type: ${queue_type}
${queue_block}
    tenantIds:
      - "${tenant_id}"
  errorQueuePath: listenerQueueError
  nonActiveQueuePath: listenerQueueNonActive
BLOCK
)" "Queue Reader"
    echo ""
    echo "  ${ICON_CHECK} Added queuereader (distributed) to ${file}"
    if [ "$cache_type" = "internal" ]; then
      local qs_redis_pass
      qs_redis_pass=$(gen_password)
      append_secret "QueueService_RedisCache_Password" "$qs_redis_pass"
      append_secret "QueueService_internalCache_ConnectionString" "rpi-queuereader-cache:6379,password=${qs_redis_pass},abortConnect=False"
      echo "  ${ICON_CHECK} Added QueueService Redis secrets to ${SECRETS_FILE}"
    fi
    if [ "$queue_type" = "internal" ]; then
      local qs_rmq_pass
      qs_rmq_pass=$(gen_password)
      append_secret "QueueService_RabbitMQ_Password" "$qs_rmq_pass"
      echo "  ${ICON_CHECK} Added QueueService RabbitMQ password to ${SECRETS_FILE}"
    fi
  else
    append_block "$file" "$(cat <<BLOCK
queuereader:
  enabled: true
  realtimeConfiguration:
    isDistributed: false
    tenantIds:
      - "${tenant_id}"
  errorQueuePath: listenerQueueError
  nonActiveQueuePath: listenerQueueNonActive
BLOCK
)" "Queue Reader"
    echo "  ${ICON_CHECK} Added queuereader to ${file}"
  fi
}

add_autoscaling() {
  local file=$1
  local svc
  prompt_choice svc "Service to autoscale" "realtimeapi|executionservice|interactionapi|integrationapi" "realtimeapi"
  if grep -qE "^${svc}:" "$file" 2>/dev/null && grep -A20 "^${svc}:" "$file" | grep -q "autoscaling:"; then
    echo "  ${ICON_WARN} ${YELLOW}autoscaling for ${svc} already exists in ${file}${RESET}"; return 0
  fi
  local type min_r max_r
  prompt_choice type "Autoscaling type" "hpa|keda" "hpa"
  prompt min_r "Min replicas" "1"
  prompt max_r "Max replicas" "5"
  if [ "$type" = "hpa" ]; then
    local cpu_pct
    prompt cpu_pct "Target CPU utilization %" "80"
    append_under_key "$file" "$svc" "$(cat <<BLOCK
  autoscaling:
    enabled: true
    type: hpa
    minReplicas: ${min_r}
    maxReplicas: ${max_r}
    targetCPUUtilizationPercentage: ${cpu_pct}
BLOCK
)" "Autoscaling"
  else
    local prom_addr threshold
    prompt prom_addr "Prometheus server address" "http://prometheus-server.monitoring.svc.cluster.local"
    prompt threshold "KEDA threshold" "5"
    append_under_key "$file" "$svc" "$(cat <<BLOCK
  autoscaling:
    enabled: true
    type: keda
    minReplicas: ${min_r}
    maxReplicas: ${max_r}
    keda:
      serverAddress: ${prom_addr}
      threshold: "${threshold}"
BLOCK
)" "Autoscaling"
  fi
  echo "  ${ICON_CHECK} Added autoscaling (${type}) for ${svc} to ${file}"
}

add_custom_metrics() {
  local file=$1
  check_replace_block "$file" "customMetrics" "Custom Metrics" || return 0
  append_block "$file" "$(cat <<'BLOCK'
customMetrics:
  enabled: true
BLOCK
)" "Custom Metrics"
  echo "  ${ICON_CHECK} Added customMetrics to ${file}"
}

add_node_scheduling() {
  local file=$1

  echo ""
  echo "  ${DIM}Node scheduling controls which nodes RPI pods are placed on.${RESET}"
  echo "  ${DIM}  nodeSelector — schedule pods only on nodes with a matching label${RESET}"
  echo "  ${DIM}  tolerations  — allow pods to run on tainted (dedicated) nodes${RESET}"
  echo ""

  local action
  if has_block "$file" "nodeSelector" || has_block "$file" "tolerations"; then
    echo "  ${DIM}Node scheduling already exists in overrides.${RESET}"
    prompt_choice action "What to configure" "replace|skip" "replace"
    if [ "$action" = "skip" ]; then return 0; fi
    remove_block "$file" "nodeSelector"
    remove_block "$file" "tolerations"
    echo "  ${ICON_CHECK} Removed existing nodeSelector/tolerations"
  fi

  local ns_key ns_value
  prompt ns_key "Node label key" "app"
  prompt ns_value "Node label value" "redpoint-rpi"

  append_block "$file" "$(cat <<BLOCK
nodeSelector:
  enabled: true
  key: ${ns_key}
  value: ${ns_value}
BLOCK
)" "Node Scheduling"
  echo "  ${ICON_CHECK} Added nodeSelector (${ns_key}=${ns_value}) to ${file}"

  local add_tolerations=""
  prompt_yesno add_tolerations "Add a matching toleration so pods can run on tainted nodes?" "y"
  if [ "$add_tolerations" = "true" ]; then
    local tol_effect
    prompt_choice tol_effect "Taint effect" "NoSchedule|NoExecute|PreferNoSchedule" "NoSchedule"
    append_block "$file" "$(cat <<BLOCK
tolerations:
  enabled: true
  effect: ${tol_effect}
  key: ${ns_key}
  operator: Equal
  value: ${ns_value}
BLOCK
)" ""
    echo "  ${ICON_CHECK} Added toleration (${tol_effect}, ${ns_key}=${ns_value}) to ${file}"
  fi
}

add_service_mesh() {
  local file=$1

  # Build server entries
  local servers=""
  local more="true"
  echo ""
  echo "  ${DIM}Each server creates a Linkerd Server CRD for L7 traffic policy.${RESET}"
  echo "  ${DIM}You need one entry per service that should be part of the mesh.${RESET}"
  echo ""
  while [ "$more" = "true" ]; do
    local srv_name srv_port srv_protocol selector_key selector_value
    prompt srv_name "Server name (e.g., rpi-interactionapi)" ""
    prompt selector_key "Pod selector label key" "app.kubernetes.io/name"
    prompt selector_value "Pod selector label value" "${srv_name}"
    prompt srv_port "Port" "8080"
    prompt srv_protocol "Proxy protocol" "HTTP/1"
    servers="${servers}
    - name: ${srv_name}
      podSelector:
        ${selector_key}: ${selector_value}
      port: ${srv_port}
      proxyProtocol: ${srv_protocol}"
    prompt_yesno more "Add another server?" "y"
  done

  if has_block "$file" "serviceMesh"; then
    if grep -q "servers:" "$file" 2>/dev/null; then
      # Append to existing servers list
      python3 "$YAML_HELPER" append_to_list "$file" "servers:" "$(echo "$servers" | sed '/^$/d')"
    else
      # serviceMesh exists but no servers: yet — append it
      append_under_key "$file" "serviceMesh" "  servers:${servers}" ""
    fi
    echo "  ${ICON_CHECK} Added server entries to existing serviceMesh in ${file}"
  else
    append_block "$file" "$(cat <<BLOCK
serviceMesh:
  enabled: true
  provider: linkerd
  servers:${servers}
BLOCK
)" "Service Mesh"
    echo "  ${ICON_CHECK} Added serviceMesh to ${file}"
  fi
}

add_validation_pods() {
  local file=$1
  check_replace_block "$file" "validationPods" "Validation Pods" || return 0
  local deployments=""
  local more="true"
  while [ "$more" = "true" ]; do
    local test_name test_type test_image
    prompt test_name "Validation pod name" "storage-check"
    prompt test_image "Container image" "busybox:1.37"
    prompt_choice test_type "Type" "pvc|csiSecret" "pvc"

    local ns_block=""
    local use_ns=""
    prompt_yesno use_ns "Add a nodeSelector for this test?" "n"
    if [ "$use_ns" = "true" ]; then
      local ns_key ns_value
      prompt ns_key "Node selector key" "app"
      prompt ns_value "Node selector value" "redpoint-rpi"
      ns_block="
      nodeSelector:
        ${ns_key}: ${ns_value}"
    fi

    if [ "$test_type" = "pvc" ]; then
      local pvc_name mount_path
      prompt pvc_name "PVC claim name" "rpifileoutputdir"
      prompt mount_path "Mount path" "/mnt/rpifileoutputdir"
      deployments="${deployments}
    - name: ${test_name}
      image: ${test_image}
      type: pvc
      claimName: ${pvc_name}
      mountPath: ${mount_path}${ns_block}"
    else
      local spc mount_path
      prompt spc "SecretProviderClass name" "rpi-secret-provider"
      prompt mount_path "Mount path" "/mnt/secrets"
      deployments="${deployments}
    - name: ${test_name}
      image: ${test_image}
      type: csiSecret
      secretProviderClass: ${spc}
      mountPath: ${mount_path}${ns_block}"
    fi
    prompt_yesno more "Add another validation pod?" "n"
  done
  append_block "$file" "$(cat <<BLOCK
validationPods:
  enabled: true
  deployments:${deployments}
BLOCK
)" "Validation Pods"
  echo "  ${ICON_CHECK} Added validationPods to ${file}"
}

add_entra_id() {
  local file=$1
  check_replace_block "$file" "MicrosoftEntraID" "Microsoft Entra ID" || return 0
  local client_id api_id tenant_id
  prompt client_id "Interaction Client App ID" ""
  prompt api_id "Interaction API App ID" ""
  prompt tenant_id "Azure AD Tenant ID" ""
  append_block "$file" "$(cat <<BLOCK
MicrosoftEntraID:
  enabled: true
  interaction_client_id: ${client_id}
  interaction_api_id: ${api_id}
  tenant_id: ${tenant_id}
BLOCK
)" "Microsoft Entra ID"
  echo "  ${ICON_CHECK} Added MicrosoftEntraID to ${file}"
}

add_oidc() {
  local file=$1
  check_replace_block "$file" "OpenIdProviders" "OpenID Connect (OIDC)" || return 0
  local provider_name auth_host client_id audience redirect_url
  local enable_refresh validate_issuer validate_audience logout_param supports_user_mgmt
  prompt_choice provider_name "OIDC provider" "Keycloak|Okta" "Keycloak"
  prompt auth_host "Authorization host URL" ""
  prompt client_id "Client ID" ""
  prompt audience "Audience" ""
  prompt redirect_url "Redirect URL (RPI client URL)" ""
  prompt_yesno enable_refresh "Enable refresh tokens?" "y"
  prompt_yesno validate_issuer "Validate issuer?" "n"
  prompt_yesno validate_audience "Validate audience?" "y"
  prompt logout_param "Logout ID token parameter" "id_token_hint"
  prompt_yesno supports_user_mgmt "Supports user management?" "n"
  local scopes_block=""
  local add_scope
  prompt_yesno add_scope "Add custom scopes?" "n"
  if [ "$add_scope" = "true" ]; then
    scopes_block=$'\n  customScopes:'
    local scope more="true"
    while [ "$more" = "true" ]; do
      prompt scope "Custom scope URI" ""
      scopes_block="${scopes_block}"$'\n'"    - ${scope}"
      prompt_yesno more "Add another scope?" "n"
    done
  fi
  append_block "$file" "$(cat <<BLOCK
OpenIdProviders:
  enabled: true
  name: ${provider_name}
  authorizationHost: ${auth_host}
  clientID: ${client_id}
  audience: ${audience}
  redirectURL: ${redirect_url}
  enableRefreshTokens: ${enable_refresh}
  validateIssuer: ${validate_issuer}
  validateAudience: ${validate_audience}
  logoutIdTokenParameter: ${logout_param}
  supportsUserManagement: ${supports_user_mgmt}${scopes_block}
BLOCK
)" "OpenID Connect (OIDC)"
  echo "  ${ICON_CHECK} Added OpenIdProviders to ${file}"
}

add_smtp() {
  local file=$1
  check_replace_block "$file" "SMTPSettings" "SMTP Settings" || return 0
  local server port from_addr sender_name enable_ssl use_creds username
  prompt server "SMTP server hostname" "smtp.example.com"
  prompt port "SMTP port" "587"
  prompt from_addr "Sender email address" "noreply@example.com"
  prompt sender_name "Sender display name" "Redpoint Global"
  prompt_yesno enable_ssl "Enable SSL/TLS?" "y"
  prompt_yesno use_creds "Use SMTP credentials?" "y"
  local creds_block=""
  if [ "$use_creds" = "true" ]; then
    prompt username "SMTP username" ""
    creds_block="
  SMTP_Username: ${username}"
  fi
  local smtp_password=""
  if [ "$use_creds" = "true" ]; then
    prompt_secret smtp_password "SMTP password"
  fi
  append_block "$file" "$(cat <<BLOCK
SMTPSettings:
  SMTP_Address: ${server}
  SMTP_Port: ${port}
  SMTP_SenderAddress: ${from_addr}
  SMTP_SenderName: "${sender_name}"
  EnableSSL: ${enable_ssl}
  UseCredentials: ${use_creds}${creds_block}
BLOCK
)" "SMTP Email Configuration"
  echo "  ${ICON_CHECK} Added SMTPSettings to ${file}"
  if [ "$use_creds" = "true" ] && [ -n "$smtp_password" ]; then
    append_secret "SMTP_Password" "$smtp_password"
    echo "  ${ICON_CHECK} Added SMTP_Password to ${SECRETS_FILE}"
  fi
}

add_redpoint_ai() {
  local file=$1
  check_replace_block "$file" "redpointAI" "Redpoint AI" || return 0
  echo ""
  echo "  ${BOLD}Natural Language (OpenAI)${RESET}"
  local api_base api_version engine temp
  prompt api_base "OpenAI API base URL" "https://example.openai.azure.com/"
  prompt api_version "API version" "2023-07-01-preview"
  prompt engine "ChatGPT engine/model" "gpt-5.2"
  prompt temp "ChatGPT temperature (0.0–1.0)" "0.5"
  echo ""
  echo "  ${BOLD}Azure AI Search${RESET}"
  local search_endpoint
  prompt search_endpoint "Search endpoint URL" "https://example.search.windows.net"
  echo ""
  echo "  ${BOLD}Model Storage${RESET}"
  local embeddings_model model_dims container_name blob_folder
  prompt embeddings_model "Embeddings model" "text-embedding-ada-002"
  prompt model_dims "Model dimensions" "1536"
  prompt container_name "Blob container name" ""
  prompt blob_folder "Blob folder name" ""
  echo ""
  echo "  ${BOLD}Secrets${RESET}"
  local nlp_api_key nlp_search_key nlp_model_connstr
  prompt_secret nlp_api_key "OpenAI API key"
  prompt_secret nlp_search_key "Cognitive Search key"
  prompt_secret nlp_model_connstr "Blob storage connection string"

  append_block "$file" "$(cat <<BLOCK
redpointAI:
  enabled: true
  naturalLanguage:
    ApiBase: ${api_base}
    ApiVersion: ${api_version}
    ChatGptEngine: ${engine}
    ChatGptTemp: ${temp}
  cognitiveSearch:
    SearchEndpoint: ${search_endpoint}
  modelStorage:
    EmbeddingsModel: ${embeddings_model}
    ModelDimensions: ${model_dims}
    ContainerName: ${container_name}
    BlobFolder: ${blob_folder}
BLOCK
)" "Redpoint AI"
  echo ""
  echo "  ${ICON_CHECK} Added redpointAI to ${file}"

  if [ -n "$nlp_api_key" ]; then
    append_secret "RPI_NLP_API_KEY" "$nlp_api_key"
  fi
  if [ -n "$nlp_search_key" ]; then
    append_secret "RPI_NLP_SEARCH_KEY" "$nlp_search_key"
  fi
  if [ -n "$nlp_model_connstr" ]; then
    append_secret "RPI_NLP_MODEL_CONNECTION_STRING" "$nlp_model_connstr"
  fi
  echo "  ${ICON_CHECK} Added AI secrets to ${SECRETS_FILE}"
}

add_storage() {
  local file=$1

  local storage_type
  prompt_choice storage_type "Storage type" "pvc|csi" "pvc"

  if [ "$storage_type" = "pvc" ]; then
    local pvc_name claim mount_path
    prompt pvc_name "PVC entry name (e.g., FileOutputDirectory, SharedCache)" "FileOutputDirectory"
    prompt claim "PVC claim name" "rpifileoutputdir"
    prompt mount_path "Mount path" "/mnt/rpifileoutputdir"

    local pvc_content="    ${pvc_name}:
      enabled: true
      claimName: ${claim}
      mountPath: ${mount_path}"

    if has_block "$file" "persistentVolumeClaims"; then
      # Append new PVC entry under existing persistentVolumeClaims block
      python3 "$YAML_HELPER" append_to_list "$file" "persistentVolumeClaims:" "$pvc_content"
      echo "  ${ICON_CHECK} Added PVC '${pvc_name}' to existing storage in ${file}"
    elif has_block "$file" "storage"; then
      # storage: exists but no persistentVolumeClaims yet
      python3 "$YAML_HELPER" create_section "$file" "storage:" "$(printf '  persistentVolumeClaims:\n%s' "$pvc_content")"
      echo "  ${ICON_CHECK} Added PVC storage to ${file}"
    else
      append_block "$file" "$(cat <<BLOCK
storage:
  persistentVolumeClaims:
${pvc_content}
BLOCK
)" "Storage Configuration"
      echo "  ${ICON_CHECK} Added PVC storage to ${file}"
    fi

  else
    # Detect platform from overrides file, or prompt
    local csi_platform
    csi_platform=$(grep -A2 'platform:' "$file" 2>/dev/null | grep 'platform:' | head -1 | sed 's/.*platform: *//' | tr -d ' "'"'"'')
    if [ -z "$csi_platform" ] || ! echo "azure|amazon|google" | tr '|' '\n' | grep -qx "$csi_platform"; then
      prompt_choice csi_platform "Cloud platform" "azure|amazon|google" "azure"
    else
      echo "  ${DIM}Detected platform: ${csi_platform}${RESET}"
    fi

    local pv_name storage_account container_name client_id resource_group volume_handle claim_name
    # pv_entry holds just the "- name: ..." list item (no persistentVolumes: header)
    local pv_entry pv_comment

    case "$csi_platform" in
      azure)
        local azure_type
        prompt_choice azure_type "Azure storage type" "blob|fileshare" "blob"
        prompt pv_name "Persistent Volume name" "pv-${azure_type}"
        prompt storage_account "Azure Storage Account name" ""
        prompt claim_name "PVC claim name (used in pod mounts)" "pvc-${azure_type}"

        if [ "$azure_type" = "blob" ]; then
          prompt container_name "Blob container name" ""
          prompt client_id "Managed Identity Client ID" ""
          prompt resource_group "Azure Resource Group (where storage account lives)" ""
          echo ""
          echo "  ${DIM}Volume handle must be unique across the cluster.${RESET}"
          echo "  ${DIM}Format: <resource-group>_<storage-account>_<container>${RESET}"
          prompt volume_handle "Volume handle" "${resource_group}_${storage_account}_${container_name}"
          pv_comment="# Azure Blob Storage"
          pv_entry="    - name: ${pv_name}
      capacity: 10Gi
      accessModes:
        - ReadWriteMany
      storageClassName: blob-fuse
      reclaimPolicy: Retain
      mountOptions:
        - -o allow_other
        - --file-cache-timeout-in-seconds=120
      csi:
        driver: blob.csi.azure.com
        volumeHandle: ${volume_handle}
        volumeAttributes:
          storageAccount: ${storage_account}
          containerName: ${container_name}
          clientID: ${client_id}
          resourcegroup: ${resource_group}
          # subscriptionid: <only if storage account is in a different subscription>
      pvc:
        claimName: ${claim_name}
      annotations:
        pv.kubernetes.io/provisioned-by: blob.csi.azure.com
        helm.sh/resource-policy: keep"
        else
          local share_name
          prompt share_name "Azure File share name" ""
          prompt client_id "Managed Identity Client ID" ""
          prompt resource_group "Azure Resource Group (where storage account lives)" ""
          echo ""
          echo "  ${DIM}Volume handle must be unique across the cluster.${RESET}"
          echo "  ${DIM}Format: <resource-group>#<storage-account>#<share-name>${RESET}"
          prompt volume_handle "Volume handle" "${resource_group}#${storage_account}#${share_name}"
          pv_comment="# Azure File Share"
          pv_entry="    - name: ${pv_name}
      capacity: 10Gi
      accessModes:
        - ReadWriteMany
      storageClassName: azurefile-csi
      reclaimPolicy: Retain
      mountOptions:
        - -o allow_other
        - --file-cache-timeout-in-seconds=120
      csi:
        driver: file.csi.azure.com
        volumeHandle: \"${volume_handle}\"
        volumeAttributes:
          storageaccount: ${storage_account}
          shareName: ${share_name}
          clientID: ${client_id}
          resourcegroup: ${resource_group}
          # subscriptionid: <only if storage account is in a different subscription>
      pvc:
        claimName: ${claim_name}"
        fi
        ;;

      amazon)
        local efs_id
        prompt pv_name "Persistent Volume name" "pv-efs"
        prompt efs_id "EFS filesystem ID (e.g., fs-0123456789abcdef0)" ""
        prompt claim_name "PVC claim name (used in pod mounts)" "pvc-efs"
        pv_comment="# AWS EFS"
        pv_entry="    - name: ${pv_name}
      capacity: 10Gi
      accessModes:
        - ReadWriteMany
      storageClassName: efs-sc
      reclaimPolicy: Retain
      csi:
        driver: efs.csi.aws.com
        volumeHandle: ${efs_id}
      pvc:
        claimName: ${claim_name}"
        ;;

      google)
        local filestore_ip share_name
        prompt pv_name "Persistent Volume name" "pv-filestore"
        prompt filestore_ip "Filestore instance IP (e.g., 10.0.0.2)" ""
        prompt share_name "Filestore share name" "rpi_data"
        prompt claim_name "PVC claim name (used in pod mounts)" "pvc-filestore"
        pv_comment="# GCP Filestore"
        pv_entry="    - name: ${pv_name}
      capacity: 10Gi
      accessModes:
        - ReadWriteMany
      storageClassName: filestore-sc
      reclaimPolicy: Retain
      csi:
        driver: filestore.csi.storage.gke.io
        volumeHandle: \"modeInstance/${filestore_ip}/${share_name}\"
        volumeAttributes:
          ip: ${filestore_ip}
          volume: ${share_name}
      pvc:
        claimName: ${claim_name}"
        ;;
    esac

    if has_block "$file" "persistentVolumes"; then
      # Append new entry to existing persistentVolumes list
      python3 "$YAML_HELPER" append_to_list "$file" "persistentVolumes:" "$(printf '    %s\n%s' "$pv_comment" "$pv_entry")"
    elif has_block "$file" "storage"; then
      # storage: exists but no persistentVolumes yet — append the section
      python3 "$YAML_HELPER" create_section "$file" "storage:" "$(printf '  persistentVolumes:\n    %s\n%s' "$pv_comment" "$pv_entry")"
    else
      # No storage: block at all — create from scratch
      append_block "$file" "$(printf 'storage:\n  persistentVolumes:\n    %s\n%s' "$pv_comment" "$pv_entry")" "Storage Configuration"
    fi
    echo "  ${ICON_CHECK} Added CSI storage (PV + PVC) to ${file}"
  fi
}

add_secrets_management() {
  local file=$1

  echo ""
  echo "  ${DIM}Configure how RPI reads sensitive values (passwords, connection strings, tokens).${RESET}"
  echo "  ${DIM}  kubernetes — Secrets stored in Kubernetes Secret objects${RESET}"
  echo "  ${DIM}  sdk        — App reads directly from cloud vault (Azure Key Vault, AWS Secrets Manager, etc.)${RESET}"
  echo "  ${DIM}  csi        — CSI driver syncs vault secrets to Kubernetes Secrets${RESET}"
  echo ""

  local action
  if has_block "$file" "secretsManagement"; then
    echo "  ${DIM}secretsManagement already exists in overrides.${RESET}"
    prompt_choice action "What to configure" "change_provider|add_sdk_settings|add_csi_class|update_csi_class" "update_csi_class"
  else
    action="new"
  fi

  case "$action" in
    new|change_provider)
      if [ "$action" = "change_provider" ]; then
        remove_block "$file" "secretsManagement"
        echo "  ${ICON_CHECK} Removed existing secretsManagement block"
      fi
      local provider secret_name
      prompt_choice provider "Secrets provider" "kubernetes|sdk|csi" "kubernetes"
      prompt secret_name "Kubernetes Secret name" "redpoint-rpi-secrets"

      local block="secretsManagement:
  provider: ${provider}
  kubernetes:
    secretName: ${secret_name}"

      if [ "$provider" = "sdk" ]; then
        local sdk_platform
        sdk_platform=$(grep -A2 'platform:' "$file" 2>/dev/null | grep 'platform:' | head -1 | sed 's/.*platform: *//' | tr -d ' "'"'"'')
        [ -z "$sdk_platform" ] && sdk_platform="azure"
        if [ "$sdk_platform" = "azure" ]; then
          local vault_uri reload_interval use_ad_token
          echo ""
          echo "  ${BOLD}Azure SDK Settings${RESET}"
          prompt vault_uri "Azure Key Vault URI (e.g., https://myvault.vault.azure.net/)" ""
          prompt reload_interval "Configuration reload interval (seconds)" "30"
          prompt_yesno use_ad_token "Use AD token for database connections?" "y"
          block="${block}
  sdk:
    azure:
      vaultUri: ${vault_uri}
      configurationReloadIntervalSeconds: ${reload_interval}
      useADTokenForDatabaseConnection: ${use_ad_token}"
        elif [ "$sdk_platform" = "amazon" ]; then
          local secret_tag_key
          echo ""
          echo "  ${BOLD}AWS SDK Settings${RESET}"
          prompt secret_tag_key "Secret tag key (leave empty to read all secrets)" ""
          block="${block}
  sdk:
    amazon:
      secretTagKey: ${secret_tag_key}"
        elif [ "$sdk_platform" = "google" ]; then
          local gcp_project_id
          echo ""
          echo "  ${BOLD}Google SDK Settings${RESET}"
          prompt gcp_project_id "GCP project ID" ""
          block="${block}
  sdk:
    google:
      projectId: ${gcp_project_id}"
        fi
      elif [ "$provider" = "csi" ]; then
        block="${block}
  csi:
    secretName: ${secret_name}"
        echo ""
        echo "  ${DIM}You can add SecretProviderClass entries now, or add them later with:${RESET}"
        echo "  ${DIM}  rpihelmcli -a secrets_management${RESET}"
        local add_classes=""
        prompt_yesno add_classes "Add a SecretProviderClass now?" "y"
        if [ "$add_classes" = "true" ]; then
          local classes_yaml=""
          classes_yaml=$(_prompt_secret_provider_classes "$file")
          block="${block}
    secretProviderClasses:
${classes_yaml}"
        fi
      fi
      append_block "$file" "$block" "Secrets Management"
      echo "  ${ICON_CHECK} Added secretsManagement (${provider}) to ${file}"
      ;;

    add_sdk_settings)
      local sdk_platform
      sdk_platform=$(grep -A2 'platform:' "$file" 2>/dev/null | grep 'platform:' | head -1 | sed 's/.*platform: *//' | tr -d ' "'"'"'')
      [ -z "$sdk_platform" ] && sdk_platform="azure"
      if [ "$sdk_platform" = "azure" ]; then
        local vault_uri reload_interval use_ad_token
        echo ""
        echo "  ${BOLD}Azure SDK Settings${RESET}"
        prompt vault_uri "Azure Key Vault URI (e.g., https://myvault.vault.azure.net/)" ""
        prompt reload_interval "Configuration reload interval (seconds)" "30"
        prompt_yesno use_ad_token "Use AD token for database connections?" "y"
        append_under_key "$file" "secretsManagement" "  sdk:
    azure:
      vaultUri: ${vault_uri}
      configurationReloadIntervalSeconds: ${reload_interval}
      useADTokenForDatabaseConnection: ${use_ad_token}" ""
        echo "  ${ICON_CHECK} Added SDK Azure settings to secretsManagement in ${file}"
      elif [ "$sdk_platform" = "amazon" ]; then
        local secret_tag_key
        echo ""
        echo "  ${BOLD}AWS SDK Settings${RESET}"
        prompt secret_tag_key "Secret tag key (leave empty to read all secrets)" ""
        append_under_key "$file" "secretsManagement" "  sdk:
    amazon:
      secretTagKey: ${secret_tag_key}" ""
        echo "  ${ICON_CHECK} Added SDK Amazon settings to secretsManagement in ${file}"
      elif [ "$sdk_platform" = "google" ]; then
        local gcp_project_id
        echo ""
        echo "  ${BOLD}Google SDK Settings${RESET}"
        prompt gcp_project_id "GCP project ID" ""
        append_under_key "$file" "secretsManagement" "  sdk:
    google:
      projectId: ${gcp_project_id}" ""
        echo "  ${ICON_CHECK} Added SDK Google settings to secretsManagement in ${file}"
      fi
      ;;

    add_csi_class)
      local classes_yaml=""
      classes_yaml=$(_prompt_secret_provider_classes "$file")

      if grep -q "secretProviderClasses:" "$file" 2>/dev/null; then
        # Append to existing list
        python3 "$YAML_HELPER" append_to_list "$file" "secretProviderClasses:" "$classes_yaml"
      else
        # No secretProviderClasses yet — add under secretsManagement.csi
        if grep -q "csi:" "$file" 2>/dev/null; then
          append_under_key "$file" "secretsManagement" "  csi:
    secretProviderClasses:
${classes_yaml}" ""
        else
          append_under_key "$file" "secretsManagement" "  csi:
    secretName: redpoint-rpi-secrets
    secretProviderClasses:
${classes_yaml}" ""
        fi
      fi
      echo "  ${ICON_CHECK} Added SecretProviderClass entries to secretsManagement in ${file}"
      ;;

    update_csi_class)
      # List existing class names
      local class_names
      class_names=$(grep -A1 'secretProviderClasses:' "$file" | grep -v 'secretProviderClasses:' | head -20 | sed 's/.*- name: //' | tr -d ' ')
      if [ -z "$class_names" ]; then
        class_names=$(python3 "$YAML_HELPER" extract_names "$file" "name" 2>/dev/null)
      fi
      if [ -z "$class_names" ]; then
        echo "  ${RED}No SecretProviderClass entries found in ${file}${RESET}"
        return 1
      fi

      # Pick class — if only one, auto-select
      local target_class
      local class_count
      class_count=$(echo "$class_names" | wc -l)
      if [ "$class_count" -eq 1 ]; then
        target_class="$class_names"
        echo "  ${DIM}Updating class: ${target_class}${RESET}"
      else
        echo "  ${DIM}Existing classes:${RESET}"
        echo "$class_names" | while read -r cn; do echo "    - $cn"; done
        prompt target_class "Class name to update" "$(echo "$class_names" | head -1)"
      fi

      local update_what
      prompt_choice update_what "What to add" "objects|secret_data|both" "objects"

      if [ "$update_what" = "objects" ] || [ "$update_what" = "both" ]; then
        echo ""
        echo "  ${BOLD}Add vault objects to '${target_class}'${RESET}"
        echo "  ${DIM}Enter objects to fetch from the vault. Empty name to finish.${RESET}"
        local new_objects=""
        while true; do
          local obj_name obj_type
          read -rp "  Object name (empty to finish): " obj_name
          [ -z "$obj_name" ] && break
          prompt obj_type "Object type" "secret"
          new_objects="${new_objects}          - objectName: \"${obj_name}\"
            objectType: ${obj_type}
"
        done
        if [ -n "$new_objects" ]; then
          python3 "$YAML_HELPER" insert_in_nested "$file" "$target_class" "objects:" "$new_objects"
          echo "  ${ICON_CHECK} Added objects to '${target_class}'"
        fi
      fi

      if [ "$update_what" = "secret_data" ] || [ "$update_what" = "both" ]; then
        echo ""
        echo "  ${BOLD}Add secret key mappings to '${target_class}'${RESET}"
        echo "  ${DIM}Maps vault objects to Kubernetes Secret keys. Empty key to finish.${RESET}"
        local new_data=""
        while true; do
          local data_key data_obj
          read -rp "    Secret key (empty to finish): " data_key
          [ -z "$data_key" ] && break
          prompt data_obj "Vault object name for '${data_key}'" "${data_key}"
          new_data="${new_data}              - key: ${data_key}
                objectName: ${data_obj}
"
        done
        if [ -n "$new_data" ]; then
          python3 "$YAML_HELPER" insert_in_nested "$file" "$target_class" "data:" "$new_data"
          echo "  ${ICON_CHECK} Added secret data mappings to '${target_class}'"
        fi
      fi
      ;;
  esac
}

# Helper: prompt for one or more SecretProviderClass entries, output YAML
_prompt_secret_provider_classes() {
  local file=$1
  local all_classes=""
  local more="true"

  # Auto-detect platform for defaults
  local detected_platform
  detected_platform=$(grep -A2 'platform:' "$file" 2>/dev/null | grep 'platform:' | head -1 | sed 's/.*platform: *//' | tr -d ' "'"'"'')

  while [ "$more" = "true" ]; do
    local spc_name spc_provider
    prompt spc_name "SecretProviderClass name" "redpoint-rpi-secrets"

    case "$detected_platform" in
      azure)  spc_provider="azure" ;;
      amazon) spc_provider="aws" ;;
      google) spc_provider="gcp" ;;
      *)      spc_provider="azure" ;;
    esac
    prompt spc_provider "CSI provider" "$spc_provider"

    # Parameters (key vault details)
    echo "" >&2
    echo "  ${BOLD}Provider Parameters${RESET}" >&2
    local params=""
    if [ "$spc_provider" = "azure" ]; then
      local kv_name kv_rg kv_sub kv_client kv_tenant
      prompt kv_name "Key Vault name" ""
      prompt kv_rg "Resource group" ""
      prompt kv_sub "Subscription ID" ""
      prompt kv_client "Client ID (Managed Identity)" ""
      prompt kv_tenant "Tenant ID" ""
      params="          keyvaultName: ${kv_name}
          resourceGroup: ${kv_rg}
          subscriptionId: ${kv_sub}
          clientID: \"${kv_client}\"
          tenantId: \"${kv_tenant}\"
          usePodIdentity: \"false\"
          useVMManagedIdentity: \"false\"
          useWorkloadIdentity: \"true\""

      local sync_secrets enable_rotation
      prompt_yesno sync_secrets "Sync secrets to Kubernetes Secret?" "y"
      if [ "$sync_secrets" = "true" ]; then
        params="${params}
          syncSecret: \"true\""
        prompt_yesno enable_rotation "Enable secret rotation?" "y"
        if [ "$enable_rotation" = "true" ]; then
          params="${params}
          enable-secret-rotation: \"true\""
        fi
      fi
    else
      echo "  ${DIM}Enter key=value pairs for parameters (empty line to finish):${RESET}" >&2
      while true; do
        local param_line=""
        read -rp "    " param_line
        [ -z "$param_line" ] && break
        local pkey="${param_line%%=*}"
        local pval="${param_line#*=}"
        params="${params}
          ${pkey}: \"${pval}\""
      done
    fi

    # Objects (vault objects to fetch)
    echo "" >&2
    echo "  ${BOLD}Vault Objects${RESET}" >&2
    echo "  ${DIM}Add vault objects to fetch (e.g., secrets, keys, certs). Empty name to finish.${RESET}" >&2
    local objects=""
    while true; do
      local obj_name obj_type
      read -rp "  Object name (empty to finish): " obj_name
      [ -z "$obj_name" ] && break
      prompt obj_type "Object type" "secret"
      objects="${objects}
          - objectName: \"${obj_name}\"
            objectType: ${obj_type}"
    done

    # Secret objects (sync to K8s Secret)
    local secret_objects=""
    local add_secret_objs=""
    prompt_yesno add_secret_objs "Add secretObjects (sync vault secrets to K8s Secret)?" "y"
    if [ "$add_secret_objs" = "true" ]; then
      local so_more="true"
      while [ "$so_more" = "true" ]; do
        local so_name so_type
        prompt so_name "Kubernetes Secret name to create" "rpi-synced-secrets"
        prompt so_type "Secret type" "Opaque"
        echo "  ${DIM}Map vault objects to Secret keys. Empty key to finish.${RESET}" >&2
        local so_data=""
        while true; do
          local data_key data_obj
          read -rp "    Secret key (empty to finish): " data_key
          [ -z "$data_key" ] && break
          prompt data_obj "Vault object name for '${data_key}'" "${data_key}"
          so_data="${so_data}
              - key: ${data_key}
                objectName: ${data_obj}"
        done
        secret_objects="${secret_objects}
          - secretName: ${so_name}
            type: ${so_type}
            data:${so_data}"
        prompt_yesno so_more "Add another secretObject?" "n"
      done
    fi

    # Build the class YAML entry
    local class_entry="      - name: ${spc_name}
        provider: ${spc_provider}"

    if [ -n "$secret_objects" ]; then
      class_entry="${class_entry}
        secretObjects:${secret_objects}"
    fi

    if [ -n "$params" ]; then
      class_entry="${class_entry}
        parameters:
${params}"
    fi

    if [ -n "$objects" ]; then
      class_entry="${class_entry}
        objects:${objects}"
    fi

    all_classes="${all_classes}${class_entry}
"

    prompt_yesno more "Add another SecretProviderClass?" "n"
  done

  echo "$all_classes"
}

add_data_warehouse() {
  local file=$1
  if grep -q "datawarehouse:" "$file" 2>/dev/null; then
    echo "  ${DIM}Skipped — datawarehouse already configured in ${file}${RESET}"; return 0
  fi
  echo ""
  echo "  ${DIM}Connect RPI to an external data warehouse for audience output and analytics.${RESET}"
  echo ""
  local provider
  prompt_choice provider "Data warehouse provider" "snowflake|bigquery" "snowflake"

  case "$provider" in
    snowflake)
      echo ""
      echo "  ${BOLD}Snowflake${RESET}"
      echo "  ${DIM}Uses JWT authentication. Create a ConfigMap with your RSA private key before deploying.${RESET}"
      local sf_configmap sf_keyname
      prompt sf_configmap "ConfigMap name (containing RSA key)" "snowflake-creds"
      prompt sf_keyname "Key file name in ConfigMap" "my-snowflake-rsakey.p8"
      append_dw_block "$file" "$(cat <<BLOCK
  datawarehouse:
    snowflake:
      enabled: true
      credentialsType: snowflake_jwt
      ConfigMapName: ${sf_configmap}
      keyName: ${sf_keyname}
      ConfigMapFilePath: /app/snowflake-creds
BLOCK
)" "Data Warehouse — Snowflake"
      echo "  ${ICON_CHECK} Added Snowflake data warehouse to ${file}"
      echo "  ${DIM}  Ensure ConfigMap '${sf_configmap}' exists with key '${sf_keyname}' before deploying.${RESET}"
      ;;

    bigquery)
      echo ""
      echo "  ${BOLD}Google BigQuery${RESET}"
      echo "  ${DIM}Uses service account authentication. Create a ConfigMap with your service account JSON key.${RESET}"
      local bq_configmap bq_sa_email bq_name bq_project
      prompt bq_name "Connection name (also used as DSN)" "gbq-tenant1"
      prompt bq_configmap "ConfigMap name (containing SA key JSON)" "gbq-tenant1"
      prompt bq_sa_email "Service account email" ""
      prompt bq_project "Google Cloud project ID" ""
      append_dw_block "$file" "$(cat <<BLOCK
  datawarehouse:
    bigquery:
      enabled: true
      connections:
        - name: ${bq_name}
          projectId: ${bq_project}
          sqlDialect: 1
          OAuthMechanism: 0
          credentialsType: serviceAccount
          serviceAccountEmail: ${bq_sa_email}
          configMapName: ${bq_configmap}
          keyName: ${bq_name}.json
          ConfigMapFilePath: /app/google-creds
          allowLargeResults: 0
          largeResultsDataSetId: _bqodbc_temp_tables
          largeResultsTempTableExpirationTime: "3600000"
BLOCK
)" "Data Warehouse — Google BigQuery"
      echo "  ${ICON_CHECK} Added BigQuery data warehouse to ${file}"
      echo "  ${DIM}  Ensure ConfigMap '${bq_configmap}' exists with key '${bq_name}.json' before deploying.${RESET}"
      ;;
  esac
}

add_extra_envs() {
  local file=$1
  check_replace_block "$file" "extraEnvs" "Extra Environment Variables" || return 0
  echo ""
  echo "  ${DIM}Extra environment variables are injected into the execution service container.${RESET}"
  echo "  ${DIM}Each variable has an enabled flag — set to true to activate.${RESET}"
  echo ""

  local envs=""
  local any_enabled=false

  # LuxSci sandbox
  local yn; prompt_yesno yn "Enable LuxSci sandbox mode?" "n"
  envs="${envs}\n    - name: Plugins__LuxSci__IsSandboxMode\n      enabled: ${yn}\n      value: \"true\""
  [ "$yn" = "true" ] && any_enabled=true

  # SendGrid sandbox
  prompt_yesno yn "Enable SendGrid sandbox mode?" "n"
  envs="${envs}\n    - name: Plugins__SendGrid__EnableSandBoxMode\n      enabled: ${yn}\n      value: \"true\""
  [ "$yn" = "true" ] && any_enabled=true

  # Twilio disable SMS
  prompt_yesno yn "Disable Twilio SMS campaigns?" "n"
  envs="${envs}\n    - name: Plugins__Twilio__DisableSendSMSCampaign\n      enabled: ${yn}\n      value: \"true\""
  [ "$yn" = "true" ] && any_enabled=true

  # Locale
  prompt_yesno yn "Set UTF-8 locale (LC_ALL, LANG, LANGUAGE)?" "n"
  envs="${envs}\n    - name: LC_ALL\n      enabled: ${yn}\n      value: \"en_US.UTF-8\""
  envs="${envs}\n    - name: LANG\n      enabled: ${yn}\n      value: \"en_US.UTF-8\""
  envs="${envs}\n    - name: LANGUAGE\n      enabled: ${yn}\n      value: \"en_US.UTF-8\""
  [ "$yn" = "true" ] && any_enabled=true

  # mPulse debug variables
  prompt_yesno yn "Enable mPulse debug variables?" "n"
  envs="${envs}\n    - name: RPI_MPULSE_UPSERT_CONTACT_DEBUG\n      enabled: ${yn}\n      value: \"1\""
  envs="${envs}\n    - name: RPI_MPULSE_EVENT_UPLOAD_DEBUG\n      enabled: ${yn}\n      value: \"1\""
  envs="${envs}\n    - name: RPI_MPULSE_EVENT_UPLOAD_FAIL_DEBUG\n      enabled: ${yn}\n      value: \"0\""
  envs="${envs}\n    - name: RPI_MPULSE_EVENT_UPLOAD_SCENARIO\n      enabled: ${yn}\n      value: \"1,5,2,3,5,7\""
  envs="${envs}\n    - name: RPI_MPULSE_SAVE_MPULSE_EVENT_CONTENT_DEBUG\n      enabled: ${yn}\n      value: \"1\""
  envs="${envs}\n    - name: RPI_MPULSE_UPSERT_CONTACT_IMPORT_PATH_DEBUG\n      enabled: ${yn}\n      value: \"/rpifileoutputdir/mpulse-debug-path\""
  [ "$yn" = "true" ] && any_enabled=true

  append_under_key "$file" "executionservice" "$(echo -e "  extraEnvs:${envs}")" "Extra Environment Variables"
  echo "  ${ICON_CHECK} Added extraEnvs to ${file}"
  if [ "$any_enabled" = "true" ]; then
    echo "  ${DIM}  Variables set to enabled: true will be injected at deploy time.${RESET}"
  else
    echo "  ${DIM}  All variables are disabled. Edit the overrides to enable as needed.${RESET}"
  fi
}


# ============================================================
# Advanced Mode Features
# ============================================================

add_common_annotations() {
  local file=$1
  check_replace_block "$file" "commonAnnotations" "Common Annotations" || return 0

  echo ""
  echo "  ${DIM}Common annotations are applied to all resources: ServiceAccounts, Services,${RESET}"
  echo "  ${DIM}Deployments, and Pods. Use for org-wide labels like cost center, support email, etc.${RESET}"
  echo ""

  local annotations=""
  local key value
  while true; do
    prompt key "Annotation key (e.g., example.com/cost-center)" ""
    [ -z "$key" ] && break
    prompt value "Annotation value" ""
    annotations="${annotations}  ${key}: \"${value}\"\n"
    local more=""
    prompt_yesno more "Add another annotation?" "n"
    [ "$more" = "false" ] && break
  done

  if [ -z "$annotations" ]; then
    echo "  ${DIM}No annotations entered, skipping.${RESET}"
    return 0
  fi

  append_block "$file" "$(printf "commonAnnotations:\n${annotations}")" "Common Annotations"
  echo "  ${ICON_CHECK} Added commonAnnotations to ${file}"

  local add_sa=""
  prompt_yesno add_sa "Add ServiceAccount-specific annotations (e.g., EKS role ARN)?" "n"
  if [ "$add_sa" = "true" ]; then
    local sa_annotations=""
    while true; do
      prompt key "ServiceAccount annotation key" ""
      [ -z "$key" ] && break
      prompt value "Annotation value" ""
      sa_annotations="${sa_annotations}  ${key}: \"${value}\"\n"
      local more=""
      prompt_yesno more "Add another?" "n"
      [ "$more" = "false" ] && break
    done
    if [ -n "$sa_annotations" ]; then
      append_block "$file" "$(printf "serviceAccountAnnotations:\n${sa_annotations}")" ""
      echo "  ${ICON_CHECK} Added serviceAccountAnnotations to ${file}"
    fi
  fi

  local add_svc=""
  prompt_yesno add_svc "Add Service-specific annotations (e.g., load balancer type)?" "n"
  if [ "$add_svc" = "true" ]; then
    local svc_annotations=""
    while true; do
      prompt key "Service annotation key" ""
      [ -z "$key" ] && break
      prompt value "Annotation value" ""
      svc_annotations="${svc_annotations}  ${key}: \"${value}\"\n"
      local more=""
      prompt_yesno more "Add another?" "n"
      [ "$more" = "false" ] && break
    done
    if [ -n "$svc_annotations" ]; then
      append_block "$file" "$(printf "serviceAnnotations:\n${svc_annotations}")" ""
      echo "  ${ICON_CHECK} Added serviceAnnotations to ${file}"
    fi
  fi
}

add_custom_ca_certs() {
  local file=$1
  check_replace_block "$file" "customCACerts" "Custom CA Certificates" || return 0

  echo ""
  echo "  ${DIM}Mount custom CA certificates into all service pods.${RESET}"
  echo "  ${DIM}Useful for connecting to databases or services using internal CAs.${RESET}"
  echo ""

  local source name mount_path cert_file
  prompt_choice source "Certificate source" "configMap|secret" "configMap"
  prompt name "Name of the ${source}" ""
  prompt mount_path "Mount path inside containers" "/usr/local/share/ca-certificates/custom"
  prompt cert_file "CA bundle filename for SSL_CERT_FILE (leave empty to skip)" ""

  local block="customCACerts:
  enabled: true
  source: ${source}
  name: ${name}
  mountPath: ${mount_path}"

  if [ -n "$cert_file" ]; then
    block="${block}
  certFile: ${cert_file}"
  fi

  append_block "$file" "$block" "Custom CA Certificates"
  echo "  ${ICON_CHECK} Added customCACerts to ${file}"
}

add_image_overrides() {
  local file=$1

  echo ""
  echo "  ${DIM}Per-service image overrides let you use a different image reference${RESET}"
  echo "  ${DIM}for specific services instead of the default {repository}/{name}:{tag} pattern.${RESET}"
  echo "  ${DIM}Useful for flat registries (e.g., ECR with all images in a single repo).${RESET}"
  echo ""

  if has_block "$file" "overrides"; then
    local replace=""
    prompt_yesno replace "Image overrides already exist. Replace them?" "n"
    if [ "$replace" != "true" ]; then
      echo "  ${DIM}Skipped — keeping existing image overrides${RESET}"
      return 0
    fi
  fi

  local services="rpi-interactionapi rpi-deploymentapi rpi-executionservice rpi-queuereader rpi-integrationapi rpi-realtimeapi rpi-callbackapi rpi-nodemanager"
  local overrides=""

  echo "  ${DIM}Enter the full image reference for each service, or press Enter to skip (use default).${RESET}"
  echo ""
  for svc in $services; do
    local img=""
    prompt img "  ${svc}" ""
    if [ -n "$img" ]; then
      overrides="${overrides}      ${svc}: ${img}\n"
    fi
  done

  if [ -z "$overrides" ]; then
    echo "  ${DIM}No overrides entered, skipping.${RESET}"
    return 0
  fi

  # Insert under global.deployment.images using append_under_key
  local content
  content=$(printf "    overrides:\n${overrides}")

  if grep -q "^  *overrides:" "$file" 2>/dev/null; then
    remove_block "$file" "overrides"
  fi

  append_under_key "$file" "global" "$(printf "  deployment:\n    images:\n      overrides:\n${overrides}")" "Per-Service Image Overrides"
  echo "  ${ICON_CHECK} Added image overrides to ${file}"
}

add_pod_anti_affinity() {
  local file=$1
  check_replace_block "$file" "podAntiAffinity" "Pod Anti-Affinity" || return 0

  echo ""
  echo "  ${DIM}Pod anti-affinity controls how pods are spread across nodes.${RESET}"
  echo "  ${DIM}  preferred — pods prefer different nodes but can co-locate if needed (default)${RESET}"
  echo "  ${DIM}  required  — pods must land on different nodes; scheduling fails if not possible${RESET}"
  echo "  ${DIM}  disabled  — no anti-affinity; scheduler places pods freely${RESET}"
  echo ""

  local aa_type aa_enabled weight topology_key
  prompt_choice aa_type "Anti-affinity type" "preferred|required|disabled" "preferred"

  if [ "$aa_type" = "disabled" ]; then
    append_block "$file" "$(cat <<'BLOCK'
podAntiAffinity:
  enabled: false
BLOCK
)" "Pod Anti-Affinity"
    echo "  ${ICON_CHECK} Disabled pod anti-affinity in ${file}"
    return 0
  fi

  prompt topology_key "Topology key" "kubernetes.io/hostname"

  local block="podAntiAffinity:
  enabled: true
  type: ${aa_type}
  topologyKey: ${topology_key}"

  if [ "$aa_type" = "preferred" ]; then
    prompt weight "Weight (1-100)" "100"
    block="${block}
  weight: ${weight}"
  fi

  append_block "$file" "$block" "Pod Anti-Affinity"
  echo "  ${ICON_CHECK} Added podAntiAffinity (${aa_type}) to ${file}"
}

add_node_provisioning() {
  local file=$1
  check_replace_block "$file" "nodeProvisioning" "Node Provisioning" || return 0

  echo ""
  echo "  ${DIM}Create a Karpenter NodePool for dedicated RPI nodes on EKS.${RESET}"
  echo "  ${DIM}Nodes are provisioned automatically with your specified instance types and taints.${RESET}"
  echo ""

  local pool_name instance_family instance_size arch capacity_type
  prompt pool_name "NodePool name" "redpoint-nodepool"
  prompt instance_family "Instance family (e.g., m7i, m5)" "m7i"
  prompt instance_size "Instance size (e.g., 4xlarge, 2xlarge)" "4xlarge"
  prompt_choice arch "Architecture" "amd64|arm64" "amd64"
  prompt_choice capacity_type "Capacity type" "on-demand|spot" "on-demand"

  local node_class_name expire_after
  prompt node_class_name "EC2NodeClass name" "default"
  prompt expire_after "Node expiration (e.g., 360h)" "360h"

  local add_taint=""
  local taint_block=""
  prompt_yesno add_taint "Add a taint to dedicate nodes to RPI?" "y"
  if [ "$add_taint" = "true" ]; then
    local taint_key taint_value taint_effect
    prompt taint_key "Taint key" "workload"
    prompt taint_value "Taint value" "redpoint-api"
    prompt_choice taint_effect "Taint effect" "NoSchedule|NoExecute|PreferNoSchedule" "NoSchedule"
    taint_block="
      taints:
        - key: ${taint_key}
          value: ${taint_value}
          effect: ${taint_effect}
      labels:
        ${taint_key}: ${taint_value}"
  fi

  local cpu_limit mem_limit
  prompt cpu_limit "CPU limit (total cores for all nodes)" "1000"
  prompt mem_limit "Memory limit (e.g., 1000Gi)" "1000Gi"

  append_block "$file" "$(cat <<BLOCK
nodeProvisioning:
  enabled: true
  provider: karpenter
  karpenter:
    nodePool:
      name: ${pool_name}${taint_block}
      requirements:
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["${instance_family}"]
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["${instance_size}"]
        - key: kubernetes.io/arch
          operator: In
          values: ["${arch}"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["${capacity_type}"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: ${node_class_name}
      expireAfter: ${expire_after}
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 15m
      limits:
        cpu: "${cpu_limit}"
        memory: ${mem_limit}
BLOCK
)" "Node Provisioning (Karpenter)"
  echo "  ${ICON_CHECK} Added nodeProvisioning to ${file}"
}

add_storage_class() {
  local file=$1
  check_replace_block "$file" "storageClass" "Storage Class" || return 0

  echo ""
  echo "  ${DIM}Create a Kubernetes StorageClass for CSI-backed storage.${RESET}"
  echo "  ${DIM}Common for EFS (AWS), Azure File, or GCE Persistent Disk.${RESET}"
  echo ""

  local sc_name provisioner reclaim_policy
  prompt sc_name "StorageClass name" "redpoint-rpi"
  prompt provisioner "CSI provisioner (e.g., efs.csi.aws.com)" ""
  prompt_choice reclaim_policy "Reclaim policy" "Delete|Retain" "Delete"

  local params=""
  local add_params=""
  prompt_yesno add_params "Add provisioner parameters?" "y"
  if [ "$add_params" = "true" ]; then
    while true; do
      local pk pv
      prompt pk "Parameter key (empty to stop)" ""
      [ -z "$pk" ] && break
      prompt pv "Parameter value" ""
      params="${params}    ${pk}: \"${pv}\"\n"
    done
  fi

  local mount_opts=""
  local add_mounts=""
  prompt_yesno add_mounts "Add mount options?" "n"
  if [ "$add_mounts" = "true" ]; then
    while true; do
      local mo
      prompt mo "Mount option (empty to stop)" ""
      [ -z "$mo" ] && break
      mount_opts="${mount_opts}    - ${mo}\n"
    done
  fi

  local block="storage:
  storageClass:
    enabled: true
    name: ${sc_name}
    provisioner: ${provisioner}
    reclaimPolicy: ${reclaim_policy}"

  if [ -n "$mount_opts" ]; then
    block="${block}
    mountOptions:
$(printf "${mount_opts}")"
  fi

  if [ -n "$params" ]; then
    block="${block}
    parameters:
$(printf "${params}")"
  fi

  append_block "$file" "$block" "Storage Class"
  echo "  ${ICON_CHECK} Added storageClass to ${file}"
}

show_feature_menu() {
  echo ""
  echo "  ${BOLD}Available features:${RESET}"
  echo ""
  echo "    ${CYAN}1${RESET})  database_upgrade  — Run schema migrations automatically after upgrades"
  echo "    ${CYAN}2${RESET})  queue_reader      — Process realtime queue events (forms, listeners, callbacks)"
  echo "    ${CYAN}3${RESET})  autoscaling       — Scale services based on CPU/memory with HPA or KEDA"
  echo "    ${CYAN}4${RESET})  custom_metrics    — Expose Prometheus /metrics endpoints for monitoring"
  echo "    ${CYAN}5${RESET})  service_mesh      — Enable Linkerd mTLS and traffic policies"
  echo "    ${CYAN}6${RESET})  validation_pods       — Validate PVC mounts and CSI drivers post-deploy"
  echo "    ${CYAN}7${RESET})  entra_id          — Single sign-on via Microsoft Entra ID (Azure AD)"
  echo "    ${CYAN}8${RESET})  oidc              — Single sign-on via OpenID Connect (Keycloak, Okta, etc.)"
  echo "    ${CYAN}9${RESET})  smtp              — Send transactional emails from RPI workflows"
  echo "    ${CYAN}10${RESET}) redpoint_ai       — AI-powered content generation (OpenAI + Cognitive Search)"
  echo "    ${CYAN}11${RESET}) storage           — Persistent volumes for file-based processing and caching"
  echo "    ${CYAN}12${RESET}) data_warehouse    — Connect to Snowflake or BigQuery"
  echo "    ${CYAN}13${RESET}) extra_envs        — Debug and plugin environment variables"
  echo "    ${CYAN}14${RESET}) secrets_management — Configure secrets provider, CSI classes, SDK vault settings"
  echo "    ${CYAN}15${RESET}) node_scheduling    — Node selector and tolerations for dedicated nodes"
  echo "    ${CYAN}16${RESET}) common_annotations — Org-wide annotations on all resources (cost center, alerts)"
  echo "    ${CYAN}17${RESET}) custom_ca_certs    — Mount internal CA certificates into service pods"
  echo "    ${CYAN}18${RESET}) image_overrides    — Per-service container image references (flat registries)"
  echo "    ${CYAN}19${RESET}) pod_anti_affinity  — Control pod scheduling spread across nodes"
  echo "    ${CYAN}20${RESET}) node_provisioning  — Karpenter NodePool for dedicated EKS nodes"
  echo "    ${CYAN}21${RESET}) storage_class      — Create a StorageClass for CSI storage (EFS, Azure File)"
  echo ""
  local choice
  read -rp "  Enter feature number or name: " choice
  case "$choice" in
    1|database_upgrade)    ADD_FEATURE="database_upgrade" ;;
    2|queue_reader)        ADD_FEATURE="queue_reader" ;;
    3|autoscaling)         ADD_FEATURE="autoscaling" ;;
    4|custom_metrics)      ADD_FEATURE="custom_metrics" ;;
    5|service_mesh)        ADD_FEATURE="service_mesh" ;;
    6|validation_pods)         ADD_FEATURE="validation_pods" ;;
    7|entra_id)            ADD_FEATURE="entra_id" ;;
    8|oidc)                ADD_FEATURE="oidc" ;;
    9|smtp)                ADD_FEATURE="smtp" ;;
    10|redpoint_ai)        ADD_FEATURE="redpoint_ai" ;;
    11|storage)            ADD_FEATURE="storage" ;;
    12|data_warehouse)     ADD_FEATURE="data_warehouse" ;;
    13|extra_envs)         ADD_FEATURE="extra_envs" ;;
    14|secrets_management) ADD_FEATURE="secrets_management" ;;
    15|node_scheduling)    ADD_FEATURE="node_scheduling" ;;
    16|common_annotations) ADD_FEATURE="common_annotations" ;;
    17|custom_ca_certs)    ADD_FEATURE="custom_ca_certs" ;;
    18|image_overrides)    ADD_FEATURE="image_overrides" ;;
    19|pod_anti_affinity)  ADD_FEATURE="pod_anti_affinity" ;;
    20|node_provisioning)  ADD_FEATURE="node_provisioning" ;;
    21|storage_class)      ADD_FEATURE="storage_class" ;;
    *) echo "  ${RED}Unknown feature: ${choice}${RESET}"; exit 1 ;;
  esac
}

# ============================================================
# Cluster Status
# ============================================================

cli_status() {
  local ns=$1
  echo ""
  echo "${CYAN}${BOLD}━━━ RPI Cluster Status ━━━${RESET}"
  echo "  Namespace: ${BOLD}${ns}${RESET}"
  echo ""

  # Check kubectl
  if ! command -v kubectl &>/dev/null; then
    echo "  ${RED}kubectl not found. Install kubectl and configure cluster access.${RESET}"
    exit 1
  fi

  if ! kubectl cluster-info &>/dev/null 2>&1; then
    echo "  ${RED}No Kubernetes cluster is reachable.${RESET}"
    echo "  Run 'kubectl cluster-info' to verify connectivity."
    exit 1
  fi

  # Pods
  echo "${CYAN}${BOLD}  Pods${RESET}"
  local pods_output
  pods_output=$(kubectl get pods -n "$ns" -o wide 2>&1) || true
  if echo "$pods_output" | grep -q "No resources found"; then
    echo "  ${YELLOW}No pods found in namespace ${ns}${RESET}"
  else
    # Count statuses
    local total running pending failed
    total=$(echo "$pods_output" | tail -n +2 | wc -l | tr -d ' ')
    running=$(echo "$pods_output" | tail -n +2 | awk '$3 == "Running"' | wc -l | tr -d ' ')
    pending=$(echo "$pods_output" | tail -n +2 | awk '$3 == "Pending"' | wc -l | tr -d ' ')
    failed=$(echo "$pods_output" | tail -n +2 | awk '$3 == "CrashLoopBackOff" || $3 == "Error" || $3 == "Failed"' | wc -l | tr -d ' ')
    local other=$((total - running - pending - failed))

    echo "  Total: ${BOLD}${total}${RESET}  |  ${GREEN}Running: ${running}${RESET}  |  ${YELLOW}Pending: ${pending}${RESET}  |  ${RED}Failed: ${failed}${RESET}  |  Other: ${other}"
    echo ""
    echo "$pods_output" | head -1
    echo "$pods_output" | tail -n +2 | while IFS= read -r line; do
      local status
      status=$(echo "$line" | awk '{print $3}')
      case "$status" in
        Running)          echo "  ${GREEN}${line}${RESET}" ;;
        Pending)          echo "  ${YELLOW}${line}${RESET}" ;;
        CrashLoopBackOff|Error|Failed) echo "  ${RED}${line}${RESET}" ;;
        *)                echo "  ${line}" ;;
      esac
    done
  fi

  echo ""

  # Services
  echo "${CYAN}${BOLD}  Services${RESET}"
  kubectl get services -n "$ns" 2>&1 | head -30 || echo "  ${DIM}Could not list services${RESET}"
  echo ""

  # Ingress
  echo "${CYAN}${BOLD}  Ingress${RESET}"
  local ingress_output
  ingress_output=$(kubectl get ingress -n "$ns" 2>&1) || true
  if echo "$ingress_output" | grep -q "No resources found"; then
    echo "  ${DIM}No Ingress resources found${RESET}"
  else
    echo "$ingress_output" | head -20
  fi

  echo ""
}

# ============================================================
# Cluster Troubleshoot
# ============================================================

cli_troubleshoot() {
  local ns=$1 symptom=${2:-}
  echo ""
  echo "${CYAN}${BOLD}━━━ RPI Troubleshoot ━━━${RESET}"
  echo "  Namespace: ${BOLD}${ns}${RESET}"
  if [ -n "$symptom" ]; then
    echo "  Symptom:   ${BOLD}${symptom}${RESET}"
  fi
  echo ""

  # Check kubectl
  if ! command -v kubectl &>/dev/null; then
    echo "  ${RED}kubectl not found. Install kubectl and configure cluster access.${RESET}"
    exit 1
  fi

  if ! kubectl cluster-info &>/dev/null 2>&1; then
    echo "  ${RED}No Kubernetes cluster is reachable.${RESET}"
    echo "  ${DIM}Run 'kubectl cluster-info' to verify connectivity.${RESET}"
    echo "  ${DIM}Check KUBECONFIG env var and cluster access.${RESET}"
    exit 1
  fi

  local findings=0

  # Get pods once
  local pods_output
  pods_output=$(kubectl get pods -n "$ns" 2>&1) || true

  if echo "$pods_output" | grep -q "No resources found"; then
    echo "  ${YELLOW}[warning] No pods found in namespace ${ns}${RESET}"
    echo "  ${DIM}  Fix: Verify the Helm release is installed: helm list -n ${ns}${RESET}"
    findings=$((findings + 1))
  else
    # CrashLoopBackOff / Error
    _ts_check_crashloop() {
      local pod_name
      echo "$pods_output" | tail -n +2 | while IFS= read -r line; do
        if echo "$line" | grep -qE "CrashLoopBackOff|Error|Failed"; then
          pod_name=$(echo "$line" | awk '{print $1}')
          echo ""
          echo "  ${RED}[critical] Pod ${pod_name} is in CrashLoopBackOff${RESET}"
          local logs
          logs=$(kubectl logs "$pod_name" --tail=30 -n "$ns" 2>&1) || logs="(could not retrieve logs)"
          echo "  ${DIM}Last 30 log lines:${RESET}"
          echo "$logs" | sed 's/^/    /'
          echo ""
          echo "  ${DIM}  Fix: Check for configuration errors (missing env vars, bad connection strings).${RESET}"
          echo "  ${DIM}  Try: kubectl logs ${pod_name} --previous -n ${ns}${RESET}"
        fi
      done
    }

    # Pending pods
    _ts_check_pending() {
      local pod_name
      echo "$pods_output" | tail -n +2 | while IFS= read -r line; do
        if echo "$line" | grep -q "Pending"; then
          pod_name=$(echo "$line" | awk '{print $1}')
          echo ""
          echo "  ${YELLOW}[warning] Pod ${pod_name} is Pending${RESET}"
          local desc events
          desc=$(kubectl describe pod "$pod_name" -n "$ns" 2>&1) || desc=""
          events=$(echo "$desc" | sed -n '/^Events:/,$p' | head -20)
          if [ -n "$events" ]; then
            echo "$events" | sed 's/^/    /'
          fi
          echo ""
          echo "  ${DIM}  Fix: Common causes: insufficient CPU/memory, unbound PVCs, image pull errors, node affinity constraints.${RESET}"
        fi
      done
    }

    # Image pull errors
    _ts_check_imagepull() {
      local pod_name
      echo "$pods_output" | tail -n +2 | while IFS= read -r line; do
        if echo "$line" | grep -qE "ImagePullBackOff|ErrImagePull"; then
          pod_name=$(echo "$line" | awk '{print $1}')
          echo ""
          echo "  ${RED}[critical] Pod ${pod_name} cannot pull its container image${RESET}"
          echo "  ${DIM}  Fix: Verify global.deployment.images.repository and tag are correct.${RESET}"
          echo "  ${DIM}  Ensure the imagePullSecret exists and has valid credentials.${RESET}"
        fi
      done
    }

    # Run checks based on symptom or all
    case "${symptom}" in
      crashloop)
        _ts_check_crashloop
        ;;
      pending)
        _ts_check_pending
        ;;
      imagepull)
        _ts_check_imagepull
        ;;
      *)
        # General: run all checks
        if echo "$pods_output" | grep -qE "CrashLoopBackOff|Error|Failed"; then
          _ts_check_crashloop
          findings=$((findings + 1))
        fi
        if echo "$pods_output" | grep -q "Pending"; then
          _ts_check_pending
          findings=$((findings + 1))
        fi
        if echo "$pods_output" | grep -qE "ImagePullBackOff|ErrImagePull"; then
          _ts_check_imagepull
          findings=$((findings + 1))
        fi
        ;;
    esac
  fi

  # Check secrets
  echo ""
  echo "${CYAN}${BOLD}  Secrets Check${RESET}"
  local secrets_output
  secrets_output=$(kubectl get secrets -n "$ns" -o name 2>&1) || secrets_output=""
  if echo "$secrets_output" | grep -q "redpoint-rpi"; then
    echo "  ${GREEN}✔ Found redpoint-rpi secret${RESET}"
  else
    echo "  ${YELLOW}[warning] No secret matching 'redpoint-rpi' found${RESET}"
    echo "  ${DIM}  Fix: Ensure secretsManagement is configured correctly and secrets are created.${RESET}"
    findings=$((findings + 1))
  fi

  # Check ingress
  echo ""
  echo "${CYAN}${BOLD}  Ingress Check${RESET}"
  local ingress_output
  ingress_output=$(kubectl get ingress -n "$ns" 2>&1) || ingress_output=""
  if echo "$ingress_output" | grep -q "No resources found"; then
    echo "  ${DIM}[info] No Ingress resources found. External access may not be configured.${RESET}"
  else
    echo "  ${GREEN}✔ Ingress resources found${RESET}"
    echo "$ingress_output" | head -10 | sed 's/^/    /'
  fi

  # Recent events
  echo ""
  echo "${CYAN}${BOLD}  Recent Events${RESET}"
  local events_output
  events_output=$(kubectl get events -n "$ns" --sort-by='.lastTimestamp' 2>&1 | tail -15) || events_output=""
  if [ -n "$events_output" ] && ! echo "$events_output" | grep -q "No resources found"; then
    echo "$events_output" | sed 's/^/    /'
  else
    echo "  ${DIM}No recent events${RESET}"
  fi

  echo ""
  if [ "$findings" -eq 0 ]; then
    echo "  ${GREEN}✔ No issues detected. All checks passed.${RESET}"
  fi
  echo ""
}

# ============================================================
# Secrets command: read overrides, prompt for credentials, write secrets.yaml
# ============================================================
read_val() {
  python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
keys = sys.argv[2].split('.')
v = d
for k in keys:
    v = (v or {}).get(k) if isinstance(v, dict) else None
print(v if v is not None else '')" "$1" "$2"
}

cli_secrets() {
  local overrides="$1" output="$2" namespace="$3"

  if [ -z "$overrides" ]; then
    echo "${RED}Error: -f <overrides-file> is required.${RESET}" >&2
    echo "Usage: rpihelmcli/setup.sh secrets -f overrides.yaml [-o secrets.yaml] [-n namespace]" >&2
    exit 1
  fi
  if [ ! -f "$overrides" ]; then
    echo "${RED}Error: File not found: ${overrides}${RESET}" >&2; exit 1
  fi

  # Check python3 + PyYAML (auto-install if missing)
  if ! command -v python3 &>/dev/null; then
    echo "${RED}Error: python3 is required.${RESET}" >&2; exit 1
  fi
  if ! python3 -c "import yaml" 2>/dev/null; then
    echo "  Installing PyYAML..."
    python3 -m pip install pyyaml --quiet 2>/dev/null || python3 -m pip install pyyaml --quiet --user 2>/dev/null
    if ! python3 -c "import yaml" 2>/dev/null; then
      echo "${RED}Error: Failed to install PyYAML. Install manually: pip3 install pyyaml${RESET}" >&2; exit 1
    fi
  fi

  echo ""
  echo "${CYAN}${BOLD}Interaction CLI — Secrets Generator${RESET}"
  echo "${DIM}Reading configuration from: ${overrides}${RESET}"
  echo ""

  # Read configuration from overrides
  local platform mode db_provider secrets_provider rt_enabled rt_cache_provider rt_queue_provider
  platform=$(read_val "$overrides" "global.deployment.platform")
  platform="${platform:-azure}"
  mode=$(read_val "$overrides" "global.deployment.mode")
  mode="${mode:-standard}"
  db_provider=$(read_val "$overrides" "databases.operational.provider")
  db_provider="${db_provider:-sqlserver}"
  secrets_provider=$(read_val "$overrides" "secretsManagement.provider")
  secrets_provider="${secrets_provider:-kubernetes}"
  rt_enabled=$(read_val "$overrides" "realtimeapi.enabled")
  rt_enabled="${rt_enabled:-false}"
  rt_cache_provider=$(read_val "$overrides" "realtimeapi.cacheProvider.provider")
  rt_cache_provider="${rt_cache_provider:-mongodb}"
  rt_queue_provider=$(read_val "$overrides" "realtimeapi.queueProvider.provider")
  rt_queue_provider="${rt_queue_provider:-rabbitmq}"

  # Pre-fill database values from overrides if present
  local db_host db_user db_pulse db_logging
  db_host=$(read_val "$overrides" "databases.operational.server_host")
  db_user=$(read_val "$overrides" "databases.operational.server_username")
  db_pulse=$(read_val "$overrides" "databases.operational.pulse_database_name")
  db_pulse="${db_pulse:-Pulse}"
  db_logging=$(read_val "$overrides" "databases.operational.pulse_logging_database_name")
  db_logging="${db_logging:-PulseLogging}"

  # Skip RPI secret for SDK and CSI modes (secrets come from vault / CSI driver)
  if [ "$secrets_provider" = "sdk" ] || [ "$secrets_provider" = "csi" ]; then
    local _provider_label="cloud vault"
    [ "$secrets_provider" = "csi" ] && _provider_label="CSI Secret Store driver"
    echo "  ${YELLOW}Secrets provider is '${secrets_provider}'. RPI secrets are managed by the ${_provider_label}.${RESET}"
    echo "  ${DIM}No Kubernetes secret will be generated by this command.${RESET}"
    echo ""
    echo "  Ensure your vault contains the required secrets before deploying."
    echo ""
    echo "  ${BOLD}References:${RESET}"
    echo "    Secrets guide:    https://github.com/RedPointGlobal/redpoint-rpi/blob/release/v7.7/docs/secrets-management.md"
    echo "    Vault setup:      https://rpi-helm-assistant.redpointcdp.com (Automate tab)"
    echo ""

    # Still create the output file for non-secret resources (image pull, TLS, ConfigMaps)
    echo "# RPI secrets managed by ${secrets_provider} (not included in this file)" > "$output"
    echo "# Generated by Interaction CLI — $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> "$output"
  fi

  # Show detected configuration
  echo "  ${BOLD}Detected configuration:${RESET}"
  echo "    Platform:         ${platform}"
  echo "    Mode:             ${mode}"
  echo "    Database:         ${db_provider}"
  echo "    Secrets provider: ${secrets_provider}"
  echo "    Realtime API:     ${rt_enabled}"
  if [ "$rt_enabled" = "true" ] || [ "$rt_enabled" = "True" ]; then
    echo "    Cache provider:   ${rt_cache_provider}"
    echo "    Queue provider:   ${rt_queue_provider}"
  fi
  echo ""

  # Initialize the secrets file (only for kubernetes provider)
  if [ "$secrets_provider" = "kubernetes" ]; then
  cat > "$output" << SECRETS_HEADER
# ============================================================
# RPI Kubernetes Secret — Generated by Interaction CLI
# $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# ============================================================
# Apply BEFORE helm install:
#   kubectl apply -f ${output} -n ${namespace}
#
# WARNING: This file contains sensitive values.
#          Do NOT commit this file to version control.
# ============================================================
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${namespace}
  annotations:
    helm.sh/resource-policy: keep
type: Opaque
stringData:
SECRETS_HEADER

  # --- Database credentials ---
  if [ "$mode" != "demo" ]; then
    echo "  ${BOLD}Database credentials${RESET}"
    if [ -z "$db_host" ]; then
      read -rp "    Server host: " db_host
    else
      echo "    Server host: ${DIM}${db_host}${RESET} (from overrides)"
    fi
    if [ -z "$db_user" ]; then
      read -rp "    Username: " db_user
    else
      echo "    Username: ${DIM}${db_user}${RESET} (from overrides)"
    fi

    local db_pass=""
    read -rsp "    Password: " db_pass
    echo ""
    echo ""

    # Build connection strings
    local ops_conn="" log_conn=""
    case "$db_provider" in
      sqlserver)
        ops_conn="Server=tcp:${db_host},1433;Database=${db_pulse};User ID=${db_user};Password=${db_pass};Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
        log_conn="Server=tcp:${db_host},1433;Database=${db_logging};User ID=${db_user};Password=${db_pass};Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
        ;;
      postgresql)
        ops_conn="PostgreSQL:Server=${db_host};Database=${db_pulse};User Id=${db_user};Password=${db_pass};"
        log_conn="PostgreSQL:Server=${db_host};Database=${db_logging};User Id=${db_user};Password=${db_pass};"
        ;;
      sqlserveronvm)
        ops_conn="Server=${db_host},1433;Database=${db_pulse};uid=${db_user};pwd=${db_pass};ConnectRetryCount=12;ConnectRetryInterval=10;Encrypt=True;TrustServerCertificate=True;"
        log_conn="Server=${db_host},1433;Database=${db_logging};uid=${db_user};pwd=${db_pass};ConnectRetryCount=12;ConnectRetryInterval=10;Encrypt=True;TrustServerCertificate=True;"
        ;;
    esac

    cat >> "$output" << SECRETS_DB
  # -- Operational Database --
  ConnectionString_Operations_Database: "${ops_conn}"
  ConnectionString_Logging_Database: "${log_conn}"
  Operations_Database_Server_Password: "${db_pass}"
  Operations_Database_ServerHost: "${db_host}"
  Operations_Database_Server_Username: "${db_user}"
  Operations_Database_Pulse_Database_Name: "${db_pulse}"
  Operations_Database_Pulse_Logging_Database_Name: "${db_logging}"
SECRETS_DB
  fi

  # --- Realtime API secrets ---
  if [ "$rt_enabled" = "true" ] || [ "$rt_enabled" = "True" ]; then
    local rt_auth_token rt_rabbitmq_pass rt_redis_pass qs_redis_pass qs_rabbitmq_pass
    rt_auth_token=$(gen_uuid)
    rt_rabbitmq_pass=$(gen_password)
    rt_redis_pass=$(gen_password)
    qs_redis_pass=$(gen_password)
    qs_rabbitmq_pass=$(gen_password)

    cat >> "$output" << SECRETS_RT
  # -- Realtime API --
  RealtimeAPI_Auth_Token: "${rt_auth_token}"
SECRETS_RT

    # Cache connection string
    if [ "$rt_cache_provider" = "mongodb" ] || [ "$rt_cache_provider" = "redis" ] || \
       [ "$rt_cache_provider" = "azureredis" ] || [ "$rt_cache_provider" = "inMemorySql" ]; then
      echo "  ${BOLD}Realtime cache connection${RESET}"
      local rt_cache_conn=""
      read -rsp "    ${rt_cache_provider} connection string: " rt_cache_conn
      echo ""

      if [ -n "$rt_cache_conn" ]; then
        local cache_key=""
        case "$rt_cache_provider" in
          mongodb)     cache_key="RealtimeAPI_MongoCache_ConnectionString" ;;
          redis|azureredis) cache_key="RealtimeAPI_RedisCache_ConnectionString" ;;
          inMemorySql) cache_key="RealtimeAPI_inMemorySql_ConnectionString" ;;
        esac
        echo "  ${cache_key}: \"${rt_cache_conn}\"" >> "$output"
      fi
    fi

    # Queue connection string (if azure)
    if [ "$rt_queue_provider" = "azureservicebus" ] || [ "$rt_queue_provider" = "azureeventhubs" ]; then
      echo "  ${BOLD}Realtime queue connection${RESET}"
      local rt_queue_conn=""
      read -rsp "    ${rt_queue_provider} connection string: " rt_queue_conn
      echo ""

      if [ -n "$rt_queue_conn" ]; then
        local queue_key=""
        case "$rt_queue_provider" in
          azureservicebus) queue_key="RealtimeAPI_ServiceBus_ConnectionString" ;;
          azureeventhubs)  queue_key="RealtimeAPI_EventHubs_ConnectionString" ;;
        esac
        echo "  ${queue_key}: \"${rt_queue_conn}\"" >> "$output"
      fi
    fi

    # AWS access keys (required for SQS/S3 when using amazonsqs queue provider)
    if [ "$platform" = "amazon" ]; then
      local use_access_keys
      use_access_keys=$(read_val "$overrides" "cloudIdentity.amazon.useAccessKeys")
      if [ "$rt_queue_provider" = "amazonsqs" ] || [ "$use_access_keys" = "true" ] || [ "$use_access_keys" = "True" ]; then
        echo "  ${BOLD}AWS Access Keys${RESET}"
        echo "  ${DIM}Required for Amazon SQS queue access. The IAM user needs SQS and S3 permissions.${RESET}"
        local aws_access_key_id aws_secret_access_key
        read -rp "    Access Key ID: " aws_access_key_id
        read -rsp "    Secret Access Key: " aws_secret_access_key
        echo ""
        if [ -n "$aws_access_key_id" ] && [ -n "$aws_secret_access_key" ]; then
          cat >> "$output" << SECRETS_AWS_KEYS
  # -- AWS Access Keys --
  AWS_Access_Key_ID: "${aws_access_key_id}"
  AWS_Secret_Access_Key: "${aws_secret_access_key}"
SECRETS_AWS_KEYS
          echo "  ${GREEN}✔ AWS access keys added${RESET}"
        else
          echo "  ${YELLOW}Skipped. Pods using SQS will fail without these keys in the secret.${RESET}"
        fi
        echo ""
      fi
    fi

    # Auto-generated internal passwords
    cat >> "$output" << SECRETS_AUTO
  RealtimeAPI_RabbitMQ_Password: "${rt_rabbitmq_pass}"
  RealtimeAPI_RedisCache_Password: "${rt_redis_pass}"
  QueueService_RedisCache_Password: "${qs_redis_pass}"
  QueueService_internalCache_ConnectionString: "rpi-queuereader-cache:6379,password=${qs_redis_pass},abortConnect=False"
  QueueService_RabbitMQ_Password: "${qs_rabbitmq_pass}"
SECRETS_AUTO
    echo ""
  fi

  # --- Execution Service internal-cache Azure Blob connection string ---
  # Only prompt when executionservice.internalCache.provider is azureblob
  # AND useCloudIdentity is false. The connection string lands in the
  # shared K8s Secret as ExecutionService_AzureBlob_ConnectionString;
  # the chart reads it via secretKeyRef. When useCloudIdentity is true,
  # the pod authenticates via Workload Identity and no secret is needed.
  local exec_internal_cache_provider exec_use_cloud_identity
  exec_internal_cache_provider=$(read_val "$overrides" "executionservice.internalCache.provider")
  exec_use_cloud_identity=$(read_val "$overrides" "executionservice.internalCache.azureStorageSettings.useCloudIdentity")
  exec_use_cloud_identity="${exec_use_cloud_identity:-false}"
  if [ "$exec_internal_cache_provider" = "azureblob" ] \
     && [ "$exec_use_cloud_identity" != "true" ] \
     && [ "$exec_use_cloud_identity" != "True" ]; then
    echo "  ${BOLD}Execution Service internal cache (Azure Blob)${RESET}"
    local exec_azure_blob_conn
    read -rsp "    Connection string: " exec_azure_blob_conn
    echo ""

    cat >> "$output" << SECRETS_EXEC_AZBLOB
  # -- Execution Service internal cache (Azure Blob) --
  ExecutionService_AzureBlob_ConnectionString: "${exec_azure_blob_conn}"
SECRETS_EXEC_AZBLOB
    echo "  ${GREEN}✔ Execution Service Azure Blob secret added${RESET}"
    echo ""
  fi

  # --- Rebrandly secrets ---
  local rebrandly_enabled_k8s
  rebrandly_enabled_k8s=$(read_val "$overrides" "rebrandly.enabled")
  rebrandly_enabled_k8s="${rebrandly_enabled_k8s:-false}"
  if [ "$rebrandly_enabled_k8s" = "true" ] || [ "$rebrandly_enabled_k8s" = "True" ]; then
    echo "  ${BOLD}Rebrandly${RESET}"
    local rb_api_key rb_redis_pass
    read -rsp "    API key: " rb_api_key
    echo ""
    rb_redis_pass=$(gen_password)

    cat >> "$output" << SECRETS_REBRANDLY
  # -- Rebrandly --
  Rebrandly_ApiKey: "${rb_api_key}"
  Rebrandly_RedisPassword: "${rb_redis_pass}"
SECRETS_REBRANDLY
    echo "  ${GREEN}✔ Rebrandly secrets added${RESET}"
    echo ""
  fi

  # --- Twilio Messaging secrets ---
  local tm_enabled_k8s
  tm_enabled_k8s=$(read_val "$overrides" "twiliomessaging.enabled")
  tm_enabled_k8s="${tm_enabled_k8s:-false}"
  if [ "$tm_enabled_k8s" = "true" ] || [ "$tm_enabled_k8s" = "True" ]; then
    echo "  ${BOLD}Twilio Messaging${RESET}"
    local tm_auth_token
    read -rsp "    Twilio auth token: " tm_auth_token
    echo ""
    cat >> "$output" << SECRETS_TWILIO
  # -- Twilio Messaging --
  TwilioMessaging_AuthToken: "${tm_auth_token}"
SECRETS_TWILIO

    # PostgreSQL password only when Twilio uses its own DB (reuseOperational=false).
    # This is the kubernetes secret path, so auth is Basic (password-based); reuse-operational
    # uses the operational DB password already collected above.
    local tm_pg_reuse
    tm_pg_reuse=$(read_val "$overrides" "twiliomessaging.postgres.reuseOperational")
    tm_pg_reuse="${tm_pg_reuse:-true}"
    if [ "$tm_pg_reuse" = "false" ] || [ "$tm_pg_reuse" = "False" ]; then
      local tm_pg_pass
      read -rsp "    PostgreSQL password (twilio_messaging): " tm_pg_pass
      echo ""
      cat >> "$output" << SECRETS_TWILIO_PG
  TwilioMessaging_Postgres_Password: "${tm_pg_pass}"
SECRETS_TWILIO_PG
    fi

    # External Redis access key only for a BYO Redis (this is the kubernetes secret path, so
    # auth is the access key/password; sdk uses managed identity - no key). The internal
    # chart-managed Redis password is generated into rpi-internal-services.
    local tm_redis_type
    tm_redis_type=$(read_val "$overrides" "twiliomessaging.redisSettings.type")
    tm_redis_type="${tm_redis_type:-internal}"
    if [ "$tm_redis_type" = "external" ]; then
      local tm_redis_pass
      read -rsp "    External Redis access key / password: " tm_redis_pass
      echo ""
      cat >> "$output" << SECRETS_TWILIO_REDIS
  TwilioMessaging_Redis_Password: "${tm_redis_pass}"
SECRETS_TWILIO_REDIS
    fi
    echo "  ${GREEN}✔ Twilio Messaging secrets added${RESET}"
    echo ""
  fi

  # --- SMTP Password ---
  local smtp_use_creds
  smtp_use_creds=$(read_val "$overrides" "SMTPSettings.UseCredentials")
  smtp_use_creds="${smtp_use_creds:-true}"
  if [ "$smtp_use_creds" = "true" ] || [ "$smtp_use_creds" = "True" ]; then
    echo "  ${BOLD}SMTP${RESET}"
    local smtp_password
    read -rsp "    SMTP password [skip]: " smtp_password
    echo ""
    if [ -n "$smtp_password" ]; then
      cat >> "$output" << SECRETS_SMTP
  # -- SMTP --
  SMTP_Password: "${smtp_password}"
SECRETS_SMTP
      echo "  ${GREEN}✔ SMTP password added${RESET}"
    else
      echo "  ${YELLOW}Skipped. Add SMTP_Password to the secret manually if SMTP authentication is needed.${RESET}"
    fi
    echo ""
  fi

  # --- Custom CA certificate ---
  local ca_enabled ca_name ca_cert_file
  ca_enabled=$(read_val "$overrides" "customCACerts.enabled")
  ca_enabled="${ca_enabled:-false}"
  if [ "$ca_enabled" = "true" ] || [ "$ca_enabled" = "True" ]; then
    ca_name=$(read_val "$overrides" "customCACerts.name")
    ca_name="${ca_name:-custom-ca-cert}"
    ca_cert_file=$(read_val "$overrides" "customCACerts.certFile")
    ca_cert_file="${ca_cert_file:-ca-bundle.pem}"
    # Only prompt if not using CSI inline mount
    local ca_spc
    ca_spc=$(read_val "$overrides" "customCACerts.secretProviderClassName")
    if [ -z "$ca_spc" ]; then
      echo "  ${BOLD}Custom CA certificate (Secret: ${ca_name})${RESET}"
      local ca_file_path
      read -rp "    Path to CA bundle file (e.g., combined.pem) [skip]: " ca_file_path
      if [ -n "$ca_file_path" ] && [ -f "$ca_file_path" ]; then
        local ca_b64
        ca_b64=$(base64 -w0 < "$ca_file_path" 2>/dev/null || base64 < "$ca_file_path")
        cat >> "$output" << SECRETS_CA
---
apiVersion: v1
kind: Secret
metadata:
  name: ${ca_name}
  namespace: ${namespace}
type: Opaque
data:
  ${ca_cert_file}: ${ca_b64}
SECRETS_CA
        echo "  ${GREEN}✔ CA certificate secret added${RESET}"
      else
        echo "  ${YELLOW}Skipped. Create the secret manually: kubectl create secret generic ${ca_name} --from-file=${ca_cert_file} -n ${namespace}${RESET}"
      fi
      echo ""
    fi
  fi

  fi  # end kubernetes provider check

  # --- Image pull secret ---
  local img_pull_enabled img_pull_name
  img_pull_enabled=$(read_val "$overrides" "global.deployment.images.imagePullSecret.enabled")
  img_pull_name=$(read_val "$overrides" "global.deployment.images.imagePullSecret.name")
  img_pull_name="${img_pull_name:-redpoint-rpi}"

  if [ "$img_pull_enabled" = "true" ] || [ "$img_pull_enabled" = "True" ]; then
    echo "  ${BOLD}Image pull secret (${img_pull_name})${RESET}"
    local registry_server registry_user registry_pass registry_email
    read -rp "    Registry server [rg1acrpub.azurecr.io]: " registry_server
    registry_server="${registry_server:-rg1acrpub.azurecr.io}"
    read -rp "    Registry username: " registry_user
    read -rsp "    Registry password: " registry_pass
    echo ""
    read -rp "    Registry email [noreply@example.com]: " registry_email
    registry_email="${registry_email:-noreply@example.com}"
    echo ""

    # Generate dockerconfigjson
    local docker_auth
    docker_auth=$(echo -n "${registry_user}:${registry_pass}" | base64)
    local docker_config="{\"auths\":{\"${registry_server}\":{\"username\":\"${registry_user}\",\"password\":\"${registry_pass}\",\"email\":\"${registry_email}\",\"auth\":\"${docker_auth}\"}}}"
    local docker_config_b64
    docker_config_b64=$(echo -n "$docker_config" | base64 -w0 2>/dev/null || echo -n "$docker_config" | base64)

    cat >> "$output" << SECRETS_IMGPULL
---
apiVersion: v1
kind: Secret
metadata:
  name: ${img_pull_name}
  namespace: ${namespace}
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: ${docker_config_b64}
SECRETS_IMGPULL
    echo "  ${GREEN}✔ Image pull secret added${RESET}"
    echo ""
  fi

  # --- TLS secret ---
  local tls_secret_name
  tls_secret_name=$(read_val "$overrides" "ingress.tls.0.secretName")
  if [ -n "$tls_secret_name" ] && [ "$tls_secret_name" != "None" ]; then
    echo "  ${BOLD}TLS certificate (${tls_secret_name})${RESET}"
    local tls_cert_path tls_key_path
    read -rp "    TLS certificate file path (.crt or .pem) [skip]: " tls_cert_path
    read -rp "    TLS private key file path (.key) [skip]: " tls_key_path
    echo ""

    if [ -n "$tls_cert_path" ] && [ -n "$tls_key_path" ] && [ -f "$tls_cert_path" ] && [ -f "$tls_key_path" ]; then
      local tls_cert_b64 tls_key_b64
      tls_cert_b64=$(base64 -w0 < "$tls_cert_path" 2>/dev/null || base64 < "$tls_cert_path")
      tls_key_b64=$(base64 -w0 < "$tls_key_path" 2>/dev/null || base64 < "$tls_key_path")

      cat >> "$output" << SECRETS_TLS
---
apiVersion: v1
kind: Secret
metadata:
  name: ${tls_secret_name}
  namespace: ${namespace}
type: kubernetes.io/tls
data:
  tls.crt: ${tls_cert_b64}
  tls.key: ${tls_key_b64}
SECRETS_TLS
      echo "  ${GREEN}✔ TLS secret added${RESET}"
    else
      echo "  ${YELLOW}Skipped TLS. Provide valid cert and key file paths, or create the secret manually.${RESET}"
    fi
    echo ""
  fi

  # --- Snowflake Secrets (one per tenant key) ---
  local sf_enabled sf_spc
  sf_enabled=$(read_val "$overrides" "databases.datawarehouse.snowflake.enabled")
  sf_spc=$(read_val "$overrides" "databases.datawarehouse.snowflake.secretProviderClassName")

  if { [ "$sf_enabled" = "true" ] || [ "$sf_enabled" = "True" ]; } && [ -z "$sf_spc" ]; then
    # Read key entries (keyName + secretName) from overrides
    local sf_keys_json
    sf_keys_json=$(python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sf = (d.get('databases') or {}).get('datawarehouse', {}).get('snowflake', {})
for k in sf.get('keys', []):
    print(k.get('keyName', 'my-snowflake-rsakey.p8') + '|' + k.get('secretName', 'snowflake-rsa-private-key'))
" "$overrides" 2>/dev/null)

    echo "  ${BOLD}Snowflake RSA keys${RESET}"
    echo "  ${DIM}Each tenant key is stored in its own K8s Secret.${RESET}"

    while IFS='|' read -r sf_keyname sf_secretname <&3; do
      [ -z "$sf_keyname" ] && continue
      echo ""
      echo "  ${BOLD}${sf_keyname}${RESET} (Secret: ${sf_secretname})"
      local sf_key_path
      read -rp "    Path to ${sf_keyname} [skip]: " sf_key_path </dev/tty

      if [ -n "$sf_key_path" ] && [ -f "$sf_key_path" ]; then
        local sf_key_b64
        sf_key_b64=$(base64 -w0 < "$sf_key_path" 2>/dev/null || base64 < "$sf_key_path")
        cat >> "$output" << SECRETS_SF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${sf_secretname}
  namespace: ${namespace}
type: Opaque
data:
  ${sf_keyname}: ${sf_key_b64}
SECRETS_SF
        echo "    ${GREEN}✔ ${sf_keyname} added${RESET}"
      else
        echo "    ${YELLOW}Skipped. Create manually: kubectl create secret generic ${sf_secretname} --from-file=${sf_keyname} -n ${namespace}${RESET}"
      fi
    done 3<<< "$sf_keys_json"
    echo ""
  fi

  # --- BigQuery ConfigMap ---
  local bq_enabled bq_configmap bq_keyname
  bq_enabled=$(read_val "$overrides" "databases.datawarehouse.bigquery.enabled")
  if [ "$bq_enabled" = "true" ] || [ "$bq_enabled" = "True" ]; then
    bq_configmap=$(read_val "$overrides" "databases.datawarehouse.bigquery.connections.0.configMapName")
    bq_keyname=$(read_val "$overrides" "databases.datawarehouse.bigquery.connections.0.keyName")
    bq_configmap="${bq_configmap:-bigquery-creds}"
    bq_keyname="${bq_keyname:-service-account.json}"
    echo "  ${BOLD}BigQuery service account (ConfigMap: ${bq_configmap})${RESET}"
    local bq_key_path
    read -rp "    Path to service account JSON file (${bq_keyname}) [skip]: " bq_key_path
    echo ""

    if [ -n "$bq_key_path" ] && [ -f "$bq_key_path" ]; then
      local bq_key_content
      bq_key_content=$(cat "$bq_key_path")
      cat >> "$output" << SECRETS_BQ
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${bq_configmap}
  namespace: ${namespace}
data:
  ${bq_keyname}: |
$(echo "$bq_key_content" | sed 's/^/    /')
SECRETS_BQ
      echo "  ${GREEN}✔ BigQuery ConfigMap added${RESET}"
    else
      echo "  ${YELLOW}Skipped BigQuery. Provide the JSON key file path, or create the ConfigMap manually.${RESET}"
    fi
    echo ""
  fi

  echo "  ${GREEN}✔ All resources written to: ${output}${RESET}"
  echo ""
  echo "  Apply with:"
  echo "    ${DIM}kubectl apply -f ${output} -n ${namespace}${RESET}"
  echo ""
}

# ============================================================
# Deploy command: pre-flight checks + helm install/upgrade
# ============================================================
cli_deploy() {
  local overrides="$1" namespace="$2" chart="$3" dry_run="$4" release="${5:-rpi}"

  if [ -z "$overrides" ]; then
    echo "${RED}Error: -f <overrides-file> is required.${RESET}" >&2
    echo "Usage: rpihelmcli/setup.sh deploy -f overrides.yaml [-n namespace] [-c chart-path] [-r release-name] [--dry-run]" >&2
    exit 1
  fi
  if [ ! -f "$overrides" ]; then
    echo "${RED}Error: File not found: ${overrides}${RESET}" >&2; exit 1
  fi

  echo ""
  echo "${CYAN}${BOLD}Interaction CLI — Deploy${RESET}"
  echo ""

  # Pre-flight checks
  echo "  ${BOLD}Pre-flight checks${RESET}"

  if ! command -v kubectl &>/dev/null; then
    echo "  ${RED}✘ kubectl not found. Install kubectl first.${RESET}"; exit 1
  fi
  echo "  ${GREEN}✔${RESET} kubectl found"

  if ! command -v helm &>/dev/null; then
    echo "  ${RED}✘ helm not found. Install Helm first.${RESET}"; exit 1
  fi
  echo "  ${GREEN}✔${RESET} helm found"

  if ! kubectl cluster-info &>/dev/null 2>&1; then
    echo "  ${RED}✘ Cannot reach Kubernetes cluster. Check your kubeconfig.${RESET}"; exit 1
  fi
  echo "  ${GREEN}✔${RESET} Cluster reachable"

  if [ ! -d "$chart" ]; then
    local _clone_dir="$(pwd)/redpoint-rpi"
    # Reuse existing clone if present
    if [ -d "${_clone_dir}/chart" ]; then
      chart="${_clone_dir}/chart"
      echo "  ${GREEN}✔${RESET} Chart found at ${chart} (existing clone)"
    else
      echo "  ${YELLOW}Chart not found at: ${chart}${RESET}"
      echo ""
      echo "  The Helm chart is required to deploy RPI."
      echo "  The CLI can clone it for you from GitHub."
      echo ""
      local _clone_confirm
      read -rp "  Clone the chart repository to ${_clone_dir}? [Y/n] " _clone_confirm
      _clone_confirm="${_clone_confirm:-Y}"
      if [[ "$_clone_confirm" =~ ^[Yy] ]]; then
        if ! command -v git &>/dev/null; then
          echo "  ${RED}✘ git not found. Install git first, or clone manually.${RESET}"; exit 1
        fi
        local _chart_branch
        prompt _chart_branch "Chart branch" "main"
        echo "  Cloning repository (branch: ${_chart_branch})..."
        git clone --depth 1 --branch "$_chart_branch" \
          https://github.com/RedPointGlobal/redpoint-rpi.git "$_clone_dir" 2>&1 | \
          sed 's/^/  /'
        chart="${_clone_dir}/chart"
        if [ ! -d "$chart" ]; then
          echo "  ${RED}✘ Clone succeeded but chart/ directory not found.${RESET}"; exit 1
        fi
        echo "  ${GREEN}✔${RESET} Chart cloned to ${chart}"
      else
        echo "  ${DIM}Provide the chart path with -c, or clone manually:${RESET}"
        echo "    git clone https://github.com/RedPointGlobal/redpoint-rpi.git"
        exit 1
      fi
    fi
  else
    echo "  ${GREEN}✔${RESET} Chart found at ${chart}"
  fi
  echo ""

  # Create namespace if needed
  if ! kubectl get namespace "$namespace" &>/dev/null 2>&1; then
    echo "  Creating namespace: ${namespace}"
    kubectl create namespace "$namespace"
    echo "  ${GREEN}✔${RESET} Namespace created"
  else
    echo "  ${GREEN}✔${RESET} Namespace exists: ${namespace}"
  fi

  if [ "$dry_run" != "true" ]; then
    # Apply secrets if secrets.yaml exists alongside overrides
    local overrides_dir
    overrides_dir="$(dirname "$overrides")"
    local secrets_file="${overrides_dir}/secrets.yaml"
    if [ -f "$secrets_file" ]; then
      echo "  Applying secrets from: ${secrets_file}"
      kubectl apply -f "$secrets_file" -n "$namespace"
      echo "  ${GREEN}✔${RESET} Secrets applied"
    fi

    # Check image pull secret
    if python3 -c "import yaml" 2>/dev/null; then
      local pull_secret_enabled
      pull_secret_enabled=$(read_val "$overrides" "global.deployment.images.imagePullSecret.enabled")
      if [ "$pull_secret_enabled" = "true" ] || [ "$pull_secret_enabled" = "True" ]; then
        local pull_secret_name
        pull_secret_name=$(read_val "$overrides" "global.deployment.images.imagePullSecret.name")
        pull_secret_name="${pull_secret_name:-rpi-docker-registry}"
        if ! kubectl get secret "$pull_secret_name" -n "$namespace" &>/dev/null 2>&1; then
          echo ""
          echo "  ${YELLOW}Image pull secret '${pull_secret_name}' not found in namespace.${RESET}"
          echo "  ${BOLD}Registry credentials${RESET}"
          local reg_server reg_user reg_pass
          read -rp "    Registry server: " reg_server
          read -rp "    Username: " reg_user
          read -rsp "    Password: " reg_pass
          echo ""
          kubectl create secret docker-registry "$pull_secret_name" \
            --namespace "$namespace" \
            --docker-server="$reg_server" \
            --docker-username="$reg_user" \
            --docker-password="$reg_pass"
          echo "  ${GREEN}✔${RESET} Image pull secret created"
        else
          echo "  ${GREEN}✔${RESET} Image pull secret exists"
        fi
      fi
    fi

    # --- Pre-deploy secret validation ---
    # Check that required secrets exist before running helm install
    echo ""
    echo "  ${BOLD}Pre-deploy secret checks${RESET}"
    local _missing_secrets=false

    # 1. Application secret (kubernetes provider)
    local _sec_provider
    _sec_provider=$(read_val "$overrides" "secretsManagement.provider")
    _sec_provider="${_sec_provider:-kubernetes}"
    if [ "$_sec_provider" = "kubernetes" ]; then
      local _app_secret_name
      _app_secret_name=$(read_val "$overrides" "secretsManagement.kubernetes.secretName")
      _app_secret_name="${_app_secret_name:-redpoint-rpi-secrets}"
      if ! kubectl get secret "$_app_secret_name" -n "$namespace" &>/dev/null 2>&1; then
        echo "  ${RED}✘ Application secret '${_app_secret_name}' not found${RESET}"
        _missing_secrets=true
      else
        echo "  ${GREEN}✔${RESET} Application secret: ${_app_secret_name}"
      fi
    fi

    # 2. Snowflake key secrets
    local _sf_enabled
    _sf_enabled=$(read_val "$overrides" "databases.datawarehouse.snowflake.enabled")
    local _sf_spc
    _sf_spc=$(read_val "$overrides" "databases.datawarehouse.snowflake.secretProviderClassName")
    if { [ "$_sf_enabled" = "true" ] || [ "$_sf_enabled" = "True" ]; } && [ -z "$_sf_spc" ]; then
      local _sf_secrets
      _sf_secrets=$(python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
sf = (d.get('databases') or {}).get('datawarehouse', {}).get('snowflake', {})
for k in sf.get('keys', []):
    print(k.get('secretName', 'snowflake-rsa-private-key'))
" "$overrides" 2>/dev/null)
      while IFS= read -r _sf_sec; do
        [ -z "$_sf_sec" ] && continue
        if ! kubectl get secret "$_sf_sec" -n "$namespace" &>/dev/null 2>&1; then
          echo "  ${RED}✘ Snowflake secret '${_sf_sec}' not found${RESET}"
          _missing_secrets=true
        else
          echo "  ${GREEN}✔${RESET} Snowflake secret: ${_sf_sec}"
        fi
      done <<< "$_sf_secrets"
    fi

    # 3. Custom CA cert secret
    local _ca_enabled
    _ca_enabled=$(read_val "$overrides" "customCACerts.enabled")
    local _ca_spc
    _ca_spc=$(read_val "$overrides" "customCACerts.secretProviderClassName")
    if { [ "$_ca_enabled" = "true" ] || [ "$_ca_enabled" = "True" ]; } && [ -z "$_ca_spc" ]; then
      local _ca_secret
      _ca_secret=$(read_val "$overrides" "customCACerts.name")
      _ca_secret="${_ca_secret:-custom-ca-cert}"
      if ! kubectl get secret "$_ca_secret" -n "$namespace" &>/dev/null 2>&1; then
        echo "  ${RED}✘ CA certificate secret '${_ca_secret}' not found${RESET}"
        _missing_secrets=true
      else
        echo "  ${GREEN}✔${RESET} CA certificate secret: ${_ca_secret}"
      fi
    fi

    if [ "$_missing_secrets" = "true" ]; then
      echo ""
      echo "  ${YELLOW}Required secrets are missing. Pods will fail to start without them.${RESET}"
      echo "  ${DIM}Generate secrets: rpihelmcli/setup.sh secrets -f $(basename "$overrides") -n ${namespace}${RESET}"
      echo "  ${DIM}Then apply:       kubectl apply -f secrets.yaml -n ${namespace}${RESET}"
      echo ""
      local _continue_anyway
      read -rp "  Continue deploying anyway? [y/N] " _continue_anyway
      if [[ ! "$_continue_anyway" =~ ^[Yy] ]]; then
        echo "  ${DIM}Deploy cancelled.${RESET}"
        exit 0
      fi
    else
      echo "  ${GREEN}✔${RESET} All required secrets found"
    fi
  fi

  echo ""

  # Dry-run mode: render templates
  if [ "$dry_run" = "true" ]; then
    echo "  ${CYAN}${BOLD}Dry run: rendering templates${RESET}"
    echo ""
    helm template "$release" "$chart" -f "$overrides" -n "$namespace"
    exit 0
  fi

  # Helm install/upgrade
  local helm_mode
  if helm status "$release" -n "$namespace" &>/dev/null; then
    helm_mode="upgrade"
  else
    helm_mode="install"
  fi

  echo "  ${CYAN}${BOLD}Running helm ${helm_mode}...${RESET}"
  echo ""

  # Submit manifests without waiting
  if ! helm "${helm_mode}" "$release" "$chart" \
    -f "$overrides" \
    -n "$namespace" \
    --create-namespace \
    --timeout 10m; then
    echo ""
    echo "  ${RED}✘${RESET} Helm ${helm_mode} failed"
    exit 1
  fi
  echo ""
  echo "  ${GREEN}✔${RESET} Helm ${helm_mode} submitted"
  echo ""

  # Poll pod status until all ready or timeout
  echo "  ${CYAN}${BOLD}Waiting for pods to be ready...${RESET}"
  echo ""
  local timeout=600
  local elapsed=0
  local all_ready=false

  while [ "$elapsed" -lt "$timeout" ]; do
    local total=0 ready_count=0
    local status_lines=""

    status_lines=$(kubectl get pods -n "$namespace" -l app.kubernetes.io/part-of=rpi --no-headers 2>/dev/null || true)

    if [ -n "$status_lines" ]; then
      echo "  $(date +%H:%M:%S) Pod status:"
      echo "$status_lines" | while IFS= read -r line; do
        local pod_name ready status
        pod_name=$(echo "$line" | awk '{print $1}')
        ready=$(echo "$line" | awk '{print $2}')
        status=$(echo "$line" | awk '{print $3}')
        if [ "$status" = "Running" ] && [[ "$ready" != *"0/"* ]]; then
          echo "    ${GREEN}✔${RESET} ${pod_name}  ${ready}  ${status}"
        elif [ "$status" = "Running" ]; then
          echo "    ${YELLOW}●${RESET} ${pod_name}  ${ready}  ${status}"
        elif [ "$status" = "CrashLoopBackOff" ] || [ "$status" = "Error" ]; then
          echo "    ${RED}✘${RESET} ${pod_name}  ${ready}  ${status}"
          # Show reason from events
          local reason
          reason=$(kubectl get events -n "$namespace" --field-selector "involvedObject.name=${pod_name}" --sort-by='.lastTimestamp' 2>/dev/null | grep -i "warning\|error\|failed" | tail -1 | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/^ *//;s/ *$//')
          [ -n "$reason" ] && echo "      ${DIM}${reason}${RESET}"
        else
          echo "    ${CYAN}◌${RESET} ${pod_name}  ${ready}  ${status}"
          # Show reason for non-running pods
          if [ "$status" = "Pending" ] || [ "$status" = "ContainerCreating" ] || [[ "$status" == *"Init"* ]] || [ "$status" = "ImagePullBackOff" ] || [ "$status" = "ErrImagePull" ]; then
            local reason
            reason=$(kubectl get events -n "$namespace" --field-selector "involvedObject.name=${pod_name}" --sort-by='.lastTimestamp' 2>/dev/null | grep -i "warning\|error\|failed" | tail -1 | awk '{for(i=6;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/^ *//;s/ *$//')
            [ -n "$reason" ] && echo "      ${DIM}${reason}${RESET}"
          fi
        fi
      done
      echo ""

      # Check if all pods are ready
      total=$(echo "$status_lines" | wc -l | tr -d ' ')
      ready_count=$(echo "$status_lines" | awk '$3 == "Running" && $2 !~ /^0\// {c++} END {print c+0}')
      if [ "$total" -gt 0 ] && [ "$ready_count" -eq "$total" ]; then
        all_ready=true
        break
      fi
    fi

    sleep 10
    elapsed=$((elapsed + 10))
  done

  if [ "$all_ready" = true ]; then
    echo "  ${GREEN}✔${RESET} All pods ready"
  else
    echo "  ${YELLOW}●${RESET} Timeout waiting for pods. Some pods may still be starting."
    echo "  ${DIM}Run 'rpihelmcli/setup.sh status -n ${namespace}' to check.${RESET}"
  fi
}

# --- Pre-flight check command ---
cli_check() {
  local overrides="${1:-}"
  local errors=0

  echo ""
  echo "${CYAN}${BOLD}RPI Helm CLI — Pre-flight Check${RESET}"
  echo ""

  # 1. Required tools
  echo "  ${BOLD}Required tools${RESET}"
  for tool in bash kubectl helm python3 git; do
    if command -v "$tool" &>/dev/null; then
      local ver
      case "$tool" in
        kubectl) ver=$(kubectl version --client -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['clientVersion']['gitVersion'])" 2>/dev/null || echo "unknown") ;;
        helm) ver=$(helm version --short 2>/dev/null || echo "unknown") ;;
        python3) ver=$(python3 --version 2>/dev/null | cut -d' ' -f2) ;;
        git) ver=$(git --version 2>/dev/null | cut -d' ' -f3) ;;
        *) ver="" ;;
      esac
      echo "  ${GREEN}✔${RESET} ${tool} ${DIM}(${ver})${RESET}"
    else
      echo "  ${RED}✘${RESET} ${tool} not found"
      errors=$((errors + 1))
    fi
  done

  # 2. Python PyYAML
  if command -v python3 &>/dev/null; then
    if python3 -c "import yaml" 2>/dev/null; then
      echo "  ${GREEN}✔${RESET} PyYAML installed"
    else
      echo "  ${RED}✘${RESET} PyYAML not installed (run: pip3 install pyyaml)"
      errors=$((errors + 1))
    fi
  fi
  echo ""

  # 3. Cluster connectivity
  echo "  ${BOLD}Cluster connectivity${RESET}"
  if kubectl cluster-info &>/dev/null 2>&1; then
    local ctx
    ctx=$(kubectl config current-context 2>/dev/null || echo "unknown")
    echo "  ${GREEN}✔${RESET} Cluster reachable ${DIM}(context: ${ctx})${RESET}"
  else
    echo "  ${RED}✘${RESET} Cannot reach Kubernetes cluster. Check your kubeconfig."
    errors=$((errors + 1))
  fi
  echo ""

  # 4. Overrides file
  echo "  ${BOLD}Overrides file${RESET}"
  if [ -n "$overrides" ] && [ -f "$overrides" ]; then
    local lines
    lines=$(wc -l < "$overrides")
    echo "  ${GREEN}✔${RESET} ${overrides} ${DIM}(${lines} lines)${RESET}"

    # Validate YAML syntax (requires PyYAML)
    if python3 -c "import yaml" 2>/dev/null; then
      if python3 -c "import yaml; yaml.safe_load(open('${overrides}'))" 2>/dev/null; then
        echo "  ${GREEN}✔${RESET} Valid YAML syntax"
      else
        echo "  ${RED}✘${RESET} Invalid YAML syntax"
        errors=$((errors + 1))
      fi
    else
      echo "  ${YELLOW}●${RESET} YAML validation skipped (PyYAML not installed)"
    fi

    # Check for required top-level keys (requires PyYAML)
    local platform
    platform=$(python3 -c "import yaml; d=yaml.safe_load(open('${overrides}')); print(d.get('global',{}).get('deployment',{}).get('platform',''))" 2>/dev/null)
    if [ -n "$platform" ]; then
      echo "  ${GREEN}✔${RESET} Platform: ${platform}"
    else
      echo "  ${YELLOW}●${RESET} No platform set (will default to azure)"
    fi

    local secrets_provider
    secrets_provider=$(python3 -c "import yaml; d=yaml.safe_load(open('${overrides}')); print(d.get('secretsManagement',{}).get('provider',''))" 2>/dev/null)
    if [ -n "$secrets_provider" ]; then
      echo "  ${GREEN}✔${RESET} Secrets provider: ${secrets_provider}"
    else
      echo "  ${YELLOW}●${RESET} No secrets provider set (will default to kubernetes)"
    fi
  elif [ -n "$overrides" ]; then
    echo "  ${RED}✘${RESET} File not found: ${overrides}"
    errors=$((errors + 1))
  else
    echo "  ${YELLOW}●${RESET} No overrides file specified (use -f)"
  fi

  echo ""
  if [ "$errors" -eq 0 ]; then
    echo "  ${GREEN}${BOLD}All checks passed.${RESET} Ready to deploy."
    echo ""
    echo "  Next steps:"
    echo "    rpihelmcli/setup.sh deploy -f overrides.yaml --dry-run  # Preview"
    echo "    rpihelmcli/setup.sh deploy -f overrides.yaml            # Deploy"
  else
    echo "  ${RED}${BOLD}${errors} check(s) failed.${RESET} Fix the issues above before deploying."
  fi
  echo ""
}

# --- Handle CLI commands ---
if [ "${CLI_COMMAND:-}" = "check" ]; then
  cli_check "$CLI_OVERRIDES"
  exit 0
elif [ "${CLI_COMMAND:-}" = "status" ]; then
  cli_status "$CLI_NAMESPACE"
  exit 0
elif [ "${CLI_COMMAND:-}" = "troubleshoot" ]; then
  cli_troubleshoot "$CLI_NAMESPACE" "$CLI_SYMPTOM"
  exit 0
elif [ "${CLI_COMMAND:-}" = "secrets" ]; then
  cli_secrets "$CLI_OVERRIDES" "$CLI_SECRETS_OUT" "$CLI_NAMESPACE"
  exit 0
elif [ "${CLI_COMMAND:-}" = "deploy" ]; then
  cli_deploy "$CLI_OVERRIDES" "$CLI_NAMESPACE" "$CLI_CHART" "$CLI_DRY_RUN" "$CLI_RELEASE"
  exit 0
fi

run_add_feature() {
  local file=$1 feature=$2
  case "$feature" in
    database_upgrade) add_database_upgrade "$file" ;;
    queue_reader)     add_queue_reader "$file" ;;
    autoscaling)      add_autoscaling "$file" ;;
    custom_metrics)   add_custom_metrics "$file" ;;
    service_mesh)     add_service_mesh "$file" ;;
    validation_pods)      add_validation_pods "$file" ;;
    entra_id)         add_entra_id "$file" ;;
    oidc)             add_oidc "$file" ;;
    smtp)             add_smtp "$file" ;;
    redpoint_ai)      add_redpoint_ai "$file" ;;
    storage)          add_storage "$file" ;;
    data_warehouse)   add_data_warehouse "$file" ;;
    extra_envs)         add_extra_envs "$file" ;;
    secrets_management) add_secrets_management "$file" ;;
    node_scheduling)    add_node_scheduling "$file" ;;
    common_annotations) add_common_annotations "$file" ;;
    custom_ca_certs)    add_custom_ca_certs "$file" ;;
    image_overrides)    add_image_overrides "$file" ;;
    pod_anti_affinity)  add_pod_anti_affinity "$file" ;;
    node_provisioning)  add_node_provisioning "$file" ;;
    storage_class)      add_storage_class "$file" ;;
    *) echo "  ${RED}Unknown feature: ${feature}${RESET}"; exit 1 ;;
  esac
}

# --- Handle --add mode ---
if [ "$ADD_MODE" = "true" ]; then
  echo ""
  echo "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${RESET}"
  echo "${CYAN}${BOLD}║     ⚡ Redpoint Interaction CLI               ║${RESET}"
  echo "${CYAN}${BOLD}║        Add Feature to Overrides               ║${RESET}"
  echo "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${RESET}"
  echo ""

  if [ ! -f "$OUTPUT_FILE" ]; then
    echo "  ${RED}Error: ${OUTPUT_FILE} not found.${RESET}"
    echo "  Run the CLI without -a first to generate your base overrides."
    exit 1
  fi

  if [ "$ADD_FEATURE" = "menu" ]; then
    show_feature_menu
  fi

  run_add_feature "$OUTPUT_FILE" "$ADD_FEATURE"
  echo ""
  exit 0
fi

# --- Full setup mode ---
echo ""
if [ "$FILE_MODE" = "true" ]; then
  echo "${CYAN}${BOLD}Redpoint Interaction CLI — File Mode${RESET}"
  echo "  Reading from: ${BOLD}${INPUT_FILE}${RESET}"
  echo ""
else
  echo "${CYAN}${BOLD}╔══════════════════════════════════════════════╗${RESET}"
  echo "${CYAN}${BOLD}║     ⚡ Redpoint Interaction CLI               ║${RESET}"
  echo "${CYAN}${BOLD}║        Deployment Generator for RPI           ║${RESET}"
  echo "${CYAN}${BOLD}╚══════════════════════════════════════════════╝${RESET}"
  echo ""
  echo "  This tool generates the files needed to deploy"
  echo "  Redpoint Interaction (RPI) on Kubernetes."
  echo ""
  echo "  ${ICON_FILE} overrides.yaml       — Helm values overrides"
  echo "  ${ICON_KEY} secrets.yaml         — Kubernetes Secret manifest"
  echo "  ${ICON_ROCKET} prereqs.sh           — Prerequisite kubectl commands"
  echo ""
fi

# ============================================================
# 1. Platform & Mode
# ============================================================
section "Platform & Deployment Mode"
prompt_choice PLATFORM "Cloud platform" "azure|amazon|google|selfhosted" "azure"
prompt_choice MODE "Deployment mode" "standard|advanced|demo" "standard"
prompt TAG "Image tag" "$DEFAULT_TAG"
prompt NAMESPACE "Kubernetes namespace" "$DEFAULT_NAMESPACE"

# ============================================================
# 2. Ingress
# ============================================================
section "Ingress"
prompt DOMAIN "Ingress domain (e.g., redpointcdp.com)" "example.com"
prompt HOST_PREFIX "Hostname prefix (e.g., 'rpi' produces rpi-deploymentapi.${DOMAIN})" "rpi"
prompt_yesno DEPLOY_CONTROLLER "Deploy chart-provided ingress controller?" "y"

INGRESS_MODE="public"
INGRESS_SUBNET=""
if [ "$DEPLOY_CONTROLLER" = "true" ]; then
  prompt_choice INGRESS_MODE "Ingress mode" "public|private" "public"
  if [ "$INGRESS_MODE" = "private" ] && [ "$PLATFORM" = "azure" ]; then
    prompt INGRESS_SUBNET "Azure subnet name for internal load balancer" ""
  fi
fi

# ============================================================
# 3. Database
# ============================================================
DB_HOST=""
DB_USER=""
DB_PASS=""
DB_PULSE="Pulse"
DB_LOGGING="Pulse_Logging"
DB_PROVIDER="sqlserver"

if [ "$MODE" = "standard" ]; then
  section "Operational Database"
  prompt_choice DB_PROVIDER "Database provider" "sqlserver|postgresql|sqlserveronvm" "sqlserver"
  prompt DB_HOST "Database server host" ""
  prompt DB_USER "Database username" ""
  if [ "$FILE_MODE" = "true" ]; then
    DB_PASS="${_CFG[DB_PASS]:-}"
  else
    read -rsp "  Database password: " DB_PASS; echo ""
  fi
  prompt DB_PULSE "Pulse database name" "Pulse"
  prompt DB_LOGGING "Pulse logging database name" "Pulse_Logging"
fi

# ============================================================
# 3b. Data Warehouse (optional, after operational DB)
# ============================================================
DW_ENABLED=false
DW_PROVIDER=""
DW_BLOCK=""
if [ "$MODE" = "standard" ]; then
  section "Data Warehouse"
  echo "  ${DIM}Connect RPI to an external data warehouse for audience output and analytics.${RESET}"
  prompt_yesno DW_ENABLED "Configure a data warehouse (Snowflake, BigQuery)?" "n"

  if [ "$DW_ENABLED" = "true" ]; then
    echo ""
    prompt_choice DW_PROVIDER "Data warehouse provider" "snowflake|bigquery" "snowflake"

    case "$DW_PROVIDER" in
      snowflake)
        echo ""
        echo "  ${BOLD}Snowflake${RESET}"
        echo "  ${DIM}Uses JWT authentication. Create a ConfigMap with your RSA private key before deploying.${RESET}"
        local_sf_configmap="" local_sf_keyname=""
        prompt local_sf_configmap "ConfigMap name (containing RSA key)" "snowflake-creds"
        prompt local_sf_keyname "Key file name in ConfigMap" "my-snowflake-rsakey.p8"
        DW_BLOCK="  datawarehouse:
    snowflake:
      enabled: true
      credentialsType: snowflake_jwt
      ConfigMapName: ${local_sf_configmap}
      keyName: ${local_sf_keyname}
      ConfigMapFilePath: /app/snowflake-creds"
        ;;
      bigquery)
        echo ""
        echo "  ${BOLD}Google BigQuery${RESET}"
        echo "  ${DIM}Uses service account authentication. Create a ConfigMap with your service account JSON key.${RESET}"
        local_bq_name="" local_bq_configmap="" local_bq_sa="" local_bq_project=""
        prompt local_bq_name "Connection name (also used as DSN)" "gbq-tenant1"
        prompt local_bq_configmap "ConfigMap name (containing SA key JSON)" "gbq-tenant1"
        prompt local_bq_sa "Service account email" ""
        prompt local_bq_project "Google Cloud project ID" ""
        DW_BLOCK="  datawarehouse:
    bigquery:
      enabled: true
      connections:
        - name: ${local_bq_name}
          projectId: ${local_bq_project}
          sqlDialect: 1
          OAuthMechanism: 0
          credentialsType: serviceAccount
          serviceAccountEmail: ${local_bq_sa}
          configMapName: ${local_bq_configmap}
          keyName: ${local_bq_name}.json
          ConfigMapFilePath: /app/google-creds
          allowLargeResults: 0
          largeResultsDataSetId: _bqodbc_temp_tables
          largeResultsTempTableExpirationTime: \"3600000\""
        ;;
    esac
    echo ""
    echo "  ${ICON_CHECK} Data warehouse configured (${DW_PROVIDER})"
  fi
fi

# ============================================================
# 4. Cloud Identity (skip for selfhosted)
# ============================================================
CLOUD_IDENTITY_ENABLED=false
SA_MODE="per-service"
AZURE_CLIENT_ID=""
AZURE_TENANT_ID=""
AMAZON_ROLE_ARN=""
AMAZON_REGION=""
AMAZON_ACCESS_KEY_ID=""
AMAZON_SECRET_ACCESS_KEY=""
GOOGLE_SA_EMAIL=""

if [ "$PLATFORM" != "selfhosted" ]; then
  section "Cloud Identity"
  prompt_yesno CLOUD_IDENTITY_ENABLED "Enable cloud identity (Workload Identity / IRSA)?" "y"

  if [ "$CLOUD_IDENTITY_ENABLED" = "true" ]; then
    case "$PLATFORM" in
      azure)
        prompt AZURE_CLIENT_ID "Azure Managed Identity Client ID" ""
        prompt AZURE_TENANT_ID "Azure Tenant ID" ""
        ;;
      amazon)
        prompt AMAZON_ROLE_ARN "IAM Role ARN for IRSA" ""
        prompt AMAZON_REGION "AWS Region" "us-east-1"
        prompt AMAZON_ACCESS_KEY_ID "AWS Access Key ID (for SQS/S3)" ""
        prompt_secret AMAZON_SECRET_ACCESS_KEY "AWS Secret Access Key"
        ;;
      google)
        prompt GOOGLE_SA_EMAIL "GCP Service Account email" ""
        ;;
    esac

    echo ""
    echo "  ${DIM}ServiceAccount mode controls how Kubernetes ServiceAccounts are created:${RESET}"
    echo "  ${DIM}  shared      — One ServiceAccount shared by all RPI services${RESET}"
    echo "  ${DIM}  per-service — Each service gets its own ServiceAccount${RESET}"
    echo "  ${DIM}  both        — Shared + per-service ServiceAccounts are created${RESET}"
    prompt SA_MODE "ServiceAccount mode" "per-service"
    while [[ "$SA_MODE" != "shared" && "$SA_MODE" != "per-service" && "$SA_MODE" != "both" ]]; do
      echo "  ${YELLOW}Invalid mode. Choose: shared, per-service, or both${RESET}"
      prompt SA_MODE "ServiceAccount mode" "per-service"
    done
  fi
fi

# ============================================================
# 5. Realtime API
# ============================================================
section "Realtime API"
prompt_yesno REALTIME_ENABLED "Enable Realtime API?" "y"

RT_CACHE_PROVIDER=""
RT_CACHE_CONNSTR=""
RT_CACHE_BIGTABLE_PROJECT=""
RT_CACHE_BIGTABLE_INSTANCE=""
RT_QUEUE_PROVIDER=""
RT_QUEUE_CONNSTR=""
RT_EVENTHUB_NAME=""
RT_EVENTHUB_NAMESPACE=""
RT_PUBSUB_PROJECT=""

if [ "$REALTIME_ENABLED" = "true" ]; then
  echo ""
  echo "  ${DIM}Cache provider stores realtime decision data for low-latency lookups.${RESET}"
  if [ "$PLATFORM" = "azure" ]; then
    prompt_choice RT_CACHE_PROVIDER "Cache provider" "mongodb|azureredis|redis|inMemorySql|googlebigtable" "mongodb"
  elif [ "$PLATFORM" = "amazon" ]; then
    prompt_choice RT_CACHE_PROVIDER "Cache provider" "mongodb|redis|inMemorySql|googlebigtable" "mongodb"
  elif [ "$PLATFORM" = "google" ]; then
    prompt_choice RT_CACHE_PROVIDER "Cache provider" "mongodb|redis|googlebigtable|inMemorySql" "mongodb"
  else
    prompt_choice RT_CACHE_PROVIDER "Cache provider" "mongodb|redis|inMemorySql|googlebigtable" "mongodb"
  fi

  if [ "$RT_CACHE_PROVIDER" = "mongodb" ]; then
    prompt RT_CACHE_CONNSTR "MongoDB connection string" ""
  elif [ "$RT_CACHE_PROVIDER" = "redis" ] || [ "$RT_CACHE_PROVIDER" = "azureredis" ]; then
    prompt RT_CACHE_CONNSTR "Redis connection string" ""
  elif [ "$RT_CACHE_PROVIDER" = "inMemorySql" ]; then
    prompt RT_CACHE_CONNSTR "SQL Server in-memory cache connection string" ""
  elif [ "$RT_CACHE_PROVIDER" = "googlebigtable" ]; then
    prompt RT_CACHE_BIGTABLE_PROJECT "Google Bigtable project ID" ""
    prompt RT_CACHE_BIGTABLE_INSTANCE "Google Bigtable instance ID" ""
  fi

  echo ""
  echo "  ${DIM}Queue provider handles asynchronous messaging between RPI services.${RESET}"
  if [ "$PLATFORM" = "azure" ]; then
    prompt_choice RT_QUEUE_PROVIDER "Queue provider" "azureservicebus|rabbitmq|azureeventhubs" "azureservicebus"
  elif [ "$PLATFORM" = "amazon" ]; then
    prompt_choice RT_QUEUE_PROVIDER "Queue provider" "amazonsqs|rabbitmq" "amazonsqs"
  elif [ "$PLATFORM" = "google" ]; then
    prompt_choice RT_QUEUE_PROVIDER "Queue provider" "googlepubsub|rabbitmq" "googlepubsub"
  else
    prompt_choice RT_QUEUE_PROVIDER "Queue provider" "rabbitmq" "rabbitmq"
  fi

  if [ "$RT_QUEUE_PROVIDER" = "azureservicebus" ]; then
    prompt RT_QUEUE_CONNSTR "Azure Service Bus connection string" ""
  elif [ "$RT_QUEUE_PROVIDER" = "azureeventhubs" ]; then
    prompt RT_QUEUE_CONNSTR "Azure Event Hubs connection string" ""
    prompt RT_EVENTHUB_NAME "Event Hub name" "RPIQueueListener"
    prompt RT_EVENTHUB_NAMESPACE "Event Hubs namespace name" ""
  elif [ "$RT_QUEUE_PROVIDER" = "googlepubsub" ]; then
    prompt RT_PUBSUB_PROJECT "Google Pub/Sub project ID" ""
  fi
fi

# ============================================================
# Generate auto-generated passwords and tokens
# ============================================================
RT_AUTH_TOKEN=""
RT_RABBITMQ_PASSWORD=""
RT_REDIS_CACHE_PASSWORD=""
QS_REDIS_PASSWORD=""
QS_RABBITMQ_PASSWORD=""

QUEUE_PREFIX=""
if [ "$REALTIME_ENABLED" = "true" ]; then
  RT_AUTH_TOKEN=$(gen_uuid)
  RT_RABBITMQ_PASSWORD=$(gen_password)
  RT_REDIS_CACHE_PASSWORD=$(gen_password)
  QS_REDIS_PASSWORD=$(gen_password)
  QS_RABBITMQ_PASSWORD=$(gen_password)
  QUEUE_PREFIX="${HOST_PREFIX}-"
fi

# ============================================================
# Build connection strings for the secret
# ============================================================
OPS_CONN=""
LOG_CONN=""

if [ "$MODE" = "standard" ]; then
  case "$DB_PROVIDER" in
    sqlserver)
      OPS_CONN="Server=tcp:${DB_HOST},1433;Database=${DB_PULSE};User ID=${DB_USER};Password=${DB_PASS};Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
      LOG_CONN="Server=tcp:${DB_HOST},1433;Database=${DB_LOGGING};User ID=${DB_USER};Password=${DB_PASS};Encrypt=True;TrustServerCertificate=True;Connection Timeout=30;"
      ;;
    postgresql)
      OPS_CONN="PostgreSQL:Server=${DB_HOST};Database=${DB_PULSE};User Id=${DB_USER};Password=${DB_PASS};"
      LOG_CONN="PostgreSQL:Server=${DB_HOST};Database=${DB_LOGGING};User Id=${DB_USER};Password=${DB_PASS};"
      ;;
    sqlserveronvm)
      OPS_CONN="Server=${DB_HOST},1433;Database=${DB_PULSE};uid=${DB_USER};pwd=${DB_PASS};ConnectRetryCount=12;ConnectRetryInterval=10;Encrypt=True;TrustServerCertificate=True;"
      LOG_CONN="Server=${DB_HOST},1433;Database=${DB_LOGGING};uid=${DB_USER};pwd=${DB_PASS};ConnectRetryCount=12;ConnectRetryInterval=10;Encrypt=True;TrustServerCertificate=True;"
      ;;
  esac
fi

# ============================================================
# Generate rpi-secrets.yaml
# ============================================================
echo ""
if [ "$FILE_MODE" = "true" ]; then
  echo "${CYAN}${BOLD}Generating files...${RESET}"
else
  printf "${CYAN}${BOLD}Generating files ${RESET}"
  for i in $(seq 1 30); do
    printf "${CYAN}▪${RESET}"
    sleep 1
  done
  echo ""
fi

cat > "$SECRETS_FILE" << SECRETS_HEADER
# ============================================================
# RPI Kubernetes Secret — Generated by Interaction CLI
# $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# ============================================================
# Apply BEFORE helm install:
#   kubectl apply -f ${SECRETS_FILE}
#
# WARNING: This file contains sensitive values.
#          Do NOT commit this file to version control.
# ============================================================
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
  annotations:
    helm.sh/resource-policy: keep
type: Opaque
stringData:
SECRETS_HEADER

if [ "$MODE" = "standard" ]; then
  cat >> "$SECRETS_FILE" << SECRETS_DB
  # -- Operational Database --
  ConnectionString_Operations_Database: "${OPS_CONN}"
  ConnectionString_Logging_Database: "${LOG_CONN}"
  Operations_Database_Server_Password: "${DB_PASS}"
  Operations_Database_ServerHost: "${DB_HOST}"
  Operations_Database_Server_Username: "${DB_USER}"
  Operations_Database_Pulse_Database_Name: "${DB_PULSE}"
  Operations_Database_Pulse_Logging_Database_Name: "${DB_LOGGING}"
SECRETS_DB
fi

if [ "$PLATFORM" = "amazon" ] && [ -n "$AMAZON_ACCESS_KEY_ID" ]; then
  cat >> "$SECRETS_FILE" << SECRETS_AWS
  # -- AWS Access Keys --
  AWS_Access_Key_ID: "${AMAZON_ACCESS_KEY_ID}"
  AWS_Secret_Access_Key: "${AMAZON_SECRET_ACCESS_KEY}"
SECRETS_AWS
fi

if [ "$REALTIME_ENABLED" = "true" ]; then
  cat >> "$SECRETS_FILE" << SECRETS_RT
  # -- Realtime API --
  RealtimeAPI_Auth_Token: "${RT_AUTH_TOKEN}"
SECRETS_RT

  # Cache provider connection string (user-provided)
  if [ "$RT_CACHE_PROVIDER" = "mongodb" ] && [ -n "$RT_CACHE_CONNSTR" ]; then
    cat >> "$SECRETS_FILE" << SECRETS_MONGO
  RealtimeAPI_MongoCache_ConnectionString: "${RT_CACHE_CONNSTR}"
SECRETS_MONGO
  elif { [ "$RT_CACHE_PROVIDER" = "redis" ] || [ "$RT_CACHE_PROVIDER" = "azureredis" ]; } && [ -n "$RT_CACHE_CONNSTR" ]; then
    cat >> "$SECRETS_FILE" << SECRETS_REDIS_CONN
  RealtimeAPI_RedisCache_ConnectionString: "${RT_CACHE_CONNSTR}"
SECRETS_REDIS_CONN
  elif [ "$RT_CACHE_PROVIDER" = "inMemorySql" ] && [ -n "$RT_CACHE_CONNSTR" ]; then
    cat >> "$SECRETS_FILE" << SECRETS_INMEM
  RealtimeAPI_inMemorySql_ConnectionString: "${RT_CACHE_CONNSTR}"
SECRETS_INMEM
  fi

  # Queue provider connection string (user-provided)
  if [ "$RT_QUEUE_PROVIDER" = "azureservicebus" ] && [ -n "$RT_QUEUE_CONNSTR" ]; then
    cat >> "$SECRETS_FILE" << SECRETS_SB
  RealtimeAPI_ServiceBus_ConnectionString: "${RT_QUEUE_CONNSTR}"
SECRETS_SB
  elif [ "$RT_QUEUE_PROVIDER" = "azureeventhubs" ] && [ -n "$RT_QUEUE_CONNSTR" ]; then
    cat >> "$SECRETS_FILE" << SECRETS_EH
  RealtimeAPI_EventHubs_ConnectionString: "${RT_QUEUE_CONNSTR}"
SECRETS_EH
  fi

  # Auto-generated passwords (always included when Realtime is enabled)
  cat >> "$SECRETS_FILE" << SECRETS_AUTO
  RealtimeAPI_RabbitMQ_Password: "${RT_RABBITMQ_PASSWORD}"
  RealtimeAPI_RedisCache_Password: "${RT_REDIS_CACHE_PASSWORD}"
  QueueService_RedisCache_Password: "${QS_REDIS_PASSWORD}"
  QueueService_internalCache_ConnectionString: "rpi-queuereader-cache:6379,password=${QS_REDIS_PASSWORD},abortConnect=False"
  QueueService_RabbitMQ_Password: "${QS_RABBITMQ_PASSWORD}"
SECRETS_AUTO
fi

# ============================================================
# Generate overrides YAML (no secrets)
# ============================================================

cat > "$OUTPUT_FILE" << YAML
# ============================================================
# RPI Helm Overrides — Generated by Interaction CLI
# $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# ============================================================
# This file contains ONLY non-sensitive configuration.
# Secrets are in ${SECRETS_FILE} (applied separately).
# ============================================================

global:
  deployment:
    mode: ${MODE}
    platform: ${PLATFORM}
    images:
      repository: ${DEFAULT_REGISTRY}
      tag: "${TAG}"
      imagePullPolicy: Always
      imagePullSecret:
        enabled: true
        name: redpoint-rpi

secretsManagement:
  provider: kubernetes
  kubernetes:
    secretName: ${SECRET_NAME}
YAML

# Database section (non-sensitive parts only)
if [ "$MODE" = "standard" ]; then
  cat >> "$OUTPUT_FILE" << YAML

# ----------------------------------------------------------
#  Operational Database
# ----------------------------------------------------------
databases:
  operational:
    provider: ${DB_PROVIDER}
    server_host: ${DB_HOST}
    server_username: ${DB_USER}
    pulse_database_name: ${DB_PULSE}
    pulse_logging_database_name: ${DB_LOGGING}
    encrypt: true
YAML
fi

# Cloud Identity
if [ "$CLOUD_IDENTITY_ENABLED" = "true" ]; then
  cat >> "$OUTPUT_FILE" << YAML

# ----------------------------------------------------------
#  Cloud Identity
# ----------------------------------------------------------
cloudIdentity:
  enabled: true
  serviceAccount:
    mode: ${SA_MODE}
    name: redpoint-rpi
YAML

  case "$PLATFORM" in
    azure)
      cat >> "$OUTPUT_FILE" << YAML
  azure:
    managedIdentityClientId: ${AZURE_CLIENT_ID}
    tenantId: ${AZURE_TENANT_ID}
YAML
      ;;
    amazon)
      local _use_keys="false"
      [ -n "$AMAZON_ACCESS_KEY_ID" ] && _use_keys="true"
      cat >> "$OUTPUT_FILE" << YAML
  amazon:
    roleArn: ${AMAZON_ROLE_ARN}
    region: ${AMAZON_REGION}
    useAccessKeys: ${_use_keys}
YAML
      ;;
    google)
      cat >> "$OUTPUT_FILE" << YAML
  google:
    serviceAccountEmail: ${GOOGLE_SA_EMAIL}
YAML
      ;;
  esac
fi

# Ingress
cat >> "$OUTPUT_FILE" << YAML

# ----------------------------------------------------------
#  Ingress
# ----------------------------------------------------------
ingress:
  controller:
    enabled: ${DEPLOY_CONTROLLER}
  mode: ${INGRESS_MODE}
  domain: ${DOMAIN}
YAML

if [ "$INGRESS_MODE" = "private" ] && [ -n "$INGRESS_SUBNET" ]; then
  cat >> "$OUTPUT_FILE" << YAML
  subnetName: ${INGRESS_SUBNET}
YAML
fi

cat >> "$OUTPUT_FILE" << YAML
  hosts:
    config: ${HOST_PREFIX}-deploymentapi
    client: ${HOST_PREFIX}-interactionapi
    integration: ${HOST_PREFIX}-integrationapi
    realtime: ${HOST_PREFIX}-realtimeapi
    callbackapi: ${HOST_PREFIX}-callbackapi
    queuereader: ${HOST_PREFIX}-queuereader
    rabbitmqconsole: ${HOST_PREFIX}-rabbitmq-console
    smartactivation: ${HOST_PREFIX}-smartActivation
YAML

# Storage is added on demand via: rpihelmcli -a storage

# Realtime API (non-sensitive parts only)
if [ "$REALTIME_ENABLED" = "true" ]; then

  # Build cache provider-specific config
  CACHE_EXTRA=""
  case "$RT_CACHE_PROVIDER" in
    mongodb)
      CACHE_EXTRA="    mongodb:
      databaseName: RealtimeCacheDB
      collectionName: RealtimeCacheCollection"
      ;;
    redis)
      CACHE_EXTRA="    redis:
      type: internal"
      ;;
    googlebigtable)
      CACHE_EXTRA="    googlebigtable:
      projectId: \"${RT_CACHE_BIGTABLE_PROJECT}\"
      instanceId: \"${RT_CACHE_BIGTABLE_INSTANCE}\""
      ;;
  esac

  # Build queue provider-specific config
  QUEUE_EXTRA=""
  case "$RT_QUEUE_PROVIDER" in
    rabbitmq)
      QUEUE_EXTRA="    rabbitmq:
      type: internal"
      ;;
    azureeventhubs)
      QUEUE_EXTRA="    azureeventhubs:
      eventHubName: \"${RT_EVENTHUB_NAME}\"
      NamespaceName: \"${RT_EVENTHUB_NAMESPACE}\"
      PartitionIds: [\"0\"]"
      ;;
    googlepubsub)
      QUEUE_EXTRA="    googlepubsub:
      projectId: \"${RT_PUBSUB_PROJECT}\""
      ;;
  esac

  cat >> "$OUTPUT_FILE" << YAML

# ----------------------------------------------------------
#  Realtime API
# ----------------------------------------------------------
realtimeapi:
  enabled: true
  replicas: 1
  cacheProvider:
    enabled: true
    provider: ${RT_CACHE_PROVIDER}
${CACHE_EXTRA}
  queueProvider:
    enabled: true
    provider: ${RT_QUEUE_PROVIDER}
    queueNames:
      formQueuePath: ${QUEUE_PREFIX}RPIWebFormSubmission
      eventsQueuePath: ${QUEUE_PREFIX}RPIWebEvents
      cacheOutputQueuePath: ${QUEUE_PREFIX}RPIWebCacheData
      recommendationsQueuePath: ${QUEUE_PREFIX}RPIWebRecommendations
      listenerQueuePath: ${QUEUE_PREFIX}RPIQueueListener
      callbackServiceQueuePath: ${QUEUE_PREFIX}RPICallbackApiQueue
${QUEUE_EXTRA}
YAML
fi

# Pre-flight
cat >> "$OUTPUT_FILE" << YAML

# ----------------------------------------------------------
#  Pre-flight Validation
# ----------------------------------------------------------
preflight:
  enabled: true
  mode: test
YAML

# ============================================================
# Data Warehouse — write block collected during step 3b
# ============================================================
if [ "$DW_ENABLED" = "true" ] && [ -n "$DW_BLOCK" ]; then
  append_dw_block "$OUTPUT_FILE" "$DW_BLOCK" "Data Warehouse — ${DW_PROVIDER}"
fi

# ============================================================
# Optional features — prompt during initial setup
# ============================================================
FEATURES_LIST="database_upgrade queue_reader storage smtp redpoint_ai oidc entra_id autoscaling custom_metrics service_mesh validation_pods extra_envs secrets_management node_scheduling common_annotations custom_ca_certs image_overrides pod_anti_affinity node_provisioning storage_class"
SELECTED_FEATURES=""

if [ "$FILE_MODE" = "true" ]; then
  # Build feature list from input file
  section "Optional Features"
  for feat in $FEATURES_LIST; do
    if _feature_enabled "$feat"; then
      SELECTED_FEATURES="${SELECTED_FEATURES} ${feat}"
      echo "  ${ICON_CHECK} ${feat}"
    fi
  done
  [ -z "$SELECTED_FEATURES" ] && echo "  ${DIM}(none selected)${RESET}"
else
  section "Optional Features"
  echo ""
  echo "  Select features to include now. You can always add more later"
  echo "  with ${DIM}rpihelmcli -a <feature>${RESET}"
  echo ""
  for feat in $FEATURES_LIST; do
    label=""
    case "$feat" in
      database_upgrade) label="Database Upgrade — run schema migrations automatically after upgrades" ;;
      queue_reader)     label="Queue Reader — process realtime queue events (forms, listeners, callbacks)" ;;
      storage)          label="Storage — persistent volumes for file-based processing and caching" ;;
      smtp)             label="SMTP — send transactional emails from RPI workflows" ;;
      redpoint_ai)      label="Redpoint AI — AI-powered content generation (OpenAI + Cognitive Search)" ;;
      oidc)             label="OIDC — single sign-on via OpenID Connect (Keycloak, Okta, etc.)" ;;
      entra_id)         label="Entra ID — single sign-on via Microsoft Entra ID (Azure AD)" ;;
      autoscaling)      label="Autoscaling — scale services based on CPU/memory with HPA or KEDA" ;;
      custom_metrics)   label="Custom Metrics — expose Prometheus /metrics endpoints for monitoring" ;;
      service_mesh)     label="Service Mesh — enable Linkerd mTLS and traffic policies" ;;
      validation_pods)      label="Validation Pods — validate PVC mounts and CSI drivers post-deploy" ;;
      extra_envs)         label="Extra Envs — debug and plugin environment variables for execution service" ;;
      secrets_management) label="Secrets Management — configure secrets provider, CSI classes, SDK vault settings" ;;
      node_scheduling)    label="Node Scheduling — node selector and tolerations for dedicated nodes" ;;
      common_annotations) label="Common Annotations — org-wide annotations on all resources (cost center, alerts)" ;;
      custom_ca_certs)    label="Custom CA Certs — mount internal CA certificates into service pods" ;;
      image_overrides)    label="Image Overrides — per-service container image references (flat registries)" ;;
      pod_anti_affinity)  label="Pod Anti-Affinity — control pod scheduling spread across nodes" ;;
      node_provisioning)  label="Node Provisioning — Karpenter NodePool for dedicated EKS nodes" ;;
      storage_class)      label="Storage Class — create a StorageClass for CSI storage (EFS, Azure File)" ;;
      *) label="$feat" ;;
    esac
    yn=""
    read -rp "  Add ${BOLD}${label}${RESET}? ${DIM}(y/n) [n]${RESET}: " yn
    if [ "${yn:-n}" = "y" ] || [ "${yn:-n}" = "Y" ]; then
      SELECTED_FEATURES="${SELECTED_FEATURES} ${feat}"
    fi
  done
fi

# Run each selected feature's add function against the generated overrides
for feat in $SELECTED_FEATURES; do
  echo ""
  section "Configuring: ${feat}"

  # In file mode, set context-specific _CFG entries for features that
  # share variable names (e.g., client_id used by both entra_id and oidc)
  if [ "$FILE_MODE" = "true" ]; then
    case "$feat" in
      entra_id)
        _CFG[client_id]=$(cfg '.features.entra_id.client_id' '')
        _CFG[tenant_id]=$(cfg '.features.entra_id.tenant_id' '')
        ;;
      oidc)
        _CFG[client_id]=$(cfg '.features.oidc.client_id' '')
        ;;
      queue_reader)
        _CFG[tenant_id]=$(cfg '.features.queue_reader.tenant_id' '')
        ;;
    esac
  fi

  case "$feat" in
    database_upgrade) add_database_upgrade "$OUTPUT_FILE" ;;
    queue_reader)     add_queue_reader "$OUTPUT_FILE" ;;
    storage)          add_storage "$OUTPUT_FILE" ;;
    smtp)             add_smtp "$OUTPUT_FILE" ;;
    redpoint_ai)      add_redpoint_ai "$OUTPUT_FILE" ;;
    oidc)             add_oidc "$OUTPUT_FILE" ;;
    entra_id)         add_entra_id "$OUTPUT_FILE" ;;
    autoscaling)      add_autoscaling "$OUTPUT_FILE" ;;
    custom_metrics)   add_custom_metrics "$OUTPUT_FILE" ;;
    service_mesh)     add_service_mesh "$OUTPUT_FILE" ;;
    validation_pods)      add_validation_pods "$OUTPUT_FILE" ;;
    extra_envs)       add_extra_envs "$OUTPUT_FILE" ;;
    secrets_management) add_secrets_management "$OUTPUT_FILE" ;;
    node_scheduling)    add_node_scheduling "$OUTPUT_FILE" ;;
    common_annotations) add_common_annotations "$OUTPUT_FILE" ;;
    custom_ca_certs)    add_custom_ca_certs "$OUTPUT_FILE" ;;
    image_overrides)    add_image_overrides "$OUTPUT_FILE" ;;
    pod_anti_affinity)  add_pod_anti_affinity "$OUTPUT_FILE" ;;
    node_provisioning)  add_node_provisioning "$OUTPUT_FILE" ;;
    storage_class)      add_storage_class "$OUTPUT_FILE" ;;
  esac
done

# Add hint for future feature additions
cat >> "$OUTPUT_FILE" << 'YAML'

# ---------------------------------------------------------------
# Add more features with the Interaction CLI:
#   rpihelmcli -a <feature>
#   rpihelmcli -a menu
#
# See docs/secrets-management.md and the Helm Assistant Reference tab for details.
# ---------------------------------------------------------------
YAML

# ============================================================
# Generate prerequisites script
# ============================================================

cat > "$PREREQS_FILE" << 'PREREQS_HEADER'
#!/usr/bin/env bash
# ============================================================
# RPI Prerequisites — Generated by Interaction CLI
# Run this BEFORE helm install to create required resources.
# ============================================================
set -euo pipefail

# --- Colors & Symbols ---
if [ -t 1 ] && command -v tput &> /dev/null && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  BOLD=$(tput bold); CYAN=$(tput setaf 6); GREEN=$(tput setaf 2)
  YELLOW=$(tput setaf 3); RED=$(tput setaf 1); DIM=$(tput dim); RESET=$(tput sgr0)
else
  BOLD="" CYAN="" GREEN="" YELLOW="" RED="" DIM="" RESET=""
fi
OK="${GREEN}✔${RESET}"; FAIL="${RED}✘${RESET}"; WARN="${YELLOW}⚠${RESET}"
STEP=0; PASS=0; ERRORS=0

step() { STEP=$((STEP + 1)); echo ""; echo "${CYAN}${BOLD}[$STEP]${RESET} ${BOLD}$1${RESET}"; }
ok()   { PASS=$((PASS + 1)); echo "  ${OK} $1"; }
err()  { ERRORS=$((ERRORS + 1)); echo "  ${FAIL} $1"; }
skip() { echo "  ${WARN} $1 ${DIM}(skipped)${RESET}"; }
line() { echo "${DIM}$(printf '%.0s─' {1..60})${RESET}"; }

echo ""
echo "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo "${BOLD}  Redpoint RPI — Prerequisite Setup${RESET}"
echo "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo "  ${DIM}This script creates the Kubernetes resources required"
echo "  before running helm install / helm upgrade.${RESET}"

PREREQS_HEADER

cat >> "$PREREQS_FILE" << 'PREREQS_BODY'
DEFAULT_NS="redpoint-rpi"
read -rp "  Kubernetes namespace ${DIM}[${DEFAULT_NS}]${RESET}: " NAMESPACE
NAMESPACE="${NAMESPACE:-$DEFAULT_NS}"

# ----------------------------------------------------------
# Step 1: Namespace
# ----------------------------------------------------------
step "Create namespace: ${NAMESPACE}"
if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  skip "Namespace ${NAMESPACE} already exists"
else
  if kubectl create namespace "${NAMESPACE}"; then
    ok "Namespace ${NAMESPACE} created"
  else
    err "Failed to create namespace ${NAMESPACE}"
  fi
fi

# ----------------------------------------------------------
# Step 2: Image pull secret
# ----------------------------------------------------------
step "Create image pull secret"
echo "  ${DIM}Credentials are provided by Redpoint Support.${RESET}"
if kubectl get secret redpoint-rpi -n "${NAMESPACE}" &>/dev/null; then
  local_update=""
  read -rp "  ${WARN} Secret ${BOLD}redpoint-rpi${RESET} already exists. Update it? (y/N): " local_update
  if [ "${local_update}" != "y" ] && [ "${local_update}" != "Y" ]; then
    skip "Image pull secret unchanged"
  else
    read -rp "  Docker username: " DOCKER_USER
    read -rsp "  Docker password: " DOCKER_PASS; echo ""
    if kubectl create secret docker-registry redpoint-rpi \
      --namespace "${NAMESPACE}" \
      --docker-server=__DOCKER_SERVER__ \
      --docker-username="${DOCKER_USER}" \
      --docker-password="${DOCKER_PASS}" \
      --dry-run=client -o yaml | kubectl apply -f -; then
      ok "Image pull secret updated"
    else
      err "Failed to update image pull secret"
    fi
  fi
else
  read -rp "  Docker username: " DOCKER_USER
  read -rsp "  Docker password: " DOCKER_PASS; echo ""
  if kubectl create secret docker-registry redpoint-rpi \
    --namespace "${NAMESPACE}" \
    --docker-server=__DOCKER_SERVER__ \
    --docker-username="${DOCKER_USER}" \
    --docker-password="${DOCKER_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -; then
    ok "Image pull secret created"
  else
    err "Failed to create image pull secret"
  fi
fi

# ----------------------------------------------------------
# Step 3: TLS secret
# ----------------------------------------------------------
step "Create TLS secret for ingress"
echo "  ${DIM}Provide the paths to your TLS certificate and private key.${RESET}"
read -rp "  Path to TLS certificate (.crt): " CERT_PATH
read -rp "  Path to TLS private key  (.key): " KEY_PATH

if [ ! -f "${CERT_PATH}" ]; then
  err "Certificate file not found: ${CERT_PATH}"
elif [ ! -f "${KEY_PATH}" ]; then
  err "Key file not found: ${KEY_PATH}"
else
  if kubectl create secret tls ingress-tls \
    --namespace "${NAMESPACE}" \
    --cert="${CERT_PATH}" \
    --key="${KEY_PATH}" \
    --dry-run=client -o yaml | kubectl apply -f -; then
    ok "TLS secret created"
  else
    err "Failed to create TLS secret"
  fi
fi

# ----------------------------------------------------------
# Step 4: RPI application secrets
# ----------------------------------------------------------
step "Apply RPI application secrets"
if [ ! -f "__SECRETS_FILE__" ]; then
  err "Secrets file not found: __SECRETS_FILE__"
  echo "  ${DIM}Generate it with the Interaction CLI or create it manually.${RESET}"
else
  if kubectl apply -f __SECRETS_FILE__ --namespace "${NAMESPACE}"; then
    ok "Secrets applied from __SECRETS_FILE__"
  else
    err "Failed to apply secrets"
  fi
fi

# ----------------------------------------------------------
# Summary
# ----------------------------------------------------------
echo ""
line
echo ""
if [ "${ERRORS}" -eq 0 ]; then
  echo "  ${GREEN}${BOLD}All ${STEP} steps completed successfully.${RESET}"
  echo ""
  echo "  ${DIM}Next: deploy RPI with Helm${RESET}"
  echo "  ${BOLD}helm install rpi ./chart -f __OUTPUT_FILE__ -n ${NAMESPACE}${RESET}"
else
  echo "  ${YELLOW}${BOLD}${PASS} passed, ${ERRORS} failed out of ${STEP} steps.${RESET}"
  echo "  ${DIM}Fix the errors above and re-run this script.${RESET}"
fi
echo ""
PREREQS_BODY

# Inject baked-in values (registry, file paths) into the generated script
DOCKER_SERVER="${DEFAULT_REGISTRY%%/docker*}"
sed -i "s|__DOCKER_SERVER__|${DOCKER_SERVER}|g" "$PREREQS_FILE"
sed -i "s|__SECRETS_FILE__|${SECRETS_FILE}|g" "$PREREQS_FILE"
sed -i "s|__OUTPUT_FILE__|${OUTPUT_FILE}|g" "$PREREQS_FILE"

chmod +x "$PREREQS_FILE"

# ============================================================
# Summary
# ============================================================
echo ""
echo "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo "${GREEN}${BOLD}║   ${ICON_CHECK}  Interaction CLI — Complete                ║${RESET}"
echo "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo ""
echo "  ${BOLD}Generated files:${RESET}"
echo "  ${ICON_KEY} ${SECRETS_FILE}"
echo "  ${ICON_FILE} ${OUTPUT_FILE}"
echo "  ${ICON_ROCKET} ${PREREQS_FILE}"
echo ""
echo "  ${BOLD}Next steps:${RESET}"
echo "  ${CYAN}1.${RESET} Review ${BOLD}${SECRETS_FILE}${RESET} — ensure all values are correct"
echo "  ${CYAN}2.${RESET} Run prerequisites:  ${DIM}bash ${PREREQS_FILE}${RESET}"
echo "  ${CYAN}3.${RESET} Deploy:             ${DIM}helm upgrade --install rpi ./chart -f ${OUTPUT_FILE} -n ${NAMESPACE}${RESET}"
echo "  ${CYAN}4.${RESET} Validate:           ${DIM}helm test rpi -n ${NAMESPACE}${RESET}"
echo ""
echo "  ${BOLD}Add features later:${RESET}"
echo "  ${DIM}rpihelmcli -a menu${RESET}"
echo ""
echo "  ${ICON_WARN}  ${YELLOW}${SECRETS_FILE} contains sensitive values.${RESET}"
echo "     ${YELLOW}Do NOT commit it to version control.${RESET}"

# Delete input file after successful generation (contains sensitive values)
if [ "$FILE_MODE" = "true" ] && [ -f "$INPUT_FILE" ]; then
  rm -f "$INPUT_FILE"
  echo ""
  echo "  ${ICON_CHECK} ${DIM}Deleted ${INPUT_FILE} (contained sensitive values)${RESET}"
fi
echo ""
echo "${DIM}──────────────────────────────────────────────${RESET}"
echo "  ${BOLD}Redpoint Global${RESET}"
echo "  ${DIM}https://www.redpointglobal.com${RESET}"
echo "  ${DIM}Support: support@redpointglobal.com${RESET}"
echo "  ${DIM}Docs:    https://docs.redpointglobal.com/rpi${RESET}"
echo "${DIM}──────────────────────────────────────────────${RESET}"
echo ""
