import json
import sys

ARCHES = {"amd64", "arm64"}
ARCH_NAMES = {"SCMP_ARCH_X86_64", "SCMP_ARCH_AARCH64"}
NAMESPACES_LEFT_DENIED = 0x00020000 | 0x02000000 | 0x04000000 | 0x08000000

upstream = json.load(open(sys.argv[1]))
rules = []
for rule in upstream["syscalls"]:
    includes = rule.get("includes") or {}
    excludes = rule.get("excludes") or {}
    if includes.get("caps"):
        continue
    if includes.get("arches") and not ARCHES & set(includes["arches"]):
        continue
    if excludes.get("arches") and ARCHES <= set(excludes["arches"]):
        continue
    names = [name for name in rule["names"] if name not in ("clone", "unshare", "chroot")]
    if not names:
        continue
    kept = {"names": names, "action": rule["action"]}
    for key in ("errnoRet", "args"):
        if rule.get(key) is not None:
            kept[key] = rule[key]
    rules.append(kept)

namespace_args = [
    {"index": 0, "value": NAMESPACES_LEFT_DENIED, "valueTwo": 0, "op": "SCMP_CMP_MASKED_EQ"}
]
rules.append({"names": ["clone", "unshare"], "action": "SCMP_ACT_ALLOW", "args": namespace_args})
rules.append({"names": ["chroot"], "action": "SCMP_ACT_ALLOW"})

profile = {
    "defaultAction": upstream["defaultAction"],
    "defaultErrnoRet": upstream["defaultErrnoRet"],
    "archMap": [arch for arch in upstream["archMap"] if arch["architecture"] in ARCH_NAMES],
    "syscalls": rules,
}
json.dump(profile, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
