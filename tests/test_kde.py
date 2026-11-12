import importlib.machinery
import importlib.util
import json
import os
import shlex
import subprocess
import tempfile
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("kde_helper", os.path.join(HERE, "..", "package", "contents", "bin", "screenrig-kde"))
spec = importlib.util.spec_from_loader("kde_helper", loader)
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)

RULE = 'rule family="ipv4" source address="192.168.1.0/24" port port="8554" protocol="tcp" accept'


class Firewalld(unittest.TestCase):
    def test_ports_and_ranges(self):
        self.assertTrue(helper.port_listed("1025-65535/tcp 1025-65535/udp"))
        self.assertTrue(helper.port_listed("80/tcp 8554/tcp"))
        self.assertFalse(helper.port_listed("8554/udp 9000-9999/tcp"))
        self.assertFalse(helper.port_listed(""))

    def test_zone_settings(self):
        self.assertTrue(helper.firewalld_opens({"target": "ACCEPT"}, "192.168.1.0/24"))
        # Fedora Workstation's zone opens every high port.
        self.assertTrue(helper.firewalld_opens({"target": "default", "ports": [("1025-65535", "tcp")]}, "192.168.1.0/24"))
        self.assertTrue(helper.firewalld_opens({"target": "default", "rules_str": [RULE]}, "192.168.1.0/24"))
        self.assertFalse(helper.firewalld_opens({"target": "default", "rules_str": [RULE]}, "10.0.0.0/24"))
        self.assertFalse(helper.firewalld_opens({"target": "default", "ports": [("22", "tcp")]}, "192.168.1.0/24"))

    def test_status_never_reads_a_zone_that_would_ask_for_a_password(self):
        with mock.patch.object(helper, "recorded_rule", return_value={}), \
                mock.patch.object(helper, "may_read_firewalld_zones", return_value=False), \
                mock.patch.object(helper, "firewalld_read") as read:
            self.assertEqual(helper.firewalld_state("192.168.1.0/24", "public"), "needed")
        read.assert_not_called()

    def test_allow_adds_one_recorded_rule_and_teardown_removes_exactly_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            runs = []

            def run(cmd, **kw):
                runs.append(cmd)
                return subprocess.CompletedProcess(cmd, 0, "success", "")
            with mock.patch.object(helper, "FIREWALL_RULE", os.path.join(tmp, "firewall.json")), \
                    mock.patch.object(helper, "lan_ip", return_value="192.168.1.20"), \
                    mock.patch.object(helper, "lan_subnet", return_value="192.168.1.0/24"), \
                    mock.patch.object(helper, "firewall_kind", return_value="firewalld"), \
                    mock.patch.object(helper, "firewall_state", return_value="needed"), \
                    mock.patch.object(helper, "firewalld_zone", return_value="public"), \
                    mock.patch.object(helper.subprocess, "run", run):
                helper.live_setup()
                self.assertEqual(runs, [["firewall-cmd", "--permanent", "--zone=public", "--add-rich-rule=" + RULE],
                                        ["firewall-cmd", "--zone=public", "--add-rich-rule=" + RULE]])
                self.assertEqual(helper.recorded_rule(), {"kind": "firewalld", "zone": "public", "subnet": "192.168.1.0/24"})
                runs.clear()
                # Wherever the computer is now, the rule removed is the one recorded.
                with mock.patch.object(helper, "lan_subnet", return_value="10.9.0.0/24"):
                    helper.live_unsetup()
                self.assertEqual(runs, [["firewall-cmd", "--permanent", "--zone=public", "--remove-rich-rule=" + RULE],
                                        ["firewall-cmd", "--zone=public", "--remove-rich-rule=" + RULE]])
                self.assertEqual(helper.recorded_rule(), {})
                self.assertEqual(helper.live_unsetup(), "Nothing to undo")

    def test_a_refused_password_is_reported_and_nothing_is_recorded(self):
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(helper, "FIREWALL_RULE", os.path.join(tmp, "firewall.json")), \
                mock.patch.object(helper, "lan_ip", return_value="192.168.1.20"), \
                mock.patch.object(helper, "lan_subnet", return_value="192.168.1.0/24"), \
                mock.patch.object(helper, "firewall_kind", return_value="firewalld"), \
                mock.patch.object(helper, "firewall_state", return_value="needed"), \
                mock.patch.object(helper, "firewalld_zone", return_value="public"), \
                mock.patch.object(helper.subprocess, "run",
                                  return_value=subprocess.CompletedProcess([], 1, "", "Authorization failed.")):
            with self.assertRaises(helper.Problem) as raised:
                helper.live_setup()
            self.assertIn("Authorization failed", str(raised.exception))
            self.assertEqual(helper.recorded_rule(), {})


