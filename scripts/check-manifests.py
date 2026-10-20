#!/usr/bin/env python3
"""Render the chart for every ci/*-values.yaml and check what `helm lint` cannot.

Failure modes that render "successfully", parse as YAML, and only show up at
apply time - or never:
  * a right-chomped action (`-}}`) directly above a literal `---` glues two
    documents together; the later root keys win and a manifest disappears
    silently. Only duplicate keys give it away, hence the strict loader;
  * a bare `{{ required ... }}` leaking its value into the manifest, leaving a
    document without apiVersion/kind;
  * a volumeMount naming a volume the pod never declares;
  * a Service selector or a PDB selector that matches no pod template;
  * a label or annotation value that is not a string - an unquoted release
    name such as `n`, `y` or `on` is a YAML 1.1 boolean, which the API
    server rejects. Every case renders as release `on` for that reason (PyYAML
    reads `on` as a boolean, but not `n`).

ci/fail/*.yaml are the opposite: each must FAIL to render, with the message
given on its first line (`# expect: <substring>`), so the guards stay guards.

Usage: check-manifests.py <chart-dir>
"""
import pathlib
import subprocess
import sys

import yaml


class StrictLoader(yaml.SafeLoader):
    """SafeLoader that refuses duplicate mapping keys."""


def _no_dupes(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                None, None, f"duplicate key {key!r}", key_node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_dupes)

WORKLOADS = ("Deployment", "StatefulSet", "DaemonSet")


def _metadatas(obj):
    """Every `metadata` mapping in a manifest (pod templates, PVC templates...)."""
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key == "metadata" and isinstance(value, dict):
                yield value
            yield from _metadatas(value)
    elif isinstance(obj, list):
        for item in obj:
            yield from _metadatas(item)


def check(name, docs):
    errors = []
    pods = []
    for doc in docs:
        if not doc:
            continue
        if not doc.get("apiVersion") or not doc.get("kind"):
            errors.append(f"document without apiVersion/kind, keys={sorted(doc)[:4]}")
            continue
        kind = doc["kind"]
        for meta in _metadatas(doc):
            for field in ("labels", "annotations"):
                for key, value in (meta.get(field) or {}).items():
                    if not isinstance(value, str):
                        errors.append(f"{kind} {doc['metadata'].get('name')}: {field[:-1]} {key}={value!r} is not a string")
        if kind in WORKLOADS or kind == "Pod":
            tmpl = doc["spec"]["template"] if kind in WORKLOADS else doc
            spec = tmpl["spec"]
            declared = {v["name"] for v in spec.get("volumes", [])}
            declared |= {v["metadata"]["name"] for v in doc["spec"].get("volumeClaimTemplates", [])}
            for c in spec.get("containers", []) + spec.get("initContainers", []):
                for m in c.get("volumeMounts", []):
                    if m["name"] not in declared:
                        errors.append(f"{doc['metadata']['name']}/{c['name']} mounts undeclared volume {m['name']!r}")
            if kind in WORKLOADS:
                sel = doc["spec"]["selector"]["matchLabels"]
                labels = tmpl["metadata"]["labels"]
                if any(labels.get(k) != v for k, v in sel.items()):
                    errors.append(f"{kind} selector {sel} does not match its own pod labels")
                pods.append(labels)
    for doc in docs:
        if not doc or doc.get("kind") not in ("Service", "PodDisruptionBudget"):
            continue
        sel = doc["spec"].get("selector") or {}
        sel = sel.get("matchLabels", sel)
        if sel and not any(all(p.get(k) == v for k, v in sel.items()) for p in pods):
            errors.append(f"{doc['kind']} {doc['metadata']['name']} selects no pod")
    return errors


def main():
    chart = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "charts/chrony")
    rc = 0
    for values in sorted((chart / "ci").glob("*-values.yaml")):
        name = values.name.removesuffix("-values.yaml")
        out = subprocess.run(["helm", "template", "on", str(chart), "-f", str(values)],
                             capture_output=True, text=True)
        if out.returncode:
            print(f"FAIL  {name}: render error\n{out.stderr.strip()}")
            rc = 1
            continue
        try:
            docs = list(yaml.load_all(out.stdout, Loader=StrictLoader))
        except yaml.YAMLError as exc:
            print(f"FAIL  {name}: {exc} - merged documents? check for `-}}}}` above a literal ---")
            rc = 1
            continue
        errors = check(name, docs)
        for e in errors:
            print(f"FAIL  {name}: {e}")
        if errors:
            rc = 1
        else:
            print(f"ok    {name}")
    for values in sorted((chart / "ci" / "fail").glob("*.yaml")):
        name = f"fail/{values.stem}"
        expect = values.read_text().splitlines()[0].removeprefix("# expect:").strip()
        out = subprocess.run(["helm", "template", "on", str(chart), "-f", str(values)],
                             capture_output=True, text=True)
        if out.returncode == 0:
            print(f"FAIL  {name}: rendered, expected an error containing {expect!r}")
            rc = 1
        elif expect not in out.stderr:
            print(f"FAIL  {name}: wrong error\n{out.stderr.strip()}")
            rc = 1
        else:
            print(f"ok    {name} (refused)")
    sys.exit(rc)


if __name__ == "__main__":
    main()
