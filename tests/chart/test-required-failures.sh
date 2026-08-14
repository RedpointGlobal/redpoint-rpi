#!/usr/bin/env bash
# Required-failure suite (T4): configurations that must FAIL `helm template`,
# with the error naming the values path so the operator knows the fix.
#
# Run from the repository root: ./test-required-failures.sh

set -u
cd "$(dirname "$0")/../.."
FAIL=0

expect_fail() { # $1 = description, $2 = expected error fragment, rest = helm args
  local desc=$1 frag=$2; shift 2
  local out
  if out=$(helm template rpi chart --namespace rf "$@" 2>&1); then
    echo "FAIL: $desc rendered successfully (expected failure)"
    FAIL=1
  elif printf '%s' "$out" | grep -q "$frag"; then
    echo "PASS: $desc fails and names '$frag'"
  else
    echo "FAIL: $desc failed without naming '$frag':"
    printf '%s\n' "$out" | tail -2
    FAIL=1
  fi
}

expect_fail "observability enabled without clientId" \
  "observability.clientId" \
  --set observability.enabled=true

expect_fail "twiliomessaging without PostgreSQL" \
  "twiliomessaging" \
  --set twiliomessaging.enabled=true

expect_fail "cloudSqlProxy enabled outside sdk mode" \
  "cloudSqlProxy" \
  --set global.deployment.platform=google \
  --set databases.operational.cloudSqlProxy.enabled=true

expect_fail "sdk secrets without cloudIdentity" \
  "cloudIdentity" \
  --set secretsManagement.provider=sdk

expect_fail "deploymentapi authentication without issuer" \
  "deploymentapi.authentication" \
  --set deploymentapi.authentication.enabled=true

expect_fail "whitespace cache provider (schema enum)" \
  "must be one of" \
  --set-string 'realtimeapi.cacheProvider.provider= '

expect_fail "invalid cache provider (schema enum)" \
  "must be one of" \
  --set realtimeapi.cacheProvider.provider=memcached

expect_fail "clientAddressOverrides without multitenant" \
  "multitenant" \
  --set 'realtimeapi.clientAddressOverrides[0].clientId=00000000-0000-0000-0000-000000000000' \
  --set 'realtimeapi.clientAddressOverrides[0].address=https://rt.example.com'

if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES DETECTED"; fi
exit "$FAIL"
