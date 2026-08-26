# omarchy-luvus — working notes

An Omarchy shell plugin that puts [luvus](https://github.com/RizRiyz/luvus)
agents in the bar. `README.md` is for people using it; this is for whoever
changes it next.

**This directory is the development home. It is not the installed plugin.**

## Two checkouts, on purpose

| Path | What it is |
| --- | --- |
| `~/src/omarchy-luvus` | this repo — where you edit, commit, push |
| `~/.config/omarchy/plugins/riclib.luvus` | the installed copy |

Same arrangement as `~/src/omarchy-capacities`, for the same reason: `omarchy
plugin validate` rejects symlinks inside a plugin folder outright, so the
installed copy has to be a real directory. The loop is edit here → copy or
`plugin update` → `omarchy restart shell`.

The shell hot-reloads a local plugin on file change (`DEBUG qml: Local plugin
changed, reloading: riclib.luvus` in the journal), so small QML edits do not
always need a restart. Reloading does **not** re-read `shell.json`, though —
a settings change does need the restart.

## Reading the log

There is no console. Everything goes to the journal under `omarchy-shell`:

```bash
journalctl --user -t omarchy-shell --since "2 minutes ago" | grep -i luvus
```

Filter to the current shell's PID when a restart is involved — warnings from
the instance you just killed look exactly like warnings from the live one, and
they are the main way to waste an hour here:

```bash
SP=$(pgrep -f "quickshell -n -p /usr/share/omarchy/shell")
journalctl --user -t omarchy-shell | grep "\[$SP\]" | grep -i luvus
```

Duplicate-IPC-target warnings are expected and harmless — one per extra
monitor, for the same reason described in `omarchy-cust/omarchy/PLUGINS.md`.

## How to test it without touching a real session

luvus supports named server sessions, and a named one can be started headless.
That is the whole test rig: a throwaway server nobody is working in.

```bash
luvus --session probe server start
# point the widget at it in shell.json:  {"id": "riclib.luvus", "session": "probe"}
omarchy restart shell
luvus --session probe workspace open /some/path   # emits real events
luvus --session probe server stop && luvus session delete probe
```

**Put the widget's `session` back afterwards.** Left pointed at an empty probe
session, the bar honestly reports zero agents and looks like a bug.

To see exactly what the widget invokes, set `luvusBin` to a shim — this is how
the argv and the timing below were established, and it beats sampling `ps`,
which cannot catch a process that lives 30ms:

```bash
cat > /tmp/luvus-shim <<'EOF'
#!/usr/bin/env bash
printf '%s  %s\n' "$(date +%H:%M:%S.%3N)" "$*" >> /tmp/shim.log
exec ~/.local/bin/luvus "$@"
EOF
chmod +x /tmp/luvus-shim
```

`grep " events$" /tmp/shim.log | awk '{print $1}' | cut -c1-8 | uniq -c` is the
health check: **one group of spawns and no more**. Several groups on a 1/2/5/15
second ladder means the subscription is flapping.

## What luvus actually gives us

Verified against a live 0.12.0 server, not read out of documentation — the docs
do not cover the event names at all.

`luvus agent list` prints JSON on stdout **by default**; there is no `--json` to
remember (the flag is accepted and changes nothing). The envelope is the same
one every luvus request answers with:

```json
{"id":"1","result":{"agents":[
  {"agent":"claude","status":"idle","pane":"1","cwd":"/home/riclib/envs/x",
   "project":"x","branch":"master","worktree":false,"focused":false,
   "name":null,"repo":"...","session":null,"tab":"1","workspace":"0",
   "workspace_name":"x"}]}}
```

Errors arrive as `{"id":"1","error":{"code":...,"message":...}}`. A dead server
produces no JSON at all. `Model.parseAgents` handles all three.

`luvus events` is NDJSON on a held-open connection. First line is the
acknowledgement, then one object per event:

```json
{"id":"1","result":{"type":"subscription_started"}}
{"data":{"pane":"2"},"event":"pane.created"}
{"data":{"workspace":"1"},"event":"workspace.created"}
{"data":{"agent":"bash","branch":"master","cwd":"...","pane":"2",
         "project":"omarchy-cust","status":"working"},
 "event":"pane.agent_status_changed"}
{"data":{"pane":"3"},"event":"pane.closed"}
{"data":{"tab":"2"},"event":"tab.created"}
{"data":{"workspace":"1"},"event":"workspace.closed"}
```

Those are every name observed; `Model.RELEVANT_EVENTS` is that list.

**Two things the schema promises and the CLI does not deliver.** The published
`event.schema.json` requires a monotonic `sequence` on every event, and the
socket API has an `after_sequence` replay buffer and a `resync_required`
overflow signal. Neither reaches you through `luvus events` — the lines carry
`event` and `data` only. And `pane.closed` is emitted **two or three times** for
the same pane.

That is why events are a doorbell and not a data source. The payload on
`pane.agent_status_changed` is complete enough to apply directly, and it is
tempting, but with duplicates and no sequence there is nothing to deduplicate
against, so an incrementally-maintained list would drift and never be caught
doing it. Debounce 300ms, re-read, move on. Revisit only if luvus starts putting
`sequence` on the CLI stream — then the socket's replay path becomes usable and
this could subscribe properly.

Timing measured through the shim: subscription up → first `agent list` ~74ms;
`workspace open` → refresh ~1.9s, nearly all of it luvus doing the work, the
debounce being 300ms of it.

## QML traps this plugin already fell into

All three cost real time. They are not obvious and they are not specific to this
plugin.

**One handler per signal.** A second `onSettingsChanged:` in the same object is
not a second handler, it is an error — `Property value set multiple times` — and
the widget silently fails to load. It does not show up as a syntax error
anywhere you would look.

**Imperative assignment destroys a binding.** `eventProcess.running = false`
permanently removes whatever `running:` binding was declared. That is fine if
you meant it, which is why `Service.openStream()` now drives `command` and
`running` together by hand and the `Process` declares neither.

**A Process you kill still reports `onExited`.** Treating that as a failure and
scheduling a retry means the retry reopens the stream, reopening closes the one
just opened, and the widget respawns its own subscription forever on the 15s
backoff. `_closing` marks an exit we asked for. This is the bug that produced
the flapping ladder above, and the shim is how it was found.

**Settings arrive key by key, after construction.** `session` and `luvusBin`
land as two separate property changes, so a rebind per key tears the
subscription down twice on the way up. `rebind()` coalesces onto a zero-interval
timer; `start()` waits a turn of the event loop via `Qt.callLater` so nothing
spawns against a half-built argv.

## One Service per monitor

A bar surface exists per monitor, so on a five-screen machine there are five
`Service` objects: five `luvus events` subscriptions and five `agent list` calls
per refresh. luvus caps subscribers at 64, so five is comfortable.

It is also much cheaper than what it replaces. herdr polls every 3s per monitor,
each poll a `bash` + `jq` + `herdr` — about five process spawns a second on this
machine. This spawns five processes per *change*, plus a 30s fallback: roughly
0.17/s at rest, some thirty times less.

A shared singleton would be better still, but a QML singleton inside a plugin
directory is not something the Omarchy loader is known to support, and the
current cost does not justify finding out.

## Tests

```bash
node --test tests/model.test.js
```

`Model.js` is deliberately free of QML types so it can be tested this way — the
`module.exports` at the bottom is invisible to QML, same trick as
`omarchy-capacities`. The fixtures are captured verbatim from a live 0.12.0
server; if luvus changes shape, those should be the first thing that fails.

Everything that is a decision rather than a mechanism — what the bar counts,
which agent a jump goes to, how a row is labelled — lives there, so it is
testable without opening the panel and squinting.

## The icon is deliberately not ours

`nf-md-robot` (U+F06A9) is worn by every agent widget in this bar, including
Claude Code's. It reads as the category. A distinctive mark was tried and
reverted for exactly that reason — do not "fix" it.

## Before a release

The lesson from omarchy-capacities' two review rounds, carried here so it is not
relearned. Both findings that cost that plugin a round — unbounded buffering and
AutoText sinks — were present in this one at first commit, and both were caught
by running these, not by reasoning.

```bash
node --test tests/model.test.js
omarchy plugin validate .

# no Text may be left on AutoText — the security review checks this mechanically
for f in *.qml; do awk '/^\s*Text \{/{s=NR;b="";d=1;next} s&&d>0{b=b"\n"$0; if(/\{/)d++; if(/\}/)d--; if(d==0){if(b !~ /textFormat/) print FILENAME": Text at "s" has no textFormat"; s=0}}' "$f"; done

# nothing private in the tree or the history
grep -rniE 'token|secret|api[-_]?key|password|bearer' --exclude-dir=.git .
find . -name '__pycache__' -o -name '*.pyc' | grep -v ./.git && echo "^ remove these"
```

**The awk check only sees `.qml` in this directory, and that is its blind spot.**
It cannot see the components this plugin passes strings *into*. Both real
AutoText findings here were one level up — `PanelHero`'s `detailText` and the bar's
`tooltipLabel`, in `/usr/share/omarchy/shell/`, neither of which sets
`textFormat`. So the rule is not "every Text of ours is PlainText"; it is **strip
and clamp at the boundary in Model.js**, because a sink you do not own cannot be
fixed and a sink added later will not inherit a fix applied at the sink.

Then bump `version` in `manifest.json`, commit, tag `vX.Y.Z`, push both.

## What is bounded, and where

Every dimension of luvus's answer is luvus's to choose — and `luvusBin` means
"luvus" is whatever binary the setting names.

| Dimension | Bounded by | Where |
| --- | --- | --- |
| seconds | `timeout 10` | `Service.boundedRead` |
| bytes on the wire | `head -c 4000000` | `Service.boundedRead` |
| bytes accepted | `text.length > 4000000` | `Service.qml` `onStreamFinished` |
| one event line | `line.length > 65536` | `Service.qml` `SplitParser.onRead` |
| agents rendered | `MAX_AGENTS` (total stays honest) | `Model.parseAgents` |
| any single string | `MAX_TEXT`, plus `<>&` stripped | `Model.clamp` |
| a pane id | `^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$` | `Model.paneId` |

Two of those need their reasons stated or they will be "simplified" away:

- **`boundedRead` is producer-side on purpose.** `StdioCollector` has no size
  limit and no deadline; by the time our own length check runs, the shell has
  already buffered the whole answer. The consumer-side check is a second line,
  not the line.
- **`Model.paneId` forbids a leading `-`, and that is the entire point.** A pane
  id is argv to the luvus binary, and luvus parses `-x` or `--remote=host` where
  an id is expected as one of its own global flags rather than rejecting it. A
  character class of `[A-Za-z0-9._-]` admits exactly the input being guarded
  against; a test covers it because the first version got this wrong.

Anything that reaches a shell goes through `Util.execArgv` or an argv array,
never `bar.run` — `bar.run` hands its argument to `bash -lc` as a string.

## Lineage

The panel's shape — the four counts, the worst-first rows, the status glyphs and
their colours — is taken from `io.github.fabean.herdr` (MIT, Josh Fabean), which
solved the same problem for herdr first. Credited in the README, and worth
keeping in mind when changing the panel: some of those choices are his, and were
adopted because they were already right.

## The watchdog is declarative, and that is the whole fix

`spawnWatch` is the only thing that notices a subscription that never arrived.
It has to exist because `onExited` cannot cover it: a `Process` that fails to
**spawn** — no such binary, fork refused — reports nothing at all, so the backoff
never arms and the widget stays poll-only for the life of the shell, its only
symptom the panel's quiet "live updates are not connected" line.

It was written imperatively twice, and failed the same way twice: `openStream()`
armed it for the incoming process, and the *outgoing* process's own `onExited`
disarmed it a moment later. Instrumented, the timer read `running=true
interval=8000` and never fired, because a stale callback had stopped it.

So it is a binding now — `running: started && pushUpdates && !subscribed` — which
is the question itself rather than a reminder to ask it, and which no callback
can cancel. Do not "simplify" it back to `restart()`/`stop()`.

The same shape is why `_closing` exists. **An exit we caused must not undo work
we did on the way to causing it.** That sentence covers three of this plugin's
five bugs; if a fourth turns up in the process lifecycle, look there first.

Proved with a shim that connects and never acknowledges: retries at a steady 8s
(`17:28:54, :29:02, :29:10, :29:18, :29:26`), `agent list` still flowing
throughout, and on a healthy server the same three PIDs across three samples —
it stops itself the instant `subscribed` turns true.
