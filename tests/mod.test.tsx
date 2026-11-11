import { expect, test } from 'claude-code/testing'

// The engine beneath the plugin: env, clock, files, store and commands are answered here.
const NOW = Date.parse('2030-01-01T00:00:00Z')
const iso = (secs: number) => new Date(NOW + secs * 1000).toISOString()
// What the engine's clock and session id answer; each engine() starts them over.
let clock = NOW
let sessionId = 'sess-A'

function engine(
  on: any,
  env: Record<string, string | undefined>,
  usage: any[] = [],
  refuseCommands = false,
  store: Record<string, unknown> = {},
) {
  const files: Record<string, string> = {}
  clock = NOW
  sessionId = 'sess-A'
  on('env.get', (_: any, e: { name: string }) => ({ value: env[e.name] }))
  on('clock.now', () => ({ value: clock }))
  on('fs.write', (_: any, e: { path: string; text: string }) => ((files[e.path] = e.text), { value: undefined }))
  on('fs.read', (_: any, e: { path: string }) => {
    if (!(e.path in files)) throw new Error(`ENOENT: ${e.path}`)
    return { value: files[e.path] }
  })
  on('fs.list', (_: any, e: { path: string }) => ({
    value: Object.keys(files)
      .filter(f => f.startsWith(e.path + '/') && !f.slice(e.path.length + 1).includes('/'))
      .map(f => ({ name: f.slice(e.path.length + 1), kind: 'file', size: files[f].length })),
  }))
  on('session.id', () => ({ value: sessionId }))
  on('store.get', (_: any, e: { key: string }) => ({ value: store[e.key] }))
  on('store.set', (_: any, e: { key: string; value: unknown }) => ((store[e.key] = e.value), { value: undefined }))
  on('store.delete', (_: any, e: { key: string }) => (delete store[e.key], { value: undefined }))
  // The model's response beneath turn.step; the test passes its usage in via the model field.
  on('turn.step', async function* (_: any, e: any) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: JSON.parse(e.model) }
  })
  on('command.register', (_: any, e: { name: string }) => {
    if (refuseCommands) throw new Error(`"/${e.name}" refused: the plugin usage-left registered it already`)
    return { value: { command: e.name } }
  })
  on('session.usage', () => ({ value: { startedAt: NOW, context: {}, rateLimits: usage } }))
  on('session.start', (_: any, e: { cwd: string }) => ({ cwd: e.cwd }))
  on('session.measure', (_: any, e: { changed: string[] }) => ({ changed: e.changed }))
  return files
}
const start = ($: any) => $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
const measure = ($: any, rateLimits: any[], usd?: number, contextTokens?: number) =>
  $.session.measure({
    context: { window: 200000, tokens: contextTokens },
    rateLimits,
    cost: usd === undefined ? undefined : { usd },
    changed: ['rateLimits'],
  })
// One model response of `total` tokens; the bottom mock answers with this usage.
const turn = async ($: any, total: number, agentId?: string) => {
  const usage = { model: 'm', input_tokens: total / 2, output_tokens: total / 4, cache_read_input_tokens: total / 4, cache_creation_input_tokens: 0 }
  const stream = $.turn.step({ turnId: 't', index: 0, model: JSON.stringify(usage), messageCount: 1, agentId })
  for await (const _ of stream) {
  }
  return stream.result
}
const lims = (h: number, d: number) => [
  { kind: 'five_hour', percentUsed: h, resetsAt: iso(6600) },
  { kind: 'seven_day', percentUsed: d, resetsAt: iso(356400) },
]
const state = (files: Record<string, string>) => JSON.parse(files['/ua/state.json'])

test('session.measure writes state.json in the schema usage-status reads', async ($, on) => {
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' })
  await start($)
  await measure($, [
    { kind: 'five_hour', percentUsed: 66, resetsAt: iso(6600) },
    { kind: 'seven_day', percentUsed: 29.5, resetsAt: iso(356400) },
    { kind: 'spend_limit', percentUsed: 12 },
  ])
  const state = JSON.parse(files['/ua/state.json'])
  expect(state).toEqual({
    updated_at: NOW / 1000,
    source: 'mod',
    five_hour: { used_percentage: 66, resets_at: NOW / 1000 + 6600, recent: [[NOW / 1000, 66]] },
    seven_day: { used_percentage: 29.5, resets_at: NOW / 1000 + 356400, recent: [[NOW / 1000, 29.5]] },
    spend_limit: { used_percentage: 12, resets_at: null },
    session_id: 'sess-A',
    session_tokens: 0,
  })
  expect(JSON.parse(files['/ua/mod.json'])).toEqual({ heartbeat: NOW / 1000 })
})

