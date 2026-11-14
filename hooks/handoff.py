#!/usr/bin/env python3
"""Automatic handoff documents for Claude Code sessions.

One script, three hooks:

  Stop          When the context window passes a threshold, asks Claude to write
                (or update) a handoff document before it finishes the turn.
  PreCompact    Always saves an automatic snapshot built from the transcript, so
                something exists even if Claude never wrote a handoff. Also tells
                the compaction summary what to keep.
  SessionStart  After a compaction, gives the handoff back to Claude. In a new
                session, points Claude at the latest handoff for the folder.

Documents are kept in ~/claude-handoffs/<project>/<session id>/.
"""
import json
import os
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
ROOT = os.environ.get("HANDOFF_DIR") or os.path.join(HOME, "claude-handoffs")
STATUS = os.path.join(HOME, ".claude", "huddle", "status")
FIRST_THRESHOLD = float(os.environ.get("HANDOFF_THRESHOLD", "70"))
UPDATE_THRESHOLD = float(os.environ.get("HANDOFF_UPDATE_THRESHOLD", "85"))
DEFAULT_WINDOW = int(os.environ.get("HANDOFF_CONTEXT_WINDOW", "200000"))
STATUS_MAX_AGE = 900
POINTER_MAX_AGE = 7 * 86400
INJECT_LIMIT = 9000

SECTIONS = """\
# Handoff: <one-line title>
## Goal
What the user is trying to achieve, in their terms, and what done looks like.
## Current state
What is finished, what is half done, and what has not been started.
## Decisions and why
Each choice that was made, the reason, and anything the user ruled out.
## Key files and commands
Exact paths, and the exact commands to build, run and test.
## Tried and failed
Approaches that did not work, with the error text, so they are not repeated.
## Next steps
An ordered list. The first item is the very next action.
## Open questions for the user
"""


def slug(cwd):
    return re.sub(r"[^A-Za-z0-9]", "-", cwd or "unknown").strip("-") or "unknown"


def session_dir(cwd, session_id):
    return os.path.join(ROOT, slug(cwd), re.sub(r"[^A-Za-z0-9_-]", "", session_id or "unknown"))


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def entries(path, tail_bytes=None):
    """Yields the user and assistant lines of the main conversation."""
    try:
        with open(path, "rb") as f:
            if tail_bytes:
                f.seek(0, os.SEEK_END)
                start = max(0, f.tell() - tail_bytes)
                f.seek(start)
                if start:
                    f.readline()
            for raw in f:
                if b'"type":"user"' not in raw and b'"type":"assistant"' not in raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                if (isinstance(entry, dict) and entry.get("type") in ("user", "assistant")
                        and not entry.get("isSidechain")):
                    yield entry
    except OSError:
        return


def context_percent(data, now=None):
    """How full the context window is, 0 to 100, or None when it cannot be told."""
    now = now or time.time()
    session = data.get("session_id") or ""
    saved = read_json(os.path.join(STATUS, session + ".json")) if session else None
    window = DEFAULT_WINDOW
    # A model setting that ends in [1m] means the 1M-token context window.
    if "[1m]" in str((read_json(os.path.join(HOME, ".claude", "settings.json")) or {}).get("model", "")):
        window = max(window, 1_000_000)
    if saved:
        context = saved.get("context_window") or {}
        if context.get("context_window_size"):
            window = context["context_window_size"]
        fresh = now - (saved.get("_updated_at") or 0) < STATUS_MAX_AGE
        if fresh and context.get("used_percentage") is not None:
            return float(context["used_percentage"])
    tokens = None
    for entry in entries(data.get("transcript_path") or "", tail_bytes=400_000):
        usage = (entry.get("message") or {}).get("usage")
        if entry["type"] == "assistant" and usage:
            tokens = sum(usage.get(key) or 0 for key in
                         ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    if tokens is None:
        return None
    return 100.0 * tokens / window


# ---- Stop: ask Claude to write the handoff ---------------------------------

def stage_for(percent):
    if percent >= UPDATE_THRESHOLD:
        return 2
    if percent >= FIRST_THRESHOLD:
        return 1
    return 0


def on_stop(data):
    if data.get("stop_hook_active"):
        return None
    percent = context_percent(data)
    if percent is None:
        return None
    folder = session_dir(data.get("cwd"), data.get("session_id"))
    state_path = os.path.join(folder, "state.json")
    state = read_json(state_path) or {}
    stage = stage_for(percent)
    asked = state.get("stage", 0)
    if stage < asked:
        # The context shrank, so a compaction or /clear happened. Start again.
        write_text(state_path, json.dumps({"stage": stage, "percent": percent}))
        return None
    if stage == 0 or stage == asked:
        return None
    write_text(state_path, json.dumps({"stage": stage, "percent": percent, "asked_at": time.time()}))
    path = os.path.join(folder, "handoff.md")
    remember_latest(data.get("cwd"), folder)
    if stage == 1 or not os.path.exists(path):
        ask = ("The context window is %d%% full. Before you finish this turn, write a handoff document to %s "
               "so that a fresh session could continue this work without this conversation. "
               "Use this outline:\n\n%s\nBe specific: exact file paths, commands and error text. "
               "Keep it under 150 lines. Write only what you have verified in this session. "
               "Then tell the user in one line where the handoff is.") % (round(percent), path, SECTIONS)
    else:
        ask = ("The context window is %d%% full and may be compacted soon. Before you finish this turn, "
               "bring the handoff document at %s up to date with everything that changed since you wrote it. "
               "Then tell the user in one line that it is current.") % (round(percent), path)
    return {"hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": ask}}


