#!/usr/bin/env python3
"""Generate docs/values_reference.yaml from the chart's effective defaults.

The reference is the COMPLETE catalog of every operator-overridable value
and its effective default - the surface a user browses to decide what to
put in their own overrides. It is generated, not hand-maintained, so it
never drifts from the chart.

Contract:
  values.yaml          defaults the chart deploys with no overrides
  _defaults.tpl        chart implementation defaults merged beneath them
  values.schema.json   the operator configuration contract (types + descriptions)
  values_reference     exactly the operator contract, with effective defaults

How it works:
  1. Render the chart's effective per-service + cross-cutting defaults
     (values.yaml merged with _defaults.tpl via the chart's own merge
     helpers) into a single values tree, using a throwaway template.
  2. Drop INTERNAL_PATHS: chart wiring the templates need but operators
     do not configure (service ports, probe endpoints, internal API paths).
  3. Overlay OPTIONAL_SCHEMA_PATHS: operator settings the schema documents
     but the chart ships no default for. Only the listed paths are
     overlaid; any other schema-only leaf aborts generation, so a schema
     entry can describe configuration but never introduce it.
  4. Pull each key's description from values.schema.json, following
     $ref and allOf.
  5. Emit a commented YAML reference.

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
    "networkPolicy", "databaseUpgrade",
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
    "customMetrics", "diagnosticsMode",
    "validationPods", "databaseUpgrade", "interactionapi", "integrationapi",
    "executionservice", "nodemanager", "queuereader", "realtimeapi",
    "callbackapi", "deploymentapi", "rebrandly", "redpointAI",
    "smartActivation", "authservice", "servicesapi", "socketio", "uiservice",
    "keycloak", "initservice", "messageq", "maintenanceservice", "cdpcache",
]

# Chart wiring that templates read but operators do not configure. These
# stay in _defaults.tpl and out of the reference and the schema.
INTERNAL_PATHS = {
    "authservice.service.port",
    "callbackapi.service.port",
    "cdpcache.service.port",
    "deploymentapi.service.port",
    "executionservice.service.port",
    "initservice.service.port",
    "integrationapi.service.port",
    "interactionapi.service.port",
    "keycloak.service.port",
    "nodemanager.service.port",
    "queuereader.service.port",
    "realtimeapi.service.port",
    "rebrandly.service.port",
    "servicesapi.service.port",
    "socketio.service.port",
    "uiservice.service.port",
    "maintenanceservice.port",
    "messageq.port",
    "ingress.service.port",
    "realtimeapi.name",
    "livenessProbe.httpGet.path",
    "livenessProbe.httpGet.port",
    "livenessProbe.httpGet.scheme",
    "readinessProbe.httpGet.path",
    "readinessProbe.httpGet.port",
    "readinessProbe.httpGet.scheme",
    "startupProbe.httpGet.path",
    "startupProbe.httpGet.port",
    "startupProbe.httpGet.scheme",
    "databaseUpgrade.deploymentapiHost",
    "databaseUpgrade.deploymentapiPort",
    "databaseUpgrade.healthPath",
    "databaseUpgrade.upgradePath",
    "diagnosticsMode.dotNetTools.path",
    "diagnosticsMode.dotNetTools.extractionBaseDir",
}

# Operator settings the schema documents but the chart ships no default
# for. They are overlaid as empty placeholders so the reference lists them.
# A schema-only leaf that is not listed here fails generation: either it
# is stale (remove it from the schema) or it is a new optional setting
# (add it here, deliberately).
OPTIONAL_SCHEMA_PATHS = {
    "nameOverride",
    "fullnameOverride",
    "global.deployment.images.overrides",
    "ingress.annotations",
    "OpenIdProviders.customScopes",
    "customCACerts.certFile",
    "databases.datawarehouse.snowflake.secretProviderClassName",
    "databases.operational.cloudSqlProxy.port",
    "deploymentapi.authentication.audience",
    "deploymentapi.authentication.clientId",
    "deploymentapi.authentication.hostAddress",
    "deploymentapi.authentication.issuer",
    "interactionapi.accountLockout.lockoutTimeSpan",
    "interactionapi.accountLockout.maxFailedAccessAttempts",
    "queuereader.realtimeConfiguration.tenantIds",
    "realtimeapi.customPlugins.list",
    "secretsManagement.sdk.useForAppSettings",
    "secretsManagement.sdk.useForConfigPasswords",
    "validationPods.deployments",
    "queuereader.internalCache.redisSettings.volumeClaimTemplates.storageClassName",
    "queuereader.internalCache.redisSettings.volumeClaimTemplates.accessModes",
    "queuereader.internalQueues.rabbitmqSettings.volumeClaimTemplates.storageClassName",
    "queuereader.internalQueues.rabbitmqSettings.volumeClaimTemplates.accessModes",
    "realtimeapi.queueProvider.rabbitmq.rabbitmqSettings.volumeClaimTemplates.storageClassName",
    "realtimeapi.queueProvider.rabbitmq.rabbitmqSettings.volumeClaimTemplates.accessModes",
    "securityContext.appArmorProfile",
    "resources.limits.cpu",
    "queuereader.internalCache.redisSettings.resources.limits.cpu",
    "queuereader.internalQueues.rabbitmqSettings.resources.limits.cpu",
    "realtimeapi.cacheProvider.redis.redisSettings.resources.limits.cpu",
    "authservice.resources.limits.cpu",
    "callbackapi.resources.limits.cpu",
    "cdpcache.resources.limits.cpu",
    "deploymentapi.resources.limits.cpu",
    "executionservice.resources.limits.cpu",
    "initservice.resources.limits.cpu",
    "integrationapi.resources.limits.cpu",
    "interactionapi.resources.limits.cpu",
    "keycloak.resources.limits.cpu",
    "maintenanceservice.resources.limits.cpu",
    "messageq.resources.limits.cpu",
    "nodemanager.resources.limits.cpu",
    "queuereader.resources.limits.cpu",
    "realtimeapi.resources.limits.cpu",
    "rebrandly.resources.limits.cpu",
    "servicesapi.resources.limits.cpu",
    "socketio.resources.limits.cpu",
    "uiservice.resources.limits.cpu",
}

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
            ["helm", "template", "t", CHART,
             "--namespace", "rpi-namespace", "--show-only",
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


def resolve(node, schema: dict):
    """Return node with $ref and allOf folded in, so properties and
    descriptions declared in shared definitions are visible at the
    referencing path. The referencing node's own keys win."""
    if not isinstance(node, dict):
        return node
    if "$ref" in node:
        target = schema
        for seg in node["$ref"].split("/")[1:]:
            target = target[seg]
        merged = dict(resolve(target, schema))
        merged.update({k: v for k, v in node.items() if k != "$ref"})
        return merged
    if "allOf" in node:
        merged = {k: v for k, v in node.items() if k != "allOf"}
        props = dict(merged.get("properties") or {})
        for part in node["allOf"]:
            part = resolve(part, schema)
            props.update(part.get("properties") or {})
            for k, v in part.items():
                if k != "properties" and k not in merged:
                    merged[k] = v
        merged["properties"] = props
        return merged
    return node


