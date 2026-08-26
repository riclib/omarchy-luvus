import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The popup behind the bar glyph: four counts, then every agent luvus knows
// about, worst first. It holds no state of its own — the Service in the bar
// slot owns the data and both surfaces read the same copy, so opening the panel
// costs nothing and never disagrees with the number on the bar.
//
// A row is a place: clicking one focuses that pane in luvus.
Panel {
  id: root
  moduleName: "riclib.luvus"
  ipcTarget: "riclib.luvus.panel"

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root

  readonly property var state: service ? service.state : Model.emptyState("starting")
  readonly property bool online: state.online === true
  readonly property var agents: Array.isArray(state.agents) ? state.agents : []

  readonly property color fg: Color.popups.text
  readonly property color muted: Qt.darker(fg, 1.6)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color running: Color.accent

  function colorFor(status) {
    if (status === "blocked") return root.urgent
    if (status === "working") return root.running
    if (status === "done") return root.fg
    return root.muted
  }

  function refresh() { if (service) service.refresh() }

  // Going somewhere closes the thing you went from. The window raise lives on
  // the bar slot, which owns the setting that configures it.
  function goToPane(paneId) {
    if (!paneId) return
    root.close()
    if (hostWidget && typeof hostWidget.goToPane === "function") hostWidget.goToPane(paneId)
    else if (service) service.focusPane(paneId)
  }

  // Opening does not need to fetch — the subscription has been keeping this
  // current all along. Ask anyway when it is not: with pushUpdates off, or
  // while the stream is down, the panel is the moment staleness shows.
  onOpenedChanged: if (opened && service && !service.subscribed) refresh()

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onMoveRequested: function (dx, dy) {
        if (dy === 0) return
        scroll.contentY = Math.max(0, Math.min(
          scroll.contentY + dy * Style.space(48),
          Math.max(0, scroll.contentHeight - scroll.height)))
      }
      onTextKey: function (text) {
        if (text === "r" || text === "R") root.refresh()
        // The same jump the bar's right click makes, without the mouse.
        else if (text === "g" || text === "G") root.goToPane(Model.jumpTarget(root.state))
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: content
          width: scroll.width
          spacing: Style.space(10)

          // ---- header
          Item {
            width: parent.width
            height: Math.max(hero.implicitHeight, Style.space(24))

            PanelHero {
              id: hero
              anchors.left: parent.left
              anchors.right: actions.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              title: "Luvus"
              meta: Model.heroMeta(root.state)
              detail: Model.heroDetail(root.state)
              foreground: root.fg
              fontFamily: Style.font.menuFamily

              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: "󰚩"
                  color: root.colorFor(root.state.blocked > 0 ? "blocked"
                    : root.state.working > 0 ? "working" : "idle")
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.display
                }
              }
            }

            Row {
              id: actions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              PanelActionButton {
                iconText: "󰐊"
                foreground: root.fg
                visible: Model.jumpTarget(root.state) !== ""
                tooltipText: "Go to what needs you  (g)"
                onClicked: root.goToPane(Model.jumpTarget(root.state))
              }

              PanelActionButton {
                iconText: "󰑐"
                foreground: root.fg
                enabled: !(root.service && root.service.refreshing)
                tooltipText: "Refresh now  (r)"
                onClicked: root.refresh()
              }
            }
          }

          // ---- not running
          Text {
            visible: !root.online
            width: parent.width
            textFormat: Text.PlainText
            // The reason often IS luvus's own error.message, passed through —
            // Model.parseAgents lifts it straight out of the error envelope. It
            // is clamped and stripped at that boundary rather than here, because
            // the same string also reaches the hero and the bar tooltip, and
            // both of those render inside components this plugin does not own.
            text: (root.state.reason || "luvus is not running") + "\n\nStart it with:  luvus"
            color: root.muted
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            topPadding: Style.space(20)
            bottomPadding: Style.space(20)
          }

          PanelSeparator {
            visible: root.online
            foreground: root.fg
          }

          // ---- counts
          Column {
            visible: root.online
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              width: parent.width
              text: "OVERVIEW"
              foreground: root.fg
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              SummaryCell { label: "Blocked"; value: Number(root.state.blocked || 0); tint: root.urgent }
              SummaryCell { label: "Working"; value: Number(root.state.working || 0); tint: root.running }
              SummaryCell { label: "Idle"; value: Number(root.state.idle || 0); tint: root.fg }
              SummaryCell { label: "Done"; value: Number(root.state.done || 0); tint: root.fg }
            }
          }

          PanelSeparator {
            visible: root.online && root.agents.length > 0
            foreground: root.fg
          }

          // ---- the agents
          Column {
            visible: root.online && root.agents.length > 0
            width: parent.width
            spacing: Style.space(2)

            PanelSectionHeader {
              width: parent.width
              text: "AGENTS  ·  " + Number(root.state.total || 0)
              foreground: root.fg
            }

            Repeater {
              model: root.agents

              AgentRow {
                required property var modelData
                width: content.width
                label: modelData.label
                detail: modelData.detail
                status: modelData.status
                glyph: Model.statusGlyph(modelData.status)
                focusedAgent: modelData.focused === true
                foreground: root.fg
                statusColor: root.colorFor(modelData.status)
                onActivated: root.goToPane(modelData.pane)
              }
            }
          }

          // Refusing to draw 100,000 rows is right; doing it silently is not,
          // because the panel would then disagree with the bar's count and look
          // simply wrong. state.total stays honest across the slice.
          Text {
            visible: root.online && root.state.truncated === true
            width: parent.width
            textFormat: Text.PlainText
            text: "Showing the first " + root.agents.length + " of " + Number(root.state.total || 0) + "."
            color: root.muted
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            visible: root.online && root.agents.length === 0
            width: parent.width
            textFormat: Text.PlainText
            text: "luvus is running, with no agents in any workspace."
            color: root.muted
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            topPadding: Style.space(16)
            bottomPadding: Style.space(16)
          }

          // Worth saying out loud: with the subscription down, everything above
          // is up to thirty seconds old, and that is the difference between
          // "nothing is blocked" and "nothing was blocked half a minute ago".
          Text {
            visible: root.online && root.service && !root.service.subscribed
            width: parent.width
            textFormat: Text.PlainText
            text: root.service && root.service.pushUpdates
              ? "Live updates are not connected — polling every 30s."
              : "Live updates are off — polling every 30s."
            color: root.muted
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  component SummaryCell: Rectangle {
    id: cell
    property string label: ""
    property int value: 0
    property color tint: root.fg
    readonly property bool lit: cell.value > 0

    width: (parent.width - parent.spacing * 3) / 4
    implicitHeight: cellLabels.implicitHeight + Style.space(12)
    radius: Style.cornerRadius
    color: cell.lit
      ? Style.selectedFillFor(cell.tint, Color.accent)
      : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.035)

    Column {
      id: cellLabels
      anchors.centerIn: parent
      spacing: Style.space(2)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: cell.value
        color: cell.lit ? cell.tint : root.fg
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        textFormat: Text.PlainText
        text: cell.label.toUpperCase()
        color: root.muted
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }
}
