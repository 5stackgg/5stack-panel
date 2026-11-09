"""Fails when a rendered workload listens on the host's network, or on a
hostPort, on a port host_network_ports.txt doesn't allow, or when MediaMTX
isn't locked down.

    python3 -I host_network_ports.py host_network_ports.txt rendered.json

rendered.json is the manifests as `kubectl patch --local -o json` prints them:
one JSON object after another. A port passes when the list allows it for that
workload, or when a hostPort outside the host network is bound to a private
hostIP; on the host network a process binds wherever it likes, whatever its
hostIP says. MediaMTX's own ports pass when every authInternalUsers entry is
locked down, and that is checked whatever ports the pod declares.
"""

import ipaddress
import json
import os
import re
import subprocess
import sys
import tempfile

PRIVATE = [ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "::1/128", "fc00::/7")]
WORKLOAD_KINDS = {"Deployment", "DaemonSet", "StatefulSet", "ReplicaSet", "Job", "CronJob", "Pod"}
PASSWORD_ENV = re.compile(r"^MTX_AUTHINTERNALUSERS_(\d+)_PASS$")


def objects(path):
    raw, decoder, at, out = open(path).read(), json.JSONDecoder(), 0, []
    while True:
        while at < len(raw) and raw[at].isspace():
            at += 1
        if at >= len(raw):
            return out
        obj, at = decoder.raw_decode(raw, at)
        out.extend(obj.get("items", [obj]) if obj.get("kind") == "List" else [obj])


def allowlist(path):
    allowed = {}
    for line in open(path):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        workload, ports, _kind = line.split()[:3]
        for port in ports.split(","):
            number, protocol = port.split("/")
            low, _, high = number.partition("-")
            allowed.setdefault(workload, []).append((int(low), int(high or low), protocol.upper()))
    return allowed


def pod_spec(obj):
    spec = obj.get("spec", {})
    if obj["kind"] == "CronJob":
        spec = spec.get("jobTemplate", {}).get("spec", {})
    return spec if obj["kind"] == "Pod" else spec.get("template", {}).get("spec", {})


def private(address):
    try:
        network = ipaddress.ip_network(address, strict=False)
    except ValueError:
        return False
    return any(network.version == p.version and network.subnet_of(p) for p in PRIVATE)


def yaml_to_json(text):
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        f.write("apiVersion: v1\nkind: MediaMTXConfig\nmetadata:\n  name: mediamtx\n" + text)
    try:
        out = subprocess.run(["kubectl", "patch", "--local", "-o", "json", "--type", "merge", "-p", "{}", "-f", f.name],
                             capture_output=True, text=True, env=dict(os.environ, KUBECONFIG=os.devnull))
    finally:
        os.unlink(f.name)
    if out.returncode != 0:
        raise SystemExit(f"could not read the MediaMTX config: {out.stderr.strip()}")
    return json.loads(out.stdout)


def mediamtx_config(spec, by_name):
    for volume in spec.get("volumes", []):
        config_map = by_name.get(("ConfigMap", volume.get("configMap", {}).get("name")))
        for text in (config_map or {}).get("data", {}).values():
            if "authInternalUsers" in text:
                return yaml_to_json(text)
    return None


# Why MediaMTX lets in more than its users with passwords, one reason each.
def mediamtx_open(spec, by_name):
    config = mediamtx_config(spec, by_name)
    if config is None:
        return ["no authInternalUsers config is mounted"]
    reasons = []
    if config.get("authMethod", "internal") != "internal":
        reasons.append(f"authMethod is {config['authMethod']}, not internal")
    passwords = set()
    container = next((c for c in spec.get("containers", []) if c["name"] == "mediamtx"), spec["containers"][0])
    for env in container.get("env", []):
        if not env["name"].startswith("MTX_AUTH"):
            continue
        ref = env.get("valueFrom", {}).get("secretKeyRef")
        match = PASSWORD_ENV.match(env["name"])
        if match and ref and not ref.get("optional"):
            passwords.add(int(match[1]))
        else:
            reasons.append(f"{env['name']} is set in the environment, which could widen who it lets in")
    for source in container.get("envFrom", []):
        if "secretRef" in source:
            reasons.append(f"its environment comes from Secret {source['secretRef']['name']}, which could set MTX_AUTH*")
        config_map = by_name.get(("ConfigMap", source.get("configMapRef", {}).get("name")), {})
        reasons.extend(f"ConfigMap {config_map['metadata']['name']} sets {key}, which could widen who it lets in"
                       for key in config_map.get("data", {}) if key.startswith("MTX_AUTH"))
    users = config.get("authInternalUsers") or []
    if not users:
        reasons.append("authInternalUsers is empty, so MediaMTX's defaults apply")
    for index, user in enumerate(users):
        name = user.get("user")
        if name != "any" and (user.get("pass") or index in passwords):
            continue
        actions = sorted({p.get("action") for p in user.get("permissions") or []} & {"api", "publish"})
        ips = user.get("ips") or []
        if actions:
            reasons.append(f"authInternalUsers grants {name} {' and '.join(actions)} with no password")
        elif not ips:
            reasons.append(f"authInternalUsers lets {name} in from any address with no password")
        elif any(not private(str(ip)) for ip in ips):
            reasons.append(f"authInternalUsers lets {name} in from a public address with no password")
    return reasons


def main():
    allowed, rendered = allowlist(sys.argv[1]), objects(sys.argv[2])
    by_name = {(o["kind"], o["metadata"]["name"]): o for o in rendered}
    problems = []
    for obj in rendered:
        if obj["kind"] not in WORKLOAD_KINDS:
            continue
        workload = f"{obj['kind']}/{obj['metadata']['name']}"
        spec = pod_spec(obj)
        host_network = spec.get("hostNetwork", False)
        if host_network and workload not in allowed:
            problems.append(f"{workload} runs on the host network but host_network_ports.txt doesn't list it")
        open_reasons = None
        if obj["metadata"]["name"] == "mediamtx":
            open_reasons = mediamtx_open(spec, by_name)
            problems.extend(f"{workload}: {reason}" for reason in open_reasons)
        for container in spec.get("initContainers", []) + spec.get("containers", []):
            for port in container.get("ports", []):
                number = port.get("hostPort") or (port["containerPort"] if host_network else None)
                if number is None:
                    continue
                protocol = port.get("protocol", "TCP").upper()
                if any(low <= number <= high and protocol == p for low, high, p in allowed.get(workload, [])):
                    continue
                if not host_network and port.get("hostIP") and private(port["hostIP"]):
                    continue
                if open_reasons == []:
                    continue
                why = f", and {open_reasons[0]}" if open_reasons else " and nothing limits who reaches it"
                problems.append(f"{workload} listens on {number}/{protocol} on the host's network, which isn't "
                                f"an intended public port{why}")
    print("\n".join(problems) or f"{len(rendered)} objects: every host port is one host_network_ports.txt allows")
    sys.exit(1 if problems else 0)


main()
