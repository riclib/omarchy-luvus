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

Verified against live servers. First established on 0.12.0; re-checked on 0.13.1,
which changed three things worth knowing about (see the end of this section).

**Read `https://luvus.dev/agent-readme.md` before doing any of this again.** It is
advertised in the ASCII art on every `luvus help` screen and is easy to scroll
past, which is exactly what happened here. It does *not* list the event names —
that part had to be excavated from a probe server, see below — but it names the
runtime discovery commands (`luvus uhp capabilities`, `luvus uhp schema`) and the
intended consumption pattern, which is not the one this plugin uses.

Careful with `uhp capabilities`: the ~69 dotted names in it are RPC **methods**,
not events. `pane.close` is something you call; `pane.closed` is something you
receive, and only the `terminal.*` events are declared in the schema bundle. None
of the events this plugin depends on appear in either.

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

**On 0.12.0, two things the schema promised and the CLI did not deliver.** The
published `event.schema.json` requires a monotonic `sequence` on every event, and
the socket API has an `after_sequence` replay buffer and a `resync_required`
overflow signal. Neither reached you through `luvus events` — the lines carried
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

### What 0.13.1 changed

Re-verified on 2026-08-26. Nothing broke — every change is additive, and the
plugin needed no code change — but all three matter to whoever edits this next.

**`sequence` is now on the CLI stream**, and the acknowledgement carries a good
deal more:

```json
{"id":"1","result":{"loss_behavior":"resync_required_then_close",
 "queue_capacity":256,"replayed":0,"sequence":2,"type":"subscription_started"}}
{"data":{"pane":"2"},"event":"pane.created","sequence":3}
```

So the paragraph above is now historical, and with it half the reason for the
design here. The doorbell-not-a-data-source choice still stands on the duplicate
`pane.closed` alone, but it is now the weaker half of the argument.

**There is a documented alternative, and it should be the starting point for
anyone revisiting this.** `agent-readme.md` spells out the intended pattern:
subscribe to sequenced events, take a `session.snapshot` (`luvus uhp snapshot`),
discard buffered events at or below the snapshot's sequence, then apply later
events in order. `uhp capabilities` advertises the contract it runs on —
`events: {loss: "resync_required", resume: "after_sequence"}`. That is a
race-free sync, and it is strictly better than debounce-and-re-read if the
duplicate `pane.closed` can be handled or is fixed upstream. It was not built
here because on 0.12.0 the CLI stream carried no sequence and the pattern was
therefore impossible — that is no longer true.
Note `loss_behavior: resync_required_then_close` with a 256-deep queue: a slow
subscriber is **closed**, not merely warned. That is handled — `onExited` backs
off and reopens, and the reopen re-reads the world — but it is now a documented
server behaviour rather than a guess.

**`terminal.*` events are on the default stream, and they are loud.** Measured on
an ordinary four-agent session: **360 events in 30 seconds, all
`terminal.output_ready`** — it fires on every chunk of pane output. On 0.12.0
this stream was silent when nothing changed. `RELEVANT_EVENTS` already excludes
them so none of it reaches `refresh()`, and a pre-parse substring filter was
written, measured and **thrown away**: 72,200 lines cost 23ms to `JSON.parse`
outright against 16ms filtered, which at ~12 events/s is 18µs per second. Real
volume, irrelevant cost. Do not re-add the filter without measuring again on a
much busier session.

**`agent list` gained fields**: `revision` and `type` on `result`, `authority`
and `state_source` on each agent. Nothing was removed, and unknown fields are
ignored, which is why the upgrade was a no-op. `state_source` (`shell_activity`,
`no_positive_state_evidence`) and `authority` (`command_fallback`) look like they
explain how confident luvus is in a status — potentially worth surfacing.

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
| one event line, on the wire | `fold -b -w MAX_LINE` | `Service.boundedStream` |
| one event line, accepted | `raw.length >= MAX_LINE` | `Model.readEventLine` |
| agents rendered | `MAX_AGENTS` (total stays honest) | `Model.parseAgents` |
| any single string | `MAX_TEXT`, plus `<>&` stripped | `Model.clamp` |
| a pane id | `^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$` | `Model.paneId` |
| processes alive | `setpriv --pdeathsig KILL`, twice | `Service.boundedStream` |

Three of those need their reasons stated or they will be "simplified" away:

- **`boundedRead` is producer-side on purpose.** `StdioCollector` has no size
  limit and no deadline; by the time our own length check runs, the shell has
  already buffered the whole answer. The consumer-side check is a second line,
  not the line.
