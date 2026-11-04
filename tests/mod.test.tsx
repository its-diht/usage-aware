import { expect, test } from 'claude-code/testing'

// The engine beneath the plugin: env, clock, files, store and commands are answered here.
const NOW = Date.parse('2030-01-01T00:00:00Z')
const iso = (secs: number) => new Date(NOW + secs * 1000).toISOString()

function engine(
  on: any,
  env: Record<string, string | undefined>,
  usage: any[] = [],
  refuseCommands = false,
  store: Record<string, unknown> = {},
) {
  const files: Record<string, string> = {}
  on('env.get', (_: any, e: { name: string }) => ({ value: env[e.name] }))
  on('clock.now', () => ({ value: NOW }))
  on('fs.write', (_: any, e: { path: string; text: string }) => ((files[e.path] = e.text), { value: undefined }))
  on('store.get', (_: any, e: { key: string }) => ({ value: store[e.key] }))
  on('store.set', (_: any, e: { key: string; value: unknown }) => ((store[e.key] = e.value), { value: undefined }))
  on('store.delete', (_: any, e: { key: string }) => (delete store[e.key], { value: undefined }))
  on('turn.complete', (_: any, e: any) => ({ text: e.answer, usage: e.usage }))
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
const turn = ($: any, total: number, agentId?: string) =>
  $.turn.complete({
    turnId: 't',
    agentId,
    answer: '',
    durationMs: 1,
    isAborted: false,
    reason: 'answer',
    usage: { model: 'm', input_tokens: total / 2, output_tokens: total / 4, cache_read_input_tokens: total / 4, cache_creation_input_tokens: 0 },
  })
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
    five_hour: { used_percentage: 66, resets_at: NOW / 1000 + 6600 },
    seven_day: { used_percentage: 29.5, resets_at: NOW / 1000 + 356400 },
    spend_limit: { used_percentage: 12, resets_at: null },
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
  expect(s.five_hour).toEqual({ used_percentage: 12, resets_at: NOW / 1000 + 6600, tokens_per_pct: 500000, samples: 1 })
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
  expect(state(files).five_hour).toEqual({ used_percentage: 20, resets_at: NOW / 1000 + 6600 })
  expect(state(files).session_usd).toBe(undefined)
})
