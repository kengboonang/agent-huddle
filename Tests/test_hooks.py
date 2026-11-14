"""Tests for the hook scripts. Each test runs in its own temporary home folder."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PYTHON = sys.executable


def run(script, payload, home, env=None, timeout=20):
    full_env = dict(os.environ, HOME=home, **(env or {}))
    full_env.pop("HANDOFF_DIR", None)
    full_env.update(env or {})
    return subprocess.run([PYTHON, os.path.join(ROOT, script)], input=json.dumps(payload), text=True,
                          capture_output=True, env=full_env, timeout=timeout)


def write_lines(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for line in lines:
            f.write(json.dumps(line, separators=(",", ":")) + "\n")


def assistant(blocks, tokens=0):
    return {"type": "assistant", "message": {"id": "m", "content": blocks, "usage": {
        "input_tokens": 10, "cache_read_input_tokens": tokens, "cache_creation_input_tokens": 0, "output_tokens": 5}}}


class HomeCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = os.path.realpath(self._tmp.name)
        self.huddle = os.path.join(self.home, ".claude", "huddle")
        self.addCleanup(self._tmp.cleanup)

    def heartbeat(self):
        os.makedirs(self.huddle, exist_ok=True)
        with open(os.path.join(self.huddle, "app.heartbeat"), "w"):
            pass


class PermissionHookTests(HomeCase):
    REQUEST = {"session_id": "s1", "cwd": "/work", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
               "tool_input": {"command": "npm test"},
               "permission_suggestions": [{"type": "addRules", "behavior": "allow", "destination": "session",
                                           "rules": [{"toolName": "Bash", "ruleContent": "npm test"}]}]}

    def answer_when_asked(self, response, seen):
        """Plays the widget: keeps the heartbeat fresh and answers the first request."""
        pending = os.path.join(self.huddle, "pending")
        deadline = time.time() + 10
        while time.time() < deadline:
            self.heartbeat()
            names = [n for n in (os.listdir(pending) if os.path.isdir(pending) else []) if n.endswith(".json")]
            if names:
                with open(os.path.join(pending, names[0])) as f:
                    seen.update(json.load(f))
                with open(os.path.join(self.huddle, "responses", names[0]), "w") as f:
                    json.dump(response, f)
                return
            time.sleep(0.05)

    def ask(self, response, request=None):
        self.heartbeat()
        seen = {}
        widget = threading.Thread(target=self.answer_when_asked, args=(response, seen))
        widget.start()
        result = run("hooks/huddle_hook.py", request or self.REQUEST, self.home)
        widget.join()
        return result, seen

    def test_silent_when_widget_is_not_running(self):
        result = run("hooks/huddle_hook.py", self.REQUEST, self.home)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertFalse(os.path.exists(os.path.join(self.huddle, "pending")))

    def test_allow(self):
        result, seen = self.ask({"behavior": "allow"})
        self.assertEqual(seen["toolName"], "Bash")
        self.assertEqual(seen["sessionId"], "s1")
        self.assertEqual(seen["toolInput"], {"command": "npm test"})
        self.assertEqual(len(seen["suggestions"]), 1)
        self.assertEqual(json.loads(result.stdout), {"hookSpecificOutput": {
            "hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}})

    def test_always_allow_passes_permission_updates(self):
        rules = self.REQUEST["permission_suggestions"]
        result, _ = self.ask({"behavior": "allow", "updatedPermissions": rules})
        decision = json.loads(result.stdout)["hookSpecificOutput"]["decision"]
        self.assertEqual(decision, {"behavior": "allow", "updatedPermissions": rules})

    def test_deny_carries_the_note(self):
        result, _ = self.ask({"behavior": "deny", "message": "use pnpm"})
        decision = json.loads(result.stdout)["hookSpecificOutput"]["decision"]
        self.assertEqual(decision, {"behavior": "deny", "message": "use pnpm"})

    def test_question_answer_goes_back_as_updated_input(self):
        questions = [{"question": "Which framework?", "header": "Framework", "multiSelect": False,
                      "options": [{"label": "React", "description": ""}, {"label": "Vue", "description": ""}]}]
        request = dict(self.REQUEST, tool_name="AskUserQuestion", tool_input={"questions": questions})
        updated = {"questions": questions, "answers": {"Which framework?": "React"}}
        result, _ = self.ask({"behavior": "allow", "updatedInput": updated}, request)
        decision = json.loads(result.stdout)["hookSpecificOutput"]["decision"]
        self.assertEqual(decision, {"behavior": "allow", "updatedInput": updated})

    def test_a_malformed_answer_decides_nothing(self):
        result, _ = self.ask({"behavior": "approve-everything"})
        self.assertEqual(result.stdout, "")

    def test_request_files_are_private_and_cleaned_up(self):
        self.ask({"behavior": "allow"})
        self.assertEqual(os.listdir(os.path.join(self.huddle, "pending")), [])
        self.assertEqual(os.listdir(os.path.join(self.huddle, "responses")), [])
        self.assertEqual(os.stat(os.path.join(self.huddle, "pending")).st_mode & 0o777, 0o700)

    def test_stops_waiting_when_the_widget_quits(self):
        self.heartbeat()
        old = time.time() - 60
        started = time.time()

        def quit_widget():
            time.sleep(0.5)
            os.utime(os.path.join(self.huddle, "app.heartbeat"), (old, old))

        threading.Thread(target=quit_widget).start()
        result = run("hooks/huddle_hook.py", self.REQUEST, self.home)
        self.assertEqual(result.stdout, "")
        self.assertLess(time.time() - started, 5)

    def test_stops_waiting_when_answered_in_the_session(self):
        transcript = os.path.join(self.home, "t.jsonl")
        write_lines(transcript, [assistant([{"type": "tool_use", "id": "t1", "name": "Bash",
                                             "input": {"command": "npm test"}}])])
        self.heartbeat()
        stop = threading.Event()

        def widget_and_terminal():
            end = time.time() + 1.0
            while not stop.is_set():
                self.heartbeat()
                if time.time() > end:
                    with open(transcript, "a") as f:
                        f.write(json.dumps({"type": "user", "message": {"content": [
                            {"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}}) + "\n")
                    end = float("inf")
                time.sleep(0.1)

        thread = threading.Thread(target=widget_and_terminal)
        thread.start()
        started = time.time()
        try:
            result = run("hooks/huddle_hook.py", dict(self.REQUEST, transcript_path=transcript), self.home)
        finally:
            stop.set()
            thread.join()
        self.assertEqual(result.stdout, "")
        self.assertLess(time.time() - started, 8)


class StatusLineTests(HomeCase):
    def test_saves_data_and_prints_a_line(self):
        now = time.time()
        payload = {"session_id": "s1", "model": {"display_name": "Opus"},
                   "context_window": {"used_percentage": 41.6, "context_window_size": 200000},
                   "cost": {"total_cost_usd": 1.5},
                   "rate_limits": {"five_hour": {"used_percentage": 23.5, "resets_at": now + 3600},
                                   "seven_day": {"used_percentage": 41.2, "resets_at": now + 86400}},
                   "vim": {"mode": "NORMAL"}}
        result = run("hooks/huddle_statusline.py", payload, self.home)
        self.assertRegex(result.stdout.strip(), r"^Opus \| ctx 42% \| 5h 24% \(resets \d\d:\d\d\) \| wk 41%$")
        with open(os.path.join(self.huddle, "status", "s1.json")) as f:
            saved = json.load(f)
        self.assertEqual(saved["rate_limits"]["five_hour"]["used_percentage"], 23.5)
        self.assertEqual(saved["context_window"]["context_window_size"], 200000)
        self.assertNotIn("vim", saved)
        self.assertAlmostEqual(saved["_updated_at"], now, delta=10)

    def test_works_without_limits_or_session(self):
        result = run("hooks/huddle_statusline.py", {"model": {"display_name": "Sonnet"}}, self.home)
        self.assertEqual(result.stdout.strip(), "Sonnet")
        self.assertFalse(os.path.exists(os.path.join(self.huddle, "status")))

    def test_bad_input_prints_nothing(self):
        result = subprocess.run([PYTHON, os.path.join(ROOT, "hooks/huddle_statusline.py")], input="not json",
                                text=True, capture_output=True, env=dict(os.environ, HOME=self.home))
        self.assertEqual((result.returncode, result.stdout), (0, ""))


class HandoffTests(HomeCase):
    def setUp(self):
        super().setUp()
        self.transcript = os.path.join(self.home, "t.jsonl")
        self.folder = os.path.join(self.home, "claude-handoffs", "work-app", "s1")
        self.base = {"session_id": "s1", "cwd": "/work/app", "transcript_path": self.transcript}
        os.makedirs(os.path.join(self.home, ".claude"), exist_ok=True)

    def status(self, percent, age=0):
        path = os.path.join(self.huddle, "status", "s1.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump({"_updated_at": time.time() - age,
                       "context_window": {"used_percentage": percent, "context_window_size": 200000}}, f)

    def stop(self, **extra):
        result = run("hooks/handoff.py", dict(self.base, hook_event_name="Stop", **extra), self.home)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)["hookSpecificOutput"]["additionalContext"] if result.stdout else None

    def test_quiet_below_the_threshold(self):
        self.status(55)
        self.assertIsNone(self.stop())

    def test_asks_once_at_the_threshold_then_again_to_update(self):
        self.status(72)
        ask = self.stop()
        self.assertIn("72% full", ask)
        self.assertIn(os.path.join(self.folder, "handoff.md"), ask)
        self.assertIn("## Next steps", ask)
        self.assertIsNone(self.stop(), "must not ask twice at the same level")

        os.makedirs(self.folder, exist_ok=True)
        with open(os.path.join(self.folder, "handoff.md"), "w") as f:
            f.write("# Handoff")
        self.status(88)
        self.assertIn("up to date", self.stop())
        self.assertIsNone(self.stop())

    def test_asks_for_a_full_document_if_none_was_written(self):
        self.status(90)
        self.assertIn("## Goal", self.stop())

    def test_never_asks_while_already_continuing_from_a_stop_hook(self):
        self.status(90)
        self.assertIsNone(self.stop(stop_hook_active=True))

    def test_starts_over_after_the_context_shrinks(self):
        self.status(75)
        self.assertIsNotNone(self.stop())
        self.status(20)
        self.assertIsNone(self.stop())
        self.status(75)
        self.assertIsNotNone(self.stop())

    def test_falls_back_to_the_transcript_when_no_status_is_saved(self):
        write_lines(self.transcript, [assistant([{"type": "text", "text": "hi"}], tokens=150_000)])
        self.assertIn("75% full", self.stop())

    def test_fallback_uses_the_1m_window_when_the_model_setting_says_so(self):
        with open(os.path.join(self.home, ".claude", "settings.json"), "w") as f:
            json.dump({"model": "claude-fable-5-2[1m]"}, f)
        write_lines(self.transcript, [assistant([{"type": "text", "text": "hi"}], tokens=150_000)])
        self.assertIsNone(self.stop(), "150k of 1M is 15%, well below the threshold")
        write_lines(self.transcript, [assistant([{"type": "text", "text": "hi"}], tokens=750_000)])
        self.assertIn("75% full", self.stop())

    def test_ignores_stale_status_and_unknown_context(self):
        self.status(95, age=3600)
        self.assertIsNone(self.stop())

    def test_precompact_saves_a_snapshot(self):
        write_lines(self.transcript, [
            {"type": "user", "message": {"content": "Build the export feature"}},
            {"type": "user", "isMeta": True, "message": {"content": "meta"}},
            {"type": "user", "message": {"content": "<system-reminder>x</system-reminder>"}},
            assistant([{"type": "text", "text": "Starting with the CSV writer."},
                       {"type": "tool_use", "id": "t1", "name": "Write", "input": {"file_path": "/work/app/export.py"}},
                       {"type": "tool_use", "id": "t2", "name": "Bash", "input": {"command": "pytest tests/test_export.py"}},
                       {"type": "tool_use", "id": "t3", "name": "TodoWrite", "input": {"todos": [
                           {"content": "CSV writer", "status": "completed"},
                           {"content": "Excel writer", "status": "in_progress"}]}}]),
            {"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": "t2", "is_error": True, "content": "ImportError: no module openpyxl"}]}},
            {"type": "user", "isSidechain": True, "message": {"content": "subagent prompt"}},
            {"type": "user", "message": {"content": "Also add Excel"}},
        ])
        result = run("hooks/handoff.py", dict(self.base, hook_event_name="PreCompact", trigger="auto"), self.home)
        self.assertIn("keep: the user's goal", result.stdout)
        self.assertIn(os.path.join(self.folder, "snapshot.md"), result.stdout)
        self.assertLess(len(result.stdout), 10000)
        with open(os.path.join(self.folder, "snapshot.md")) as f:
            snapshot = f.read()
        for expected in ("Build the export feature", "- Also add Excel", "`/work/app/export.py`",
                         "`pytest tests/test_export.py`: ImportError: no module openpyxl",
                         "- [x] CSV writer", "- [~] Excel writer", "Starting with the CSV writer."):
            self.assertIn(expected, snapshot)
        for unwanted in ("meta", "system-reminder", "subagent prompt"):
            self.assertNotIn(unwanted, snapshot)

    def test_a_broken_emoji_in_the_transcript_does_not_lose_the_snapshot(self):
        with open(self.transcript, "w") as f:
            f.write('{"type":"user","message":{"content":"Build the export \\ud83d"}}\n')
        result = run("hooks/handoff.py", dict(self.base, hook_event_name="PreCompact"), self.home)
        self.assertIn("keep: the user's goal", result.stdout)
        with open(os.path.join(self.folder, "snapshot.md"), encoding="utf-8") as f:
            self.assertIn("Build the export", f.read())

    def test_notes_stay_in_one_folder_when_the_working_folder_changes(self):
        self.status(72)
        self.assertIn(os.path.join(self.folder, "handoff.md"), self.stop())
        self.base["cwd"] = "/work/app/sub"
        self.status(82)
        self.assertIn(os.path.join(self.folder, "handoff.md"), self.stop())

    def test_more_tokens_than_a_200k_window_means_the_1m_window(self):
        write_lines(self.transcript, [assistant([{"type": "text", "text": "hi"}], tokens=260_000)])
        self.assertIsNone(self.stop(), "260k of 1M is 26%")

    def test_precompact_works_with_no_transcript(self):
        result = run("hooks/handoff.py", dict(self.base, hook_event_name="PreCompact", transcript_path="/missing"), self.home)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(os.path.exists(os.path.join(self.folder, "snapshot.md")))

    def start(self, source, session="s1"):
        payload = dict(self.base, hook_event_name="SessionStart", source=source, session_id=session)
        result = run("hooks/handoff.py", payload, self.home)
        return json.loads(result.stdout)["hookSpecificOutput"]["additionalContext"] if result.stdout else None

    def test_after_compaction_the_notes_come_back(self):
        self.assertIsNone(self.start("compact"))
        run("hooks/handoff.py", dict(self.base, hook_event_name="PreCompact"), self.home)
        with open(os.path.join(self.folder, "handoff.md"), "w") as f:
            f.write("# Handoff: export feature\n## Next steps\n1. Install openpyxl\n")
        context = self.start("compact")
        self.assertIn("1. Install openpyxl", context)
        self.assertIn("# Automatic snapshot", context)
        self.assertLess(len(context), 10000)

    def test_long_notes_are_capped(self):
        run("hooks/handoff.py", dict(self.base, hook_event_name="PreCompact"), self.home)
        with open(os.path.join(self.folder, "handoff.md"), "w") as f:
            f.write("x" * 50000)
        self.assertLess(len(self.start("compact")), 10000)

    def test_a_new_session_gets_a_pointer_not_the_document(self):
        self.assertIsNone(self.start("startup", session="s2"))
        run("hooks/handoff.py", dict(self.base, hook_event_name="PreCompact"), self.home)
        context = self.start("startup", session="s2")
        self.assertIn(os.path.join(self.folder, "snapshot.md"), context)
        self.assertNotIn("# Automatic snapshot", context)
        self.assertIsNone(self.start("startup", session="s1"), "a session is not pointed at its own notes")
        self.assertIsNone(self.start("resume", session="s2"))

    def test_old_notes_are_not_mentioned(self):
        run("hooks/handoff.py", dict(self.base, hook_event_name="PreCompact"), self.home)
        old = time.time() - 30 * 86400
        os.utime(os.path.join(self.folder, "snapshot.md"), (old, old))
        self.assertIsNone(self.start("startup", session="s2"))


class EvidenceTests(HomeCase):
    SEARCH = {"query": "agent huddle", "searchCount": 1, "results": [
        {"tool_use_id": "x", "content": [{"title": "Open [Huddle]", "url": "https://example.com/huddle"},
                                         {"title": "Docs", "url": "https://docs.example.com/hooks/"}]},
        "I found two pages about it."]}
    FETCH = {"bytes": 738597, "code": 200, "codeText": "OK", "url": "https://example.com/huddle",
             "result": "The page describes a widget.\nIt lists agents."}

    def setUp(self):
        super().setUp()
        self.transcript = os.path.join(self.home, "t.jsonl")
        self.base = {"session_id": "s1", "cwd": "/work/app", "transcript_path": self.transcript}
        self.folder = os.path.join(self.home, "claude-evidence", "work-app", "s1")

    def tool(self, name, tool_input, response):
        payload = dict(self.base, hook_event_name="PostToolUse", tool_name=name, tool_input=tool_input,
                       tool_response=response, tool_use_id="t1")
        result = run("hooks/evidence.py", payload, self.home)
        self.assertEqual((result.returncode, result.stdout), (0, ""), result.stderr)

    def stop(self, message, **extra):
        payload = dict(self.base, hook_event_name="Stop", last_assistant_message=message, **extra)
        result = run("hooks/evidence.py", payload, self.home)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout) if result.stdout else None

    def evidence(self):
        with open(os.path.join(self.folder, "evidence.md")) as f:
            return f.read()

    def test_search_and_page_are_written_down_with_links(self):
        self.tool("WebSearch", {"query": "agent huddle"}, self.SEARCH)
        self.tool("WebFetch", {"url": "https://example.com/huddle", "prompt": "What is it?"}, self.FETCH)
        text = self.evidence()
        self.assertEqual(text.count("# Evidence log"), 1)
        for expected in ("Query: `agent huddle`", "Results that came back (2):",
                         "- [Open (Huddle)](https://example.com/huddle)", "> I found two pages about it.",
                         "Address: [https://example.com/huddle](https://example.com/huddle)",
                         "Answer from the site: 200 OK, 738,597 bytes", "What Claude asked about the page: What is it?",
                         "> The page describes a widget.\n> It lists agents."):
            self.assertIn(expected, text)
        with open(os.path.join(self.folder, "log.jsonl")) as f:
            records = [json.loads(line) for line in f]
        self.assertEqual([r["tool"] for r in records], ["WebSearch", "WebFetch"])
        self.assertEqual(records[1]["response"], self.FETCH)

    def test_other_tools_are_ignored(self):
        self.tool("Bash", {"command": "ls"}, {"stdout": "x"})
        self.assertFalse(os.path.exists(self.folder))

    def test_stop_reports_each_turn_once(self):
        self.tool("WebSearch", {"query": "agent huddle"}, self.SEARCH)
        self.tool("WebFetch", {"url": "https://example.com/huddle"}, self.FETCH)
        output = self.stop("It is a widget. Source: https://example.com/huddle.")
        self.assertIn("Evidence this turn: 1 web search, 1 page read.", output["systemMessage"])
        self.assertIn("file://" + os.path.join(self.folder, "evidence.md"), output["systemMessage"])
        self.assertNotIn("hookSpecificOutput", output)
        self.assertIsNone(self.stop("Anything else?"))

    def test_links_that_came_back_from_a_search_count_as_checked(self):
        self.tool("WebSearch", {"query": "agent huddle"}, self.SEARCH)
        output = self.stop("See [the docs](https://docs.example.com/hooks) and https://EXAMPLE.com/huddle/.")
        self.assertNotIn("Not checked", output["systemMessage"])

    def test_a_link_from_nowhere_is_reported_and_claude_is_asked_to_check(self):
        self.tool("WebSearch", {"query": "agent huddle"}, self.SEARCH)
        output = self.stop("Read https://made-up.example.org/paper and https://example.com/huddle")
        self.assertIn("Not checked: 1 link in the answer appears in nothing", output["systemMessage"])
        self.assertIn("https://made-up.example.org/paper", output["systemMessage"])
        ask = output["hookSpecificOutput"]["additionalContext"]
        self.assertIn("https://made-up.example.org/paper", ask)
        self.assertNotIn("https://example.com/huddle", ask)

    def test_a_link_from_memory_is_reported_even_with_no_web_use(self):
        output = self.stop("The docs are at https://made-up.example.org/docs.")
        self.assertIn("Not checked", output["systemMessage"])
        self.assertNotIn("Evidence this turn", output["systemMessage"])

    def test_claude_is_asked_only_once(self):
        output = self.stop("See https://made-up.example.org/docs", stop_hook_active=True)
        self.assertIn("Not checked", output["systemMessage"])
        self.assertNotIn("hookSpecificOutput", output)

    def test_links_the_user_gave_or_a_tool_printed_count_as_seen(self):
        write_lines(self.transcript, [
            {"type": "user", "message": {"content": "look at https://user-gave.example.com/page please"}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "b1",
                                                      "content": "origin https://github.com/me/repo.git"}]}},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "https://claude-said.example.com"}]}},
        ])
        self.assertIsNone(self.stop("Done: https://user-gave.example.com/page and https://github.com/me/repo.git"))
        output = self.stop("As I said, https://claude-said.example.com")
        self.assertIn("https://claude-said.example.com", output["systemMessage"])

    def test_a_link_claude_passed_to_a_tool_counts_as_seen(self):
        write_lines(self.transcript, [assistant([{"type": "tool_use", "id": "b1", "name": "Bash",
                                                  "input": {"command": "curl -s https://api.example.com/v1/status"}}])])
        self.assertIsNone(self.stop("Checked https://api.example.com/v1/status and it is up."))

    def test_small_differences_in_how_a_link_is_written_do_not_matter(self):
        self.tool("WebSearch", {"query": "agent huddle"}, self.SEARCH)
        for answer in (u"See https://docs.example.com/hooks\u3002", u"See \u201chttps://docs.example.com/hooks\u201d",
                       "See http://www.docs.example.com/hooks/", "See https://docs.example.com/hooks#install."):
            output = self.stop(answer)
            self.assertTrue(output is None or "Not checked" not in output["systemMessage"], answer)

    def test_the_report_shows_the_link_as_it_was_written(self):
        output = self.stop("Read https://WWW.Made-Up.example.org/Paper.")
        self.assertIn("https://WWW.Made-Up.example.org/Paper", output["systemMessage"])

    def test_a_broken_emoji_does_not_stop_the_log(self):
        self.tool("WebFetch", {"url": "https://example.com/huddle"}, dict(self.FETCH, result="cut text \ud83d"))
        self.assertIn("cut text", self.evidence())

    def test_the_log_stays_in_one_folder_when_the_working_folder_changes(self):
        self.tool("WebSearch", {"query": "one"}, self.SEARCH)
        self.base["cwd"] = "/work/app/sub"
        self.tool("WebSearch", {"query": "two"}, self.SEARCH)
        self.assertEqual(self.evidence().count("Web search"), 2)
        self.assertEqual(os.listdir(os.path.join(self.home, "claude-evidence")), ["work-app"])

    def test_an_answer_without_links_is_silent(self):
        self.assertIsNone(self.stop("All done, no links."))


class SettingsTests(HomeCase):
    def setUp(self):
        super().setUp()
        self.path = os.path.join(self.home, ".claude", "settings.json")
        os.makedirs(os.path.dirname(self.path))

    def settings(self, action):
        result = subprocess.run([PYTHON, os.path.join(ROOT, "scripts/settings.py"), action, self.path],
                                capture_output=True, text=True, env=dict(os.environ, HOME=self.home))
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(self.path) as f:
            return json.load(f), result.stdout

    def test_install_twice_then_uninstall_restores_the_original(self):
        original = {"theme": "dark", "model": "fable",
                    "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]},
                    "permissions": {"allow": ["Bash(ls:*)"]}}
        with open(self.path, "w") as f:
            json.dump(original, f)
        self.settings("install")
        installed, _ = self.settings("install")
        self.assertEqual(sorted(installed["hooks"]),
                         ["PermissionRequest", "PostToolUse", "PreCompact", "SessionStart", "Stop"])
        self.assertEqual(len(installed["hooks"]["Stop"]), 3)
        self.assertEqual(installed["hooks"]["PostToolUse"][0]["matcher"], "WebSearch|WebFetch")
        self.assertEqual(len(installed["hooks"]["PermissionRequest"]), 1)
        self.assertEqual(installed["hooks"]["PermissionRequest"][0]["hooks"][0]["timeout"], 600)
        self.assertIn("huddle_statusline.py", installed["statusLine"]["command"])
        self.assertIn("Edit(~/.claude/huddle/**)", installed["permissions"]["deny"])
        self.assertIn("Edit(~/claude-handoffs/**)", installed["permissions"]["allow"])
        self.assertTrue(any(".huddle-backup-" in name for name in os.listdir(os.path.dirname(self.path))))
        removed, _ = self.settings("uninstall")
        self.assertEqual(removed, original)

    def test_an_existing_status_line_is_kept(self):
        with open(self.path, "w") as f:
            json.dump({"statusLine": {"type": "command", "command": "my-status"}}, f)
        installed, output = self.settings("install")
        self.assertEqual(installed["statusLine"]["command"], "my-status")
        self.assertIn("left alone", output)
        removed, _ = self.settings("uninstall")
        self.assertEqual(removed, {"statusLine": {"type": "command", "command": "my-status"}})

    def test_install_creates_the_file_when_missing(self):
        installed, _ = self.settings("install")
        self.assertIn("PermissionRequest", installed["hooks"])


if __name__ == "__main__":
    unittest.main()
