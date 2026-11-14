#!/usr/bin/env python3
"""Evidence log for web tools.

Two hooks, so you can check what Claude really searched and read:

  PostToolUse (WebSearch, WebFetch)
      Saves each call: the query or address, and exactly what came back to Claude.
      The record goes into a readable file with clickable links.

  Stop
      At the end of a turn, shows you a one-line summary with a link to that file.
      It also compares the links in Claude's answer with everything that was
      searched, fetched, read or typed in the session. Links that appear nowhere
      else are reported to you, and Claude is asked once to check or remove them.

Files are kept in ~/claude-evidence/<project>/<session id>/.
"""
import io
import json
import os
import re
import sys
import time

HOME = os.path.expanduser("~")
ROOT = os.environ.get("EVIDENCE_DIR") or os.path.join(HOME, "claude-evidence")
NUDGE = os.environ.get("EVIDENCE_NUDGE", "1") != "0"
URL = re.compile(u"https?://[^\\s\"'<>\\\\)\\]}`|\u3002\uff0c\u3001\uff1b\uff1a\uff09\u3011\u300d\u201c\u201d\u2018\u2019\u2026]+")
RESULT_LIMIT = 6000


def slug(cwd):
    return re.sub(r"[^A-Za-z0-9]", "-", cwd or "unknown").strip("-") or "unknown"


def session_dir(data):
    """One folder per session. It stays where it was first made, even if the working folder changes later."""
    session = re.sub(r"[^A-Za-z0-9_-]", "", data.get("session_id") or "unknown")
    try:
        for project in sorted(os.listdir(ROOT)):
            if os.path.isdir(os.path.join(ROOT, project, session)):
                return os.path.join(ROOT, project, session)
    except OSError:
        pass
    return os.path.join(ROOT, slug(data.get("cwd")), session)


def normalise(url):
    """The form used to compare two addresses: no http/https, no www, no #part, no trailing slash."""
    url = url.split("#")[0].rstrip(".,;:!?*_")
    match = re.match(r"https?://(?:www\.)?([^/]+)(.*)", url, re.I)
    if not match:
        return url
    return match.group(1).lower() + match.group(2).rstrip("/")


def urls_in(value):
    """Every web address found anywhere inside a string, list or dictionary."""
    found = set()
    if isinstance(value, str):
        found.update(normalise(u) for u in URL.findall(value))
    elif isinstance(value, dict):
        for item in value.values():
            found |= urls_in(item)
    elif isinstance(value, list):
        for item in value:
            found |= urls_in(item)
    return found