test('missing windows are null', async ($, on) => {
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' })
  await measure($, [{ kind: 'seven_day', percentUsed: 3, resetsAt: iso(60) }])
  const state = JSON.parse(files['/ua/state.json'])
  expect(state.five_hour).toBe(null)
  expect(state.spend_limit).toBe(null)
})

test('no rate limits: heartbeat only, state untouched', async ($, on) => {
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' })
  await measure($, [])
  expect(files['/ua/state.json']).toBe(undefined)
  expect(files['/ua/mod.json']).toBeDefined()
})

test('session.start writes the heartbeat but never state (its figures may be from before)', async ($, on) => {
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' }, [{ kind: 'five_hour', percentUsed: 50, resetsAt: iso(60) }])
  await start($)
  expect(files['/ua/mod.json']).toBeDefined()
  expect(files['/ua/state.json']).toBe(undefined)
})

test('defaults to ~/.claude/usage-aware', async ($, on) => {
  const files = engine(on, { HOME: '/home/u' })
  await measure($, [{ kind: 'five_hour', percentUsed: 1, resetsAt: iso(60) }])
  expect(files['/home/u/.claude/usage-aware/state.json']).toBeDefined()
})

test('a non-default CLAUDE_CONFIG_DIR gets its own runtime dir (one per account)', async ($, on) => {
  const files = engine(on, { HOME: '/home/u', CLAUDE_CONFIG_DIR: '/home/u/.claude-alt/' })
  await measure($, [{ kind: 'five_hour', percentUsed: 1, resetsAt: iso(60) }])
  expect(files['/home/u/.claude-alt/usage-aware/state.json']).toBeDefined()
  expect(files['/home/u/.claude/usage-aware/state.json']).toBe(undefined)
})

test('CLAUDE_CONFIG_DIR set to the default dir keeps ~/.claude/usage-aware', async ($, on) => {
  const files = engine(on, { HOME: '/home/u', CLAUDE_CONFIG_DIR: '/home/u/.claude' })
  await measure($, [{ kind: 'five_hour', percentUsed: 1, resetsAt: iso(60) }])
  expect(files['/home/u/.claude/usage-aware/state.json']).toBeDefined()
})

test('context is written per session, beside the shared state', async ($, on) => {
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' })
  await measure($, lims(10, 2), 0, 85000)
  expect(JSON.parse(files['/ua/contexts/sess-A.json'])).toEqual({ context_tokens: 85000, at: NOW / 1000 })
  expect(state(files).session_id).toBe('sess-A')
  await measure($, [], 0, 90000) // no rate limits yet: context still recorded
  expect(JSON.parse(files['/ua/contexts/sess-A.json']).context_tokens).toBe(90000)
})

test('bars above the prompt show what is left, on every surface', async ($, on) => {
  engine(on, { USAGE_AWARE_DIR: '/ua' })
  await start($)
  await measure($, [{ kind: 'five_hour', percentUsed: 66, resetsAt: iso(6600) }])
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'usage-aware', surface, component: 'AbovePrompt', props: {} as any })
    const t = await ui.find({ type: 'Text', text: /5h/ })
    expect(t?.text).toContain('34% left')
    await ui.unmount()
  }
})

test('/usage-color sets and resets the bar color', async ($, on) => {
  engine(on, { USAGE_AWARE_DIR: '/ua' })
  await start($)
  expect((await $.command.run({ command: 'usage-color', args: '#ff8800' } as any)).text).toContain('#ff8800')
  expect((await $.command.run({ command: 'usage-color', args: 'nope' } as any)).text).toContain('Not a hex color')
  expect((await $.command.run({ command: 'usage-color', args: 'reset' } as any)).text).toContain('reset')
})

