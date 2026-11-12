import QtQuick
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
  property alias cfg_showCounts: showCounts.checked

  Kirigami.FormLayout {
    QQC2.CheckBox {
      id: showCounts
      Kirigami.FormData.label: "Panel:"
      text: "Show online and offline counts"
    }
  }
}