def read_records(folder):
    records = []
    try:
        with io.open(os.path.join(folder, "log.jsonl"), encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    records.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return records


def text_of(value):
    """The readable text in a tool result."""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(t for t in (text_of(v) for v in value) if t)
    if isinstance(value, dict):
        for key in ("result", "text", "content"):
            if key in value:
                return text_of(value[key])
    return ""


def search_links(response):
    links = []

    def walk(value):
        if isinstance(value, dict):
            if isinstance(value.get("url"), str):
                links.append((value.get("title") or value["url"], value["url"]))
            else:
                for item in value.values():
                    walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    walk(response)
    return links


def quote(text, limit=RESULT_LIMIT):
    text = (text or "").strip()
    if len(text) > limit:
        text = text[:limit] + "\n… (cut; the full text is in log.jsonl)"
    return "\n".join("> " + line for line in text.splitlines()) if text else "> (nothing)"


def entry_markdown(record):
    when = time.strftime("%H:%M:%S", time.localtime(record["time"]))
    tool_input, response = record.get("input") or {}, record.get("response")
    if record["tool"] == "WebSearch":
        query = tool_input.get("query", "")
        lines = ["## %s · Web search" % when, "", "Query: `%s`" % query, ""]
        links = search_links(response)
        if links:
            lines += ["Results that came back (%d):" % len(links), ""]
            lines += ["- [%s](%s)" % (title.replace("[", "(").replace("]", ")"), url) for title, url in links] + [""]
        else:
            lines += ["No result links came back.", ""]
        summary = "\n".join(s for s in (response or {}).get("results", []) if isinstance(s, str)) \
            if isinstance(response, dict) else text_of(response)
        lines += ["What Claude was given:", "", quote(summary), ""]
    else:
        url = tool_input.get("url", "")
        lines = ["## %s · Page read" % when, "", "Address: [%s](%s)" % (url, url), ""]
        if isinstance(response, dict) and response.get("code") is not None:
            size = response.get("bytes")
            lines += ["Answer from the site: %s %s%s" % (
                response.get("code"), response.get("codeText") or "",
                ", %s bytes" % format(size, ",") if isinstance(size, int) else ""), ""]
        if tool_input.get("prompt"):
            lines += ["What Claude asked about the page: %s" % tool_input["prompt"], ""]
        lines += ["What Claude was given (a summary of the page made by a small model, not the page itself):",
                  "", quote(text_of(response)), ""]
    return "\n".join(lines)


def on_tool(data):
    if data.get("tool_name") not in ("WebSearch", "WebFetch"):
        return None
    folder = session_dir(data)
    os.makedirs(folder, exist_ok=True)
    record = {"time": time.time(), "tool": data["tool_name"], "id": data.get("tool_use_id"),
              "input": data.get("tool_input") or {}, "response": data.get("tool_response")}
    with io.open(os.path.join(folder, "log.jsonl"), "a", encoding="utf-8", errors="replace") as f:
        f.write(json.dumps(record) + "\n")
    path = os.path.join(folder, "evidence.md")
    new = not os.path.exists(path)
    with io.open(path, "a", encoding="utf-8", errors="replace") as f:
        if new:
            f.write("# Evidence log\n\nEvery web search and page read in this session, with what came back.\n\n"
                    "- Folder: `%s`\n- Session: `%s`\n\n" % (data.get("cwd") or "", data.get("session_id") or ""))
        f.write(entry_markdown(record) + "\n")
    return None


def seen_in_transcript(path):
    """Links in what the user typed, in every tool result (files read, command output and so on),
    and in what Claude passed to a tool (for example a curl command)."""
    found = set()
    try:
        with open(path, "rb") as f:
            for raw in f:
                if b"http" not in raw or (b'"type":"user"' not in raw and b'"type":"assistant"' not in raw):
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(entry, dict):
                    continue
                if entry.get("type") == "user":
                    found |= urls_in(entry.get("message"))
                    found |= urls_in(entry.get("toolUseResult"))
                elif entry.get("type") == "assistant":
                    content = (entry.get("message") or {}).get("content")
                    for block in content if isinstance(content, list) else []:
                        if isinstance(block, dict) and block.get("type") == "tool_use":
                            found |= urls_in(block.get("input"))
    except OSError:
        pass
    return found


def on_stop(data):
    folder = session_dir(data)
    records = read_records(folder)
    state_path = os.path.join(folder, "state.json")
    try:
        with io.open(state_path, encoding="utf-8") as f:
            reported = json.load(f).get("reported", 0)
    except (OSError, ValueError):
        reported = 0
    fresh = records[reported:]
    answer_text = data.get("last_assistant_message") or ""
    written = {normalise(u): u.split("#")[0].rstrip(".,;:!?*_") for u in URL.findall(answer_text)}
    answer_links = set(written)

    unverified = []
    if answer_links:
        known = urls_in([[r.get("input"), r.get("response")] for r in records])
        missing = answer_links - known
        if missing:
            missing -= seen_in_transcript(data.get("transcript_path") or "")
        unverified = sorted(written[m] for m in missing)
    if not fresh and not unverified:
        return None

    parts = []
    if fresh:
        searches = sum(1 for r in fresh if r["tool"] == "WebSearch")
        pages = len(fresh) - searches
        counts = [("%d web search%s" % (searches, "" if searches == 1 else "es")) if searches else "",
                  ("%d page%s read" % (pages, "" if pages == 1 else "s")) if pages else ""]
        parts.append("Evidence this turn: %s. Open: file://%s" % (
            ", ".join(c for c in counts if c), os.path.join(folder, "evidence.md").replace(" ", "%20")))
        os.makedirs(folder, exist_ok=True)
        with open(state_path, "w") as f:
            json.dump({"reported": len(records)}, f)
    if unverified:
        shown = ", ".join(unverified[:8]) + (" and %d more" % (len(unverified) - 8) if len(unverified) > 8 else "")
        parts.append("Not checked: %d link%s in the answer appear%s in nothing that was searched, fetched or read "
                     "in this session: %s" % (len(unverified), "" if len(unverified) == 1 else "s",
                                              "s" if len(unverified) == 1 else "", shown))
    output = {"systemMessage": "\n".join(parts)}
    if unverified and NUDGE and not data.get("stop_hook_active"):
        output["hookSpecificOutput"] = {"hookEventName": "Stop", "additionalContext": (
            "These links in your answer do not appear in anything you searched, fetched or read in this session, "
            "or in anything the user gave you: %s. For each one, either check it now with WebFetch or WebSearch, "
            "or remove it, or tell the user plainly that it comes from memory and was not checked." % shown)}
    return output


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    try:
        event = data.get("hook_event_name")
        output = on_tool(data) if event == "PostToolUse" else on_stop(data) if event == "Stop" else None
    except Exception:
        # A problem in this hook must never get in the way of the session.
        return
    if output:
        print(json.dumps(output))


if __name__ == "__main__":
    main()