test('a refused /usage-color (name taken) does not stop the rest of session.start', async ($, on) => {
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' }, [{ kind: 'five_hour', percentUsed: 40, resetsAt: iso(600) }], true)
  await start($)
  expect(files['/ua/mod.json']).toBeDefined()
  const ui = await $.ui.mount({ plugin: 'usage-aware', surface: 'terminal', component: 'AbovePrompt', props: {} as any })
  expect((await ui.find({ type: 'Text', text: /5h/ }))?.text).toContain('60% left')
  await ui.unmount()
})

// ---- token estimate --------------------------------------------------------

test('learns tokens per 1% from cost per point moved and tokens per dollar', async ($, on) => {
  const store: Record<string, unknown> = {}
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' }, [], false, store)
  await measure($, lims(10, 2), 0)
  expect(state(files).five_hour.tokens_per_pct).toBe(undefined)
  await turn($, 600000)
  await turn($, 400000, 'agent-1') // subagent turns count too
  await measure($, lims(12, 3), 1.0, 85000)
  const s = state(files)
  expect(s.five_hour).toEqual({
    used_percentage: 12,
    resets_at: NOW / 1000 + 6600,
    usd_per_pct: 0.5,
    tokens_per_pct: 500000,
    samples: 1,
    recent: [
      [NOW / 1000, 10],
      [NOW / 1000, 12],
    ],
  })
  expect(s.seven_day.tokens_per_pct).toBe(1000000)
  expect(s.context_tokens).toBe(85000)
  expect([s.session_tokens, s.session_usd]).toEqual([1000000, 1.0])
  expect((store.cal as any).tokPerUsd).toBe(1000000)
  const ui = await $.ui.mount({ plugin: 'usage-aware', surface: 'terminal', component: 'AbovePrompt', props: {} as any })
  expect((await ui.find({ type: 'Text', text: /5h/ }))?.text).toContain('88% left (~44M)')
  await ui.unmount()
})

test('less than a whole point moved: no sample yet', async ($, on) => {
  const store: Record<string, unknown> = {}
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' }, [], false, store)
  await measure($, lims(10, 2), 0)
  await turn($, 100000)
  await measure($, lims(10.9, 2.5), 0.3)
  expect(state(files).five_hour.tokens_per_pct).toBe(undefined)
  expect((store.cal as any).usdPerPct).toEqual({})
  await measure($, lims(11, 2.5), 0.6) // now 1.0 point since the anchor
  expect(Math.abs((store.cal as any).usdPerPct.five_hour.v - (0.6)) < 1e-9).toBe(true)
})

test('a window reset re-anchors instead of sampling', async ($, on) => {
  const store: Record<string, unknown> = {}
  engine(on, { USAGE_AWARE_DIR: '/ua' }, [], false, store)
  await measure($, lims(90, 2), 0)
  await turn($, 100000)
  await measure($, lims(1, 2), 0.2) // 5h reset
  await measure($, lims(3, 2), 1.2) // 2 points for $1.0
  expect(Math.abs((store.cal as any).usdPerPct.five_hour.v - (0.5)) < 1e-9).toBe(true)
})

test('calibration persists across sessions and is smoothed, with outliers clamped', async ($, on) => {
  const store: Record<string, unknown> = {
    cal: { usdPerPct: { five_hour: { v: 1, n: 5 }, seven_day: { v: 4, n: 5 } }, tokPerUsd: 200000 },
  }
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' }, [], false, store)
  await measure($, lims(10, 2), 0)
  expect(state(files).five_hour.tokens_per_pct).toBe(200000) // from the store, before any sample
  await measure($, lims(20, 2), 0.1) // $0.01/pt, e.g. another session burning: clamped to v/3
  expect(Math.abs((store.cal as any).usdPerPct.five_hour.v - (0.7 + 0.3 / 3)) < 1e-9).toBe(true)
  expect((store.cal as any).usdPerPct.five_hour.n).toBe(6)
})

test('no cost figure: no estimate, state still written', async ($, on) => {
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' })
  await measure($, lims(10, 2))
  await turn($, 100000)
  await measure($, lims(20, 4))
  expect(state(files).five_hour).toEqual({
    used_percentage: 20,
    resets_at: NOW / 1000 + 6600,
    recent: [
      [NOW / 1000, 10],
      [NOW / 1000, 20],
    ],
  })
  expect(state(files).session_usd).toBe(undefined)
})

