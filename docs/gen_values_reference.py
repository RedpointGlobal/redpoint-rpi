#!/usr/bin/env python3
"""Generate docs/values_reference.yaml from the chart's effective defaults.

The reference is the COMPLETE catalog of every configurable value and its
default - the surface a user browses to decide what to put in their own
overrides. It is generated, not hand-maintained, so it never drifts from
the chart.

How it works:
  1. Render the chart's effective per-service + cross-cutting defaults
     (values.yaml merged with _defaults.tpl via the chart's own merge
     helpers) into a single values tree, using a throwaway template.
  2. Pull each key's description from values.schema.json.
  3. Emit a commented YAML reference.

Run from the chart repo root:
  python3 docs/gen_values_reference.py

Requires: helm on PATH, PyYAML.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import textwrap

import yaml

CHART = "chart"
SCHEMA = "chart/values.schema.json"
OUT = "docs/values_reference.yaml"
DUMP_TEMPLATE = "chart/templates/zzz-values-reference-dump.yaml"

# Services that resolve through rpi.merged.service (name in _defaults.tpl).
SERVICES = [
    "realtimeapi", "callbackapi", "executionservice", "interactionapi",
    "integrationapi", "nodemanager", "deploymentapi", "queuereader",
    "rebrandly", "authservice", "keycloak", "initservice", "messageq",
    "maintenanceservice", "servicesapi", "socketio", "uiservice", "cdpcache",
]
# Cross-cutting blocks that resolve through their own rpi.merged.<name> helper.
CROSSCUT = [
    "securityContext", "livenessProbe", "readinessProbe", "startupProbe",
    "topologySpreadConstraints", "ingress", "diagnosticsMode",
    "networkPolicy", "postInstall", "databaseUpgrade",
]

# Reading order for top-level keys; anything else follows alphabetically.
TOP_ORDER = [
    "global", "nameOverride", "fullnameOverride", "commonAnnotations",
    "customAnnotations", "customLabels", "podLabels", "serviceAnnotations",
    "serviceAccountAnnotations", "databases", "secretsManagement",
    "cloudIdentity", "customCACerts", "SMTPSettings", "OpenIdProviders",
    "MicrosoftEntraID", "ingress", "networkPolicy", "serviceMesh", "storage",
    "nodeSelector", "tolerations", "podAntiAffinity",
    "topologySpreadConstraints", "nodeProvisioning", "resources",
    "securityContext", "livenessProbe", "readinessProbe", "startupProbe",
    "customMetrics", "diagnosticsMode", "preflight", "postInstall",
    "validationPods", "databaseUpgrade", "interactionapi", "integrationapi",
    "executionservice", "nodemanager", "queuereader", "realtimeapi",
    "callbackapi", "deploymentapi", "rebrandly", "observability", "redpointAI",
    "smartActivation", "authservice", "servicesapi", "socketio", "uiservice",
    "keycloak", "initservice", "messageq", "maintenanceservice", "cdpcache",
]

HEADER = """# ============================================================
# REDPOINT INTERACTION (RPI) - Values Reference
# ============================================================
# COMPLETE catalog of every configurable value and its default.
#
# GENERATED from the chart's effective defaults - do not edit by hand.
# Regenerate with: python3 docs/gen_values_reference.py
#
# Browse this file to see what you can configure, then copy only the
# keys you want to change into your own overrides file. You do not need
# to set everything here; the chart applies these defaults automatically.
# ============================================================
"""

_DUMP_TPL = """{{- $out := deepCopy .Values -}}
{{- $services := list %s -}}
{{- range $svc := $services -}}
{{- $_ := set $out $svc (fromYaml (include "rpi.merged.service" (dict "root" $ "name" $svc))) -}}
{{- end -}}
%s
apiVersion: v1
kind: ConfigMap
metadata:
  name: zzz-values-reference-dump