- **`boundedStream` is the same lesson, learned again on the stream.** This one
  was a marketplace review finding, and it was right: `luvus events` used to go
  straight into `SplitParser`, which has exactly one property — the marker it
  splits on — so `line.length` could not run until a newline arrived, and a
  producer that never sent one grew the shell's buffer without limit. Measured
  under real Quickshell against a "luvus" that acknowledges and then emits an
  endless unterminated line: **3.1GB of RSS after two seconds, 9GB after nine,
  still climbing.** With `fold` in front, flat at 365MB.

  Each piece of `exec stdbuf -oL fold -b -w … < <(exec "$@")` is load-bearing,
  and all three were measured:

  - **`fold`, not `timeout`/`head -c`.** The stream is meant to stay open for
    the life of the shell, so a deadline or a total-byte ceiling would close a
    *healthy* subscription on a schedule. What needs bounding is the line, and
    `fold` is the tool that bounds one without reading it whole first.
  - **`stdbuf -oL` is not decoration.** fold's stdout is a pipe, so it
    block-buffers by default and the doorbell simply stops ringing — against a
    producer emitting one line a second, *nothing* arrived in four seconds
    without it, and one line a second with it. Drop it and the widget silently
    degrades to the 30s poll while `spawnWatch` retries every 8s forever.
  - **`exec` and the process substitution keep this one process to kill.**
    Written the obvious way, `luvus events | fold`, bash stays the parent and
    Quickshell terminates only the pid it spawned — measured, luvus and fold
    both outlive it, and this widget closes the stream on every rebind and
    every `spawnWatch` retry, so that leaks a pair each time. Written as it is,
    bash *becomes* fold: the pid Quickshell holds is the pid that dies.
  - **Both `setpriv --pdeathsig KILL` are the guarantee, not a nicety.** This
    was the second marketplace finding, and it was right too. Filter and
    producer are two processes and Quickshell signals only one of them, so
    without this the producer dies only when it *notices* — writing into a pipe
    with no reader and taking EPIPE. A luvus that is silent or hung never
    writes, never notices, and `spawnWatch` reopens every eight seconds for as
    long as no acknowledgement comes: one orphan per retry, indefinitely.
    Measured under Quickshell against a producer that never acknowledges,
    **11 orphans after nine seconds, 18 after sixty-three, all 18 still running
    after the shell itself exited.** With both in place, flat at one live tree
    and nothing left behind.

    `PR_SET_PDEATHSIG` is the kernel doing it: the child is signalled the moment
    its parent dies, whatever it is blocked on and however the parent went —
    which is why this holds through SIGKILL and through a shell that crashes.
    The outer one (on fold, watching Quickshell) closes a leak that predates all
    of this: **v0.1.0 left a `luvus events` behind every time the shell exited**,
    because Quickshell does not reap its children on the way out. Verified the
    outer one does not misfire: the signal follows the parent *thread*, so if Qt
    forked from a worker that later exited it would kill a healthy stream — one
    fold pid held for a full minute against a live server, so it does not.

    KILL rather than TERM because the threat model is a luvus that is broken or
    hostile, and TERM is a signal a hostile one can ignore — which reinstates
    the leak exactly. Nothing is lost by it: a subscription is a read, with
    nothing to flush. It does not cover a producer that deliberately forks away
    from its own children; nothing short of a cgroup would, and that is a lot of
    machinery for a bar widget.

- **`Model.paneId` forbids a leading `-`, and that is the entire point.** A pane
  id is argv to the luvus binary, and luvus parses `-x` or `--remote=host` where
  an id is expected as one of its own global flags rather than rejecting it. A
  character class of `[A-Za-z0-9._-]` admits exactly the input being guarded
  against; a test covers it because the first version got this wrong.

Anything that reaches a shell goes through `Util.execArgv` or an argv array,
never `bar.run` — `bar.run` hands its argument to `bash -lc` as a string.

## How luvus decides a status, and why that is our problem

The widget renders `status` and never computes it, so every complaint about a
wrong state resolves here. luvus detects state by **matching substrings against
the pane's rendered output** — screen-scraping, per agent, with rules merged by
priority. `luvus agent explain <pane>` returns the working out:

```json
{"status":"working","authority":null,
 "identity":{"confidence":"authoritative","source":"process_tree"},
 "state_evidence":{"source":"manifest_rule","confidence":"high",
                   "rule_priority":200,"rule_region":"screen","blocked_hint":null}}
```

Two fields, two different questions. `identity` is *which agent is this*
(`process_tree` = found the real process, trustworthy; `command_fallback` =
guessed from the command line). `state_evidence` is *how the status was reached*
— `manifest_rule` is a positive match, `shell_activity` is inferred, and
`no_positive_state_evidence` with `confidence: "none"` means **nothing matched
and `idle` is a fallback, not a finding**. Treat that last one as "unknown".

Measured 2026-08-26: luvus ships **23 rules across 15 recognised agents**, so
coverage is thin outside claude. A live grok running a subagent for nine minutes
reported `idle`/`confidence: none` — the widget was honest and luvus was blind.
Rules live in `~/.luvus/manifests/<agent>.toml`, merge over the built-ins, and
load on `server.reload_agent_manifests` with no rebuild. The README carries the
worked example.

**`working` is not `blocked`, and the distinction is ours to defend.** luvus
reserves `blocked` for needing a human — the built-in claude rule for it is
`"do you want to proceed"` — and this widget spends its urgent colour, its
`jumpTarget`, and the `g` key on exactly that. An agent parked on its own
subagent is busy, not stuck. Anyone tempted to write a `blocked` rule for a
waiting-on-a-child state is about to make the bar cry wolf.

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
