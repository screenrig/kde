import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

// The chip: the screenRIG mark in the panel's text color, the online and
// offline counts, and a red dot when a screen dropped, credits run low or a
// cast is live. Click for the panel, middle-click to stop a live cast.
MouseArea {
  id: chip

  readonly property var svc: root.svc
  readonly property bool horizontal: Plasmoid.formFactor === PlasmaCore.Types.Horizontal
  readonly property bool showCounts: Plasmoid.configuration.showCounts && horizontal && svc.ready

  Layout.minimumWidth: horizontal ? row.implicitWidth + Kirigami.Units.smallSpacing * 2 : Kirigami.Units.iconSizes.small
  Layout.minimumHeight: horizontal ? Kirigami.Units.iconSizes.small : row.implicitHeight

  acceptedButtons: Qt.LeftButton | Qt.MiddleButton
  hoverEnabled: true
  property bool wasExpanded: false
  onPressed: function(mouse) { wasExpanded = root.expanded }
  onClicked: function(mouse) {
    if (mouse.button === Qt.MiddleButton) {
      if (root.casting) svc.liveStop()
      return
    }
    root.expanded = !wasExpanded
  }

  RowLayout {
    id: row
    anchors.centerIn: parent
    spacing: Kirigami.Units.smallSpacing

    Item {
      Layout.preferredWidth: Math.min(chip.height, Kirigami.Units.iconSizes.medium) * 0.82
      Layout.preferredHeight: Layout.preferredWidth

      Logomark {
        anchors.centerIn: parent
        size: parent.width
        color: Kirigami.Theme.textColor
        opacity: chip.svc.ready && !chip.svc.connected ? 0.5 : 1
      }

      Rectangle {
        visible: root.warn
        width: Math.max(5, parent.width * 0.3)
        height: width
        radius: width / 2
        color: Kirigami.Theme.negativeTextColor
        x: parent.width - width * 0.6
        y: -height * 0.2
        SequentialAnimation on opacity {
          running: root.warn && Kirigami.Units.longDuration > 0
          loops: Animation.Infinite
          NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
        }
      }
    }

    PlasmaComponents3.Label {
      visible: chip.showCounts
      text: chip.svc.onlineCount + " ●" + (chip.svc.offlineCount > 0 ? "  " + chip.svc.offlineCount + " ○" : "")
      textFormat: Text.PlainText
    }
  }
}