test('cost is pooled across sessions on this machine', async ($, on) => {
  const store: Record<string, unknown> = {}
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' }, [], false, store)
  const other = (usd: number, at = NOW / 1000) => (files['/ua/sessions/sess-B.json'] = JSON.stringify({ usd, at }))
  other(5)
  files['/ua/sessions/old.json'] = JSON.stringify({ usd: 100, at: NOW / 1000 - 8 * 86400 }) // over a week: ignored
  files['/ua/sessions/garbage.json'] = '{half'
  await measure($, lims(10, 2), 0)
  expect(JSON.parse(files['/ua/sessions/sess-A.json'])).toEqual({ usd: 0, at: NOW / 1000 })
  other(6.5) // the other session spent $1.50 meanwhile
  await turn($, 100000)
  await measure($, lims(14, 2), 0.5) // 4 points for $2.00 across both sessions
  expect((store.cal as any).usdPerPct.five_hour).toEqual({ v: 0.5, n: 1 })
})

test('calibration written by another session is picked up', async ($, on) => {
  const store: Record<string, unknown> = {}
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' }, [], false, store)
  await measure($, lims(10, 2), 0)
  store.cal = { usdPerPct: { five_hour: { v: 2, n: 4 } }, tokPerUsd: 1000 }
  await measure($, lims(10.5, 2), 0.1)
  expect(state(files).five_hour.tokens_per_pct).toBe(2000)
})

test('tokens per dollar is blended into the saved figure, not replaced', async ($, on) => {
  const store: Record<string, unknown> = { cal: { usdPerPct: {}, tokPerUsd: 200000 } }
  engine(on, { USAGE_AWARE_DIR: '/ua' }, [], false, store)
  await measure($, lims(10, 2), 0)
  await turn($, 1000000)
  await measure($, lims(10, 2), 1.0) // this session: 1M tokens per dollar
  expect((store.cal as any).tokPerUsd).toBe(0.7 * 200000 + 0.3 * 1000000)
  await turn($, 1000000)
  await measure($, lims(10, 2), 2.0) // still blended against the figure the session started with
  expect((store.cal as any).tokPerUsd).toBe(0.7 * 200000 + 0.3 * 1000000)
})

// ---- cost per step -----------------------------------------------------------

const ctxFile = (files: Record<string, string>, id = 'sess-A') => JSON.parse(files[`/ua/contexts/${id}.json`])

test('cost per main-loop step, with subagent spend charged to it', async ($, on) => {
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' })
  await measure($, lims(10, 2), 0, 50000)
  expect(ctxFile(files).usd_per_step).toBe(undefined)
  await turn($, 1000)
  await turn($, 1000)
  await turn($, 1000, 'agent-1') // a subagent's call is not a step, but its cost counts
  await measure($, lims(10, 2), 0.2, 60000)
  expect(ctxFile(files).usd_per_step).toBe(undefined) // only 2 main steps: no sample yet
  await turn($, 1000)
  await measure($, lims(10, 2), 0.9, 70000)
  expect(ctxFile(files)).toEqual({ context_tokens: 70000, usd_per_step: 0.3, at: NOW / 1000 })
  expect(state(files).usd_per_step).toBe(0.3)
  for (let i = 0; i < 3; i++) await turn($, 1000)
  await measure($, lims(10, 2), 2.1, 80000) // $0.40/step: smoothed
  expect(Math.abs(ctxFile(files).usd_per_step - (0.7 * 0.3 + 0.3 * 0.4)) < 1e-9).toBe(true)
})

test('cost per step starts over for a new session id (after /clear)', async ($, on) => {
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' })
  await measure($, lims(10, 2), 0)
  for (let i = 0; i < 3; i++) await turn($, 1000)
  await measure($, lims(10, 2), 0.9)
  expect(ctxFile(files).usd_per_step).toBe(0.3)
  sessionId = 'sess-B'
  for (let i = 0; i < 3; i++) await turn($, 1000)
  await measure($, lims(10, 2), 1.2, 1000)
  expect(ctxFile(files, 'sess-B')).toEqual({ context_tokens: 1000, at: NOW / 1000 }) // re-based, no sample yet
  for (let i = 0; i < 3; i++) await turn($, 1000)
  await measure($, lims(10, 2), 1.5, 2000)
  expect(Math.abs(ctxFile(files, 'sess-B').usd_per_step - 0.1) < 1e-9).toBe(true)
})

