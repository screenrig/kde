import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

// The screenRIG panel: every screen with its latest screenshot and actions, and
// Cast (live desktop or window, a region capture, the clipboard or a file).
PlasmaExtras.Representation {
  id: panel

  readonly property var svc: root.svc
  readonly property real u: Kirigami.Units.gridUnit

  Layout.preferredWidth: u * 46
  Layout.preferredHeight: u * 34
  Layout.minimumWidth: u * 30
  Layout.minimumHeight: u * 22
  collapseMarginsHint: true

  // -------------------------------------------------------------- state
  readonly property var tabs: [
    { id: "screens", label: "Screens", icon: "video-display" },
    { id: "cast", label: "Cast", icon: "media-record" }
  ]
  property string mode: Plasmoid.configuration.lastMode === "cast" ? "cast" : "screens"
  onModeChanged: {
    Plasmoid.configuration.lastMode = mode
    if (mode === "cast" && !casting && !openingSend) resetCast()
  }
  property bool openingSend: false

  property string focusId: ""
  property string screenFilter: "all"
  property string search: ""
  property var picker: null
  property int pickMinutes: 30
  property int shotBump: 0
  property double nowMs: Date.now()

  // Cast: "live", or what a capture, the clipboard or a file brought.
  property string sendSource: "live"
  property string sendKind: ""
  property string sendPath: ""
  property string sendUrl: ""
  property var sendSelected: ({})
  property int sendMinutes: 10
  property bool sending: false
  property string liveSource: "screen"
  property int liveMinutes: 0
  readonly property var liveSources: [
    { id: "screen", title: "Desktop", detail: "A whole screen. Plasma asks which when the cast starts.", icon: "video-display" },
    { id: "window", title: "A window", detail: "One app window. Plasma asks which when the cast starts.", icon: "window" }
  ]
  readonly property string liveLabel: liveSource === "window" ? "A window" : "Desktop"

  readonly property bool casting: root.casting
  property bool stopping: false
  onCastingChanged: if (!casting) stopping = false
  property double tickMs: Date.now()

  // ------------------------------------------------------------ opening
  Connections {
    target: root
    function onOpened(payload) { panel.open(payload || {}) }
  }

  function open(p) {
    var want = p.mode
    openingSend = !!(p.kind || p.path || p.url)
    if (want === "screens" || want === "cast") mode = want
    openingSend = false
    focusId = p.focus || ""
    picker = null
    if (focusId !== "") { screenFilter = "all"; search = "" }
    if (mode === "cast" && !(p.kind || p.path || p.url) && !casting) resetCast()
    if (p.kind || p.path || p.url) {
      sendKind = p.kind || ""
      sendSource = p.source || (p.kind === "url" ? "clipboard" : "file")
      sendPath = p.path || ""
      sendUrl = p.url || ""
      sendSelected = ({})
      sending = false
      Qt.callLater(preselectScreens)
    }
    nowMs = Date.now()
    svc.acknowledge()
    svc.loadProjects()
    svc.refreshLive()
    svc.loadLiveTargets()
    refreshOnboarding()
    refreshLiveSetup()
    Qt.callLater(scrollToFocus)
  }

  Component.onCompleted: open({})

  // ------------------------------------------------------------ helpers
  readonly property var visibleScreens: {
    var list = svc.screens
    var q = search.trim().toLowerCase()
    var out = []
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      if (screenFilter === "online" && !s.online) continue
      if (screenFilter === "offline" && s.online) continue
      if (q !== "" && (s.label + " " + (s.playing_name || "")).toLowerCase().indexOf(q) < 0) continue
      out.push(s)
    }
    return out
  }

  function scrollToFocus() {
    for (var i = 0; i < visibleScreens.length; i++)
      if (visibleScreens[i].id === focusId) { grid.positionViewAtIndex(i, GridView.Contain); return }
  }

  function ago(iso) {
    if (!iso) return "never"
    var s = Math.max(0, Math.round((nowMs - Date.parse(iso)) / 1000))
    if (s < 60) return s + "s ago"
    if (s < 3600) return Math.round(s / 60) + "m ago"
    if (s < 86400) return Math.round(s / 3600) + "h ago"
    return Math.round(s / 86400) + "d ago"
  }

  function minutesLeft(iso) {
    if (!iso) return ""
    var m = Math.round((Date.parse(iso) - nowMs) / 60000)
    return m > 0 ? " · " + m + " min" : ""
  }

  function has(list, value) { return (list || []).indexOf(value) >= 0 }

  function countWhere(online) {
    var n = 0
    for (var i = 0; i < svc.screens.length; i++) if (online === null || svc.screens[i].online === online) n++
    return n
  }

  function restartAction(s) {
    if (has(s.capabilities, "reboot")) return { action: "reboot", tip: "Reboot the device" }
    if (has(s.capabilities, "restart_app")) return { action: "restart-app", tip: "Restart the Player app" }
    return { action: "", tip: "This device cannot be restarted remotely" }
  }

  function isImage(path) { return /\.(png|jpe?g|webp|gif)$/i.test(path || "") }

  function screenNames(ids) {
    var names = []
    for (var i = 0; i < ids.length; i++) {
      var s = svc.screenById(ids[i])
      names.push(s ? s.label : ids[i])
    }
    if (names.length <= 1) return names.join("")
    return names.slice(0, -1).join(", ") + " and " + names[names.length - 1]
  }

  // 1:04:09 or 12:34.
  function clock(ms) {
    var t = Math.max(0, Math.floor(ms / 1000))
    var h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), sec = t % 60
    var pad = function(n) { return (n < 10 ? "0" : "") + n }
    return (h > 0 ? h + ":" + pad(m) : m) + ":" + pad(sec)
  }

  Timer {
    interval: 15000
    repeat: true
    running: root.expanded
    onTriggered: panel.nowMs = Date.now()
  }

  Timer {
    interval: 1000
    repeat: true
    running: panel.casting && root.expanded
    triggeredOnStart: true
    onTriggered: panel.tickMs = Date.now()
  }

  // --------------------------------------------------------- cast logic
  function castTargets() {
    if (sendSource === "live") return svc.liveTargets.screens || []
    return svc.screens
  }

  function selectedIds() {
    var ids = []
    var allowed = {}
    var list = castTargets()
    for (var i = 0; i < list.length; i++) if (list[i].online) allowed[list[i].id] = true
    for (var k in sendSelected) if (sendSelected[k] && allowed[k]) ids.push(k)
    return ids
  }

  function toggleSend(id) {
    var next = Object.assign({}, sendSelected)
    next[id] = !next[id]
    sendSelected = next
  }

  function allTargetsSelected() {
    var list = castTargets()
    var any = false
    for (var i = 0; i < list.length; i++) {
      if (!list[i].online) continue
      any = true
      if (!sendSelected[list[i].id]) return false
    }
    return any
  }

  function selectAllTargets() {
    var clear = allTargetsSelected()
    var next = {}
    var list = castTargets()
    if (!clear) for (var i = 0; i < list.length; i++) if (list[i].online) next[list[i].id] = true
    sendSelected = next
  }

  // Preselect the screens of the last cast that are available now.
  function preselectScreens() {
    if (selectedIds().length) return
    var want = (svc.liveTargets.last || {}).screens || []
    var list = castTargets()
    var next = {}
    for (var i = 0; i < list.length; i++) if (list[i].online && want.indexOf(list[i].id) >= 0) next[list[i].id] = true
    sendSelected = next
  }

  Connections {
    target: panel.svc
    function onLiveTargetsChanged() {
      var last = panel.svc.liveTargets.last || {}
      if (last.source === "screen" || last.source === "window") panel.liveSource = last.source
      panel.preselectScreens()
    }
  }

  // Cast starts live, until stopped, with the source and screens cast last.
  function resetCast() {
    sendSource = "live"
    sendKind = ""
    sendSelected = ({})
    liveMinutes = 0
    preselectScreens()
  }

  function doSend() {
    var ids = selectedIds()
    if (!ids.length || sending || sendKind === "") return
    sending = true
    var args = ["send", "--screens", ids.join(","), "--minutes", String(sendMinutes)]
    args = args.concat(sendKind === "url" ? ["--url", sendUrl] : ["--file", sendPath])
    svc.report(true, "Casting to " + ids.length + " screen" + (ids.length === 1 ? "" : "s"))
    svc.run(args, function(ok, message) {
      panel.sending = false
      svc.report(ok, message)
      if (ok) { panel.mode = "screens"; panel.sendKind = "" }
    })
  }

  // Live casting changes this computer only after the person allows it here.
  property var liveSetup: ({})
  readonly property bool needsFirewall: liveSetup.firewall === "needed" || liveSetup.firewall === "no-sudo"
  readonly property bool needsConsent: sendSource === "live" && needsFirewall
  property bool allowing: false
  function refreshLiveSetup() {
    svc.run(["live-setup-status"], function(ok, message, answer) { if (ok) panel.liveSetup = answer })
  }
  function allowLive() {
    allowing = true
    svc.run(["live-setup"], function(ok, message) {
      panel.allowing = false
      svc.report(ok, message)
      panel.refreshLiveSetup()
    })
  }

  function goLive() {
    var ids = selectedIds()
    if (!ids.length || sending || needsConsent) return
    sending = true
    svc.report(true, "Choose what to share in Plasma's dialog")
    // Plasma's screen-share dialog opens as a window: step out of its way.
    root.expanded = false
    svc.liveStart(liveSource, liveLabel, ids, liveMinutes, function(ok, message) {
      panel.sending = false
      svc.report(ok, message)
      if (ok) panel.mode = "cast"
      if (!ok) svc.runDetached(["summon", JSON.stringify({ mode: "cast" })])
    })
  }

  function stopCast() {
    if (stopping) return
    stopping = true
    svc.liveStop()
  }

  // First run: the screenRIG plugin for an agent, then a sign-in.
  property var onboarding: ({})
  property bool installingPlugin: false
  readonly property bool needsPlugin: onboarding.ok === true && !(onboarding.plugin && onboarding.cli)
  readonly property bool needsSignIn: onboarding.ok === true && !onboarding.signed_in
  readonly property bool firstRun: needsPlugin || needsSignIn
  function refreshOnboarding() {
    svc.run(["onboarding"], function(ok, message, answer) { if (ok) panel.onboarding = answer })
  }
  function installPlugin() {
    if (installingPlugin) return
    installingPlugin = true
    svc.run(["install-plugin"], function(ok, message) {
      panel.installingPlugin = false
      svc.report(ok, message)
      panel.refreshOnboarding()
    })
  }
  Connections {
    target: panel.svc
    function onPendingLoginChanged() { if (!panel.svc.pendingLogin) panel.refreshOnboarding() }
  }

  // ------------------------------------------------------------- header
  header: PlasmaExtras.PlasmoidHeading {
    RowLayout {
      anchors.fill: parent
      spacing: Kirigami.Units.smallSpacing

      Kirigami.Icon {
        Layout.leftMargin: Kirigami.Units.smallSpacing
        Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
        Layout.preferredHeight: Layout.preferredWidth
        source: Qt.resolvedUrl("../icons/screenrig.svg")
      }

      PlasmaComponents3.ToolButton {
        id: projectButton
        text: panel.svc.project.name || "screenRIG"
        icon.name: "go-down"
        LayoutMirroring.enabled: true
        checkable: true
        checked: projectMenu.visible
        onClicked: projectMenu.popup(projectButton, 0, projectButton.height)
        PlasmaComponents3.ToolTip { text: panel.svc.project.organization ? panel.svc.project.organization : "Switch project" }
      }

      Item { Layout.fillWidth: true }

      Repeater {
        model: panel.firstRun ? [] : panel.tabs
        PlasmaComponents3.ToolButton {
          required property var modelData
          text: modelData.label
          icon.name: modelData.icon
          checkable: true
          checked: panel.mode === modelData.id
          onClicked: panel.mode = modelData.id
        }
      }

      PlasmaComponents3.ToolButton {
        icon.name: "globe"
        display: QQC2.AbstractButton.IconOnly
        text: "Open the dashboard"
        onClicked: Qt.openUrlExternally("https://screenrig.ai/dashboard")
        PlasmaComponents3.ToolTip { text: parent.text }
      }
    }

    PlasmaComponents3.Menu {
      id: projectMenu
      Instantiator {
        model: panel.svc.projects
        delegate: PlasmaComponents3.MenuItem {
          required property var modelData
          text: modelData.name + (modelData.organization ? "  ·  " + modelData.organization : "")
          checkable: true
          checked: modelData.current
          onTriggered: panel.svc.switchProject(modelData.id)
        }
        onObjectAdded: function(index, object) { projectMenu.insertItem(index, object) }
        onObjectRemoved: function(index, object) { projectMenu.removeItem(object) }
      }
      PlasmaComponents3.MenuSeparator {}
      PlasmaComponents3.MenuItem {
        text: panel.svc.pendingLogin ? "Approve code " + panel.svc.pendingLogin.code + " in the browser" : "Add a project"
        icon.name: "list-add"
        onTriggered: panel.svc.addProject()
      }
      PlasmaComponents3.MenuItem {
        text: "Manage projects"
        icon.name: "configure"
        onTriggered: Qt.openUrlExternally("https://screenrig.ai/dashboard/projects")
      }
    }
  }

  // ------------------------------------------------------------- footer
  footer: PlasmaExtras.PlasmoidHeading {
    visible: panel.svc.statusMessage !== "" || (!panel.svc.connected && panel.svc.lastError !== "")
    position: PlasmaComponents3.ToolBar.Footer
    RowLayout {
      anchors.fill: parent
      Kirigami.Icon {
        Layout.preferredWidth: Kirigami.Units.iconSizes.small
        Layout.preferredHeight: Kirigami.Units.iconSizes.small
        source: panel.svc.statusMessage !== "" ? (panel.svc.statusOk ? "dialog-ok-apply" : "dialog-error") : "network-disconnect"
      }
      PlasmaComponents3.Label {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: panel.svc.statusMessage !== "" ? panel.svc.statusMessage : panel.svc.lastError
      }
    }
  }

  // --------------------------------------------------------------- body
  StackLayout {
    anchors.fill: parent
    anchors.margins: Kirigami.Units.smallSpacing
    currentIndex: panel.firstRun ? 0 : (panel.mode === "cast" ? 2 : 1)

    // ---------------------------------------------------- first run
    Item {
      ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - panel.u * 2, panel.u * 30)
        spacing: Kirigami.Units.largeSpacing

        Kirigami.Heading { level: 2; text: "Set up screenRIG" }
        PlasmaComponents3.Label {
          Layout.fillWidth: true
          wrapMode: Text.Wrap
          opacity: 0.7
          text: "screenRIG is free digital signage driven by your AI agent. The panel uses the official screenRIG plugin (its skill and CLI) and your screenRIG sign-in."
        }

        RowLayout {
          spacing: Kirigami.Units.largeSpacing
          Kirigami.Icon {
            Layout.preferredWidth: Kirigami.Units.iconSizes.medium
            Layout.preferredHeight: Layout.preferredWidth
            source: panel.needsPlugin ? "download" : "checkmark"
          }
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            PlasmaComponents3.Label { text: "Install the screenRIG plugin for " + (panel.onboarding.agent_name || "your agent") }
            PlasmaComponents3.Label {
              Layout.fillWidth: true
              wrapMode: Text.Wrap
              opacity: 0.7
              text: !panel.needsPlugin ? "Installed"
                : panel.onboarding.installable
                  ? "Runs " + (panel.onboarding.agent || "the agent") + "'s plugin install from github.com/screenrig/plugin."
                  : "Install it from github.com/screenrig/plugin, then open the panel again."
            }
          }
          PlasmaComponents3.Button {
            visible: panel.needsPlugin && !!panel.onboarding.installable
            icon.name: "download"
            text: panel.installingPlugin ? "Installing" : "Install"
            enabled: !panel.installingPlugin
            onClicked: panel.installPlugin()
          }
        }

        RowLayout {
          spacing: Kirigami.Units.largeSpacing
          Kirigami.Icon {
            Layout.preferredWidth: Kirigami.Units.iconSizes.medium
            Layout.preferredHeight: Layout.preferredWidth
            source: panel.needsSignIn ? "im-user" : "checkmark"
          }
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            PlasmaComponents3.Label { text: "Sign in to screenRIG" }
            PlasmaComponents3.Label {
              Layout.fillWidth: true
              wrapMode: Text.Wrap
              opacity: 0.7
              text: !panel.needsSignIn ? "Signed in"
                : panel.svc.pendingLogin ? "Approve code " + panel.svc.pendingLogin.code + " in the browser."
                : "Opens screenrig.ai in your browser to approve this computer."
            }
          }
          PlasmaComponents3.Button {
            visible: panel.needsSignIn
            icon.name: "im-user"
            text: panel.svc.pendingLogin ? "Open again" : "Sign in"
            enabled: !panel.needsPlugin
            onClicked: panel.svc.addProject()
          }
        }
      }
    }

    // ------------------------------------------------------ screens
    ColumnLayout {
      spacing: Kirigami.Units.smallSpacing

      RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing
        Repeater {
          model: [
            { id: "all", label: "All", count: panel.countWhere(null) },
            { id: "online", label: "Online", count: panel.countWhere(true) },
            { id: "offline", label: "Offline", count: panel.countWhere(false) }
          ]
          PlasmaComponents3.ToolButton {
            required property var modelData
            text: modelData.label + "  " + modelData.count
            checkable: true
            checked: panel.screenFilter === modelData.id
            onClicked: panel.screenFilter = modelData.id
          }
        }
        Item { Layout.fillWidth: true }
        PlasmaExtras.SearchField {
          Layout.preferredWidth: panel.u * 14
          placeholderText: "Search screens and playlists"
          text: panel.search
          onTextChanged: panel.search = text
        }
      }

      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true

        PlasmaExtras.PlaceholderMessage {
          anchors.centerIn: parent
          width: parent.width - panel.u * 4
          visible: !panel.svc.ready || panel.visibleScreens.length === 0
          iconName: panel.svc.ready ? "video-display" : (panel.svc.lastError !== "" ? "network-disconnect" : "")
          text: !panel.svc.ready ? (panel.svc.lastError !== "" ? panel.svc.lastError : "Loading screens")
            : (panel.svc.screens.length === 0 ? "No screens yet" : "No screens match")
          explanation: panel.svc.ready && panel.svc.screens.length === 0 ? "Pair a Player in the dashboard, or ask your agent to add one." : ""
        }

        PlasmaComponents3.ScrollView {
          anchors.fill: parent
          visible: panel.svc.ready && panel.visibleScreens.length > 0

          GridView {
            id: grid
            model: panel.visibleScreens
            boundsBehavior: Flickable.StopAtBounds
            cacheBuffer: 2000
            clip: true
            readonly property int columns: Math.max(1, Math.floor(width / (panel.u * 14)))
            cellWidth: Math.floor(width / columns)
            cellHeight: (cellWidth - Kirigami.Units.largeSpacing * 2) * 9 / 16 + panel.u * 3.4

            delegate: Item {
              id: tile
              required property var modelData
              readonly property var s: modelData
              readonly property var restart: panel.restartAction(s)
              width: grid.cellWidth
              height: grid.cellHeight

              HoverHandler { id: tileHover }

              Rectangle {
                anchors.fill: parent
                anchors.margins: Kirigami.Units.smallSpacing
                radius: Kirigami.Units.cornerRadius
                color: Qt.alpha(Kirigami.Theme.textColor, tileHover.hovered ? 0.07 : 0.04)
                border.width: panel.focusId === tile.s.id ? 2 : 1
                border.color: panel.focusId === tile.s.id ? Kirigami.Theme.highlightColor
                  : Qt.alpha(Kirigami.Theme.textColor, tileHover.hovered ? 0.25 : 0.1)

                ColumnLayout {
                  anchors.fill: parent
                  anchors.margins: Kirigami.Units.smallSpacing
                  spacing: Kirigami.Units.smallSpacing

                  // Screenshot.
                  Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: width * 9 / 16
                    radius: Kirigami.Units.cornerRadius / 2
                    color: "#101215"
                    clip: true

                    Logomark {
                      anchors.centerIn: parent
                      visible: shotImage.status !== Image.Ready
                      size: parent.width / 6
                      color: Qt.alpha("white", 0.25)
                    }
                    PlasmaComponents3.Label {
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: Kirigami.Units.smallSpacing
                      visible: !tile.s.shot
                      color: Qt.alpha("white", 0.6)
                      font: Kirigami.Theme.smallFont
                      text: "No screenshot yet"
                    }
                    Image {
                      id: shotImage
                      anchors.fill: parent
                      source: tile.s.shot ? "file://" + tile.s.shot + "?" + tile.s.shot_mtime + "-" + panel.shotBump : ""
                      cache: false
                      asynchronous: true
                      fillMode: Image.PreserveAspectFit
                      opacity: tile.s.online ? 1 : 0.55
                    }

                    // State, top left.
                    Rectangle {
                      x: Kirigami.Units.smallSpacing
                      y: Kirigami.Units.smallSpacing
                      radius: height / 2
                      color: Qt.rgba(0, 0, 0, 0.6)
                      width: stateRow.implicitWidth + Kirigami.Units.smallSpacing * 3
                      height: stateRow.implicitHeight + Kirigami.Units.smallSpacing
                      Row {
                        id: stateRow
                        anchors.centerIn: parent
                        spacing: Kirigami.Units.smallSpacing
                        Rectangle {
                          anchors.verticalCenter: parent.verticalCenter
                          width: Kirigami.Units.smallSpacing * 1.5
                          height: width
                          radius: width / 2
                          color: tile.s.online ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
                        }
                        PlasmaComponents3.Label {
                          text: tile.s.online ? "LIVE" : "OFFLINE"
                          color: "white"
                          font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                          font.bold: true
                        }
                      }
                    }

                    // Override or display off, top right.
                    Rectangle {
                      visible: tile.s.online && (tile.s.display_off || tile.s.has_takeover)
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.margins: Kirigami.Units.smallSpacing
                      radius: height / 2
                      color: Kirigami.Theme.highlightColor
                      width: statePill.implicitWidth + Kirigami.Units.smallSpacing * 3
                      height: statePill.implicitHeight + Kirigami.Units.smallSpacing
                      PlasmaComponents3.Label {
                        id: statePill
                        anchors.centerIn: parent
                        color: Kirigami.Theme.highlightedTextColor
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        font.bold: true
                        text: tile.s.display_off ? "DISPLAY OFF" : "OVERRIDE" + panel.minutesLeft(tile.s.takeover_until).toUpperCase()
                      }
                    }

                    // Actions, on hover.
                    Rectangle {
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: Kirigami.Units.smallSpacing
                      width: actionRow.implicitWidth + Kirigami.Units.smallSpacing
                      height: actionRow.implicitHeight + Kirigami.Units.smallSpacing
                      radius: Kirigami.Units.cornerRadius
                      color: Kirigami.Theme.backgroundColor
                      opacity: tileHover.hovered || panel.focusId === tile.s.id ? 1 : 0
                      visible: opacity > 0
                      Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration } }

                      Row {
                        id: actionRow
                        anchors.centerIn: parent
                        Repeater {
                          model: [
                            { icon: "view-refresh", tip: "Reload", go: "reload", ok: true },
                            { icon: "view-media-playlist", tip: "Switch playlist", go: "pick-switch", ok: true },
                            { icon: tile.s.display_off ? "video-display" : "system-suspend", tip: tile.s.display_off ? "Turn the display back on" : "Turn the display off", go: tile.s.display_off ? "display-on" : "display-off", ok: true },
                            { icon: "chronometer", tip: tile.s.has_takeover ? "End the override" : "Override with a playlist for a while", go: tile.s.has_takeover ? "end-override" : "pick-override", ok: true },
                            { icon: "camera-photo", tip: tile.s.online ? "Take a fresh screenshot" : "Offline: no fresh screenshot", go: "shot", ok: tile.s.online },
                            { icon: "system-reboot", tip: tile.restart.tip, go: tile.restart.action, ok: tile.restart.action !== "" },
                            { icon: "globe", tip: "Open in the dashboard", go: "dashboard", ok: true }
                          ]
                          PlasmaComponents3.ToolButton {
                            required property var modelData
                            icon.name: modelData.icon
                            display: QQC2.AbstractButton.IconOnly
                            text: modelData.tip
                            enabled: modelData.ok
                            PlasmaComponents3.ToolTip { text: parent.text }
                            onClicked: {
                              var a = modelData.go
                              if (a === "pick-switch") panel.picker = { screenId: tile.s.id, label: tile.s.label, action: "switch" }
                              else if (a === "pick-override") panel.picker = { screenId: tile.s.id, label: tile.s.label, action: "override" }
                              else if (a === "dashboard") Qt.openUrlExternally("https://screenrig.ai/dashboard/screens/" + tile.s.id)
                              else if (a === "shot") {
                                panel.svc.report(true, "Asking " + tile.s.label + " for a screenshot")
                                panel.svc.run(["act", tile.s.id, "shot"], function(ok, message) {
                                  panel.svc.report(ok, message)
                                  panel.shotBump++
                                })
                              }
                              else panel.svc.act(tile.s.id, a)
                            }
                          }
                        }
                      }
                    }
                  }

                  // Name, seen, playlist.
                  RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents3.Label {
                      Layout.fillWidth: true
                      text: tile.s.label
                      textFormat: Text.PlainText
                      font.bold: true
                      elide: Text.ElideRight
                    }
                    PlasmaComponents3.Label {
                      text: "seen " + panel.ago(tile.s.online ? tile.s.last_seen_at : (tile.s.last_online_at || tile.s.last_seen_at))
                      font: Kirigami.Theme.smallFont
                      opacity: 0.7
                    }
                  }
                  PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                    text: "▶  " + (tile.s.playing_name || "nothing")
                      + (tile.s.playing_source && tile.s.playing_source !== "default" ? "  ·  " + tile.s.playing_source : "")
                  }
                }
              }
            }
          }
        }

        // Playlist sheet for switch and override.
        Rectangle {
          anchors.fill: parent
          visible: !!panel.picker
          color: Qt.alpha(Kirigami.Theme.backgroundColor, 0.6)
          MouseArea { anchors.fill: parent; onClicked: panel.picker = null }
        }
        Rectangle {
          id: sheet
          visible: !!panel.picker
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: Math.min(parent.width, panel.u * 20)
          color: Kirigami.Theme.backgroundColor
          border.color: Qt.alpha(Kirigami.Theme.textColor, 0.15)
          radius: Kirigami.Units.cornerRadius
          MouseArea { anchors.fill: parent }

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.smallSpacing

            RowLayout {
              Layout.fillWidth: true
              Kirigami.Heading {
                Layout.fillWidth: true
                level: 3
                text: panel.picker ? (panel.picker.action === "switch" ? "Switch playlist" : "Override") : ""
              }
              PlasmaComponents3.ToolButton {
                icon.name: "window-close"
                display: QQC2.AbstractButton.IconOnly
                text: "Close"
                onClicked: panel.picker = null
              }
            }
            PlasmaComponents3.Label {
              Layout.fillWidth: true
              wrapMode: Text.Wrap
              opacity: 0.7
              textFormat: Text.PlainText
              text: panel.picker ? panel.picker.label + (panel.picker.action === "switch" ? " plays this from now on" : " plays this, then returns to its own playlist") : ""
            }
            RowLayout {
              visible: !!panel.picker && panel.picker.action === "override"
              Repeater {
                model: [{ id: 10, label: "10 min" }, { id: 30, label: "30 min" }, { id: 60, label: "1 h" }, { id: 240, label: "4 h" }]
                PlasmaComponents3.ToolButton {
                  required property var modelData
                  text: modelData.label
                  checkable: true
                  checked: panel.pickMinutes === modelData.id
                  onClicked: panel.pickMinutes = modelData.id
                }
              }
            }
            Kirigami.Separator { Layout.fillWidth: true }
            PlasmaComponents3.ScrollView {
              Layout.fillWidth: true
              Layout.fillHeight: true
              ListView {
                clip: true
                model: panel.svc.playlists
                delegate: PlasmaComponents3.ItemDelegate {
                  required property var modelData
                  width: ListView.view.width
                  icon.name: "view-media-playlist"
                  text: modelData.name + (modelData.approved ? "" : "  ·  awaiting approval")
                  onClicked: {
                    var p = panel.picker
                    panel.picker = null
                    if (p.action === "switch") panel.svc.act(p.screenId, "switch", modelData.id)
                    else panel.svc.act(p.screenId, "override", modelData.id + ":" + panel.pickMinutes)
                  }
                }
              }
            }
          }
        }
      }
    }

    // --------------------------------------------------------- cast
    ColumnLayout {
      spacing: Kirigami.Units.largeSpacing

      // Casting now: its status and Stop in place of the pickers.
      RowLayout {
        id: liveNow
        visible: panel.casting
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Kirigami.Units.largeSpacing * 2
        readonly property var info: panel.svc.live || ({})
        readonly property real untilMs: info.until ? Date.parse(info.until) : 0
        readonly property real startedMs: (info.started_at || 0) * 1000
        readonly property real leftMs: untilMs ? Math.max(0, untilMs - panel.tickMs) : 0
        readonly property real fixedMs: untilMs && startedMs ? untilMs - startedMs : 0

        Rectangle {
          Layout.preferredWidth: panel.u * 16
          Layout.preferredHeight: width * 10 / 16
          Layout.alignment: Qt.AlignVCenter
          radius: Kirigami.Units.cornerRadius
          color: "#101215"
          Kirigami.Icon {
            anchors.centerIn: parent
            width: Kirigami.Units.iconSizes.huge
            height: width
            source: liveNow.info.source === "window" ? "window" : "video-display"
          }
          Rectangle {
            x: Kirigami.Units.smallSpacing
            y: Kirigami.Units.smallSpacing
            radius: height / 2
            color: Kirigami.Theme.negativeTextColor
            width: livePill.implicitWidth + Kirigami.Units.largeSpacing
            height: livePill.implicitHeight + Kirigami.Units.smallSpacing
            PlasmaComponents3.Label {
              id: livePill
              anchors.centerIn: parent
              text: "LIVE"
              color: "white"
              font.bold: true
              font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          spacing: Kirigami.Units.smallSpacing
          PlasmaComponents3.Label { text: "CASTING"; opacity: 0.7; font.bold: true; font.letterSpacing: 1.4 }
          Kirigami.Heading {
            Layout.fillWidth: true
            level: 2
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: liveNow.info.label || "Desktop"
          }
          PlasmaComponents3.Label {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            opacity: 0.7
            text: "on " + panel.screenNames(liveNow.info.screens || [])
          }
          Kirigami.Heading {
            level: 1
            font.family: "monospace"
            text: panel.clock(liveNow.untilMs ? liveNow.leftMs : panel.tickMs - liveNow.startedMs)
          }
          PlasmaComponents3.Label {
            opacity: 0.7
            text: liveNow.untilMs ? "left · ends at " + new Date(liveNow.untilMs).toLocaleTimeString(Qt.locale(), "h:mm AP") : "live, until you stop it"
          }
          PlasmaComponents3.ProgressBar {
            Layout.fillWidth: true
            visible: liveNow.fixedMs > 0
            from: 0
            to: 1
            value: liveNow.fixedMs > 0 ? liveNow.leftMs / liveNow.fixedMs : 0
          }
          PlasmaComponents3.Button {
            Layout.topMargin: Kirigami.Units.largeSpacing
            icon.name: "media-playback-stop"
            text: panel.stopping ? "Stopping" : "Stop casting"
            enabled: !panel.stopping
            onClicked: panel.stopCast()
          }
        }
      }

      // What to cast.
      RowLayout {
        visible: !panel.casting
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing
        Repeater {
          model: [
            { id: "live", label: "Live", icon: "media-record" },
            { id: "capture", label: "Capture", icon: "camera-photo" },
            { id: "clipboard", label: "Clipboard", icon: "edit-paste" },
            { id: "file", label: "File", icon: "document-open" }
          ]
          PlasmaComponents3.ToolButton {
            required property var modelData
            Layout.fillWidth: true
            icon.name: modelData.icon
            text: modelData.label
            checkable: true
            checked: panel.sendSource === "live" ? modelData.id === "live" : (panel.sendKind !== "" && panel.sendSource === modelData.id)
            onClicked: {
              var id = modelData.id
              if (id === "live") { panel.sendSource = "live"; panel.sendKind = ""; panel.svc.loadLiveTargets() }
              else if (id === "capture") { root.expanded = false; panel.svc.runDetached(["capture"]) }
              else if (id === "clipboard") panel.svc.run(["clip"], function(ok, message) { if (!ok) panel.svc.report(false, message) })
              else { root.expanded = false; panel.svc.runDetached(["pick-file"]) }
              checked = Qt.binding(function() {
                return panel.sendSource === "live" ? modelData.id === "live" : (panel.sendKind !== "" && panel.sendSource === modelData.id)
              })
            }
          }
        }
      }

      RowLayout {
        visible: !panel.casting
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Kirigami.Units.largeSpacing

        // The source: Desktop or a window, or the captured image, link or file.
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 1
          spacing: Kirigami.Units.smallSpacing

          Repeater {
            model: panel.sendSource === "live" ? panel.liveSources : []
            PlasmaComponents3.ItemDelegate {
              id: src
              required property var modelData
              Layout.fillWidth: true
              checkable: true
              checked: panel.liveSource === modelData.id
              onClicked: panel.liveSource = modelData.id
              Keys.onReturnPressed: panel.goLive()
              contentItem: RowLayout {
                spacing: Kirigami.Units.largeSpacing
                Kirigami.Icon {
                  Layout.preferredWidth: Kirigami.Units.iconSizes.large
                  Layout.preferredHeight: Layout.preferredWidth
                  source: src.modelData.icon
                }
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0
                  PlasmaComponents3.Label { text: src.modelData.title; font.bold: src.checked }
                  PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: src.modelData.detail
                    wrapMode: Text.Wrap
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
                  }
                }
                Kirigami.Icon {
                  visible: src.checked
                  Layout.preferredWidth: Kirigami.Units.iconSizes.small
                  Layout.preferredHeight: Layout.preferredWidth
                  source: "checkmark"
                }
              }
            }
          }
          Item { visible: panel.sendSource === "live"; Layout.fillHeight: true }

          Rectangle {
            visible: panel.sendSource !== "live"
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Kirigami.Units.cornerRadius
            color: "#101215"
            clip: true
            Image {
              id: preview
              anchors.fill: parent
              anchors.margins: Kirigami.Units.smallSpacing
              visible: panel.sendKind === "file" && panel.isImage(panel.sendPath)
              source: visible ? "file://" + panel.sendPath : ""
              fillMode: Image.PreserveAspectFit
              asynchronous: true
            }
            ColumnLayout {
              anchors.centerIn: parent
              width: parent.width - Kirigami.Units.largeSpacing * 2
              visible: !preview.visible
              Logomark { Layout.alignment: Qt.AlignHCenter; size: panel.u * 2.5; color: Qt.alpha("white", 0.4) }
              PlasmaComponents3.Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WrapAnywhere
                textFormat: Text.PlainText
                color: Qt.alpha("white", 0.75)
                text: panel.sendKind === "url" ? panel.sendUrl
                  : (panel.sendKind === "file" ? panel.sendPath.split("/").pop()
                  : "Capture a region, use the clipboard, or pick a file")
              }
            }
          }
          PlasmaComponents3.Label {
            visible: panel.sendSource !== "live" && panel.sendKind !== ""
            Layout.fillWidth: true
            elide: Text.ElideMiddle
            textFormat: Text.PlainText
            opacity: 0.7
            text: panel.sendKind === "url" ? "Web page  ·  shown live on the screen"
              : panel.sendPath.split("/").pop() + (preview.status === Image.Ready ? "  ·  " + preview.sourceSize.width + "×" + preview.sourceSize.height : "")
          }
        }

        Kirigami.Separator { Layout.fillHeight: true }

        // Where to show it.
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredWidth: 1
          spacing: Kirigami.Units.smallSpacing

          RowLayout {
            Layout.fillWidth: true
            Kirigami.Heading { Layout.fillWidth: true; level: 3; text: "Show on" }
            PlasmaComponents3.ToolButton {
              visible: panel.castTargets().length > 0
              text: panel.allTargetsSelected() ? "Clear" : "Select all"
              onClicked: panel.selectAllTargets()
            }
          }
          PlasmaComponents3.Label {
            visible: panel.sendSource === "live"
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            opacity: 0.7
            text: !panel.svc.liveTargets.ok ? "Finding Android and Linux screens on this network"
              : (panel.castTargets().length === 0
                ? "No Android or Linux screens are on this network. Live casts reach screens on the same network as this computer"
                  + (panel.svc.liveTargets.elsewhere ? " (" + panel.svc.liveTargets.elsewhere + " are elsewhere)." : ".")
                : "Android and Linux screens on this network")
          }
          PlasmaComponents3.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            ListView {
              clip: true
              model: panel.castTargets()
              delegate: PlasmaComponents3.CheckDelegate {
                required property var modelData
                width: ListView.view.width
                enabled: modelData.online
                checked: !!panel.sendSelected[modelData.id]
                text: modelData.label + "  ·  " + (panel.sendSource === "live" ? (modelData.platform === "qt" ? "Linux" : "Android")
                  : (modelData.online ? (modelData.playing_name || "online") : "Offline"))
                onClicked: panel.toggleSend(modelData.id)
              }
            }
          }
        }
      }

      // What live casting changes on this computer, allowed once.
      Kirigami.InlineMessage {
        Layout.fillWidth: true
        visible: panel.needsConsent && !panel.casting
        type: Kirigami.MessageType.Information
        icon.source: "security-high"
        text: "<b>Allow live casting on this computer.</b> The firewall (" + (panel.liveSetup.firewall_kind || "firewall") + ") lets screens on "
          + (panel.liveSetup.subnet || "your network") + " reach TCP " + (panel.liveSetup.port || 8554) + " here."
          + (panel.liveSetup.firewall === "no-sudo" ? " This needs your password once: Allow shows the command."
            : panel.liveSetup.firewall_kind === "firewalld" ? " Plasma asks for your password." : "")
        actions: [
          Kirigami.Action {
            icon.name: "dialog-ok-apply"
            text: panel.allowing ? "Allowing" : "Allow"
            enabled: !panel.allowing
            onTriggered: panel.allowLive()
          }
        ]
      }

      Kirigami.Separator { Layout.fillWidth: true; visible: !panel.casting }

      RowLayout {
        visible: !panel.casting
        Layout.fillWidth: true
        PlasmaComponents3.Label { text: "Show for"; opacity: 0.7 }
        Repeater {
          model: panel.sendSource === "live"
            ? [{ id: 15, label: "15 min" }, { id: 60, label: "1 h" }, { id: 240, label: "4 h" }, { id: 0, label: "Until I stop" }]
            : [{ id: 5, label: "5 min" }, { id: 10, label: "10 min" }, { id: 30, label: "30 min" }, { id: 60, label: "1 h" }]
          PlasmaComponents3.ToolButton {
            required property var modelData
            text: modelData.label
            checkable: true
            checked: (panel.sendSource === "live" ? panel.liveMinutes : panel.sendMinutes) === modelData.id
            onClicked: {
              if (panel.sendSource === "live") panel.liveMinutes = modelData.id
              else panel.sendMinutes = modelData.id
            }
          }
        }
        Item { Layout.fillWidth: true }
        PlasmaComponents3.Button {
          readonly property int n: panel.selectedIds().length
          readonly property bool liveMode: panel.sendSource === "live"
          icon.name: liveMode ? "media-record" : "document-send"
          text: panel.sending ? (liveMode ? "Going live" : "Casting")
            : (n === 0 ? "Pick screens" : (liveMode ? "Go live on " : "Cast to ") + n + " screen" + (n === 1 ? "" : "s"))
          enabled: n > 0 && !panel.sending && (liveMode ? !panel.needsConsent : panel.sendKind !== "")
          onClicked: liveMode ? panel.goLive() : panel.doSend()
        }
      }
    }
  }
}
