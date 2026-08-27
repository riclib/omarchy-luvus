// Everything that turns luvus's JSON into what the bar and the panel render.
// Free of QML types on purpose: this is where the parsing and the ranking live,
// so they can be tested with node (tests/model.test.js) instead of by opening
// the panel and squinting.

// The four states `luvus wait agent-status` will accept, plus the one we use
// when luvus reports something we have not seen before. Ordering is the panel's
// sort: what needs a human first, what is asleep last.
var STATUS_ORDER = { blocked: 0, working: 1, done: 2, idle: 3, unknown: 4 }

// Every dimension of luvus's answer is luvus's to choose, not just its length —
// and "luvus" here means whatever binary `luvusBin` names, reporting whatever a
// branch name or a project directory happens to be called. So bound all of them,
// and bound them HERE, at the one place external text becomes plugin state.
// Clamping at each sink is what leaves a gap: a sink gets added later and the
// clamp does not come with it.
//
// The strip is not belt-and-braces. Some of the shell components this text is
// handed to render on Qt's default AutoText, which turns a string containing a
// recognised HTML tag into rich text — so a branch called `<b>x</b>` would
// render as markup in a panel this plugin does not own.
var MAX_TEXT = 160
var MAX_AGENTS = 200

// The ceiling on one line of `luvus events`, in two places at once: Service.qml
// hands it to `fold` as the width that chops the stream up, and readEventLine
// refuses a line that arrives at it. Both halves are needed and neither is
// enough alone — see Service.boundedStream for why the bound has to be applied
// before the line reaches us at all.
var MAX_LINE = 65536

function clamp(value) {
  var text = String(value === null || value === undefined ? "" : value)
  text = text.replace(/[<>&]/g, " ")
  return text.length > MAX_TEXT ? text.slice(0, MAX_TEXT - 1) + "\u2026" : text
}

function emptyState(reason) {
  return {
    online: false,
    // Clamped like any other external string: this carries luvus's own
    // error.message straight through on the error-envelope path below.
    reason: clamp(reason || ""),
    total: 0,
    working: 0,
    blocked: 0,
    done: 0,
    idle: 0,
    unknown: 0,
    agents: []
  }
}

// A cwd is nearly always under $HOME and nearly always too long for a panel
// row. Trim the home prefix; leave anything else alone rather than inventing
// an abbreviation for a path the reader may need to recognise.
function shortPath(path, home) {
  var text = String(path || "")
  if (!text) return ""
  // The boundary check is the point: without it /home/riclib-backup/src renders
  // as ~-backup/src, which reads as a path the user does not have.
  if (home && text === home) return "~"
  if (home && text.indexOf(home + "/") === 0) return "~" + text.slice(home.length)
  return text
}

function baseName(path) {
  var parts = String(path || "").replace(/\/+$/, "").split("/")
  return parts.length ? parts[parts.length - 1] : ""
}

// What to call an agent. A name the user set beats anything we can derive; the
// project is what luvus itself puts in the event payload, so it is the next
// most likely to be recognised; the pane id is the last resort that is at least
// unambiguous.
function agentLabel(agent) {
  if (!agent) return "Agent"
  if (agent.name) return clamp(agent.name)
  if (agent.project) return clamp(agent.project)
  var base = baseName(agent.cwd)
  if (base) return clamp(base)
  return agent.pane ? "pane " + clamp(agent.pane) : "Agent"
}

// The second line of a row: which agent binary, on which branch, and whether
// it is off in a worktree. Worth saying — a `working` claude on a worktree
// branch is a different thing from one on master.
function agentDetail(agent, home) {
  if (!agent) return ""
  var bits = []
  if (agent.agent) bits.push(clamp(agent.agent))
  if (agent.branch) bits.push(clamp(agent.branch) + (agent.worktree === true ? " ⑂" : ""))
  var path = shortPath(agent.cwd, home)
  if (path && bits.length < 2) bits.push(clamp(path))
  return bits.join("  ·  ")
}

