import base64
import hashlib
import http.client
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

REAL_POPEN = subprocess.Popen

try:
    import yaml
except ImportError:
    yaml = None

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("helper", os.path.join(HERE, "..", "package", "contents", "bin", "screenrig-kde"))
spec = importlib.util.spec_from_loader("helper", loader)
helper = importlib.util.module_from_spec(spec)
loader.exec_module(helper)

SNAP = {
    "screens": [{"id": "scr_A", "label": "Lobby TV", "online": True, "playing_name": "Welcome"},
                {"id": "scr_B", "label": "Kitchen", "online": False, "playing_name": ""}],
    "playlists": [{"id": "pl_1", "name": "Welcome", "approved": True}],
}



class Screens(unittest.TestCase):
    def test_summary_fields(self):
        raw = {"id": "scr_X", "label": "Foyer", "online": False, "state": "active", "playlist_id": "pl_1",
               "effective_playlist": {"id": "pl_2", "source": "takeover", "until": "2026-11-08T18:00:00Z"},
               "takeover": {"playlist_id": "pl_2", "until": "2026-11-08T18:00:00Z"},
               "display": {"requested": "off"}, "host": {"platform": "android", "capabilities": ["reboot"]},
               "manifest_upgrade": {"state": "current"}}
        s = helper.summarize_screen(raw, {"pl_1": "Default", "pl_2": "Sent"})
        self.assertEqual((s["playlist_name"], s["playing_name"], s["playing_source"]), ("Default", "Sent", "takeover"))
        self.assertTrue(s["has_takeover"] and s["display_off"])
        self.assertEqual(s["capabilities"], ["reboot"])

    def test_media_page_video_advances_on_end(self):
        page = helper.media_page("med_1", "video/mp4")
        self.assertEqual(page["advance"], {"mode": "media_end"})
        self.assertEqual(page["primitives"][0]["primitive"], "video")

    def test_iso_in_is_utc_z(self):
        self.assertTrue(re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", helper.iso_in(10)))


class Token(unittest.TestCase):
    def test_exp_from_jwt(self):
        import base64
        body = base64.urlsafe_b64encode(json.dumps({"exp": 1234}).encode()).decode().rstrip("=")
        self.assertEqual(helper.token_exp("h." + body + ".s"), 1234)
        self.assertEqual(helper.token_exp("garbage"), 0)


class LiveCast(unittest.TestCase):
    def test_fallback_png_is_a_png(self):
        png = helper.solid_png(4, 2)
        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n") and png.endswith(b"IEND\xaeB`\x82"))


class LiveCastStart(unittest.TestCase):
    """live_start with the recorder, mediamtx and the keep-alive replaced by idle processes."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = self.tmp.name
        self.children, self.calls, self.probed, self.waits = [], [], [], []
        self.fail_on = {}
        # What the backend holds: each screen's takeover and the playlists, so the cleanup's checks have answers.
        self.screens = {sid: {"id": sid, "revision": 5, "takeover": None} for sid in ("scr_A", "scr_B", "scr_C")}
        self.playlists = {}
        self.lost = set()          # (method, path) applied by the backend whose reply never arrives
        self.unreadable = {}       # screen id -> reads that fail before one succeeds
        self.headers = []          # (method, path, request headers) of each call
        self.on_write = {}         # (method, path) -> callable run just before the backend sees the write
        real_popen = subprocess.Popen

        def popen(cmd, **kw):
            if hasattr(kw.get("stdout"), "close"):
                kw["stdout"].close()
            if "live-capture" in cmd and "capture" in self.fail_on:
                raise self.fail_on["capture"]
            if cmd[0] in self.fail_on:
                raise self.fail_on[cmd[0]]
            # Restores SIGINT in case the test run started with it ignored.
            idle = "import signal, time; signal.signal(signal.SIGINT, signal.SIG_DFL); time.sleep(60)"
            proc = real_popen([sys.executable, "-I", "-c", idle], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, start_new_session=kw.get("start_new_session", False))
            name = "capture" if "live-capture" in cmd else ("keepalive" if "live-keepalive" in cmd else cmd[0])
            self.children.append(([name] + list(cmd[1:]), proc))
            return proc

        def api(method, path, body=None, **kw):
            self.calls.append((method, path, body))
            headers = kw.get("headers") or {}
            self.headers.append((method, path, headers))
            if method == "POST" and path.endswith("/playlists"):
                if "playlist" in self.fail_on:
                    raise self.fail_on["playlist"]
                pid = "pl_lost" if (method, path) in self.lost else "pl_cast"
                self.playlists[pid] = body["name"]
                if (method, path) in self.lost:
                    raise helper.Uncertain("the answer was cut off")
                return {"id": pid}
            if method == "GET" and path.startswith("/api/playlists?"):
                return {"items": [{"id": pid, "name": name} for pid, name in self.playlists.items()]}
            if method == "DELETE" and path.startswith("/api/playlists/"):
                if "playlist_delete" in self.fail_on:
                    raise self.fail_on["playlist_delete"]
                self.playlists.pop(path.rsplit("/", 1)[1], None)
                return {}
            match = re.fullmatch(r"/api/screens/(\w+)(/takeover)?", path)
            if match and match.group(1) in self.screens:
                screen = self.screens[match.group(1)]
                if method == "GET":
                    if self.unreadable.get(screen["id"]):
                        self.unreadable[screen["id"]] -= 1
                        raise helper.Uncertain("the answer was cut off")
                    return json.loads(json.dumps(screen))
                if match.group(2):
                    if (method, path) in self.on_write:
                        self.on_write[(method, path)]()
                    guard = headers.get("If-Match")
                    if guard is not None and guard != '"%d"' % screen["revision"]:
                        raise helper.Problem("The screen changed.", 412)
                    screen["takeover"] = {"playlist_id": body["playlist_id"]} if method == "POST" else None
                    screen["revision"] += 1
                    if (method, path) in self.lost:
                        raise helper.Uncertain("the answer was cut off")
                    return json.loads(json.dumps(screen))
            return {}

        patches = [
            mock.patch.object(helper, "STATE", os.path.join(root, "state")),
            mock.patch.object(helper, "CACHE", os.path.join(root, "cache")),
            mock.patch.object(helper, "LIVE_DIR", os.path.join(root, "state", "live")),
            mock.patch.object(helper, "LAST_CAST", os.path.join(root, "state", "last-cast.json")),
            mock.patch.object(helper, "ASSETS", os.path.join(root, "no-assets")),
            mock.patch.object(helper, "load_config", return_value={"project_id": "prj_1"}),
            mock.patch.object(helper, "access_token", return_value=({"project_id": "prj_1"}, "token")),
            mock.patch.object(helper, "api", api),
            mock.patch.object(helper, "upload_media", return_value=("med_1", "image/png")),
            mock.patch.object(helper, "notify"),
            mock.patch.object(helper, "lan_ip", return_value="192.0.2.10"),
            mock.patch.object(helper, "lan_subnet", return_value="192.0.2.0/24"),
            mock.patch.object(helper, "firewall_state", return_value="ok"),
            mock.patch.object(helper, "mediamtx_binary", return_value="/fake/mediamtx"),
            mock.patch.object(helper, "wait_for_stream", lambda url, seconds=20, recorder=None: self.probed.append(url) or self.waits.append(seconds) or True),
            mock.patch.object(helper.time, "sleep"),
            mock.patch.object(helper.subprocess, "run",
                              return_value=subprocess.CompletedProcess([], 0, "", "")),
            mock.patch.object(helper.subprocess, "Popen", popen),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.addCleanup(self.reap)

    def reap(self):
        for _, proc in self.children:
            if proc.poll() is None:
                proc.kill()
            proc.wait()

    def assertStopped(self, *names):
        started = [cmd[0] for cmd, _ in self.children]
        self.assertEqual(sorted(started), sorted(names))
        for cmd, proc in self.children:
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.fail("%s is still running" % cmd[0])

    def start(self, source="screen", screens=("scr_A",)):
        return helper.live_start(source, list(screens), 30, "Desktop")

    def live_file(self, name):
        return os.path.join(helper.LIVE_DIR, name)

    def cleared(self):
        """The screens whose takeover was ended."""
        return [path.split("/")[3] for method, path, _ in self.calls
                if method == "DELETE" and path.endswith("/takeover")]

    def test_playlist_failure_stops_the_capture(self):
        self.fail_on["playlist"] = helper.Problem("This project holds agent writes for review.")
        with self.assertRaises(helper.Problem):
            self.start(screens=("scr_A", "scr_B"))
        self.assertStopped("/fake/mediamtx", "capture")
        self.assertFalse(os.path.exists(self.live_file("live.json")))
        # No takeover was placed, so none is ended: a failed cast leaves the screens' own overrides alone.
        self.assertEqual(self.cleared(), [])
        self.assertFalse([c for c in self.calls if c[1].endswith("/takeover")])
        self.assertFalse([c for c in self.calls if c[0] == "DELETE"])

    def test_each_cast_asks_plasmas_screen_share_dialog(self):
        for source in ("screen", "window"):
            with self.subTest(source=source):
                self.start(source=source)
                capture = [cmd for cmd, _ in self.children if cmd[0] == "capture"][-1]
                self.assertEqual(capture[-2:], ["live-capture", source])
                # Time for a person to choose in the dialog.
                self.assertEqual(self.waits[-1], helper.PICK_WAIT_S)
                helper.live_stop()

    def test_a_cast_names_no_screen_or_window_itself(self):
        for source in ("window:0x5567aa", "screen:DP-1", "nonsense"):
            with self.subTest(source=source), self.assertRaises(helper.Problem):
                self.start(source=source)
        # Refused before anything started.
        self.assertStopped()

    def test_a_cast_whose_dialog_was_dismissed_says_so(self):
        fake = helper.subprocess.Popen

        def popen(cmd, **kw):
            if "live-capture" in cmd:
                return REAL_POPEN([sys.executable, "-I", "-c", "raise SystemExit(%d)" % helper.CAPTURE_CANCELLED])
            return fake(cmd, **kw)
        with mock.patch.object(helper.subprocess, "Popen", popen), \
                mock.patch.object(helper, "wait_for_stream",
                                  lambda url, seconds=20, recorder=None: recorder.wait() is None), \
                self.assertRaises(helper.Problem) as raised:
            self.start(source="window")
        self.assertIn("Nothing was chosen", str(raised.exception))
        self.assertEqual(self.cleared(), [])

    def test_capture_that_does_not_start_leaves_the_screens_alone(self):
        with mock.patch.object(helper, "wait_for_stream", return_value=False), self.assertRaises(helper.Problem):
            self.start(screens=("scr_A", "scr_B"))
        self.assertStopped("/fake/mediamtx", "capture")
        self.assertFalse(os.path.exists(self.live_file("live.json")))
        self.assertEqual(self.cleared(), [])

    def test_failure_while_placing_takeovers_ends_only_those_placed(self):
        real_api = helper.api

        def flaky(method, path, body=None, **kw):
            if method == "POST" and path == "/api/screens/scr_B/takeover":
                raise RuntimeError("unexpected")
            return real_api(method, path, body, **kw)
        with mock.patch.object(helper, "api", flaky), self.assertRaises(RuntimeError):
            self.start(screens=("scr_A", "scr_B", "scr_C"))
        self.assertStopped("/fake/mediamtx", "capture")
        self.assertFalse(os.path.exists(self.live_file("live.json")))
        self.assertEqual(self.cleared(), ["scr_A"])

    def test_a_screen_that_refused_is_not_ended_when_the_cast_stops(self):
        real_api = helper.api

        def refuse_b(method, path, body=None, **kw):
            if method == "POST" and path == "/api/screens/scr_B/takeover":
                raise helper.Problem("offline")
            return real_api(method, path, body, **kw)
        with mock.patch.object(helper, "api", refuse_b):
            self.start(screens=("scr_A", "scr_B"))
        self.assertEqual(helper.live_status()["screens"], ["scr_A"])
        helper.live_stop()
        self.assertEqual(self.cleared(), ["scr_A"])

    def test_every_screen_refusing_the_takeover_stops_the_capture(self):
        real_api = helper.api

        def refuse(method, path, body=None, **kw):
            if path.endswith("/takeover") and method == "POST":
                raise helper.Problem("offline")
            return real_api(method, path, body, **kw)
        with mock.patch.object(helper, "api", refuse), self.assertRaises(helper.Problem):
            self.start(screens=("scr_A", "scr_B"))
        self.assertStopped("/fake/mediamtx", "capture")
        self.assertFalse(os.path.exists(self.live_file("live.json")))
        self.assertEqual(self.cleared(), [])

    def test_recorder_that_cannot_start_stops_the_server(self):
        self.fail_on["capture"] = FileNotFoundError("capture")
        with self.assertRaises(FileNotFoundError):
            self.start(screens=("scr_A", "scr_B"))
        self.assertStopped("/fake/mediamtx")
        self.assertFalse(os.path.exists(self.live_file("live.json")))
        self.assertEqual(self.cleared(), [])

    def login(self, url):
        match = re.fullmatch(r"rtsp://([0-9a-f]{16}):([0-9a-f]{32})@192\.0\.2\.10:8554/live", url)
        self.assertTrue(match, "the screens' address carries a random login")
        return match.groups()

    def playlist_url(self):
        post = next(body for method, path, body in self.calls if path.endswith("/playlists"))
        return post["pages"][0]["primitives"][0]["sources"][0]["url"]

    def test_each_cast_has_its_own_login(self):
        self.start()
        first = self.login(self.playlist_url())
        self.assertEqual(self.probed, ["rtsp://%s:%s@127.0.0.1:8554/live" % first])
        helper.live_stop()
        self.calls.clear()
        self.start()
        second = self.login(self.playlist_url())
        self.assertNotEqual(first, second)
        helper.live_stop()

    def test_reading_needs_the_login_and_only_this_machine_publishes(self):
        envs = []
        fake = helper.subprocess.Popen

        def popen(cmd, **kw):
            if "live-capture" in cmd:
                envs.append(kw.get("env") or {})
            return fake(cmd, **kw)
        with mock.patch.object(helper.subprocess, "Popen", popen):
            self.start()
        user, password = self.login(self.playlist_url())
        with open(self.live_file("mediamtx.yml")) as f:
            text = f.read()
        self.assertEqual(stat.S_IMODE(os.stat(self.live_file("mediamtx.yml")).st_mode), 0o600)
        for secret in (user, password):
            self.assertNotIn(secret, text)

        def digest(value):
            return "sha256:" + base64.b64encode(hashlib.sha256(value.encode()).digest()).decode()
        self.assertIn(digest(user), text)
        self.assertIn(digest(password), text)
        # The capture publishes over loopback with the cast's second login, handed over in its environment.
        capture = next(cmd for cmd, _ in self.children if cmd[0] == "capture")
        self.assertFalse([arg for arg in capture if "rtsp://" in arg])
        sent = re.fullmatch(r"rtsp://([0-9a-f]{16}):([0-9a-f]{32})@127\.0\.0\.1:8554/live", envs[0]["SCREENRIG_PUBLISH"])
        self.assertTrue(sent, "the capture publishes with a random login")
        self.assertNotIn(sent.group(1), (user, password))
        for secret in sent.groups():
            self.assertNotIn(secret, text)
        if yaml:
            conf = yaml.safe_load(text)
            self.assertEqual(conf["authMethod"], "internal")
            # Only RTSP listens: no MoQ, WebRTC, HLS, SRT or RTMP port is opened.
            for proto in ("moq", "webrtc", "hls", "srt", "rtmp", "api", "metrics", "pprof", "playback"):
                self.assertIs(conf[proto], False, proto)
            local, reader = conf["authInternalUsers"]
            self.assertEqual((local["user"], local["pass"], local["ips"]),
                             (digest(sent.group(1)), digest(sent.group(2)), ["127.0.0.1", "::1"]))
            self.assertIs(conf["paths"]["live"]["overridePublisher"], False)
            self.assertEqual(local["permissions"], [{"action": "publish", "path": "live"}])
            self.assertEqual((reader["user"], reader["pass"], reader["ips"]), (digest(user), digest(password), []))
            self.assertEqual(reader["permissions"], [{"action": "read", "path": "live"}])
        helper.live_stop()

    def test_login_is_kept_only_in_the_private_state_until_the_cast_ends(self):
        self.start()
        _, password = self.login(self.playlist_url())
        state = self.live_file("live.json")
        self.assertEqual(stat.S_IMODE(os.stat(state).st_mode), 0o600)
        self.assertNotIn("url", helper.live_status())
        self.assertNotIn(password, json.dumps(helper.live_status()))

        def holders():
            found = []
            for top, _, names in os.walk(self.tmp.name):
                for name in names:
                    with open(os.path.join(top, name), "rb") as f:
                        if password.encode() in f.read():
                            found.append(name)
            return found
        self.assertEqual(holders(), ["live.json"])
        helper.live_stop()
        self.assertEqual(holders(), [])
        self.assertIn(("DELETE", "/api/playlists/pl_cast", None), self.calls)

    def takeover_of(self, sid):
        return (self.screens[sid]["takeover"] or {}).get("playlist_id")

    # A takeover or playlist create whose reply is lost may still have been applied.

    def test_takeover_with_a_lost_reply_is_found_and_counted(self):
        self.lost.add(("POST", "/api/screens/scr_B/takeover"))
        self.start(screens=("scr_A", "scr_B"))
        self.assertEqual(helper.live_status()["screens"], ["scr_A", "scr_B"])
        helper.live_stop()
        self.assertEqual(self.cleared(), ["scr_A", "scr_B"])
        self.assertEqual([self.takeover_of("scr_A"), self.takeover_of("scr_B")], [None, None])

    def test_takeover_that_cannot_be_read_back_is_ended_when_the_cast_stops(self):
        self.lost.add(("POST", "/api/screens/scr_A/takeover"))
        self.unreadable["scr_A"] = 1
        with mock.patch.object(helper, "warn"), self.assertRaises(helper.Problem):
            self.start()
        self.assertStopped("/fake/mediamtx", "capture")
        self.assertEqual(self.cleared(), ["scr_A"])
        self.assertIsNone(self.takeover_of("scr_A"))
        self.assertFalse(os.path.exists(self.live_file("live.json")))

    def test_every_screen_is_recorded_before_its_takeover_is_asked_for(self):
        recorded = []
        real = self.on_write

        def before_b():
            with open(self.live_file("live.json")) as f:
                recorded.append(json.load(f)["unsure"])
        real[("POST", "/api/screens/scr_B/takeover")] = before_b
        self.start(screens=("scr_A", "scr_B"))
        self.assertEqual(recorded, [["scr_B"]])
        self.assertEqual(helper.live_status()["unsure"], [])

    def test_playlist_with_a_lost_reply_is_found_by_name_and_deleted(self):
        self.lost.add(("POST", "/api/projects/prj_1/playlists"))
        with mock.patch.object(helper, "warn"), self.assertRaises(helper.Problem):
            self.start(screens=("scr_A", "scr_B"))
        self.assertStopped("/fake/mediamtx", "capture")
        self.assertEqual(self.playlists, {})
        self.assertIn(("DELETE", "/api/playlists/pl_lost", None), self.calls)
        # No screen was asked to take a playlist nobody knew the id of.
        self.assertFalse([c for c in self.calls if c[1].endswith("/takeover")])

    def test_a_refused_playlist_is_not_searched_for(self):
        self.fail_on["playlist"] = helper.Problem("This project holds agent writes for review.")
        with self.assertRaises(helper.Problem):
            self.start()
        self.assertFalse([c for c in self.calls if c[0] == "GET"])

    # Only a takeover that is still this cast's playlist is ended or renewed.

    def test_a_takeover_placed_by_someone_else_is_left_alone_when_the_cast_stops(self):
        self.start(screens=("scr_A", "scr_B"))
        self.screens["scr_B"]["takeover"] = {"playlist_id": "pl_other"}
        helper.live_stop()
        self.assertEqual(self.cleared(), ["scr_A"])
        self.assertEqual(self.takeover_of("scr_B"), "pl_other")

    def test_a_takeover_placed_between_the_check_and_the_clear_is_left_alone(self):
        self.start()

        def rival():
            self.screens["scr_A"]["takeover"] = {"playlist_id": "pl_other"}
            self.screens["scr_A"]["revision"] += 1
        self.on_write[("DELETE", "/api/screens/scr_A/takeover")] = rival
        helper.live_stop()
        self.assertEqual(self.takeover_of("scr_A"), "pl_other")
        # The clear was guarded by the revision read with the check, so the backend refused it.
        sent = [h for m, p, h in self.headers if m == "DELETE" and p == "/api/screens/scr_A/takeover"]
        self.assertEqual(sent, [{"If-Match": '"6"'}])

    def due_for_renewal(self):
        """The running cast's state, with its lease due to be renewed."""
        with open(self.live_file("live.json")) as f:
            state = json.load(f)
        state.update(lease=True, renewed_at=0)
        helper.write_private(self.live_file("live.json"), json.dumps(state))

    def test_renewal_extends_only_takeovers_that_are_still_the_casts(self):
        self.start(screens=("scr_A", "scr_B"))
        self.screens["scr_B"]["takeover"] = {"playlist_id": "pl_other"}
        self.due_for_renewal()
        self.calls.clear()
        self.headers.clear()
        with mock.patch.object(helper, "warn"), self.assertRaises(Stop):
            helper.keep_alive_loop(self.live_file("live.json"), mock.Mock(wait=mock.Mock(side_effect=[False, Stop])))
        posts = [(p, h) for m, p, h in self.headers if m == "POST"]
        self.assertEqual(posts, [("/api/screens/scr_A/takeover", {"If-Match": '"6"'})])
        self.assertEqual(self.takeover_of("scr_B"), "pl_other")
        with open(self.live_file("live.json")) as f:
            self.assertEqual(json.load(f)["screens"], ["scr_A"])

    def test_cast_ends_when_every_screen_shows_something_else(self):
        self.start()
        self.screens["scr_A"]["takeover"] = {"playlist_id": "pl_other"}
        self.due_for_renewal()
        self.calls.clear()
        with mock.patch.object(helper, "warn"):
            ended = helper.keep_alive_loop(self.live_file("live.json"), mock.Mock(wait=mock.Mock(return_value=False)))
        self.assertEqual(ended, 0)
        self.assertFalse([c for c in self.calls if c[0] == "POST"])
        self.assertFalse(os.path.exists(self.live_file("live.json")))
        self.assertEqual(self.takeover_of("scr_A"), "pl_other")
        self.assertEqual(self.cleared(), [])

    # Stop ends the capture first and says why anything else could not be undone.

    def test_capture_and_server_end_before_the_api_is_asked_anything(self):
        self.start()
        self.calls.clear()
        real_killpg = helper.os.killpg

        def killpg(pid, sig):
            self.calls.append(("KILL", pid, None))
            return real_killpg(pid, sig)
        with mock.patch.object(helper.os, "killpg", killpg):
            helper.live_stop()
        kinds = [m for m, _, _ in self.calls]
        self.assertEqual(kinds.count("KILL"), 3)
        self.assertEqual(kinds[:3], ["KILL"] * 3)
        self.assertNotIn("KILL", kinds[3:])
        self.assertTrue(kinds[3:])

    def test_unexpected_failures_do_not_leave_the_capture_running_or_skip_the_playlist(self):
        self.start(screens=("scr_A", "scr_B"))
        real_api = helper.api

        def broken(method, path, body=None, **kw):
            if method == "GET" and path.startswith("/api/screens/"):
                raise KeyError("revision")
            return real_api(method, path, body, **kw)
        with mock.patch.object(helper, "api", broken), mock.patch.object(helper, "warn") as warned:
            helper.live_stop()
        for cmd, proc in self.children:
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.fail("%s is still running" % cmd[0])
        self.assertFalse(os.path.exists(self.live_file("live.json")))
        self.assertEqual(self.playlists, {})
        self.assertEqual(sum("could not end the takeover" in c.args[0] for c in warned.call_args_list), 2)

    def test_a_playlist_that_cannot_be_deleted_is_logged_with_its_cause(self):
        self.start()
        self.fail_on["playlist_delete"] = helper.Problem("A screen still shows this playlist.", 409)
        with mock.patch.object(helper, "warn") as warned:
            helper.live_stop()
        messages = [c.args[0] for c in warned.call_args_list]
        self.assertEqual(len(messages), 1)
        self.assertIn("pl_cast", messages[0])
        self.assertIn("A screen still shows this playlist.", messages[0])


class Answer:
    """A urlopen() result whose body can fail the way a dropped connection does."""

    def __init__(self, body=b"{}", fail=None):
        self.headers = {}
        self.body, self.fail = body, fail

    def read(self):
        if self.fail:
            raise self.fail
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class Stop(Exception):
    """Ends a loop that would otherwise run forever."""


class BadAnswers(unittest.TestCase):
    CFG = {"api_url": "https://api.example.invalid", "project_id": "prj_1"}
    FAILURES = {
        "truncated body": lambda: Answer(fail=http.client.IncompleteRead(b'{"items"', 40)),
        "not JSON": lambda: Answer(b"<html>502 Bad Gateway</html>"),
        "connection reset": lambda: Answer(fail=ConnectionResetError("reset")),
        "read timeout": lambda: Answer(fail=TimeoutError("timed out")),
    }

    def setUp(self):
        for patch in (mock.patch.object(helper, "access_token", return_value=(self.CFG, "token")),
                      mock.patch.object(helper, "warn")):
            patch.start()
            self.addCleanup(patch.stop)

    def urlopen(self, name):
        return mock.patch.object(helper.urllib.request, "urlopen", side_effect=lambda *a, **k: self.FAILURES[name]())

    def test_api_turns_each_into_a_problem(self):
        for name in self.FAILURES:
            with self.subTest(name), self.urlopen(name), self.assertRaises(helper.Problem):
                helper.api("GET", "/api/screens")

    def cut_error(self):
        """A 502 whose body the connection drops while it is read."""
        class Cut(io.BytesIO):
            def read(self, *args):
                raise http.client.IncompleteRead(b"", 10)
        err = urllib.error.HTTPError("https://api.example.invalid/x", 502, "Bad Gateway", {}, Cut())
        self.addCleanup(err.close)
        return err

    def keyed(self, *answers, **call):
        """api() against a sequence of answers; returns (result or error, the Idempotency-Key of each request)."""
        sent = []

        def urlopen(req, timeout=None):
            sent.append(req.get_header("Idempotency-key"))  # urllib capitalizes header names
            answer = answers[len(sent) - 1]
            if isinstance(answer, Exception):
                raise answer
            return answer()
        with mock.patch.object(helper.urllib.request, "urlopen", urlopen), mock.patch.object(helper.time, "sleep"):
            try:
                result = helper.api("POST", "/api/screens/scr_A/takeover", {}, **call)
            except helper.Problem as err:
                result = err
        return result, sent

    def http_error(self, code, body=b'{"detail":"no"}'):
        err = urllib.error.HTTPError("https://api.example.invalid/x", code, "x", {}, io.BytesIO(body))
        self.addCleanup(err.close)
        return err

    def test_a_keyed_write_whose_answer_is_lost_is_sent_again_with_the_same_key(self):
        lost = dict(self.FAILURES)
        lost["bad gateway"] = lambda: self.http_error(502)
        lost["no route"] = lambda: urllib.error.URLError("unreachable")
        for name, make in lost.items():
            with self.subTest(name):
                first = make()
                result, sent = self.keyed(first if isinstance(first, Exception) else make,
                                          lambda: Answer(b'{"id":"scr_A"}'), idempotent=True)
                self.assertEqual(result, {"id": "scr_A"})
                self.assertEqual(len(sent), 2)
                self.assertTrue(sent[0].startswith("kde-"))
                self.assertEqual(sent[0], sent[1])

    def test_each_keyed_write_has_its_own_key(self):
        _, first = self.keyed(lambda: Answer(), idempotent=True)
        _, second = self.keyed(lambda: Answer(), idempotent=True)
        self.assertNotEqual(first, second)

    def test_a_second_lost_answer_is_uncertain_not_refused(self):
        result, sent = self.keyed(lambda: Answer(fail=ConnectionResetError("reset")),
                                  lambda: Answer(fail=TimeoutError("timed out")), idempotent=True)
        self.assertIsInstance(result, helper.Uncertain)
        self.assertEqual(len(sent), 2)

    def test_a_refusal_is_final_and_is_not_sent_again(self):
        result, sent = self.keyed(self.http_error(409), idempotent=True)
        self.assertIsInstance(result, helper.Problem)
        self.assertNotIsInstance(result, helper.Uncertain)
        self.assertEqual((result.status, len(sent)), (409, 1))

    def test_a_write_without_a_key_and_a_plain_read_are_not_sent_again(self):
        result, sent = self.keyed(lambda: Answer(fail=ConnectionResetError("reset")))
        self.assertIsInstance(result, helper.Uncertain)
        self.assertEqual(sent, [None])

    def test_a_read_can_ask_to_be_sent_again(self):
        result, sent = self.keyed(lambda: Answer(fail=ConnectionResetError("reset")), lambda: Answer(b'{"id":"scr_A"}'),
                                  retry=True)
        self.assertEqual((result, sent), ({"id": "scr_A"}, [None, None]))

    def test_error_answer_with_a_truncated_body_is_still_its_status(self):
        with mock.patch.object(helper.urllib.request, "urlopen", side_effect=self.cut_error()):
            with self.assertRaisesRegex(helper.Problem, "HTTP 502"):
                helper.api("GET", "/api/screens")

    def test_event_stream_refused_with_a_truncated_body_reconnects(self):
        sent = []
        with mock.patch.object(helper.urllib.request, "urlopen", side_effect=self.cut_error()), \
             mock.patch.object(helper, "emit", sent.append), \
             mock.patch.object(helper.time, "sleep", side_effect=Stop):
            with self.assertRaises(Stop):
                helper.Follower(do_notify=False).stream()
        self.assertEqual([(s["ok"], s["error"]) for s in sent], [(False, "HTTP 502")])

    def test_refresh_reports_and_returns(self):
        for name in self.FAILURES:
            sent = []
            with self.subTest(name), self.urlopen(name), mock.patch.object(helper, "emit", sent.append):
                helper.Follower(do_notify=False).refresh()
            self.assertEqual([(s["kind"], s["ok"]) for s in sent], [("status", False)])

    def test_snapshot_loop_survives_them(self):
        for name in self.FAILURES:
            follower = helper.Follower(do_notify=False)
            follower.dirty = mock.Mock(wait=mock.Mock(side_effect=[False, Stop]))
            with self.subTest(name), self.urlopen(name), mock.patch.object(helper, "emit"):
                with self.assertRaises(Stop):
                    follower.snapshot_loop()
            self.assertEqual(follower.dirty.wait.call_count, 2)

    def test_reviews_loop_survives_them(self):
        for name in self.FAILURES:
            with self.subTest(name), self.urlopen(name), mock.patch.object(helper.time, "sleep", side_effect=Stop):
                with self.assertRaises(Stop):
                    helper.Follower(do_notify=False).reviews_loop()

    def test_event_stream_cut_mid_chunk_reconnects(self):
        class Cut:
            def __iter__(self):
                raise http.client.IncompleteRead(b"", 5)
        sent = []
        with mock.patch.object(helper.urllib.request, "urlopen", return_value=Cut()), \
             mock.patch.object(helper, "emit", sent.append), \
             mock.patch.object(helper.time, "sleep", side_effect=Stop):
            with self.assertRaises(Stop):
                helper.Follower(do_notify=False).stream()
        self.assertEqual([s["ok"] for s in sent], [True, False])


class PluginLookup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.caches = {agent: os.path.join(self.tmp.name, agent) for agent in ("claude", "codex", "grok")}
        patch = mock.patch.object(helper, "PLUGIN_CACHES", self.caches)
        patch.start()
        self.addCleanup(patch.stop)

    def install(self, agent, version="26.11.298"):
        root = os.path.join(self.caches[agent], "screenrig-a1b2c3" if agent == "grok" else version)
        for suffix in ("skills/screenrig/SKILL.md", "cli/dist/bin.js"):
            path = os.path.join(root, suffix)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            open(path, "w").close()
        os.makedirs(os.path.join(root, ".claude-plugin"))
        with open(os.path.join(root, ".claude-plugin", "plugin.json"), "w") as f:
            json.dump({"name": "screenrig", "version": version}, f)
        return root

    def test_default_grok_is_ready_when_plugin_is_installed(self):
        for agent in self.caches:
            self.install(agent)
        with mock.patch.object(helper, "default_agent", return_value="grok"), \
             mock.patch.object(helper.shutil, "which", side_effect=lambda name: "/bin/" + name), \
             mock.patch.object(helper, "load_config", return_value={"token": "fixture"}):
            status = helper.onboarding()
        self.assertEqual(status["agent"], "grok")
        self.assertTrue(status["plugin"] and status["cli"] and status["signed_in"])

    def test_uses_installed_integration_when_default_has_no_plugin(self):
        self.install("codex")
        for preferred in ("grok", "claude", "other-agent"):
            with self.subTest(preferred=preferred), \
                 mock.patch.object(helper, "default_agent", return_value=preferred), \
                 mock.patch.object(helper.shutil, "which", side_effect=lambda name: "/bin/" + name):
                self.assertEqual(helper.panel_agent(), "codex")

    def test_ignores_plugin_when_its_agent_executable_is_missing(self):
        self.install("grok")
        self.install("codex")
        with mock.patch.object(helper, "default_agent", return_value="grok"), \
             mock.patch.object(helper.shutil, "which", side_effect=lambda name: "/bin/codex" if name == "codex" else None):
            self.assertEqual(helper.panel_agent(), "codex")

    def test_offers_install_for_available_grok_when_no_plugin_is_installed(self):
        with mock.patch.object(helper, "default_agent", return_value="grok"), \
             mock.patch.object(helper.shutil, "which", side_effect=lambda name: "/bin/grok" if name == "grok" else None), \
             mock.patch.object(helper, "load_config", return_value={}):
            status = helper.onboarding()
        self.assertEqual(status["agent_name"], "Grok")
        self.assertTrue(status["installable"])
        self.assertFalse(status["plugin"])

    def test_grok_bundle_uses_manifest_version_for_cli_selection(self):
        self.install("codex", "26.11.275")
        grok = self.install("grok")
        with mock.patch.dict(os.environ, {"SCREENRIG_CLI": ""}), \
             mock.patch.object(helper.shutil, "which", return_value="/usr/bin/node"):
            self.assertEqual(helper.cli_command(), ["/usr/bin/node", os.path.join(grok, "cli", "dist", "bin.js")])

    def test_newest_bundled_cli_across_agents(self):
        import tempfile
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            caches = {"claude": os.path.join(tmp, "claude"), "codex": os.path.join(tmp, "codex")}
            for root, version in (("claude", "26.10.1155"), ("codex", "26.11.275"), ("codex", "26.9.2")):
                path = os.path.join(caches[root], version, "cli", "dist")
                os.makedirs(path)
                open(os.path.join(path, "bin.js"), "w").close()
            with mock.patch.object(helper, "PLUGIN_CACHES", caches), \
                 mock.patch.dict(os.environ, {"SCREENRIG_CLI": ""}), \
                 mock.patch.object(helper.shutil, "which", return_value="/usr/bin/node"):
                self.assertEqual(helper.cli_command(),
                                 ["/usr/bin/node", os.path.join(caches["codex"], "26.11.275", "cli", "dist", "bin.js")])



class Hardening(unittest.TestCase):
    def test_stream_probe_sends_the_login_in_a_header(self):
        import socket
        import threading
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        self.addCleanup(server.close)
        port = server.getsockname()[1]
        seen = []

        def serve(answer):
            conn, _ = server.accept()
            with conn:
                seen.append(conn.recv(4096).decode())
                conn.sendall(answer)
        for answer, expected in ((b"RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n", True), (b"RTSP/1.0 404 Not Found\r\n\r\n", False)):
            thread = threading.Thread(target=serve, args=(answer,))
            thread.start()
            self.assertIs(helper.stream_ready("rtsp://u1:p1@127.0.0.1:%d/live" % port), expected)
            thread.join()
        self.assertTrue(seen[0].startswith("DESCRIBE rtsp://127.0.0.1:%d/live RTSP/1.0\r\n" % port))
        self.assertIn("Authorization: Basic " + base64.b64encode(b"u1:p1").decode(), seen[0])
        self.assertNotIn("u1:p1@", seen[0])

    def test_stream_probe_of_a_closed_port_is_not_ready(self):
        self.assertFalse(helper.stream_ready("rtsp://u:p@127.0.0.1:1/live"))

    def subnet(self, ip, addr):
        out = "2: wlan0    inet %s brd 0.0.0.0 scope global wlan0\n" % addr
        with mock.patch.object(helper.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, out, "")):
            return helper.lan_subnet(ip)

    def test_firewall_rule_is_only_ever_for_a_private_network(self):
        self.assertEqual(helper.rule_subnet(self.subnet("192.168.1.20", "192.168.1.20/24")), "192.168.1.0/24")
        self.assertEqual(helper.rule_subnet(self.subnet("10.20.4.5", "10.20.4.5/16")), "10.20.0.0/16")
        for ip, addr in (("10.20.4.5", "10.20.4.5/0"), ("10.20.4.5", "10.20.4.5/8"), ("203.0.113.9", "203.0.113.9/24")):
            with self.assertRaises(helper.Problem):
                helper.rule_subnet(self.subnet(ip, addr))

    def test_allowing_live_casting_never_writes_a_rule_for_a_wide_network(self):
        runs = []
        with mock.patch.object(helper, "firewall_kind", return_value="ufw"), \
                mock.patch.object(helper, "lan_ip", return_value="10.0.0.5"), \
                mock.patch.object(helper, "lan_subnet", return_value="0.0.0.0/0"), \
                mock.patch.object(helper, "firewall_state", return_value="needed"), \
                mock.patch.object(helper.subprocess, "run", lambda cmd, **kw: runs.append(cmd)), \
                self.assertRaises(helper.Problem):
            helper.live_setup()
        self.assertEqual(runs, [])

    def test_a_wide_network_without_a_firewall_still_casts(self):
        # No rule is written when ufw is off, so the width of the network is the person's own business.
        self.assertEqual(self.subnet("10.0.0.5", "10.0.0.5/8"), "10.0.0.0/8")
        answers = {"systemctl": subprocess.CompletedProcess([], 0, "", ""),
                   "sudo": subprocess.CompletedProcess([], 0, "Status: inactive\n", "")}
        with mock.patch.object(helper, "firewall_kind", return_value="ufw"), \
                mock.patch.object(helper, "lan_ip", return_value="10.0.0.5"), \
                mock.patch.object(helper, "lan_subnet", return_value="10.0.0.0/8"), \
                mock.patch.object(helper.subprocess, "run", lambda cmd, **kw: answers[cmd[0]]):
            self.assertEqual(helper.live_setup_status()["firewall"], "inactive")
            self.assertEqual(helper.live_setup(), "Live casting is set up")

    def test_ufw_switched_off_needs_no_rule(self):
        answers = {"systemctl": subprocess.CompletedProcess([], 0, "", ""),
                   "sudo": subprocess.CompletedProcess([], 0, "Status: inactive\n", "")}
        with mock.patch.object(helper, "firewall_kind", return_value="ufw"), \
                mock.patch.object(helper.subprocess, "run", lambda cmd, **kw: answers[cmd[0]]):
            self.assertEqual(helper.firewall_state("192.168.1.0/24"), "inactive")
            answers["sudo"] = subprocess.CompletedProcess([], 0, "Status: active\n\nTo  Action  From\n", "")
            self.assertEqual(helper.firewall_state("192.168.1.0/24"), "needed")
            answers["sudo"] = subprocess.CompletedProcess(
                [], 0, "Status: active\n\n8554/tcp                   ALLOW       192.168.1.0/24                # screenRIG live cast\n", "")
            self.assertEqual(helper.firewall_state("192.168.1.0/24"), "ok")

    def test_api_is_https_or_this_machine(self):
        self.assertEqual(helper.api_base({}), "https://api.screenrig.ai")
        self.assertEqual(helper.api_base({"api_url": "http://localhost:8080/"}), "http://localhost:8080")
        for bad in ("http://api.screenrig.ai", "ftp://x", "http://localhost.evil.example"):
            with self.assertRaises(helper.Problem):
                helper.api_base({"api_url": bad})

    def test_a_redirect_is_not_followed_with_the_sign_in(self):
        import http.server
        import threading
        hits = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append((self.path, self.headers.get("Authorization")))
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:%d/elsewhere" % self.server.server_address[1])
                self.end_headers()

            def log_message(self, *a):
                pass
        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.addCleanup(server.server_close)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.shutdown)
        cfg = {"api_url": "http://127.0.0.1:%d" % server.server_address[1], "project_id": "prj_1"}
        with mock.patch.object(helper, "access_token", return_value=(cfg, "tok")), self.assertRaises(helper.Problem):
            helper._send("GET", "/api/x", None, False, {})
        self.assertEqual(hits, [("/api/x", "Bearer tok")])

    def test_only_plain_ids_reach_commands_and_paths(self):
        items = [{"id": "scr_A1-b"}, {"id": "scr_x; rm -rf ~"}, {"id": "../../etc"}, {"id": "a'b"}, {"id": ""}, {}]
        self.assertEqual(helper.safe_ids(items), [{"id": "scr_A1-b"}])

    def test_only_https_addresses_are_opened(self):
        with mock.patch.object(helper.subprocess, "Popen") as popen:
            for bad in ("file:///etc/passwd", "javascript:alert(1)", "http://example.com", "smb://host/share"):
                with self.assertRaises(helper.Problem):
                    helper.open_url(bad)
            popen.assert_not_called()
            helper.open_url("https://screenrig.ai/dashboard/")
            popen.assert_called_once()

