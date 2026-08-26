import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The one thing that talks to luvus. The bar face and the panel both read
// `state` from here so a change costs one `agent list`, not two.
//
// Two ways in, deliberately:
//
//   `luvus agent list`  — the whole truth, on demand. JSON on stdout by
//                         default; there is no --json to remember.
//   `luvus events`      — a held-open NDJSON subscription that says *when* to
//                         ask again. Events are a doorbell here, not a data
//                         source: pane.closed arrives more than once for the
//                         same pane and the CLI stream carries no sequence
//                         number, so applying payloads incrementally would
//                         drift. Debounce, then re-read.
//
// The 30s timer is not the update mechanism, it is the thing that notices the
// doorbell has stopped working — a server restart, a subscription dropped on
// the floor, `pushUpdates` turned off.
Item {
  id: root

  property string session: ""
  property string luvusBin: "luvus"
  property bool pushUpdates: true

  readonly property string home: Quickshell.env("HOME") || ""

  property var state: Model.emptyState("starting")
  property bool subscribed: false
  property bool refreshing: false

  // Nothing is spawned until the bar host has injected this widget's shell.json
  // entry. A Process started before that would hold a subscription to the wrong
  // session for the life of the shell: changing `command` on a running Process
  // does not restart it, so the argv it was born with is the argv it keeps.
  property bool started: false

  function start() {
    if (root.started) return
    root.started = true
    root.refresh()
    root.openStream()
  }

  // The stream is driven by hand rather than by a `running:` binding, and this
  // is the whole reason: a binding flips the process on the instant `started`
  // becomes true, which is before `session` and `luvusBin` have settled. The
  // process then spawns on a half-built argv, dies, and the backoff below turns
  // that into fifteen seconds with no subscription — for a mistake that only
  // ever happens at startup. Setting command and running together, only when we
  // know both, removes the race instead of waiting it out.
  function openStream() {
    restart.stop()
    // Closing the stream ourselves also fires onExited, and an exit we asked
    // for is not a failure. Left unmarked it schedules a retry, that retry
    // reopens the stream, reopening closes the one just opened — and the widget
    // sits there respawning its own subscription every fifteen seconds forever.
    if (eventProcess.running) {
      root._closing = true
      eventProcess.running = false
    }
    if (!root.started || !root.pushUpdates) return
    eventProcess.command = root.argv(["events"])
    eventProcess.running = true
  }

  // A settings change is a different server, or a different binary. Either way
  // the open subscription now points at the wrong thing: drop it, reopen on the
  // new argv, and re-read the world. The backoff is cleared too — a deliberate
  // change is not a failure, and should not inherit a failure's patience.
  onSessionChanged: rebind()
  onLuvusBinChanged: rebind()
  onPushUpdatesChanged: openStream()

  // The host injects settings key by key, so `session` and `luvusBin` arrive as
  // two separate changes and a rebind per key would tear the subscription down
  // twice on the way up. Coalesce them onto the next turn of the event loop:
  // by then the whole entry has landed and one reopen serves all of it.
  function rebind() {
    if (!root.started) return
    settle.restart()
  }

  Timer {
    id: settle
    interval: 0
    onTriggered: {
      root.subscribed = false
      root._backoffIndex = 0
      root.refresh()
      root.openStream()
    }
  }

  // `luvus [--session <name>] <command>` — the session flag is global and comes
  // before the command, so it cannot simply be appended.
  function argv(rest) {
    var head = [root.luvusBin]
    if (root.session) head = head.concat(["--session", root.session])
    return head.concat(rest)
  }

  // A read is bounded before it reaches us, not after. StdioCollector has no
  // size limit of its own and no deadline, so an `agent list` that hangs would
  // wedge this widget until the shell restarts, and one that answers with
  // hundreds of megabytes would be buffered whole into the shell's memory —
  // the whole desktop's, not this widget's — before any check of ours could run.
  //
  // Same shape the first-party notifications service uses for a read it does
  // not control: `timeout` for the deadline, `head -c` for the ceiling. The
  // script is a constant and every variable part arrives as a positional
  // parameter, which bash expands without re-tokenizing, so a path or a session
  // name containing $(…) stays literal.
  //
  // pipefail matters as much as the bounds: `head` is last in the pipeline, so
  // without it the status is always head's 0 and every failure looks like
  // success. With it, 127 is "not found", 124 is "timed out", anything else
  // non-zero is luvus itself objecting — three different things to tell the user.
  readonly property string boundedRead:
    'set -o pipefail; timeout "$1" "${@:3}" | head -c "$2"'

  // A refresh that arrives while one is in flight used to be dropped and never
  // retried: the answer already on the wire predates the event that asked for
  // it, so the panel would sit on stale state until the 30s poll. Remember that
  // one was wanted and run it when the current one lands.
  property bool _pending: false

  function refresh() {
    if (!root.started) return
    if (listProcess.running) {
      root._pending = true
      return
    }
    root.refreshing = true
    listProcess.command = ["bash", "-lc", root.boundedRead, "bash", "10", "4000000"]
      .concat(root.argv(["agent", "list"]))
    listProcess.running = true
  }

  // Fire-and-forget: nothing to read back, and a blocked write here would stall
  // a frame.
  function focusPane(paneId) {
    if (!paneId) return
    Quickshell.execDetached(root.argv(["pane", "focus", String(paneId)]))
  }

  // ---- the whole truth -----------------------------------------------------

  Process {
    id: listProcess

    stdout: StdioCollector {
      waitForEnd: true
      // Sole delivery path. A killed process still closes its stream, so this
      // fires on failure too — never also deliver from onExited, or a slow call
      // can overwrite a newer one's answer.
      //
      // StdioCollector offers no size limit of its own, so it buffers whatever
      // the child writes, in full, before this runs. The cap therefore cannot
      // prevent the buffering — it can only refuse to spend a second copy and a
      // JSON.parse on it. A luvus that answers with hundreds of megabytes is
      // broken or is not luvus, and either way this is the whole desktop shell's
      // memory, not one widget's.
      onStreamFinished: root.state = text.length > 4000000
        ? Model.emptyState("luvus answered with more data than makes sense")
        : Model.parseAgents(text, root.home)
    }

    onExited: function (exitCode) {
      root.refreshing = false
      // onStreamFinished has already run by the time this does, so state is set;
      // this only refines the reason, using codes pipefail makes real.
      if (exitCode !== 0 && !root.state.online) {
        root.state = Model.emptyState(
          exitCode === 127 ? "luvus not found — check the luvusBin setting"
          : exitCode === 124 ? "luvus did not answer in time"
          : "luvus server not running")
      }
      if (root._pending) {
        root._pending = false
        root.refresh()
      }
    }
  }

  // ---- the doorbell --------------------------------------------------------

  property int _backoffIndex: 0
  readonly property var _backoffs: [1000, 2000, 5000, 15000]
  // Set by openStream() across a deliberate close, so onExited can tell "we
  // closed it" from "it died". Cleared by the exit it was set for.
  property bool _closing: false

  // No `running:` or `command:` binding here on purpose — see openStream().
  Process {
    id: eventProcess

    stdout: SplitParser {
      onRead: function (line) {
        // An event line is a small JSON object; the largest observed is a few
        // hundred bytes. Anything at this size is not one, and parsing it only
        // to discard it is work an unbounded stream gets to choose for us.
        if (line.length > 65536) return
        var read = Model.readEventLine(line)
        if (read.kind === "subscribed") {
          root.subscribed = true
          // The subscription starts empty: whatever changed while it was down
          // is not replayed to us, so read the world once it is live.
          root.refresh()
        } else if (read.kind === "refresh") {
          debounce.restart()
        }
      }
    }

    onExited: {
      root.subscribed = false
      if (root._closing) {
        root._closing = false
        return
      }
      if (!root.started || !root.pushUpdates) return
      restart.interval = root._backoffs[Math.min(root._backoffIndex, root._backoffs.length - 1)]
      root._backoffIndex = root._backoffIndex + 1
      restart.start()
    }
  }

  Timer {
    id: restart
    onTriggered: root.openStream()
  }

  // The one thing that notices a subscription that never arrived.
  //
  // onExited cannot cover this: a Process that fails to SPAWN — no such binary,
  // fork refused — reports nothing at all, so the backoff above never arms and
  // the widget stays poll-only for the life of the shell, its only symptom the
  // panel's quiet "live updates are not connected" line. A server that accepts
  // the connection and then never acknowledges looks the same from here.
  //
  // Declarative on purpose, after two goes at arming it by hand. `running` as a
  // binding cannot be cancelled by a stale callback, and both earlier attempts
  // failed exactly that way: openStream armed the timer for the new process and
  // the outgoing process's own exit handler disarmed it a moment later. The
  // condition below IS the question being asked — we want a subscription, and we
  // have not got one — so it needs no arming and no disarming, and it stops
  // itself the instant `subscribed` turns true.
  Timer {
    id: spawnWatch
    interval: 8000
    repeat: true
    running: root.started && root.pushUpdates && !root.subscribed
    onTriggered: root.openStream()
  }

  // A subscription that has held for half a minute is healthy; forget that it
  // ever failed, so a server restarted twice in a week does not creep towards
  // the long backoff and stay there.
  Timer {
    interval: 30000
    running: eventProcess.running
    onTriggered: root._backoffIndex = 0
  }

  // One agent finishing a turn produces several events in a burst — a status
  // change per pane, sometimes a pane closing behind it. Coalesce, or a busy
  // fleet spawns an `agent list` per event.
  Timer {
    id: debounce
    interval: 300
    onTriggered: root.refresh()
  }

  // ---- the fallback --------------------------------------------------------

  Timer {
    interval: 30000
    running: root.started
    repeat: true
    onTriggered: root.refresh()
  }
}
