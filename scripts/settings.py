#!/usr/bin/env python3
"""Adds or removes Agent Huddle's entries in a Claude Code settings file.

  settings.py install   [settings.json]   (default: ~/.claude/settings.json)
  settings.py uninstall [settings.json]

A dated backup of the file is made before any change.
"""
import json
import os
import shlex
import shutil
import sys
import time

HOME = os.path.expanduser("~")
BIN = os.path.join(HOME, ".claude", "huddle", "bin")
MARK = os.path.join(".claude", "huddle", "bin") + os.sep
PYTHON = "/usr/bin/python3"

ALLOW = ["Edit(~/claude-handoffs/**)", "Read(~/claude-handoffs/**)"]
# Sessions must not be able to write their own approvals.
DENY = ["Edit(~/.claude/huddle/**)"]


def command(script):
    return "%s %s" % (PYTHON, shlex.quote(os.path.join(BIN, script)))


def hook_groups():
    """Event name → the groups Agent Huddle adds to it."""
    def run(script, timeout):
        return {"type": "command", "command": command(script), "timeout": timeout}

    return {
        "PermissionRequest": [{"matcher": "*", "hooks": [run("huddle_hook.py", 600)]}],
        "PostToolUse": [{"matcher": "WebSearch|WebFetch", "hooks": [run("evidence.py", 15)]}],
        "Stop": [{"hooks": [run("handoff.py", 15)]}, {"hooks": [run("evidence.py", 15)]}],
        "PreCompact": [{"hooks": [run("handoff.py", 60)]}],
        "SessionStart": [{"hooks": [run("handoff.py", 15)]}],
    }


def ours(text):
    return MARK in (text or "")


def strip(settings):
    hooks = settings.get("hooks") or {}
    for event in list(hooks):
        kept = []
        for group in hooks[event]:
            handlers = [h for h in group.get("hooks", []) if not ours(h.get("command"))]
            if handlers:
                kept.append(dict(group, hooks=handlers))
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if "hooks" in settings and not hooks:
        del settings["hooks"]
    if ours((settings.get("statusLine") or {}).get("command")):
        del settings["statusLine"]
    permissions = settings.get("permissions") or {}
    for key, rules in (("allow", ALLOW), ("deny", DENY)):
        if key in permissions:
            permissions[key] = [r for r in permissions[key] if r not in rules]
            if not permissions[key]:
                del permissions[key]
    if "permissions" in settings and not permissions:
        del settings["permissions"]


def install(settings):
    """Returns a list of notes for the person."""
    notes = []
    strip(settings)
    hooks = settings.setdefault("hooks", {})
    for event, groups in hook_groups().items():
        hooks.setdefault(event, []).extend(groups)
    if "statusLine" in settings:
        notes.append("You already have a status line, so it was left alone. Usage limits and exact context "
                     "percentages will not show until the status line runs %s." % command("huddle_statusline.py"))
    else:
        settings["statusLine"] = {"type": "command", "command": command("huddle_statusline.py")}
    permissions = settings.setdefault("permissions", {})
    for key, rules in (("allow", ALLOW), ("deny", DENY)):
        current = permissions.setdefault(key, [])
        current.extend(r for r in rules if r not in current)
    return notes


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HOME, ".claude", "settings.json")
    if action not in ("install", "uninstall"):
        sys.exit(__doc__)
    settings = {}
    if os.path.exists(path):
        with open(path) as f:
            settings = json.load(f)
        shutil.copy2(path, "%s.huddle-backup-%s" % (path, time.strftime("%Y%m%d-%H%M%S")))
    notes = install(settings) if action == "install" else strip(settings) or []
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    print("Settings updated: %s" % path)
    for note in notes:
        print("Note: " + note)


if __name__ == "__main__":
    main()
