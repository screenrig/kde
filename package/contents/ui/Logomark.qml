import QtQuick
import QtQuick.Shapes

// The screenRIG logomark as a
// vector shape in one color. `size` is its width; height keeps the mark's
// 224:176 proportions.
Item {
  id: root

  property real size: 16
  property color color: "white"

  readonly property real unit: size / 224
  implicitWidth: size
  implicitHeight: 176 * unit
  width: implicitWidth
  height: implicitHeight

  Shape {
    x: -16 * root.unit
    y: -40 * root.unit
    width: 256
    height: 256
    scale: root.unit
    transformOrigin: Item.TopLeft
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.color
      strokeColor: "transparent"
      fillRule: ShapePath.OddEvenFill
      PathSvg { path: "M40 40H216Q240 40 240 64V192Q240 216 216 216H40Q16 216 16 192V64Q16 40 40 40Z M108 60H220V168Q220 196 192 196H36V154L86 72Q94 60 108 60Z" }
    }
    ShapePath {
      fillColor: root.color
      strokeColor: "transparent"
      fillRule: ShapePath.OddEvenFill
      PathSvg { path: "M114 118A14 14 0 1 1 86 118A14 14 0 1 1 114 118Z M180 118A14 14 0 1 1 152 118A14 14 0 1 1 180 118Z" }
    }
  }
}
