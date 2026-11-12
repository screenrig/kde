import QtQuick
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

// screenRIG in the Plasma panel: a chip with the screens' state, and the panel
// with Screens and Cast.
PlasmoidItem {
  id: root

  readonly property alias svc: service
  Service { id: service }

  readonly property bool casting: !!service.live && !!service.live.live
  readonly property bool warn: service.droppedIds.length > 0 || casting || (!!service.credits && !!service.credits.low)

  // What the next opening should show: {} for the last tab, or a summon's payload.
  property var openPayload: ({})
  signal opened(var payload)

  Plasmoid.icon: Qt.resolvedUrl("../icons/screenrig.svg")
  Plasmoid.status: warn ? PlasmaCore.Types.NeedsAttentionStatus : PlasmaCore.Types.ActiveStatus

  toolTipMainText: "screenRIG" + (service.project.name ? " · " + service.project.name : "")
  toolTipSubText: {
    if (!service.ready) return service.lastError !== "" ? service.lastError : "Connecting"
    var lines = [service.onlineCount + " of " + service.screens.length + " screens online"]
    var dropped = service.droppedNames()
    for (var i = 0; i < dropped.length; i++) lines.push(dropped[i] + " went offline")
    if (casting) lines.push("Live: " + (service.live.label || "Desktop") + " on " + (service.live.screens || []).length
                            + " screen(s) · middle-click to stop")
    if (service.credits && service.credits.low) lines.push("Credits are low")
    if (!service.connected && service.lastError !== "") lines.push(service.lastError)
    return lines.join("\n")
  }

  switchWidth: Kirigami.Units.gridUnit * 30
  switchHeight: Kirigami.Units.gridUnit * 20
  preferredRepresentation: compactRepresentation
  compactRepresentation: CompactRepresentation {}
  fullRepresentation: FullRepresentation {}

  onExpandedChanged: {
    if (expanded) {
      opened(openPayload)
      openPayload = ({})
    } else {
      service.acknowledge()
    }
  }

  Connections {
    target: service
    function onSummoned(payload) {
      if (root.expanded) root.opened(payload)
      else { root.openPayload = payload; root.expanded = true }
    }
  }

  Plasmoid.contextualActions: [
    PlasmaCore.Action {
      text: "Cast a region capture"
      icon.name: "camera-photo"
      onTriggered: service.runDetached(["capture"])
    },
    PlasmaCore.Action {
      text: "Cast the clipboard"
      icon.name: "edit-paste"
      onTriggered: service.run(["clip"], function(ok, message) { if (!ok) service.report(false, message) })
    },
    PlasmaCore.Action {
      text: "Stop the live cast"
      icon.name: "media-playback-stop"
      visible: root.casting
      onTriggered: service.liveStop()
    },
    PlasmaCore.Action {
      isSeparator: true
    },
    PlasmaCore.Action {
      text: "Undo screenRIG's changes to this computer"
      icon.name: "edit-clear-history"
      onTriggered: service.teardown()
    }
  ]
}
