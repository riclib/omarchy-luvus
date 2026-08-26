// Everything that turns luvus's JSON into what the bar and the panel render.
// Free of QML types on purpose: this is where the parsing and the ranking live,
// so they can be tested with node (tests/model.test.js) instead of by opening
// the panel and squinting.

// The four states `luvus wait agent-status` will accept, plus the one we use
// when luvus reports something we have not seen before. Ordering is the panel's
// sort: what needs a human first, what is asleep last.
var STATUS_ORDER = { blocked: 0, working: 1, done: 2, idle: 3, unknown: 4 }

function emptyState(reason) {
  return {
    online: false,
    reason: reason || "",
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
  if (home && text.indexOf(home) === 0) return "~" + text.slice(home.length)
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
  if (agent.name) return String(agent.name)
  if (agent.project) return String(agent.project)
  var base = baseName(agent.cwd)
  if (base) return base
  return agent.pane ? "pane " + agent.pane : "Agent"
}

// The second line of a row: which agent binary, on which branch, and whether
// it is off in a worktree. Worth saying — a `working` claude on a worktree
// branch is a different thing from one on master.
function agentDetail(agent, home) {
  if (!agent) return ""
  var bits = []
  if (agent.agent) bits.push(String(agent.agent))
  if (agent.branch) bits.push(String(agent.branch) + (agent.worktree === true ? " ⑂" : ""))
  var path = shortPath(agent.cwd, home)
  if (path && bits.length < 2) bits.push(path)
  return bits.join("  ·  ")
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

  var list = parsed && parsed.result && Array.isArray(parsed.result.agents)
    ? parsed.result.agents : []

  var state = emptyState("")
  state.online = true
  state.total = list.length

  var rows = []
  for (var i = 0; i < list.length; i++) {
    var agent = list[i] || {}
    var status = normalizeStatus(agent.status)
    state[status] = (state[status] || 0) + 1
    rows.push({
      label: agentLabel(agent),
      detail: agentDetail(agent, home),
      status: status,
      pane: agent.pane === undefined || agent.pane === null ? "" : String(agent.pane),
      cwd: String(agent.cwd || ""),
      project: String(agent.project || ""),
      kind: String(agent.agent || ""),
      focused: agent.focused === true
    })
  }

  rows.sort(function (a, b) {
    var byStatus = STATUS_ORDER[a.status] - STATUS_ORDER[b.status]
    if (byStatus !== 0) return byStatus
    return a.label.localeCompare(b.label)
  })

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
  var text = String(line || "").trim()
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
  for (var i = 0; i < agents.length; i++)
    if (agents[i].status === "blocked") return agents[i].pane
  for (var j = 0; j < agents.length; j++)
    if (agents[j].status === "working") return agents[j].pane
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
