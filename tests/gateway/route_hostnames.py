"""Every HTTPRoute in a rendered overlay names the hosts of the listeners it
attaches to. A route's hostnames intersect with its listener's, so equal ones
change nothing about routing, but put the host on the route itself.

    python3 route_hostnames.py overlay.yaml
"""

import re
import sys


def block(doc, key, indent):
    """The lines of `key:` at `indent` spaces, up to the next key at that indent."""
    lines, inside = [], False
    for line in doc.split("\n"):
        if line == " " * indent + key + ":":
            inside = True
        elif inside and (not line.startswith(" " * indent) or re.match(rf"^ {{{indent}}}\S", line) and not line.startswith(" " * indent + "- ")):
            break
        elif inside:
            lines.append(line)
    return lines


def items(lines, indent):
    """Each `- ` item of a list at `indent`, as a dict of its scalar fields."""
    out, current = [], None
    for line in lines:
        m = re.match(rf"^ {{{indent}}}- (\S+): (.*)$", line) or re.match(rf"^ {{{indent}}}  (\S+): (.*)$", line)
        if line.startswith(" " * indent + "- "):
            current = {}
            out.append(current)
        if m and current is not None:
            current[m[1]] = m[2].strip('"')
    return out


docs = open(sys.argv[1]).read().split("\n---\n")
kind = lambda d: (re.search(r"(?m)^kind: (\S+)$", d) or [None, None])[1]
meta = lambda d, f: (re.search(rf"(?m)^  {f}: (\S+)$", d.split("\nspec:", 1)[0]) or [None, None])[1]

listeners = {}
for d in docs:
    if kind(d) == "Gateway":
        for listener in items(block(d.split("\nstatus:", 1)[0], "listeners", 2), 2):
            listeners[(meta(d, "namespace"), meta(d, "name"), listener["name"])] = listener.get("hostname")

problems, attachments = [], 0
for d in docs:
    if kind(d) != "HTTPRoute":
        continue
    namespace, name = meta(d, "namespace"), meta(d, "name")
    hostnames = [re.sub(r"^ *- ", "", l).strip('"') for l in block(d, "hostnames", 2) if l.strip().startswith("- ")]
    if any("${" in h for h in hostnames):
        problems.append(f"{namespace}/{name}: unreplaced hostnames {hostnames}")
    for ref in items(block(d, "parentRefs", 2), 2):
        key = (ref.get("namespace", namespace), ref["name"], ref.get("sectionName"))
        if key not in listeners or listeners[key] is None:
            continue
        attachments += 1
        if hostnames != [listeners[key]]:
            problems.append(f"{namespace}/{name} -> {key[1]}/{key[2]} ({listeners[key]}): hostnames {hostnames}")

if problems or not attachments:
    print("\n".join(problems) or "no route is attached to a listener with a hostname")
    sys.exit(1)
print(f"{attachments} route attachments name their listener's host")
