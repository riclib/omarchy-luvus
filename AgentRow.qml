import QtQuick
import qs.Commons

// One agent in the panel: a status glyph that carries the colour, a name with
// the detail line under it, and the status spelled out on the right for anyone
// who does not read the glyphs. Rows are places — activating one focuses that
// pane in luvus.
Item {
  id: root

  property string label: ""
  property string detail: ""
  property string status: "unknown"
  property string glyph: "?"
  property bool focusedAgent: false
  property color foreground: Color.popups.text
  property color statusColor: Color.popups.text
  property color hoverBackground: Color.menu.selectedBackground

  signal activated()

  readonly property color muted: Qt.darker(root.foreground, 1.6)

  implicitHeight: Math.max(Style.space(38), labels.implicitHeight + Style.space(10))
  height: implicitHeight

  Rectangle {
    anchors.fill: parent
    radius: Style.space(5)
    color: hover.hovered ? root.hoverBackground : "transparent"
  }

  Text {
    id: glyphText
    anchors.left: parent.left
    anchors.leftMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    text: root.glyph
    color: root.statusColor
    font.family: Style.font.menuFamily
    font.pixelSize: Style.font.subtitle
  }

  Column {
    id: labels
    anchors.left: glyphText.right
    anchors.leftMargin: Style.space(10)
    anchors.right: statusText.left
    anchors.rightMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(2)

    Text {
      width: parent.width
      // Project names, branches and paths are text, never markup: under
      // AutoText a branch called "<wip>" renders as empty and the row looks
      // broken.
      textFormat: Text.PlainText
      text: root.label
      color: root.foreground
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
      // The one the cursor is in, and the ones that are doing something, are
      // the ones worth finding without reading.
      font.bold: root.focusedAgent || root.status === "working" || root.status === "blocked"
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      visible: root.detail !== ""
      text: root.detail
      color: root.muted
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
    }
  }

  Text {
    id: statusText
    anchors.right: parent.right
    anchors.rightMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    text: root.status.charAt(0).toUpperCase() + root.status.slice(1)
    color: root.status === "idle" ? root.muted : root.statusColor
    font.family: Style.font.menuFamily
    font.pixelSize: Style.font.caption
    font.bold: root.status === "blocked"
  }

  HoverHandler { id: hover }

  TapHandler {
    onTapped: root.activated()
  }
}