data:
  effective: |
{{ toYaml $out | indent 4 }}
"""


def render_effective() -> dict:
    svc_list = " ".join('"%s"' % s for s in SERVICES)
    cross = "\n".join(
        '{{- $_ := set $out "%s" (fromYaml (include "rpi.merged.%s" $)) -}}' % (c, c)
        for c in CROSSCUT
    )
    with open(DUMP_TEMPLATE, "w") as f:
        f.write(_DUMP_TPL % (svc_list, cross))
    try:
        out = subprocess.run(
            ["helm", "template", "t", CHART, "--show-only",
             "templates/zzz-values-reference-dump.yaml"],
            capture_output=True, text=True, check=True,
        ).stdout
    finally:
        if os.path.exists(DUMP_TEMPLATE):
            os.remove(DUMP_TEMPLATE)
    for doc in yaml.safe_load_all(out):
        if isinstance(doc, dict) and doc.get("kind") == "ConfigMap":
            return yaml.safe_load(doc["data"]["effective"])
    raise SystemExit("could not find the effective-values ConfigMap in helm output")


def build_desc(schema: dict) -> dict:
    desc: dict[str, str] = {}

    def walk(node, prefix=""):
        if not isinstance(node, dict):
            return
        for k, v in (node.get("properties") or {}).items():
            p = f"{prefix}.{k}" if prefix else k
            if isinstance(v, dict) and v.get("description"):
                desc[p] = v["description"]
            walk(v, p)
        items = node.get("items")
        if isinstance(items, dict):
            walk(items, prefix + "[]")

    walk(schema)
    return desc


def _placeholder(node):
    t = node.get("type")
    if isinstance(t, list):
        t = next((x for x in t if x != "null"), t[0] if t else "string")
    if t == "array":
        return []
    if t == "object":
        return {}
    if t == "boolean":
        return False
    if t in ("integer", "number"):
        return None
    return ""


def overlay_schema_only(tree: dict, schema: dict):
    """Add configurable keys the schema documents but the chart ships no
    default for (secrets, optional toggles, overrides) as empty placeholders,
    so the reference lists everything a user may set - not only defaulted keys.
    List-item ('[]') paths are skipped (the list default already shows shape)."""
    leaves: list[tuple[str, dict]] = []

    def walk(node, prefix=""):
        if not isinstance(node, dict):
            return
        props = node.get("properties")
        if props:
            for k, v in props.items():
                walk(v, f"{prefix}.{k}" if prefix else k)
        elif prefix and "$ref" not in node:
            leaves.append((prefix, node))

    walk(schema)
    for path, node in leaves:
        if "[]" in path:
            continue
        parts = path.split(".")
        cur = tree
        ok = True
        for seg in parts[:-1]:
            nxt = cur.get(seg)
            if nxt is None:
                nxt = {}
                cur[seg] = nxt
            if not isinstance(nxt, dict):
                ok = False
                break
            cur = nxt
        if ok and parts[-1] not in cur:
            cur[parts[-1]] = _placeholder(node)


def scalar(v) -> str:
    # Format a leaf value (scalar, or empty {}/[]) exactly as PyYAML would.
    dumped = yaml.safe_dump({"k": v}, default_flow_style=True,
                            allow_unicode=True, width=10 ** 9).strip()
    return dumped[1:-1].split(":", 1)[1].strip()


def order(keys, path):
    keys = list(keys)
    if path == "":
        rank = {name: i for i, name in enumerate(TOP_ORDER)}
        return sorted(keys, key=lambda k: (rank.get(k, len(TOP_ORDER)), k))
    return keys


def comment(text, indent):
    pad = "  " * indent
    return [f"{pad}# {line}" for line in textwrap.wrap(text, width=max(40, 92 - len(pad)))]


def emit(node, indent, path, lines, desc, top=False):
    for k in order(node.keys(), path):
        v = node[k]
        cp = f"{path}.{k}" if path else k
        if top:
            lines.append("")
        if cp in desc:
            lines += comment(desc[cp], indent)
        pad = "  " * indent
        if isinstance(v, dict) and v:
            lines.append(f"{pad}{k}:")
            emit(v, indent + 1, cp, lines, desc)
        elif isinstance(v, list) and v:
            lines.append(f"{pad}{k}:")
            emit_list(v, indent, cp, lines, desc)
        else:
            lines.append(f"{pad}{k}: {scalar(v)}")


def emit_list(lst, indent, path, lines, desc):
    pad = "  " * indent
    for item in lst:
        if isinstance(item, dict) and item:
            first = True
            for k in item:
                v = item[k]
                cp = f"{path}[].{k}"
                prefix = f"{pad}- " if first else f"{pad}  "
                if isinstance(v, dict) and v:
                    lines.append(f"{prefix}{k}:")
                    emit(v, indent + 2, cp, lines, desc)
                elif isinstance(v, list) and v:
                    lines.append(f"{prefix}{k}:")
                    emit_list(v, indent + 2, cp, lines, desc)
                else:
                    lines.append(f"{prefix}{k}: {scalar(v)}")
                first = False
        else:
            lines.append(f"{pad}- {scalar(item)}")


def main():
    if not os.path.isdir(CHART):
        raise SystemExit("run from the chart repo root (chart/ not found)")
    effective = render_effective()
    schema = yaml.safe_load(open(SCHEMA))
    overlay_schema_only(effective, schema)
    desc = build_desc(schema)
    lines: list[str] = [HEADER.rstrip("\n")]
    emit(effective, 0, "", lines, desc, top=True)
    text = "\n".join(lines).rstrip("\n") + "\n"
    yaml.safe_load(text)  # fail loudly if we produced invalid YAML
    with open(OUT, "w") as f:
        f.write(text)
    print(f"wrote {OUT}: {text.count(chr(10))} lines")


if __name__ == "__main__":
    main()