// A pane id is argv to the luvus binary, so it is not merely text. luvus parses
// a leading-dash "id" as one of its own global flags rather than rejecting it,
// which quietly changes what the command means — so anything that is not
// plainly an id is dropped, and the row simply loses its jump.
function paneId(value) {
  var text = String(value === null || value === undefined ? "" : value)
  // The first character may not be `-`: that is the whole point. An id of "-x"
  // is what luvus's parser mistakes for a flag, and a class of [A-Za-z0-9._-]
  // that allows it at the front admits exactly the input being guarded against.
  return /^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$/.test(text) ? text : ""
}

function normalizeStatus(value) {
  var text = String(value || "unknown")
  return STATUS_ORDER.hasOwnProperty(text) ? text : "unknown"
}

// `luvus agent list` answers with the same envelope every luvus request does:
// {"id": "...", "result": {...}} on success, {"id": "...", "error": {...}} when
// the server is up but unhappy. A dead server produces no JSON at all, which
// lands in the catch.
function parseAgents(raw, home) {
  var text = String(raw || "").trim()
  if (!text) return emptyState("no answer from luvus")

  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return emptyState("unreadable answer from luvus")
  }

  if (parsed && parsed.error) {
    var message = parsed.error.message || parsed.error.code || "luvus returned an error"
    return emptyState(String(message))
  }

  // `null`, `0`, `"hello"` and `[]` all parse, and all used to read as a healthy
  // server with no agents. An answer that is not an object with a result is not
  // an answer.
  if (!parsed || typeof parsed !== "object" || !parsed.result || typeof parsed.result !== "object")
    return emptyState("unreadable answer from luvus")

  var list = Array.isArray(parsed.result.agents) ? parsed.result.agents : []

  var state = emptyState("")
  state.online = true
  state.total = list.length
  state.truncated = list.length > MAX_AGENTS

  // Two passes, and the split matters. The COUNTS are taken over every agent,
  // because the bar's number and the urgent colour are driven by them: counting
  // only what survives a cap means 300 idle agents and one blocked one past the
  // cut reads as `blocked: 0`, which takes the bar off the urgent colour and —
  // with hideWhenIdle on — hides the widget precisely when someone is waiting.
  //
  // Only the ROWS are capped, and only after the sort, so what a cap drops is
  // always the least urgent. Building a sort key per agent rather than a whole
  // row keeps the cost of that promise proportional to a list nobody will read.
  var keys = []
  for (var i = 0; i < list.length; i++) {
    var status = normalizeStatus((list[i] || {}).status)
    state[status] = (state[status] || 0) + 1
    keys.push({ i: i, order: STATUS_ORDER[status], status: status })
  }

  keys.sort(function (a, b) {
    if (a.order !== b.order) return a.order - b.order
    return agentLabel(list[a.i] || {}).localeCompare(agentLabel(list[b.i] || {}))
  })

  var rows = []
  var shown = Math.min(keys.length, MAX_AGENTS)
  for (var k = 0; k < shown; k++) {
    var agent = list[keys[k].i] || {}
    rows.push({
      label: agentLabel(agent),
      detail: agentDetail(agent, home),
      status: keys[k].status,
      pane: paneId(agent.pane),
      focused: agent.focused === true
    })
  }

  state.agents = rows
  return state
}

// Which luvus events are worth a re-read. Verified against a live 0.12.0
// server: pane.agent_status_changed carries {agent, branch, cwd, pane, project,
// status}, and the pane/tab/workspace lifecycle events carry only their own id.
// We treat all of them as "go and look" rather than trying to apply payloads
// incrementally — pane.closed is emitted more than once for the same pane, and
// the stream carries no sequence number to deduplicate against.
var RELEVANT_EVENTS = {
  "pane.agent_status_changed": true,
  "pane.created": true,
  "pane.closed": true,
  "tab.created": true,
  "tab.closed": true,
  "workspace.created": true,
  "workspace.closed": true
}

