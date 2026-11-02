// usage-aware mod: feeds state.json from the engine's own rate-limit readings,
// and draws remaining-usage bars above the prompt (folded in from usage-left).
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Limits } from '../types'

const limits = atom({ plugin: 'usage-aware', key: 'limits' } as const, [] as Limits)
const color = atom({ plugin: 'usage-aware', key: 'color' } as const, null)

// ---- data source ---------------------------------------------------------

type Window = { used_percentage: number; resets_at: number | null } | null

const toWindow = (all: Limits, kind: string): Window => {
  const l = all.find(x => x.kind === kind)
  if (!l) return null
  const t = l.resetsAt ? Date.parse(l.resetsAt) : NaN
  return { used_percentage: l.percentUsed, resets_at: Number.isFinite(t) ? Math.floor(t / 1000) : null }
}

const runtimeDir = async ($: EngineInterface): Promise<string> =>
  (await $.env.get('USAGE_AWARE_DIR')) || `${await $.env.get('HOME')}/.claude/usage-aware`

const heartbeat = async ($: EngineInterface, dir: string, nowSecs: number) =>
  $.fs.write(`${dir}/mod.json`, JSON.stringify({ heartbeat: nowSecs }) + '\n')

// ---- bars ----------------------------------------------------------------

const LABELS: Record<string, string> = { five_hour: '5h', seven_day: 'week', spend_limit: 'spend' }
const WIDTH = 10
const HEX = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i

const bar = (left: number) => {
  const filled = Math.round((left / 100) * WIDTH)
  return '█'.repeat(filled) + '░'.repeat(WIDTH - filled)
}

const resetIn = (iso: string | undefined, now: number) => {
  if (!iso) return ''
  const mins = Math.max(0, Math.round((Date.parse(iso) - now) / 60000))
  if (mins >= 1440) return ` ↻${Math.floor(mins / 1440)}d${Math.floor((mins % 1440) / 60)}h`
  if (mins >= 60) return ` ↻${Math.floor(mins / 60)}h${mins % 60}m`
  return ` ↻${mins}m`
}

const describe = (all: Limits, now: number) =>
  all.length === 0
    ? 'usage left: waiting for first reply'
    : all
        .map(l => {
          const left = Math.min(100, Math.max(0, 100 - l.percentUsed))
          return `${LABELS[l.kind] ?? l.kind} ${bar(left)} ${left.toFixed(0)}% left${resetIn(l.resetsAt, now)}`
        })
        .join('   ')

// ---- hooks ---------------------------------------------------------------

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const r = await next(e)
    await $.command.register({
      name: 'usage-color',
      description: 'Set the usage bar color: /usage-color #ff8800, or /usage-color reset',
      argumentHint: '<hex> | reset',
    })
    const saved = await $.store.get('color')
    await update($, color, () => (typeof saved === 'string' ? saved : null))
    // Display only: these figures may predate this session, so they are not persisted.
    const usage = await $.session.usage()
    await update($, limits, () => usage.rateLimits)
    await heartbeat($, await runtimeDir($), Math.floor((await $.clock.now()) / 1000))
    return r
  })

  on('session.measure', async ($, e, next) => {
    await update($, limits, () => e.rateLimits)
    const dir = await runtimeDir($)
    const now = Math.floor((await $.clock.now()) / 1000)
    if (e.rateLimits.length > 0) {
      const state = {
        updated_at: now,
        source: 'mod',
        five_hour: toWindow(e.rateLimits, 'five_hour'),
        seven_day: toWindow(e.rateLimits, 'seven_day'),
        spend_limit: toWindow(e.rateLimits, 'spend_limit'),
      }
      await $.fs.write(`${dir}/state.json`, JSON.stringify(state) + '\n')
    }
    await heartbeat($, dir, now)
    return next(e)
  })

  on('command.run', { command: 'usage-color' }, async ($, e) => {
    const arg = e.args.trim()
    if (arg === 'reset' || arg === '') {
      await $.store.delete('color')
      await update($, color, () => null)
      return { text: 'Usage bar color reset to default.' }
    }
    if (!HEX.test(arg)) return { text: `Not a hex color: ${arg}. Try /usage-color #ff8800` }
    const hex = arg.startsWith('#') ? arg : `#${arg}`
    await $.store.set('color', hex)
    await update($, color, () => hex)
    return { text: `Usage bar color set to ${hex}.` }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const c = await read($, color)
    const text = describe(await read($, limits), await $.clock.now())
    return <Box>{c ? <Text color={c}>{text}</Text> : <Text dimColor>{text}</Text>}</Box>
  })
}