class Notices(unittest.TestCase):
    def test_actions_wait_for_the_click(self):
        cmd = helper.notice_command({"title": "Lobby went offline", "body": "Last online 10:04.", "urgency": "critical",
                                     "actions": [["Open", ["x"]], ["Reload", ["y"]]]})
        self.assertIn("--action=a0=Open", cmd)
        self.assertIn("--action=a1=Reload", cmd)
        self.assertIn("--wait", cmd)
        self.assertIn("--print-id", cmd)
        # Names come from the project and are never read as options.
        self.assertEqual(cmd[-3:], ["--", "Lobby went offline", "Last online 10:04."])

    def test_a_plain_notice_does_not_wait(self):
        self.assertNotIn("--wait", helper.notice_command({"title": "-rf", "body": ""}))

    def test_the_chosen_action_runs_and_the_tag_is_cleared(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(helper, "NOTICES", tmp):
            script = "import sys; print(41, flush=True); print('a1', flush=True)"
            started = []
            real = subprocess.Popen

            def popen(cmd, **kw):
                if cmd[0] == "notify-send":
                    return real(["python3", "-I", "-c", script], **kw)
                started.append(cmd)
                return mock.Mock()
            with mock.patch.object(helper.subprocess, "Popen", popen):
                helper.show_notice({"title": "t", "actions": [["Open", ["open-it"]], ["Reload", ["reload-it"]]], "tag": "live"})
            self.assertEqual(started, [["reload-it"]])
            self.assertFalse(os.path.exists(os.path.join(tmp, "live")))


class OpenWith(unittest.TestCase):
    def test_exec_quotes_paths_with_spaces_and_specials(self):
        self.assertEqual(helper.desktop_quote('/home/a b/$x"`\\100%'), '"/home/a b/\\$x\\"\\`\\\\100%%"')

    def test_entry_runs_this_helper(self):
        with mock.patch.object(helper, "SELF", ["/usr/bin/python3", "/home/me/my plasmoids/screenrig-kde"]):
            entry = helper.send_entry()
        self.assertIn('Exec="/usr/bin/python3" "/home/me/my plasmoids/screenrig-kde" send-file %f\n', entry)
        self.assertIn("NoDisplay=true", entry)


class Feed(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        for name, value in (("FEED", "feed.json"), ("SUMMON", "summon.json"), ("HEARTBEAT", "heartbeat"),
                            ("SERVE_LOCK", "serve.lock"), ("LIVE_DIR", "live")):
            patch = mock.patch.object(helper, name, os.path.join(self.tmp.name, value))
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(helper, "ensure_server")
        patch.start()
        self.addCleanup(patch.stop)

    def test_each_change_raises_seq_and_repeats_are_dropped(self):
        feed = helper.Feed()
        first = helper.read_json(helper.FEED, {})["seq"]
        feed({"kind": "status", "ok": False, "error": "offline"})
        feed({"kind": "status", "ok": False, "error": "offline"})
        feed({"kind": "snapshot", "screens": [], "playlists": []})
        state = helper.read_json(helper.FEED, {})
        self.assertEqual(state["seq"], first + 2)
        self.assertEqual(state["status"], {"ok": False, "error": "offline"})
        # A restarted follower never repeats a seq the widget already saw.
        self.assertGreater(helper.read_json(helper.FEED, {})["seq"], 0)
        self.assertEqual(helper.Feed().state["seq"], state["seq"] + 1)

    def test_wait_returns_at_once_for_a_change_or_a_new_summon(self):
        helper.Feed()
        seq = helper.read_json(helper.FEED, {})["seq"]
        self.assertEqual(helper.wait_feed(-1, 0, seconds=5)["feed"]["seq"], seq)
        started = time.time()
        answer = helper.wait_feed(seq, 0, seconds=0.3)
        self.assertGreaterEqual(time.time() - started, 0.25)
        self.assertIsNone(answer["summon"])
        helper.summon_panel({"mode": "cast"})
        answer = helper.wait_feed(seq, 0, seconds=5)
        self.assertEqual(answer["summon"]["payload"], {"mode": "cast"})
        # A summon the widget already handled is not handed over again.
        self.assertIsNone(helper.wait_feed(seq, answer["summon"]["at"], seconds=0.2)["summon"])


class Teardown(unittest.TestCase):
    def test_removes_everything_it_made(self):
        with tempfile.TemporaryDirectory() as tmp:
            dirs = {name: os.path.join(tmp, name) for name in ("STATE", "CACHE", "DATA", "APPS")}
            for path in dirs.values():
                os.makedirs(path)
            entry = os.path.join(dirs["APPS"], "screenrig-kde-send.desktop")
            with mock.patch.multiple(helper, SEND_ENTRY=entry, **dirs), \
                    mock.patch.object(helper, "live_status", return_value={"live": False}), \
                    mock.patch.object(helper, "live_unsetup", return_value="Nothing to undo"), \
                    mock.patch.object(helper, "stop_server", return_value=False), \
                    mock.patch.object(helper.subprocess, "run"):
                helper.setup()
                self.assertTrue(os.path.exists(entry))
                helper.teardown()
            self.assertEqual(sorted(os.listdir(tmp)), ["APPS"])
            self.assertEqual(os.listdir(dirs["APPS"]), [])


class Capture(unittest.TestCase):
    def test_pipeline_letterboxes_to_1080p30_and_writes_mpegts_to_the_socket(self):
        cmd = helper.capture_pipeline(7, 42, 9, helper.ENCODERS[3])
        text = " ".join(cmd)
        self.assertIn("pipewiresrc fd=7 path=42", text)
        self.assertIn("videoscale add-borders=true", text)
        self.assertIn("video/x-raw,width=1920,height=1080,pixel-aspect-ratio=1/1,framerate=30/1", cmd)
        self.assertIn("x264enc tune=zerolatency", text)
        self.assertEqual(cmd[-6:], ["!", "mpegtsmux", "!", "fdsink", "fd=9", "sync=false"])

    def test_every_encoder_line_is_plain_arguments(self):
        for enc in helper.ENCODERS:
            self.assertEqual(shlex.split(enc), enc.split())


class Clipboard(unittest.TestCase):
    def test_link_file_and_nothing(self):
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(helper, "clipboard_types", return_value=["text/plain"]), \
                mock.patch.object(helper, "summon_panel") as summon:
            with mock.patch.object(helper, "clipboard_text", return_value="https://example.com/menu"):
                helper.clip()
            summon.assert_called_with({"mode": "cast", "kind": "url", "source": "clipboard", "url": "https://example.com/menu"})
            path = os.path.join(tmp, "a b.png")
            open(path, "w").close()
            with mock.patch.object(helper, "clipboard_text", return_value="file://" + path.replace(" ", "%20")):
                helper.clip()
            summon.assert_called_with({"mode": "cast", "kind": "file", "source": "clipboard", "path": path})
            for text in ("http://example.com", "javascript:alert(1)", ""):
                with mock.patch.object(helper, "clipboard_text", return_value=text), self.assertRaises(helper.Problem):
                    helper.clip()


if __name__ == "__main__":
    unittest.main()