# ---- PreCompact: automatic snapshot ----------------------------------------

def clean(text, limit):
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[:limit] + "…"


def user_text(entry):
    if entry.get("isMeta"):
        return None
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, list):
        content = " ".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    if not isinstance(content, str):
        return None
    content = content.strip()
    return content if content and not content.startswith("<") else None


def git(cwd, *args):
    try:
        out = subprocess.run(("git",) + args, cwd=cwd, capture_output=True, text=True, timeout=5)
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def build_snapshot(data, now=None):
    """A handoff made only from what the transcript and git record. No model is involved."""
    prompts, files, failed, replies, todos = [], [], [], [], None
    calls = {}
    for entry in entries(data.get("transcript_path") or ""):
        message = entry.get("message") or {}
        if entry["type"] == "user":
            text = user_text(entry)
            if text:
                prompts.append(text)
            content = message.get("content")
            for block in content if isinstance(content, list) else []:
                if isinstance(block, dict) and block.get("type") == "tool_result" and block.get("is_error"):
                    call = calls.get(block.get("tool_use_id"))
                    if call:
                        result = block.get("content")
                        if isinstance(result, list):
                            result = " ".join(b.get("text", "") for b in result if isinstance(b, dict))
                        failed.append((call, clean(str(result or ""), 300)))
            continue
        for block in message.get("content") or []:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text" and block.get("text", "").strip():
                replies.append(block["text"].strip())
            elif block.get("type") == "tool_use":
                name, tool_input = block.get("name"), block.get("input") or {}
                if name in ("Edit", "Write", "NotebookEdit"):
                    path = tool_input.get("file_path") or tool_input.get("notebook_path")
                    if path and path not in files:
                        files.append(path)
                elif name == "Bash":
                    calls[block.get("id")] = clean(tool_input.get("command", ""), 200)
                elif name == "TodoWrite":
                    todos = tool_input.get("todos")

    cwd = data.get("cwd") or ""
    lines = ["# Automatic snapshot",
             "",
             "Saved %s, just before the conversation was compacted (%s)." % (
                 time.strftime("%Y-%m-%d %H:%M", time.localtime(now or time.time())), data.get("trigger") or "auto"),
             "Built by a script from the transcript. It records what happened, not why.",
             "",
             "- Folder: `%s`" % cwd,
             "- Session: `%s`" % (data.get("session_id") or ""),
             "- Full transcript: `%s`" % (data.get("transcript_path") or ""),
             ""]
    if prompts:
        lines += ["## What the user asked for first", "", clean(prompts[0], 1500), ""]
        later = prompts[1:][-12:]
        if later:
            lines += ["## Later requests from the user (most recent last)", ""]
            lines += ["- " + clean(p, 400) for p in later] + [""]
    if todos:
        lines += ["## Task list when the snapshot was taken", ""]
        lines += ["- [%s] %s" % ({"completed": "x", "in_progress": "~"}.get(t.get("status"), " "),
                                 clean(t.get("content", ""), 200)) for t in todos if isinstance(t, dict)] + [""]
    if files:
        lines += ["## Files Claude edited or created", ""] + ["- `%s`" % f for f in files[-40:]] + [""]
    if failed:
        lines += ["## Commands that failed (most recent last)", ""]
        lines += ["- `%s`: %s" % pair for pair in failed[-8:]] + [""]
    if replies:
        lines += ["## Claude's last messages", ""] + ["> " + clean(r, 1200) + "\n" for r in replies[-3:]]
    branch = git(cwd, "rev-parse", "--abbrev-ref", "HEAD") if cwd else ""
    if branch:
        lines += ["## Git", "", "Branch: `%s`" % branch, ""]
        status = git(cwd, "status", "--short")
        if status:
            lines += ["```", "\n".join(status.splitlines()[:40]), "```", ""]
    return "\n".join(lines).rstrip() + "\n"


