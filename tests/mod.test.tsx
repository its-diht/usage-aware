import { expect, test } from 'claude-code/testing'

// The engine beneath the plugin: env, clock, files, store and commands are answered here.
const NOW = Date.parse('2030-01-01T00:00:00Z')
const iso = (secs: number) => new Date(NOW + secs * 1000).toISOString()

function engine(on: any, env: Record<string, string | undefined>, usage: any[] = [], refuseCommands = false) {
  const files: Record<string, string> = {}
  on('env.get', (_: any, e: { name: string }) => ({ value: env[e.name] }))
  on('clock.now', () => ({ value: NOW }))
  on('fs.write', (_: any, e: { path: string; text: string }) => ((files[e.path] = e.text), { value: undefined }))
  on('store.get', () => ({ value: undefined }))
  on('store.set', () => ({ value: undefined }))
  on('store.delete', () => ({ value: undefined }))
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
const measure = ($: any, rateLimits: any[]) => $.session.measure({ context: {}, rateLimits, changed: ['rateLimits'] })

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
