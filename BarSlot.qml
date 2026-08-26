import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar slot for luvus. One glyph and one number, where the number is chosen to
// answer the only question the bar can usefully answer at a glance: is anything
// waiting for me? Blocked agents outrank working ones outrank a plain count,
// and the urgent colour is spent on nothing else.
BarWidget {
  id: root
  moduleName: "riclib.luvus"

  // nf-md-robot, U+F06A9. Not this plugin's invention and deliberately not
  // replaced: every agent widget in the bar wears it, so it reads as the
  // category rather than as any one plugin, and a mark of our own would only
  // break that. It is a private-use codepoint, so it does not survive every
  // editor that touches this file — if it is ever dropped the widget renders as
  // a bare number, and U+F06A9 is what to put back.
  readonly property string icon: "󰚩"

  readonly property bool hideWhenIdle: setting("hideWhenIdle", false) === true
  readonly property string focusWindowClass: String(setting("focusWindowClass", ""))

  readonly property var state: service.state
  readonly property bool online: state.online === true
  readonly property int blocked: Number(state.blocked || 0)
  readonly property int working: Number(state.working || 0)
  readonly property bool needsAttention: blocked > 0
  readonly property bool busy: working > 0

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color faceColor: !online ? Qt.darker(foreground, 1.4)
    : needsAttention ? urgent
    : busy ? foreground
    : Qt.darker(foreground, 1.4)

  readonly property string barText: {
    if (root.vertical) return root.icon
    var count = Model.barCount(root.state)
    return count < 0 ? root.icon + " ×" : root.icon + " " + count
  }

  // Quiet means: luvus is up, and nothing is working or waiting. An unreachable
  // server is not quiet — that is worth seeing.
  readonly property bool quiet: online && !busy && !needsAttention
  visible: !hideWhenIdle || !quiet || opened

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service {
    id: service
    session: String(root.setting("session", ""))
    luvusBin: String(root.setting("luvusBin", "luvus"))
    pushUpdates: root.setting("pushUpdates", true) === true
  }

  // The host injects `settings` after this widget is constructed, so nothing may
  // be spawned during construction: a subscription opened against the default
  // session cannot be moved to a configured one afterwards — changing `command`
  // on a running Process does not restart it. Wait a turn of the event loop,
  // by which point the entry has landed. A later injection re-binds instead,
  // and start() is guarded, so both paths together are safe in either order.
  Component.onCompleted: Qt.callLater(function () { service.start() })

  function refresh() { service.refresh() }

  // Focusing a pane moves the cursor inside the luvus TUI. It cannot raise the
  // terminal window that hosts it — nothing inside a terminal can — so the
  // window half is a separate, opt-in dispatch the user configures by class.
  //
  // Util.execArgv, never bar.run: bar.run hands its argument to `bash -lc` as a
  // shell string, so concatenating a setting into it is a command-injection
  // sink — `x; curl … | bash` in focusWindowClass would run on the next click.
  // execArgv passes the vector through positional parameters, which bash does
  // not re-tokenize, so the class stays literal whatever is in it.
  function goToPane(paneId) {
    if (!paneId) return
    service.focusPane(paneId)
    if (root.focusWindowClass)
      Util.execArgv(["hyprctl", "dispatch", "focuswindow", "class:" + root.focusWindowClass])
  }

  // ---- the panel ---------------------------------------------------------
  //
  // A bar surface exists per monitor, so this widget — and its Service, and its
  // panel — exist per monitor. The panel is loaded here rather than mounted
  // globally so the one that opens is the one on the screen you are looking at.

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = service
  }

  onBarChanged: injectPanel()
  // One handler per signal — QML rejects a second `onSettingsChanged` outright,
  // and the widget then fails to load with "Property value set multiple times".
  onSettingsChanged: {
    injectPanel()
    service.start()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Shape contract for the bar's popout routing: open/close/opened have to live
  // on the widget root, which stands in for the panel as the bar's popout
  // identity — the same way the first-party panel widgets do.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    labelVisible: !root.vertical
    active: root.busy || root.needsAttention
    activeColor: root.faceColor
    fontSize: Style.font.bodySmall
    horizontalMargin: 3.5
    tooltipText: Model.tooltipFor(root.state)
      + "\nclick to open   ·   middle click to refresh"
      + (Model.jumpTarget(root.state) ? "   ·   right click to jump there" : "")

    onPressed: function (pressedButton) {
      if (pressedButton === Qt.MiddleButton) {
        root.broadcast("refresh")
      } else if (pressedButton === Qt.RightButton) {
        // Nothing is waiting and nothing is running: there is no "there" to go
        // to, so the useful thing to do with the click is re-read.
        var target = Model.jumpTarget(root.state)
        if (target) root.goToPane(target)
        else root.broadcast("refresh")
      } else {
        root.togglePanel()
      }
    }
  }

  // An IPC target routes to exactly one handler, but this widget is live once
  // per monitor, so the instance that claimed the target is rarely the one you
  // are looking at. The bar already resolves this for its own summons by asking
  // Hyprland which output is focused; borrow that rather than acting locally.
  function focusedInstance() {
    if (root.bar && typeof root.bar.findPanelWidget === "function") {
      var item = root.bar.findPanelWidget(root.moduleName)
      if (item) return item
    }
    return root
  }

  IpcHandler {
    target: "riclib.luvus"

    function open(): void { root.focusedInstance().open() }
    function close(): void { root.focusedInstance().close() }
    function toggle(): void { root.focusedInstance().togglePanel() }

    // A refresh is not a place, so it goes to every instance.
    function refresh(): void { root.broadcast("refresh") }
  }
}