def on_precompact(data):
    folder = session_dir(data.get("cwd"), data.get("session_id"))
    write_text(os.path.join(folder, "snapshot.md"), build_snapshot(data))
    write_text(os.path.join(folder, "state.json"), json.dumps({"stage": 0}))
    remember_latest(data.get("cwd"), folder)
    handoff = os.path.join(folder, "handoff.md")
    kept = handoff if os.path.exists(handoff) else os.path.join(folder, "snapshot.md")
    # For PreCompact, plain output becomes instructions for the compaction summary.
    return ("In the summary, keep: the user's goal in their own words, every decision and its reason, "
            "what is finished and what is not, exact file paths and commands, approaches that failed, "
            "and the next step. A handoff document for this session is saved at %s." % kept)


# ---- SessionStart: give the handoff back -----------------------------------

def remember_latest(cwd, folder):
    write_text(os.path.join(ROOT, slug(cwd), "latest"), folder)


def read_capped(path, limit):
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return ""
    if len(text) > limit:
        text = text[:limit] + "\n… (cut here; the full file is at %s)" % path
    return text


def on_session_start(data, now=None):
    now = now or time.time()
    source = data.get("source")
    if source == "compact":
        folder = session_dir(data.get("cwd"), data.get("session_id"))
        handoff = read_capped(os.path.join(folder, "handoff.md"), 6000)
        snapshot = read_capped(os.path.join(folder, "snapshot.md"), INJECT_LIMIT - len(handoff) - 500)
        if not handoff and not snapshot:
            return None
        parts = ["The conversation was just compacted. These notes were saved before that, in %s." % folder]
        if handoff:
            parts.append("Handoff document you wrote earlier:\n\n" + handoff)
        if snapshot:
            parts.append(snapshot)
        context = "\n\n".join(parts)
    elif source in ("startup", "clear"):
        try:
            with open(os.path.join(ROOT, slug(data.get("cwd")), "latest")) as f:
                folder = f.read().strip()
        except OSError:
            return None
        if os.path.basename(folder) == re.sub(r"[^A-Za-z0-9_-]", "", data.get("session_id") or ""):
            return None
        found = [p for p in (os.path.join(folder, "handoff.md"), os.path.join(folder, "snapshot.md"))
                 if os.path.exists(p)]
        if not found:
            return None
        age = now - max(os.path.getmtime(p) for p in found)
        if age > POINTER_MAX_AGE:
            return None
        hours = age / 3600
        when = "%d minutes ago" % (age / 60) if hours < 1 else "%d hours ago" % hours if hours < 48 else "%d days ago" % (hours / 24)
        context = ("An earlier session in this folder left handoff notes %s: %s. "
                   "Do not read them unless the user wants to continue that work; if their first message "
                   "could be a continuation, mention that the notes exist." % (when, ", ".join(found)))
    else:
        return None
    return {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}}


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    event = data.get("hook_event_name")
    try:
        if event == "Stop":
            output = on_stop(data)
        elif event == "PreCompact":
            output = on_precompact(data)
        elif event == "SessionStart":
            output = on_session_start(data)
        else:
            output = None
    except OSError:
        # A handoff problem must never get in the way of the session.
        return
    if isinstance(output, str):
        print(output)
    elif output:
        print(json.dumps(output))


if __name__ == "__main__":
    main()
