#!/usr/bin/env bash
# Empty-value gate (T5): renders the chart across the scenario matrix and fails
# if ANY workload env var carries an empty/whitespace/missing value unless the
# (workload, env) pair is on the explicit reviewed allowlist below.
#
# The allowlist is a contract artifact: adding to it is a deliberate decision,
# reviewed like a schema change. Entries carry the classification and owner.
#
# Run from the repository root: ./test-empty-env.sh

set -u
cd "$(dirname "$0")/../.."
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# workload<TAB>env-name<TAB>reason
ALLOWLIST=$(cat <<'EOF'
Deployment/rpi-callbackapi	KeyVault__AmazonSettings__AppSettingsTag	PENDING F-guard: empty-tag app semantics unconfirmed (audit G1)
Deployment/rpi-deploymentapi	KeyVault__AmazonSettings__AppSettingsTag	PENDING F-guard (audit G1)
Deployment/rpi-executionservice	KeyVault__AmazonSettings__AppSettingsTag	PENDING F-guard (audit G1)
Deployment/rpi-integrationapi	KeyVault__AmazonSettings__AppSettingsTag	PENDING F-guard (audit G1)
Deployment/rpi-interactionapi	KeyVault__AmazonSettings__AppSettingsTag	PENDING F-guard (audit G1)
Deployment/rpi-nodemanager	KeyVault__AmazonSettings__AppSettingsTag	PENDING F-guard (audit G1)
Deployment/rpi-queuereader	KeyVault__AmazonSettings__AppSettingsTag	PENDING F-guard (audit G1)
Deployment/rpi-realtimeapi	KeyVault__AmazonSettings__AppSettingsTag	PENDING F-guard (audit G1)
Deployment/rpi-twiliomessaging	Twilio__Client__AccountSid	PENDING F-guard: required-when-enabled (audit F1)
EOF
)

render() { # $1 = scenario name, rest = helm args
  local name=$1; shift
  if ! helm template rpi chart --namespace gate "$@" > "$TMP/$name.yaml" 2> "$TMP/$name.err"; then
    echo "FAIL: scenario $name did not render:"
    tail -2 "$TMP/$name.err"
    FAIL=1
    return 1
  fi
}

scan() { # $1 = scenario name
  python3 - "$TMP/$1.yaml" "$1" <<'EOF'
import sys, yaml
path, scenario = sys.argv[1], sys.argv[2]
KINDS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}
for doc in yaml.safe_load_all(open(path)):
    if not doc or doc.get("kind") not in KINDS:
        continue
    wl = f"{doc['kind']}/{doc['metadata']['name']}"
    spec = doc["spec"]["jobTemplate"]["spec"]["template"]["spec"] \
        if doc["kind"] == "CronJob" else doc["spec"]["template"]["spec"]
    for ctype in ("initContainers", "containers"):
        for c in spec.get(ctype) or []:
            for e in c.get("env") or []:
                if "valueFrom" in e:
                    continue
                v = e.get("value")
                if v is None or str(v).strip() == "":
                    print(f"{scenario}\t{wl}\t{e['name']}")
EOF
}

SCENARIOS_DONE=0
run() { # $1 = name, rest = helm args
  local name=$1; shift
  render "$name" "$@" || return
  SCENARIOS_DONE=$((SCENARIOS_DONE + 1))
  while IFS=$'\t' read -r sc wl env; do
    [ -n "$sc" ] || continue
    if printf '%s\n' "$ALLOWLIST" | grep -q "^${wl}	${env}	"; then
      continue
    fi
    echo "FAIL: [$sc] $wl $env is empty and not allowlisted"
    FAIL=1
  done < <(scan "$name")
}

run default
run azure --set global.deployment.platform=azure
run google --set global.deployment.platform=google
run selfhosted --set global.deployment.platform=selfhosted
run sdk --set secretsManagement.provider=sdk --set cloudIdentity.enabled=true
run postgres --set databases.operational.provider=postgresql
run redis-cache --set realtimeapi.cacheProvider.provider=redis
run rabbit-queue --set realtimeapi.queueProvider.provider=rabbitmq
run observability --set observability.enabled=true \
  --set observability.clientId=00000000-0000-0000-0000-000000000000 \
  --set observability.telemetry.mode=advanced
run rebrandly --set rebrandly.enabled=true
run multitenant-callback --set callbackapi.multitenancy.enabled=true
run twilio --set twiliomessaging.enabled=true \
  --set twiliomessaging.postgres.reuseOperational=false \
  --set twiliomessaging.postgres.host=pg.example \
  --set twiliomessaging.postgres.username=tw \
  --set twiliomessaging.postgres.database=tw

echo "scenarios rendered: $SCENARIOS_DONE"
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS (zero unexpected empty values)"; else echo "FAILURES DETECTED"; fi
exit "$FAIL"
