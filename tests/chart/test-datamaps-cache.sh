#!/usr/bin/env bash
# Render-level contract tests for the RealtimeAPI DataMaps Cache rule.
#
# Contract: every DataMap (indices 0-7) always receives a Cache assignment.
# A per-map realtimeapi.dataMaps.<map>.Cache overrides it; otherwise the map
# receives realtimeapi.cacheProvider.provider. An empty per-map value falls
# back to the provider. No DataMap may render without a Cache assignment.
#
# Run from the repository root: ./test-datamaps-cache.sh

set -u
cd "$(dirname "$0")/../.."
CHART=chart
FAIL=0

render() {
  helm template rpi "$CHART" --namespace test \
    --set realtimeapi.enabled=true \
    "$@" -s templates/deploy-realtimeapi.yaml
}

cache_value() { # $1 = rendered manifest, $2 = DataMap index
  printf '%s\n' "$1" | grep -A1 "DataMaps__$2__Cache$" | tail -1 \
    | sed 's/.*value: //; s/"//g'
}

check() { # $1 = description, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
  else
    echo "FAIL: $1 (expected [$2], got [$3])"
    FAIL=1
  fi
}

BASE=$(render --set realtimeapi.cacheProvider.provider=mongodb)

# 1. All 8 Cache env vars are present at default configuration.
n=$(printf '%s\n' "$BASE" | grep -cE "DataMaps__[0-7]__Cache$")
check "all 8 Cache env vars present at default configuration" "8" "$n"

# 2. All 8 equal cacheProvider.provider when no per-map override exists.
for i in 0 1 2 3 4 5 6 7; do
  check "DataMaps__${i}__Cache defaults to cacheProvider.provider" \
    "mongodb" "$(cache_value "$BASE" "$i")"
done

# 3. Each DataMap can independently override the provider.
OVR=$(render --set realtimeapi.cacheProvider.provider=mongodb \
  --set realtimeapi.dataMaps.visitorBackup.Cache=azureredis)
check "visitorBackup override applies to index 4" \
  "azureredis" "$(cache_value "$OVR" 4)"
for i in 0 1 2 3 5 6 7; do
  check "index $i unaffected by the visitorBackup override" \
    "mongodb" "$(cache_value "$OVR" "$i")"
done

# 4. An empty per-map value falls back to cacheProvider.provider.
EMPTY=$(render --set realtimeapi.cacheProvider.provider=mongodb \
  --set realtimeapi.dataMaps.visitorProfile.Cache="")
check "empty per-map Cache falls back to the provider" \
  "mongodb" "$(cache_value "$EMPTY" 0)"

# 5. Changing the global provider changes every non-overridden DataMap.
SWAP=$(render --set realtimeapi.cacheProvider.provider=redis \
  --set realtimeapi.dataMaps.visitorBackup.Cache=azureredis)
for i in 0 1 2 3 5 6 7; do
  check "provider change propagates to index $i" \
    "redis" "$(cache_value "$SWAP" "$i")"
done
check "per-map override survives a provider change" \
  "azureredis" "$(cache_value "$SWAP" 4)"

# 6. No DataMap renders without a Cache assignment.
for i in 0 1 2 3 4 5 6 7; do
  if [ -z "$(cache_value "$BASE" "$i")" ]; then
    echo "FAIL: DataMaps__${i}__Cache rendered without a value"
    FAIL=1
  fi
done

