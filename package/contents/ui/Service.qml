import QtQuick
import org.kde.plasma.plasma5support as P5Support

// Owns the project snapshot the chip and the panel read. The helper's `serve`
// follows the project in the background; `wait` returns as soon as something
// changed, so this keeps exactly one `wait` running. Actions run the helper and
// report back.
Item {
  id: root
  visible: false

  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("../bin/screenrig-kde").toString().replace("file://", ""))

  property var screens: []
  property var playlists: []
  property var project: ({})
  property var credits: ({})
  property bool ready: false
  property bool connected: false
  property string lastError: ""
  readonly property int onlineCount: count(true)
  readonly property int offlineCount: screens.length - onlineCount
  // Screens that went offline since the panel was last opened.
  property var droppedIds: []
  property string statusMessage: ""
  property bool statusOk: true

  property var projects: []
  property bool switching: false
  // After teardown the widget stops following until Plasma loads it again.
  property bool active: true

  signal actionFinished(bool ok, string message)
  // The helper asked the panel to open (a notification's Open, a capture, Open With).
  signal summoned(var payload)

  // ------------------------------------------------------------ processes
  P5Support.DataSource {
    id: exec
    engine: "executable"
    connectedSources: []
    property var pending: ({})
    onNewData: function(source, data) {
      var done = pending[source]
      delete pending[source]
      disconnectSource(source)
      if (done) done(Number(data["exit code"]), String(data.stdout || ""), String(data.stderr || ""))
    }
  }
  property int nonce: 0

  function quote(arg) { return "'" + String(arg).replace(/'/g, "'\\''") + "'" }

  // Run the helper with args; done(code, stdout, stderr).
  function spawn(args, done) {
    nonce++
    // The engine keys commands by their text: the nonce keeps two equal commands apart.
    var cmd = "SCREENRIG_REQ=" + nonce + " " + [helper].concat(args).map(quote).join(" ")
    exec.pending[cmd] = done || null
    exec.connectSource(cmd)
  }

  // Run the helper with args; done(ok, message, payload) gets its JSON answer.
  function run(args, done) {
    spawn(args, function(code, out) {
      var lines = out.trim().split("\n")
      var answer = {}
      try { answer = JSON.parse(lines[lines.length - 1] || "{}") } catch (e) {}
      if (done) done(answer.ok === true, String(answer.message || ""), answer)
    })
  }

  function runDetached(args) { spawn(args, null) }

  // ------------------------------------------------------------- the feed
  property int seq: -1
  // Summons older than the widget are not for it.
  property real summonAt: Date.now() / 1000

  function poll() {
    if (!active) return
    spawn(["wait", "--since", String(seq), "--summon", String(summonAt)], function(code, out) {
      var answer = {}
      try { answer = JSON.parse(out.trim().split("\n").pop() || "{}") } catch (e) {}
      if (answer.ok) {
        var feed = answer.feed || {}
        if (feed.seq !== root.seq) {
          root.seq = feed.seq
          if (feed.snapshot) root.ingest(feed.snapshot)
          var st = feed.status || {}
          root.connected = !!st.ok
          if (!st.ok && st.error) root.lastError = st.error
        }
        root.live = answer.live || { live: false }
        if (answer.summon) {
          root.summonAt = answer.summon.at
          root.summoned(answer.summon.payload || {})
        }
      }
      pollTimer.interval = answer.ok ? 10 : 3000
      pollTimer.restart()
    })
  }

  Timer { id: pollTimer; onTriggered: root.poll() }

  function ingest(msg) {
    var before = {}
    for (var i = 0; i < screens.length; i++) before[screens[i].id] = screens[i].online
    var dropped = droppedIds.slice()
    for (var j = 0; j < msg.screens.length; j++) {
      var s = msg.screens[j]
      var at = dropped.indexOf(s.id)
      if (ready && before[s.id] === true && !s.online && at < 0) dropped.push(s.id)
      if (s.online && at >= 0) dropped.splice(at, 1)
    }
    screens = msg.screens
    playlists = msg.playlists
    project = msg.project || {}
    if (msg.credits && msg.credits.low !== undefined) credits = msg.credits
    droppedIds = dropped
    ready = true
    lastError = ""
  }

  function count(online) {
    var n = 0
    for (var i = 0; i < screens.length; i++) if (screens[i].online === online) n++
    return n
  }

  function screenById(id) {
    for (var i = 0; i < screens.length; i++) if (screens[i].id === id) return screens[i]
    return null
  }

  function droppedNames() {
    var names = []
    for (var i = 0; i < droppedIds.length; i++) {
      var s = screenById(droppedIds[i])
      names.push(s ? s.label : droppedIds[i])
    }
    return names
  }

  function acknowledge() {
    if (droppedIds.length) droppedIds = []
  }

  // Start from a clean slate after the project or sign-in changed.
  function restartFeed() {
    ready = false
    screens = []
    playlists = []
    droppedIds = []
    seq = -1
    loadProjects()
  }

  // ------------------------------------------------------------- projects
  function loadProjects() {
    run(["projects"], function(ok, message, answer) {
      if (ok) root.projects = answer.projects || []
    })
  }

  // Add a project to this sign-in: the person approves it in the dashboard.
  property var pendingLogin: null

  function addProject() {
    if (pendingLogin) {
      Qt.openUrlExternally(pendingLogin.url)
      return
    }
    run(["login-start"], function(ok, message, answer) {
      if (!ok) { root.report(false, message || "Could not start the approval"); return }
      root.pendingLogin = { code: answer.code, url: answer.url, login: answer.login }
      root.run(["login-wait", answer.login], function(ok2, message2) {
        root.pendingLogin = null
        root.report(ok2, message2)
        if (ok2) root.restartFeed()
      })
    })
  }

  function switchProject(id) {
    if (!id || id === project.id || switching) return
    switching = true
    run(["project-use", id], function(ok, message) {
      root.switching = false
      root.report(ok, message)
      if (ok) root.restartFeed()
    })
  }

  // ------------------------------------------------------------- actions
  function act(screenId, action, arg) {
    var args = ["act", screenId, action]
    if (arg !== undefined && arg !== null) args.push(String(arg))
    run(args, function(ok, message) { root.report(ok, message) })
  }

  function report(ok, message) {
    statusOk = ok
    statusMessage = message || (ok ? "Done" : "Failed")
    actionFinished(ok, statusMessage)
    clearStatus.restart()
  }

  Timer {
    id: clearStatus
    interval: 8000
    onTriggered: root.statusMessage = ""
  }

  // ------------------------------------------------------------- live cast
  property var live: ({ live: false })
  property var liveTargets: ({ ok: false, screens: [] })

  function refreshLive() {
    run(["live-status"], function(ok, message, answer) { root.live = answer || { live: false } })
  }

  function loadLiveTargets() {
    run(["live-targets"], function(ok, message, answer) {
      root.liveTargets = ok ? answer : { ok: true, screens: [], elsewhere: 0, error: message }
    })
  }

  function liveStart(source, label, screens, minutes, done) {
    run(["live-start", "--source", source, "--label", label, "--screens", screens.join(","), "--minutes", String(minutes)],
        function(ok, message) {
          root.refreshLive()
          if (done) done(ok, message)
        })
  }

  function liveStop(done) {
    run(["live-stop"], function(ok, message) {
      root.report(ok, message)
      root.refreshLive()
      if (done) done(ok, message)
    })
  }

  // A timed cast ends on time even while nobody looks at the panel.
  Timer {
    interval: 5000
    repeat: true
    running: !!root.live.live && !!root.live.until
    onTriggered: if (Date.parse(root.live.until) <= Date.now()) root.liveStop()
  }

  // Undo everything the widget changed on this computer.
  function teardown() {
    active = false
    pollTimer.stop()
    run(["teardown"], function(ok, message) { root.report(ok, message) })
  }

  Component.onCompleted: {
    run(["setup"])
    loadProjects()
    poll()
  }
}
