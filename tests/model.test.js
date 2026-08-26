const test = require('node:test')
const assert = require('node:assert')
const Model = require('../Model.js')

// The fixtures below are verbatim from a live luvus 0.12.0 server — captured
// with `luvus agent list` and `luvus events` — not invented. If luvus changes
// its shape, these are what should fail first.

const HOME = '/home/riclib'

const LIVE_LIST = JSON.stringify({
  id: '1',
  result: {
    agents: [
      {
        agent: 'claude', branch: 'master', cwd: '/home/riclib/envs/advisory/advisory-v4',
        focused: false, name: null, pane: '1', project: 'advisory-v4',
        repo: '/home/riclib/envs/advisory/advisory-v4/.git', session: null,
        status: 'idle', tab: '1', workspace: '0', workspace_name: 'advisory-v4', worktree: false
      },
      {
        agent: 'grok', branch: 'master', cwd: '/home/riclib/envs/solid-next',
        focused: true, name: null, pane: '6', project: 'solid-next',
        repo: '/home/riclib/envs/solid-next/.git', session: null,
        status: 'working', tab: '1', workspace: '1', workspace_name: 'solid-next', worktree: false
      }
    ]
  }
})

// --- parsing -------------------------------------------------------------

test('parseAgents reads the live envelope and counts by status', () => {
  const state = Model.parseAgents(LIVE_LIST, HOME)
  assert.equal(state.online, true)
  assert.equal(state.total, 2)
  assert.equal(state.working, 1)
  assert.equal(state.idle, 1)
  assert.equal(state.blocked, 0)
})

test('parseAgents sorts what needs a human above what is asleep', () => {
  const state = Model.parseAgents(LIVE_LIST, HOME)
  assert.deepEqual(state.agents.map(a => a.status), ['working', 'idle'])
})

test('parseAgents keeps the pane id as a string, so "0" is not falsy', () => {
  const raw = JSON.stringify({ id: '1', result: { agents: [{ pane: 0, status: 'idle' }] } })
  assert.strictEqual(Model.parseAgents(raw, HOME).agents[0].pane, '0')
})

test('an unknown status is bucketed rather than dropped', () => {
  const raw = JSON.stringify({ id: '1', result: { agents: [{ pane: '2', status: 'thinking' }] } })
  const state = Model.parseAgents(raw, HOME)
  assert.equal(state.total, 1)
  assert.equal(state.unknown, 1)
  assert.equal(state.agents[0].status, 'unknown')
})

test('a dead server produces an offline state, never a throw', () => {
  for (const raw of ['', '   ', 'connection refused', null, undefined]) {
    const state = Model.parseAgents(raw, HOME)
    assert.equal(state.online, false)
    assert.equal(state.total, 0)
    assert.deepEqual(state.agents, [])
  }
})

test('an error envelope is offline and carries its message', () => {
  const raw = JSON.stringify({ id: '1', error: { code: 'no_session', message: 'no such session' } })
  const state = Model.parseAgents(raw, HOME)
  assert.equal(state.online, false)
  assert.equal(state.reason, 'no such session')
})

test('a running server with nothing open is online with zero agents', () => {
  const state = Model.parseAgents(JSON.stringify({ id: '1', result: { agents: [] } }), HOME)
  assert.equal(state.online, true)
  assert.equal(state.total, 0)
})

// --- labelling -----------------------------------------------------------

test('agentLabel prefers a name, then the project, then the directory', () => {
  assert.equal(Model.agentLabel({ name: 'reviewer', project: 'v4', cwd: '/a/b' }), 'reviewer')
  assert.equal(Model.agentLabel({ name: null, project: 'v4', cwd: '/a/b' }), 'v4')
  assert.equal(Model.agentLabel({ cwd: '/home/riclib/src/lg' }), 'lg')
  assert.equal(Model.agentLabel({ pane: '7' }), 'pane 7')
})

test('shortPath trims $HOME and leaves everything else alone', () => {
  assert.equal(Model.shortPath('/home/riclib/src/lg', HOME), '~/src/lg')
  assert.equal(Model.shortPath('/etc/cups', HOME), '/etc/cups')
  assert.equal(Model.shortPath('', HOME), '')
})