// ---- recent history ------------------------------------------------------------

test('recent history: kept two hours, unchanged readings thinned, cleared on reset', async ($, on) => {
  const store: Record<string, unknown> = {}
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' }, [], false, store)
  const t0 = NOW / 1000
  const at = async (secs: number, h: number) => {
    clock = NOW + secs * 1000
    await measure($, [{ kind: 'five_hour', percentUsed: h, resetsAt: iso(6600) }])
    return state(files).five_hour.recent
  }
  await at(0, 10)
  expect(await at(60, 10)).toEqual([[t0, 10]]) // unchanged within 5 minutes: not recorded
  expect(await at(400, 10)).toEqual([[t0, 10], [t0 + 400, 10]])
  expect(await at(500, 12)).toEqual([[t0, 10], [t0 + 400, 10], [t0 + 500, 12]])
  expect(await at(7700, 12)).toEqual([[t0 + 500, 12], [t0 + 7700, 12]]) // over two hours old: dropped
  expect((store.hist as any).five_hour.pts).toEqual([[t0 + 500, 12], [t0 + 7700, 12]]) // shared via the store
  expect(await at(7800, 1)).toEqual([[t0 + 7800, 1]]) // the window reset
})

test('recent history written by another session is extended', async ($, on) => {
  const t0 = NOW / 1000
  const store: Record<string, unknown> = { hist: { five_hour: { resetsAt: iso(6600), pts: [[t0 - 3600, 40]] } } }
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' }, [], false, store)
  await measure($, [{ kind: 'five_hour', percentUsed: 66, resetsAt: iso(6600) }])
  expect(state(files).five_hour.recent).toEqual([[t0 - 3600, 40], [t0, 66]])
})

test("another session's slightly older reading leaves the shared history alone", async ($, on) => {
  const t0 = NOW / 1000
  const pts = [
    [t0 - 3600, 30],
    [t0 - 60, 40.1],
  ]
  const store: Record<string, unknown> = { hist: { five_hour: { resetsAt: iso(6600), pts } } }
  const files = engine(on, { USAGE_AWARE_DIR: '/ua' }, [], false, store)
  await measure($, [{ kind: 'five_hour', percentUsed: 40, resetsAt: iso(6600) }]) // this session's last reading
  expect((store.hist as any).five_hour.pts).toEqual(pts)
  expect(state(files).five_hour.recent).toEqual(pts) // still handed to usage-status
})

test('a reading timed before the last stored point is skipped', async ($, on) => {
  const t0 = NOW / 1000
  const pts = [[t0 + 30, 40]]
  const store: Record<string, unknown> = { hist: { five_hour: { resetsAt: iso(6600), pts } } }
  engine(on, { USAGE_AWARE_DIR: '/ua' }, [], false, store)
  await measure($, [{ kind: 'five_hour', percentUsed: 41, resetsAt: iso(6600) }])
  expect((store.hist as any).five_hour.pts).toEqual(pts)
})

test('a reading from the previous window (session idle across a reset) is ignored', async ($, on) => {
  const t0 = NOW / 1000
  const pts = [[t0 - 600, 2]] // the new window, stored by another session
  const store: Record<string, unknown> = { hist: { five_hour: { resetsAt: iso(18000), pts } } }
  engine(on, { USAGE_AWARE_DIR: '/ua' }, [], false, store)
  await measure($, [{ kind: 'five_hour', percentUsed: 1, resetsAt: iso(60) }]) // old window's end: earlier
  expect((store.hist as any).five_hour).toEqual({ resetsAt: iso(18000), pts })
})

test('a later window end is a reset, even if the % barely moved', async ($, on) => {
  const t0 = NOW / 1000
  const store: Record<string, unknown> = { hist: { five_hour: { resetsAt: iso(60), pts: [[t0 - 600, 3]] } } }
  engine(on, { USAGE_AWARE_DIR: '/ua' }, [], false, store)
  await measure($, [{ kind: 'five_hour', percentUsed: 1, resetsAt: iso(18060) }])
  expect((store.hist as any).five_hour).toEqual({ resetsAt: iso(18060), pts: [[t0, 1]] })
})