// One line of `luvus events` NDJSON. The first line is the subscription
// acknowledgement — {"id":"1","result":{"type":"subscription_started"}} — which
// is how we know the stream is live rather than merely spawned.
function readEventLine(line) {
  var raw = String(line || "")
  // An event line is a small JSON object; the largest observed is a few hundred
  // bytes. A line at MAX_LINE is not one — `fold` upstream cuts anything longer
  // into fragments of exactly that size, so a line this long is a piece of
  // something over-long rather than a whole event, and parsing it only to
  // discard it is work an unbounded stream would get to choose for us.
  if (raw.length >= MAX_LINE) return { kind: "none" }

  var text = raw.trim()
  if (!text) return { kind: "none" }

  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return { kind: "none" }
  }

  if (parsed && parsed.result && parsed.result.type === "subscription_started")
    return { kind: "subscribed" }

  if (parsed && typeof parsed.event === "string") {
    return {
      kind: RELEVANT_EVENTS[parsed.event] === true ? "refresh" : "ignored",
      event: parsed.event
    }
  }

  return { kind: "none" }
}

// The bar face. Blocked outranks working outranks a plain count, because the
// only number worth spending the urgent colour on is the one that means an
// agent is waiting for a human.
function barCount(state) {
  if (!state || !state.online) return -1
  if (state.blocked > 0) return state.blocked
  if (state.working > 0) return state.working
  return state.total
}

function tooltipFor(state) {
  if (!state || !state.online)
    return "luvus — " + (state.reason || "not running")
  if (state.total === 0) return "luvus — no agents"

  var parts = []
  if (state.blocked > 0) parts.push(state.blocked + " blocked")
  if (state.working > 0) parts.push(state.working + " working")
  if (state.idle > 0) parts.push(state.idle + " idle")
  if (state.done > 0) parts.push(state.done + " done")
  return "luvus — " + parts.join(", ")
}

// The panel's one-line summary under the title.
function heroDetail(state) {
  if (!state || !state.online) return state && state.reason ? state.reason : "Not running"
  if (state.blocked > 0) return state.blocked + (state.blocked === 1 ? " agent waiting" : " agents waiting")
  if (state.working > 0) return state.working + (state.working === 1 ? " agent working" : " agents working")
  if (state.total === 0) return "No agents"
  return state.total + (state.total === 1 ? " agent" : " agents") + ", all quiet"
}

function heroMeta(state) {
  if (!state || !state.online) return "OFFLINE"
  if (state.blocked > 0) return "NEEDS YOU"
  if (state.working > 0) return "IN MOTION"
  return "AT REST"
}

// Right-click target: the thing most worth being taken to. A blocked agent is
// waiting on a human, so it wins; otherwise the first one actually working.
// Returns "" when nothing deserves the jump, and the caller refreshes instead.
function jumpTarget(state) {
  if (!state || !state.online) return ""
  var agents = state.agents || []
  // `&& pane` is not belt-and-braces: paneId() blanks an id it will not hand to
  // luvus, so the first blocked agent may have no jump while the second does.
  // Returning its empty pane would hide the jump for every reachable agent
  // behind it.
  for (var i = 0; i < agents.length; i++)
    if (agents[i].status === "blocked" && agents[i].pane) return agents[i].pane
  for (var j = 0; j < agents.length; j++)
    if (agents[j].status === "working" && agents[j].pane) return agents[j].pane
  return ""
}

function statusGlyph(status) {
  if (status === "working") return "󰐊"
  if (status === "blocked") return ""
  if (status === "done") return ""
  if (status === "idle") return "󰒲"
  return "?"
}

function statusLabel(status) {
  var text = String(status || "unknown")
  return text.charAt(0).toUpperCase() + text.slice(1)
}

// QML ignores this (module is undefined); node uses it to load the file.
if (typeof module !== "undefined") {
  module.exports = {
    STATUS_ORDER: STATUS_ORDER,
    RELEVANT_EVENTS: RELEVANT_EVENTS,
    emptyState: emptyState,
    shortPath: shortPath,
    baseName: baseName,
    clamp: clamp,
    paneId: paneId,
    MAX_TEXT: MAX_TEXT,
    MAX_AGENTS: MAX_AGENTS,
    MAX_LINE: MAX_LINE,
    agentLabel: agentLabel,
    agentDetail: agentDetail,
    normalizeStatus: normalizeStatus,
    parseAgents: parseAgents,
    readEventLine: readEventLine,
    barCount: barCount,
    tooltipFor: tooltipFor,
    heroDetail: heroDetail,
    heroMeta: heroMeta,
    jumpTarget: jumpTarget,
    statusGlyph: statusGlyph,
    statusLabel: statusLabel
  }
}
