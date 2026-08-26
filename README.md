# omarchy-luvus

An Omarchy shell plugin for [luvus](https://github.com/RizRiyz/luvus): the
coding agents you have running, in the bar, with a click to go to whichever one
is waiting for you.

One glyph and one number. The number answers the only question a bar can usefully
answer at a glance — *is anything waiting for me?* — so blocked agents outrank
working ones, which outrank a plain count, and the urgent colour is spent on
nothing else.

```
󰚩 2      two agents blocked, in the urgent colour
󰚩 5      nothing blocked, five working
󰚩 9      nothing running, nine agents exist
󰚩 ×      luvus is not running
```

Click for the panel. Middle click to refresh. Right click to jump straight to
whatever needs you.

## Requires

- [luvus](https://github.com/RizRiyz/luvus) 0.11 or newer, with a server running
  (`luvus` in any terminal starts one). Tested against 0.12.0.
- The Omarchy shell.
- A Nerd Font for the glyphs — Omarchy's default bar font already is one.

No jq, no helper script, no daemon of its own. `luvus agent list` prints JSON
without being asked, so the plugin parses it directly.

## Install

```bash
omarchy plugin add https://github.com/riclib/omarchy-luvus.git --enable
omarchy restart shell
```

`--enable` places the widget for you — it asks which bar section, offering the
centre by default — and writes `~/.config/omarchy/shell.json` itself. There is
no file to edit by hand.

To place it later, or to move it:

```bash
omarchy plugin enable riclib.luvus --section right
```

> Omarchy plugins are unsandboxed code running inside the long-lived shell
> process. Read the source before installing this or any other one.

## Update

```bash
omarchy plugin update riclib.luvus --yes
omarchy restart shell
```

Without `--yes` it prints the incoming diff and waits for a keypress.

## Remove

```bash
omarchy plugin remove riclib.luvus
omarchy restart shell
```

That is the whole removal, because the plugin's own folder is its whole
footprint. It creates no files, writes no configuration of yours, installs no
service, takes no keybinding, and stores nothing on disk — it reads luvus and
draws. Removing it takes the widget out of your bar layout and deletes the
checkout; luvus itself, its sessions and its data are untouched.

## Settings

All of these are also editable in the shell's widget settings UI.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `session` | string | *(empty)* | Which luvus server session to watch. Empty means the default one. `luvus session list` names the others. |
| `luvusBin` | string | `luvus` | Resolved on PATH as a bare name. Set an absolute path if the widget says the binary is missing while your terminal finds it — the shell does not always inherit a login PATH. |
| `pushUpdates` | boolean | `true` | Hold a `luvus events` subscription open and refresh the moment something changes. Off falls back to polling alone. |
| `hideWhenIdle` | boolean | `false` | Show the widget only while an agent is working or blocked. It stays visible while the panel is open, and while luvus is unreachable — that is worth seeing. |
| `focusWindowClass` | string | *(empty)* | The Hyprland class of the terminal that hosts luvus. See [Jumping to an agent](#jumping-to-an-agent). |

## The panel

Four counts — blocked, working, idle, done — and then every agent luvus knows
about, worst first. Each row carries the agent kind, the branch, and a `⑂` when
it is off in a worktree, because a `working` claude on a worktree branch is a
different thing from one on master.

Keys, while the panel has focus: `r` refreshes, `g` jumps to whatever needs you,
`Escape` closes.

## How it stays current

Two ways in, deliberately:

- **`luvus agent list`** — the whole truth, on demand.
- **`luvus events`** — a held-open NDJSON subscription that says *when* to ask
  again.

Events are a doorbell here, not a data source. `pane.agent_status_changed`
carries a full payload and it is tempting to apply it directly, but `pane.closed`
is emitted more than once for the same pane and the CLI stream carries no
sequence number to deduplicate against — so an incrementally-maintained list
would drift. A relevant event debounces for 300ms and then re-reads.

A 30-second timer sits behind all of it. It is not the update mechanism; it is
the thing that notices the doorbell has stopped working — a luvus server
restarted, a subscription dropped, `pushUpdates` turned off. When the
subscription is down the panel says so, because "nothing is blocked" and
"nothing was blocked half a minute ago" are different claims.

If the subscription dies, it comes back with backoff (1s, 2s, 5s, 15s), and
thirty seconds of health resets that — so a server restarted twice in a week
never creeps toward the long backoff and stays there.

## Jumping to an agent

Right-clicking the bar glyph, pressing `g`, or clicking a panel row runs
`luvus pane focus <id>`, which moves the cursor to that pane inside the luvus
TUI.

It cannot raise the terminal window that hosts the TUI — nothing running inside
a terminal can. So the window half is opt-in: set `focusWindowClass` to the
Hyprland class of your terminal and the plugin will also dispatch
`hyprctl dispatch focuswindow class:<that>`. Find it with:

```bash
hyprctl clients | grep -A2 -i luvus
```

Left empty, the pane is focused and the window is left alone.

## Credit

This plugin began as a reading of
[**omarchy-herdr**](https://github.com/fabean/omarchy-herdr) by Josh Fabean,
which does the same job for [herdr](https://github.com/fabean/herdr). Its panel
worked out what an agent widget in this bar should show — counts across the top,
worst-first rows below, the urgent colour reserved for blocked — and that shape
is kept here almost intact, along with its status glyphs and its colour mapping.
The bar's robot glyph is the shared mark every agent widget in Omarchy wears, so
it carries over too.

What changed is underneath. herdr's plugin shells out through a `jq` script on a
blind three-second timer; luvus prints JSON without being asked and will tell you
when something changed, so this parses directly and waits on a subscription
instead. Rows are clickable here because `luvus pane focus` exists.

If you run herdr rather than luvus, use Josh's plugin — this is not a
replacement for it.

## Licence

MIT — see [LICENSE](LICENSE).

This plugin contains and links no luvus code — it executes the `luvus` binary
as a separate process and reads its stdout — so the MIT licence above applies to
this repository alone. luvus itself remains AGPL-3.0 for anyone who redistributes
it. Do not vendor luvus source into this repository.

Portions of `Panel.qml` and `AgentRow.qml` are derived from
[omarchy-herdr](https://github.com/fabean/omarchy-herdr) (MIT, Copyright (c)
2026 Josh Fabean); the notice is in [LICENSE](LICENSE).
