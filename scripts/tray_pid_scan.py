#!/usr/bin/env python3
"""Tray-to-PID resolver for UnifiedAppTray.

Lists every StatusNotifierItem registered on the session bus, resolves the
owning connection to a PID, expands that PID to its full process subtree,
and emits one tab-separated line per item:

    <id>\x1f<title>\x1f<tooltip_title>\t<pid,pid,...>\t<hint,hint,...>

The key columns match UnifiedAppTrayWidget.trayItemKey() (id + US + title +
US + tooltip title) so the QML side can join scan output back onto live
tray items. Duplicate keys are emitted twice on purpose; the QML parser
drops duplicates (ambiguous matches are safer discarded than guessed).

Generic process names (node, python, sh...) are filtered out of the hint
column so they cannot pollute the app_id scoring.

Cost: one busctl call per tray item. Run from the widget's Process {} on a
slow interval; ~0.1s for a typical 3-item tray.
"""

import json
import os
import re
import subprocess
import sys

SNI = "org.kde.StatusNotifierItem"
SEP = chr(31)
GENERIC = set(["electron", "node", "nodejs", "python", "python3", "sh",
               "bash", "zsh", "dash", "env", "wrapper", "sleep", "cat",
               "app", "main", "exe"])


def norm(s):
    return re.sub("[^a-z0-9]+", "", (s or "").lower())


def bus(args):
    try:
        r = subprocess.run(["busctl", "--user", "--json=short"] + args,
                            capture_output=True, text=True, timeout=2)
        if r.returncode != 0:
            return None
        return json.loads(r.stdout)
    except Exception:
        return None


def conn_pid(svc):
    j = bus(["call", "org.freedesktop.DBus", "/org/freedesktop/DBus",
             "org.freedesktop.DBus", "GetConnectionUnixProcessID", "s", svc])
    try:
        d = j["data"]
        return int(d[0] if isinstance(d, list) else d)
    except Exception:
        return None


def get_all(svc, path):
    j = bus(["call", svc, path, "org.freedesktop.DBus.Properties",
             "GetAll", "s", SNI])
    try:
        return j["data"][0]
    except Exception:
        return {}


def val(d, k):
    v = d.get(k)
    return v.get("data") if isinstance(v, dict) else None


def clean(s):
    if s is None:
        return ""
    s = str(s)
    for c in (chr(31), chr(9), chr(10), chr(13)):
        s = s.replace(c, " ")
    return s


def child_map():
    cm = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            fh = open("/proc/" + pid + "/stat")
            data = fh.read()
            fh.close()
            ppid = int(data.rsplit(")", 1)[1].split()[1])
            cm.setdefault(ppid, []).append(int(pid))
        except Exception:
            pass
    return cm


def subtree(root_pid, cm):
    seen = set()
    stack = [root_pid]
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        stack.extend(cm.get(p, []))
    return sorted(seen)


def proc_names(pid):
    names = []
    try:
        fh = open("/proc/" + str(pid) + "/comm")
        names.append(fh.read().strip())
        fh.close()
    except Exception:
        pass
    try:
        names.append(os.path.basename(os.readlink("/proc/" + str(pid) + "/exe")))
    except Exception:
        pass
    return names


def main():
    j = bus(["get-property", "org.kde.StatusNotifierWatcher",
             "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
             "RegisteredStatusNotifierItems"])
    try:
        entries = j["data"]
    except Exception:
        entries = []
    cm = child_map()
    out = []
    for e in entries:
        try:
            if "/" in e:
                svc, path = e.split("/", 1)
                path = "/" + path
            else:
                svc = e
                path = "/StatusNotifierItem"
            pid = conn_pid(svc)
            if pid is None:
                continue
            d = get_all(svc, path)
            iid = clean(val(d, "Id"))
            title = clean(val(d, "Title"))
            tt = val(d, "ToolTip")
            tttitle = clean(tt[2]) if isinstance(tt, list) and len(tt) > 2 else ""
            pids = subtree(pid, cm)
            hints = set()
            for p in pids:
                for nm in proc_names(p):
                    n = norm(nm)
                    if len(n) >= 2 and n not in GENERIC:
                        hints.add(n)
            key = iid + SEP + title + SEP + tttitle
            out.append(key + chr(9) + ",".join(str(x) for x in pids) + chr(9) + ",".join(sorted(hints)))
        except Exception:
            pass
    sys.stdout.write(chr(10).join(out))


if __name__ == "__main__":
    main()