# 7. Unset provider resolves to the platform default (never empty).
for spec in "azure:mongodb" "amazon:mongodb" "selfhosted:mongodb" "google:googlebigtable"; do
  plat=${spec%%:*}; want=${spec##*:}
  PD=$(render --set global.deployment.platform="$plat")
  check "platform=$plat default cache provider" "$want" "$(cache_value "$PD" 0)"
  for i in 0 1 2 3 4 5 6 7; do
    if [ -z "$(cache_value "$PD" "$i")" ]; then
      echo "FAIL: platform=$plat DataMaps__${i}__Cache empty"
      FAIL=1
    fi
  done
done

# 8. Explicit provider override beats the platform default.
OVR2=$(render --set global.deployment.platform=google \
  --set realtimeapi.cacheProvider.provider=mongodb)
check "explicit provider beats the platform default" \
  "mongodb" "$(cache_value "$OVR2" 0)"

# 9. Queue provider resolves to the platform default.
queue_assembly() { # $1 = rendered manifest
  printf '%s\n' "$1" | grep -A1 "ListenerQueueSettings__Assembly$" | tail -1 \
    | sed 's/.*value: //; s/"//g'
}
for spec in "azure:RedPoint.Azure.Server" "amazon:RedPoint.Amazon.Server" "selfhosted:RedPoint.Resonance.RabbitMQAccess" "google:RedPoint.Google.Server"; do
  plat=${spec%%:*}; want=${spec##*:}
  PD=$(render --set global.deployment.platform="$plat")
  got=$(queue_assembly "$PD")
  check "platform=$plat default queue assembly" "$want" "$got"
done
AZQ=$(render --set global.deployment.platform=azure)
check "platform=azure default queue is Service Bus" "ServiceBus" \
  "$(printf '%s\n' "$AZQ" | grep -A3 'ListenerQueueSettings__Settings__0__Key$' | tail -1 | sed 's/.*value: //; s/"//g')"

# 10. Provider resolution contract: unset / "" / null resolve to the platform
#     default; whitespace fails render (schema enum); non-empty operator value wins.
for state in 'unset:' 'empty:--set-string realtimeapi.cacheProvider.provider=' 'null:--set realtimeapi.cacheProvider.provider=null'; do
  label=${state%%:*}; flag=${state#*:}
  R=$(render $flag)
  check "cache provider ${label} resolves to the platform default" \
    "mongodb" "$(cache_value "$R" 0)"
done
if render --set-string 'realtimeapi.cacheProvider.provider= ' >/dev/null 2>&1; then
  echo "FAIL: whitespace cache provider did not fail render"; FAIL=1
else
  echo "PASS: whitespace cache provider fails render (schema enum)"
fi
R=$(render --set realtimeapi.cacheProvider.provider=redis)
check "explicit cache provider wins over the platform default" \
  "redis" "$(cache_value "$R" 0)"
for state in 'empty:--set-string realtimeapi.queueProvider.provider=' 'null:--set realtimeapi.queueProvider.provider=null'; do
  label=${state%%:*}; flag=${state#*:}
  R=$(render $flag --set global.deployment.platform=azure)
  check "queue provider ${label} resolves to the platform default" \
    "RedPoint.Azure.Server" "$(queue_assembly "$R")"
done
if render --set-string 'realtimeapi.queueProvider.provider= ' >/dev/null 2>&1; then
  echo "FAIL: whitespace queue provider did not fail render"; FAIL=1
else
  echo "PASS: whitespace queue provider fails render (schema enum)"
fi
R=$(render --set realtimeapi.queueProvider.provider=rabbitmq --set global.deployment.platform=azure)
check "explicit queue provider wins over the platform default" \
  "RedPoint.Resonance.RabbitMQAccess" "$(queue_assembly "$R")"

# 11. Optional settings: absent when unset, present when configured, never empty.
opt_check() { # $1 = env name, $2 = values path, $3 = expected-when-set
  R=$(render)
  if printf '%s\n' "$R" | grep -q "name: $1$"; then
    echo "FAIL: optional $1 emitted while unset"; FAIL=1
  else
    echo "PASS: optional $1 absent when unset"
  fi
  R=$(render --set "$2=$3")
  check "optional $1 present when configured" "$3" \
    "$(printf '%s\n' "$R" | grep -A1 "name: $1$" | tail -1 | sed 's/.*value: //; s/"//g')"
}
opt_check "RealtimeAPIConfiguration__AppSettings__RealtimeServerCookieDomain" \
  "realtimeapi.RealtimeServerCookieDomain" ".example.com"
opt_check "RealtimeAPIConfiguration__IdentitySettings__MasterKeyName" \
  "realtimeapi.identitySettings.masterKeyName" "CustomerKey"

if [ "$FAIL" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "FAILURES DETECTED"
fi
exit "$FAIL"
