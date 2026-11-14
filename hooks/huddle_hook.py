#!/usr/bin/env python3
"""Agent Huddle permission hook.

Claude Code runs this on every PermissionRequest. It hands the request to the
Agent Huddle widget through a file, waits for the person's answer, and prints
the decision. When the widget is not running it prints nothing, so Claude Code
asks in the session as usual.
"""
import json
import os
import signal
import sys
import time
import uuid

BASE = os.path.join(os.path.expanduser("~"), ".claude", "huddle")
PENDING = os.path.join(BASE, "pending")
RESPONSES = os.path.join(BASE, "responses")
HEARTBEAT = os.path.join(BASE, "app.heartbeat")
WAIT_SECONDS = float(os.environ.get("HUDDLE_WAIT_SECONDS", "590"))
HEARTBEAT_MAX_AGE = 6
POLL_SECONDS = 0.2


def app_alive():
    try:
        return time.time() - os.path.getmtime(HEARTBEAT) < HEARTBEAT_MAX_AGE
    except OSError:
        return False


def write_private(path, payload):
    tmp = path + ".tmp"
    with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        json.dump(payload, f)
    os.replace(tmp, path)


def remove(*paths):
    for path in paths:
        try:
            os.remove(path)
        except OSError:
            pass


class TranscriptWatch:
    """Notices when the same request was answered in the session itself."""

    def __init__(self, path, tool_name, tool_input):
        self.path = path
        self.tool_name = tool_name
        self.tool_input = tool_input
        self.candidates = set()
        self.offset = 0
        try:
            self.offset = max(0, os.path.getsize(path) - 2_000_000)
        except OSError:
            self.path = None
            return
        self.scan()

    def blocks(self):
        with open(self.path, "rb") as f:
            f.seek(self.offset)
            chunk = f.read()
        end = chunk.rfind(b"\n") + 1
        self.offset += end
        for raw in chunk[:end].split(b"\n"):
            if b'"tool_use' not in raw:
                continue
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(entry, dict) or entry.get("type") not in ("user", "assistant"):
                continue
            content = (entry.get("message") or {}).get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict):
                        yield block

    def scan(self):
        resolved = False
        for block in self.blocks():
            if (block.get("type") == "tool_use" and block.get("name") == self.tool_name
                    and block.get("input") == self.tool_input):
                self.candidates.add(block.get("id"))
            elif block.get("type") == "tool_result" and block.get("tool_use_id") in self.candidates:
                self.candidates.discard(block.get("tool_use_id"))
                resolved = True
        return resolved

    def answered_elsewhere(self):
        if not self.path:
            return False
        try:
            return self.scan()
        except OSError:
            return False


def decision_output(response):
    """Turns the widget's answer file into the JSON Claude Code expects, or None."""
    if not isinstance(response, dict) or response.get("behavior") not in ("allow", "deny"):
        return None
    decision = {"behavior": response["behavior"]}
    if response["behavior"] == "allow":
        if response.get("updatedInput") is not None:
            decision["updatedInput"] = response["updatedInput"]
        if response.get("updatedPermissions"):
            decision["updatedPermissions"] = response["updatedPermissions"]
    else:
        decision["message"] = response.get("message") or "The user denied this in Agent Huddle."
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if not app_alive():
        return

    for path in (BASE, PENDING, RESPONSES):
        os.makedirs(path, mode=0o700, exist_ok=True)
    request_id = uuid.uuid4().hex
    pending_path = os.path.join(PENDING, request_id + ".json")
    response_path = os.path.join(RESPONSES, request_id + ".json")

    def stop(*_):
        remove(pending_path, response_path)
        sys.exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    tool_input = data.get("tool_input") or {}
    write_private(pending_path, {
        "id": request_id,
        "sessionId": data.get("session_id"),
        "cwd": data.get("cwd"),
        "toolName": data.get("tool_name"),
        "toolInput": tool_input,
        "suggestions": data.get("permission_suggestions") or [],
        "agentType": data.get("agent_type"),
        "createdAt": time.time(),
        "hookPid": os.getpid(),
    })

    watch = TranscriptWatch(data.get("transcript_path") or "", data.get("tool_name"), tool_input)
    next_watch = time.time() + 1
    response = None
    deadline = time.time() + WAIT_SECONDS
    try:
        while time.time() < deadline:
            if os.path.exists(response_path):
                try:
                    with open(response_path) as f:
                        response = json.load(f)
                except ValueError:
                    response = None
                break
            if not app_alive():
                break
            if time.time() >= next_watch:
                if watch.answered_elsewhere():
                    break
                next_watch = time.time() + 1
            time.sleep(POLL_SECONDS)
    finally:
        remove(pending_path, response_path)

    output = decision_output(response)
    if output:
        print(json.dumps(output))


if __name__ == "__main__":
    main()
