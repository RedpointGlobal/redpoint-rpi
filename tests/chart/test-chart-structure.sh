#!/usr/bin/env bash
# Structural lint suite (T7): mechanism invariants that hold regardless of values.
#
# 1. Provider resolution: no template consumes the raw realtimeapi provider keys.
#    The ONLY resolution points are the rpi.realtime.cacheProvider /
#    rpi.realtime.queueProvider helpers; every consumer uses their resolved value.
# 2. No `dict "root" .` inside a range block (the loop variable is not the chart
#    root; this class of bug made callbackapi multitenancy unrenderable).
# 3. helm lint passes.
#
# Run from the repository root: ./test-chart-structure.sh

set -u
cd "$(dirname "$0")/../.."
FAIL=0

# 1. Raw provider reads outside the resolver helpers.
hits=$(grep -rn "cacheProvider\.provider\|queueProvider\.provider" chart/templates/ \
  | grep -v "^chart/templates/_helpers.tpl:" \
  | grep -vE "^\S+: *(#|\{\{- /\*)" )
if [ -n "$hits" ]; then
  echo "FAIL: raw realtimeapi provider reads outside the resolver helpers:"
  printf '%s\n' "$hits"
  FAIL=1
else
  echo "PASS: no template bypasses the provider resolvers"
fi

# Resolver helpers themselves exist and are consumed.
for h in rpi.realtime.cacheProvider rpi.realtime.queueProvider; do
  if ! grep -q "define \"$h\"" chart/templates/_helpers.tpl; then
    echo "FAIL: resolver helper $h missing"; FAIL=1
  elif [ "$(grep -rl "include \"$h\"" chart/templates/ | grep -cv _helpers.tpl)" -eq 0 ]; then
    echo "FAIL: resolver helper $h has no consumers"; FAIL=1
  else
    echo "PASS: resolver helper $h defined and consumed"
  fi
done

# 2. dict "root" . inside a range scope (block-stack tracking).
badroot=$(python3 - <<'EOF'
import re, glob
for path in glob.glob('chart/templates/**/*.yaml', recursive=True) + glob.glob('chart/templates/*.tpl'):
    stack = []
    for i, line in enumerate(open(path), 1):
        for m in re.finditer(r'\{\{-?\s*(range|if|with|define|else if|else|end)\b', line):
            t = m.group(1)
            if t in ('range', 'if', 'with', 'define'):
                stack.append(t)
            elif t == 'end' and stack:
                stack.pop()
        if 'range' in stack and re.search(r'"root"\s+\.(?![A-Za-z$])', line):
            print(f"{path}:{i}: {line.strip()}")
EOF
)
if [ -n "$badroot" ]; then
  echo "FAIL: dict \"root\" . inside a range block (loop variable passed as chart root):"
  printf '%s\n' "$badroot"
  FAIL=1
else
  echo "PASS: no root-dot references inside range blocks"
fi

# 3. helm lint.
if helm lint chart >/dev/null 2>&1; then
  echo "PASS: helm lint"
else
  echo "FAIL: helm lint"
  helm lint chart 2>&1 | grep -i error
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES DETECTED"; fi
exit "$FAIL"
