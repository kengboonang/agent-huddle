#!/usr/bin/env python3
"""Agent Huddle status line.

Claude Code sends session data (context use, cost, rate limits) to the status
line command. This script saves that data where the Agent Huddle widget and the
handoff hook can read it, then prints a short status line.
"""
import json
import os
import sys
import time

STATUS = os.path.join(os.path.expanduser("~"), ".claude", "huddle", "status")
KEEP = ("session_id", "session_name", "transcript_path", "cwd", "model", "cost", "context_window", "rate_limits")


def clock(epoch):
    return time.strftime("%H:%M", time.localtime(epoch))


def line(data, now):
    parts = []
    model = (data.get("model") or {}).get("display_name")
    if model:
        parts.append(model)
    used = (data.get("context_window") or {}).get("used_percentage")
    if used is not None:
        parts.append("ctx %d%%" % round(used))
    limits = data.get("rate_limits") or {}
    for key, label in (("five_hour", "5h"), ("seven_day", "wk"), ("spend_limit", "spend")):
        window = limits.get(key) or {}
        if window.get("used_percentage") is None:
            continue
        text = "%s %d%%" % (label, round(window["used_percentage"]))
        resets = window.get("resets_at")
        if key == "five_hour" and resets and resets > now:
            text += " (resets %s)" % clock(resets)
        parts.append(text)
    return " | ".join(parts)


def save(data, now):
    session = data.get("session_id")
    if not session or "/" in session:
        return
    os.makedirs(STATUS, mode=0o700, exist_ok=True)
    record = {key: data[key] for key in KEEP if key in data}
    record["_updated_at"] = now
    path = os.path.join(STATUS, session + ".json")
    tmp = path + ".tmp"
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        json.dump(record, f)
    os.replace(tmp, path)


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    now = time.time()
    try:
        save(data, now)
    except OSError:
        pass
    print(line(data, now))


if __name__ == "__main__":
    main()