def build_desc(schema: dict) -> dict:
    desc: dict[str, str] = {}

    def walk(node, prefix=""):
        node = resolve(node, schema)
        if not isinstance(node, dict):
            return
        for k, v in (node.get("properties") or {}).items():
            p = f"{prefix}.{k}" if prefix else k
            v = resolve(v, schema)
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


def drop_internal(tree: dict):
    """Remove INTERNAL_PATHS from the effective tree, pruning any parent
    left empty. A listed path that is absent from the tree is reported so
    the list cannot silently go stale."""
    missing = []
    for path in sorted(INTERNAL_PATHS):
        parts = path.split(".")
        cur = tree
        chain = []
        for seg in parts[:-1]:
            if not isinstance(cur, dict) or seg not in cur:
                cur = None
                break
            chain.append((cur, seg))
            cur = cur[seg]
        if not isinstance(cur, dict) or parts[-1] not in cur:
            missing.append(path)
            continue
        del cur[parts[-1]]
        for parent, seg in reversed(chain):
            if parent[seg] == {}:
                del parent[seg]
            else:
                break
    if missing:
        print("INTERNAL_PATHS not present in the effective tree (stale list entry?):",
              file=sys.stderr)
        for p in missing:
            print(f"  {p}", file=sys.stderr)


def overlay_schema_only(tree: dict, schema: dict):
    """Add OPTIONAL_SCHEMA_PATHS - operator settings the schema documents
    but the chart ships no default for - as empty placeholders, so the
    reference lists everything a user may set, not only defaulted keys.
    Every overlaid path is logged. A schema-only leaf that is neither
    optional nor internal aborts generation: the schema may describe
    configuration but never introduce it. List-item ('[]') paths are
    skipped (the list default already shows shape)."""
    leaves: list[tuple[str, dict]] = []

    def walk(node, prefix=""):
        node = resolve(node, schema)
        if not isinstance(node, dict):
            return
        props = node.get("properties")
        if props:
            for k, v in props.items():
                walk(v, f"{prefix}.{k}" if prefix else k)
        elif prefix:
            leaves.append((prefix, node))

    walk(schema)
    overlaid: list[str] = []
    unclassified: list[str] = []
    for path, node in leaves:
        if "[]" in path:
            continue
        parts = path.split(".")
        if _present(tree, parts):
            continue
        if path in INTERNAL_PATHS:
            continue
        if path not in OPTIONAL_SCHEMA_PATHS:
            unclassified.append(path)
            continue
        cur = tree
        for seg in parts[:-1]:
            cur = cur.setdefault(seg, {})
        cur[parts[-1]] = _placeholder(node)
        overlaid.append(path)
    print(f"overlaid {len(overlaid)} schema-only optional path(s):", file=sys.stderr)
    for p in overlaid:
        print(f"  {p}", file=sys.stderr)
    if unclassified:
        print("schema-only leaf(s) with no chart default that are not listed in "
              "OPTIONAL_SCHEMA_PATHS or INTERNAL_PATHS - remove the stale schema "
              "entry, or list the path deliberately:", file=sys.stderr)
        for p in unclassified:
            print(f"  {p}", file=sys.stderr)
        raise SystemExit(1)


def _present(tree: dict, parts: list[str]) -> bool:
    """True when the path already resolves in the effective tree, or when
    an ancestor is a non-map (a scalar or list default owns the subtree)."""
    cur = tree
    for seg in parts[:-1]:
        if not isinstance(cur, dict) or seg not in cur:
            return False
        cur = cur[seg]
        if not isinstance(cur, dict):
            return True
    return isinstance(cur, dict) and parts[-1] in cur


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
                if cp in desc:
                    lines += comment(desc[cp], indent if first else indent + 1)
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
    drop_internal(effective)
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