test('agentDetail names the agent and marks a worktree', () => {
  assert.equal(Model.agentDetail({ agent: 'claude', branch: 'master' }, HOME), 'claude  ·  master')
  assert.ok(Model.agentDetail({ agent: 'codex', branch: 'fix/x', worktree: true }, HOME).includes('⑂'))
})

// --- the event stream ----------------------------------------------------

test('the subscription acknowledgement is recognised as the stream going live', () => {
  const read = Model.readEventLine('{"id":"1","result":{"type":"subscription_started"}}')
  assert.equal(read.kind, 'subscribed')
})

test('a live agent status change asks for a re-read', () => {
  const line = '{"data":{"agent":"bash","branch":"master","cwd":"/home/riclib/src/omarchy-cust",'
    + '"pane":"2","project":"omarchy-cust","status":"working"},"event":"pane.agent_status_changed"}'
  assert.equal(Model.readEventLine(line).kind, 'refresh')
})

test('every lifecycle event captured from a live server is one we act on', () => {
  const captured = [
    '{"data":{"pane":"2"},"event":"pane.created"}',
    '{"data":{"pane":"3"},"event":"pane.closed"}',
    '{"data":{"tab":"2"},"event":"tab.created"}',
    '{"data":{"workspace":"1"},"event":"workspace.created"}',
    '{"data":{"workspace":"1"},"event":"workspace.closed"}'
  ]
  for (const line of captured) assert.equal(Model.readEventLine(line).kind, 'refresh', line)
})

test('an event we do not care about is ignored, not treated as noise', () => {
  const read = Model.readEventLine('{"data":{},"event":"terminal.frame"}')
  assert.equal(read.kind, 'ignored')
  assert.equal(read.event, 'terminal.frame')
})

test('a partial or non-JSON line is survivable', () => {
  for (const line of ['', '{"data":', 'luvus: connection lost', null]) {
    assert.equal(Model.readEventLine(line).kind, 'none')
  }
})

// --- what the bar says ---------------------------------------------------

test('barCount spends the number on blocked, then working, then the total', () => {
  const base = { online: true, total: 5, blocked: 0, working: 0 }
  assert.equal(Model.barCount({ ...base, blocked: 2, working: 3 }), 2)
  assert.equal(Model.barCount({ ...base, working: 3 }), 3)
  assert.equal(Model.barCount(base), 5)
})

test('barCount returns -1 when luvus is not there, so the bar can say ×', () => {
  assert.equal(Model.barCount(Model.emptyState('not running')), -1)
})

test('jumpTarget goes to a blocked agent before a working one', () => {
  const state = Model.parseAgents(JSON.stringify({
    id: '1',
    result: {
      agents: [
        { pane: '1', status: 'working', project: 'a' },
        { pane: '2', status: 'blocked', project: 'b' }
      ]
    }
  }), HOME)
  assert.equal(Model.jumpTarget(state), '2')
})

test('jumpTarget is empty when nothing is worth jumping to', () => {
  const state = Model.parseAgents(JSON.stringify({
    id: '1', result: { agents: [{ pane: '1', status: 'idle' }] }
  }), HOME)
  assert.equal(Model.jumpTarget(state), '')
  assert.equal(Model.jumpTarget(Model.emptyState('offline')), '')
})

test('the hero line reads correctly at each state', () => {
  assert.equal(Model.heroDetail({ online: true, blocked: 1, working: 2, total: 4 }), '1 agent waiting')
  assert.equal(Model.heroDetail({ online: true, blocked: 0, working: 2, total: 4 }), '2 agents working')
  assert.equal(Model.heroDetail({ online: true, blocked: 0, working: 0, total: 4 }), '4 agents, all quiet')
  assert.equal(Model.heroDetail({ online: true, blocked: 0, working: 0, total: 0 }), 'No agents')
  assert.equal(Model.heroMeta(Model.emptyState('x')), 'OFFLINE')
})

test('the tooltip names the states that are actually populated', () => {
  const state = Model.parseAgents(LIVE_LIST, HOME)
  assert.equal(Model.tooltipFor(state), 'luvus — 1 working, 1 idle')
  assert.ok(Model.tooltipFor(Model.emptyState('luvus not found on PATH')).includes('not found'))
})
