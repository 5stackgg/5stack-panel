"""Fails when a workload of a rendered overlay listens on the host's network on
a port host_network_ports.txt doesn't allow.

    python3 -I host_network_ports.py host_network_ports.txt rendered.json

rendered.json is the overlay as `kubectl patch --local -o json` prints it: one
JSON object after another. A port passes when the list allows it for that
workload, when the container binds it to a private hostIP, or, for MediaMTX,
when every authInternalUsers entry only lets in private addresses.
"""

import ipaddress
import json
import os
import subprocess
import sys
import tempfile

PRIVATE = [ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "::1/128", "fc00::/7")]
WORKLOAD_KINDS = {"Deployment", "DaemonSet", "StatefulSet", "ReplicaSet", "Job", "CronJob", "Pod"}


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


# None when every user is limited to private addresses; the node-addresses
# init container adds only the node's own.
def mediamtx_open(spec, by_name):
    for volume in spec.get("volumes", []):
        config_map = by_name.get(("ConfigMap", volume.get("configMap", {}).get("name")))
        for text in (config_map or {}).get("data", {}).values():
            if "authInternalUsers" not in text:
                continue
            users = yaml_to_json(text).get("authInternalUsers") or []
            if not users:
                return "authInternalUsers is empty, so MediaMTX's defaults apply"
            for user in users:
                ips = user.get("ips") or []
                if not ips:
                    return f"authInternalUsers lets {user.get('user')} in from any address"
                public = [ip for ip in ips if not private(str(ip))]
                if public:
                    return f"authInternalUsers lets {user.get('user')} in from {', '.join(map(str, public))}"
            return None
    return "no authInternalUsers config is mounted"


def main():
    allowed, rendered = allowlist(sys.argv[1]), objects(sys.argv[2])
    by_name = {(o["kind"], o["metadata"]["name"]): o for o in rendered}
    known = set(allowed)
    problems = []
    for obj in rendered:
        if obj["kind"] not in WORKLOAD_KINDS:
            continue
        workload = f"{obj['kind']}/{obj['metadata']['name']}"
        spec = pod_spec(obj)
        host_network = spec.get("hostNetwork", False)
        if host_network and workload not in known:
            problems.append(f"{workload} runs on the host network but host_network_ports.txt doesn't list it")
        open_reason = "unchecked"
        for container in spec.get("initContainers", []) + spec.get("containers", []):
            for port in container.get("ports", []):
                number = port.get("hostPort") or (port["containerPort"] if host_network else None)
                if number is None:
                    continue
                protocol = port.get("protocol", "TCP").upper()
                if any(low <= number <= high and protocol == p for low, high, p in allowed.get(workload, [])):
                    continue
                if port.get("hostIP") and private(port["hostIP"]):
                    continue
                if obj["metadata"]["name"] == "mediamtx":
                    if open_reason == "unchecked":
                        open_reason = mediamtx_open(spec, by_name)
                    if open_reason is None:
                        continue
                    problems.append(f"{workload} listens on {number}/{protocol} on the host's network, which isn't "
                                    f"an intended public port, and {open_reason}")
                    continue
                problems.append(f"{workload} listens on {number}/{protocol} on the host's network, which isn't "
                                f"an intended public port and nothing limits who reaches it")
    print("\n".join(problems) or f"{len(rendered)} objects: every host port is one host_network_ports.txt allows")
    sys.exit(1 if problems else 0)


main()
