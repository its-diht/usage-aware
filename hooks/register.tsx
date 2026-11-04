// usage-aware mod: feeds state.json from the engine's own rate-limit readings,
// and draws remaining-usage bars above the prompt (folded in from usage-left).
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Limits, PerPct } from '../types'

const limits = atom({ plugin: 'usage-aware', key: 'limits' } as const, [] as Limits)
const color = atom({ plugin: 'usage-aware', key: 'color' } as const, null)
// Estimated tokens per 1% of each window, once calibrated.
const perPct = atom({ plugin: 'usage-aware', key: 'perPct' } as const, {} as PerPct)

// ---- data source ---------------------------------------------------------

type Window = { used_percentage: number; resets_at: number | null; tokens_per_pct?: number; samples?: number } | null

const toWindow = (all: Limits, kind: string, cal?: Cal): Window => {
  const l = all.find(x => x.kind === kind)
  if (!l) return null
  const t = l.resetsAt ? Date.parse(l.resetsAt) : NaN
  const w: Window = { used_percentage: l.percentUsed, resets_at: Number.isFinite(t) ? Math.floor(t / 1000) : null }
  const tpp = cal && tokensPerPct(cal, kind)
  if (tpp) Object.assign(w, { tokens_per_pct: tpp, samples: cal!.usdPerPct[kind].n })
  return w
}

// ---- token estimate --------------------------------------------------------
// No API reports a token allowance, only % used. So learn it: the session's
// cost (price-weighted, subagents included) per 1% a window moves, smoothed
// and kept across sessions; then dollars -> tokens at the observed tokens/$.

type Cal = { usdPerPct: Record<string, { v: number; n: number }>; tokPerUsd: number | null }
const CAL_KINDS = ['five_hour', 'seven_day']
const MIN_DP = 1 // % points per sample; percentUsed has one decimal, so ~10% sample error
const MIN_USD = 0.25 // session spend before its tokens/$ replaces the saved one
const ALPHA = 0.3 // weight of a new sample
const BAND = 3 // after 3 samples, a sample is clamped to [v/BAND, v*BAND]

const tokensPerPct = (cal: Cal, kind: string) => {
  const u = cal.usdPerPct[kind]
  return u && cal.tokPerUsd ? Math.round(u.v * cal.tokPerUsd) : undefined
}

const fmtTok = (n: number) =>
  n >= 1e6 ? `${(n / 1e6).toFixed(n >= 1e7 ? 0 : 1)}M` : n >= 1e3 ? `${Math.round(n / 1e3)}k` : `${Math.round(n)}`

type Anchor = { usd: number; pct: number; resetsAt?: string }
// One calibration step for one window; returns whether `cal` changed.
function calibrate(cal: Cal, anchors: Record<string, Anchor>, kind: string, l: Limits[number], usd: number) {
  const a = anchors[kind]
  const resetMoved = a && a.resetsAt && l.resetsAt && Math.abs(Date.parse(a.resetsAt) - Date.parse(l.resetsAt)) > 3600e3
  if (!a || l.percentUsed < a.pct || resetMoved || usd < a.usd) {
    anchors[kind] = { usd, pct: l.percentUsed, resetsAt: l.resetsAt }
    return false
  }
  const dp = l.percentUsed - a.pct
  if (dp < MIN_DP) return false
  anchors[kind] = { usd, pct: l.percentUsed, resetsAt: l.resetsAt }
  const du = usd - a.usd
  if (du <= 0) return false // moved by another session alone: nothing to learn
  let sample = du / dp
  const cur = cal.usdPerPct[kind]
  if (!cur) {
    cal.usdPerPct[kind] = { v: sample, n: 1 }
    return true
  }
  if (cur.n >= 3) sample = Math.min(cur.v * BAND, Math.max(cur.v / BAND, sample))
  cal.usdPerPct[kind] = { v: cur.v * (1 - ALPHA) + sample * ALPHA, n: cur.n + 1 }
  return true
}

const sumUsage = (u: any) =>
  u ? (u.input_tokens ?? 0) + (u.output_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0) : 0

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

const describe = (all: Limits, now: number, est: PerPct = {}) =>
  all.length === 0
    ? 'usage left: waiting for first reply'
    : all
        .map(l => {
          const left = Math.min(100, Math.max(0, 100 - l.percentUsed))
          const tok = est[l.kind] ? ` (~${fmtTok(left * est[l.kind])})` : ''
          return `${LABELS[l.kind] ?? l.kind} ${bar(left)} ${left.toFixed(0)}% left${tok}${resetIn(l.resetsAt, now)}`
        })
        .join('   ')

// ---- hooks ---------------------------------------------------------------

// Per-process estimator state.
type Session = {
  cal: Cal | null
  anchors: Record<string, Anchor>
  tokens: number // this process's tokens, from every model response (main and subagents)
  ratioBase: { tok: number; usd: number } | null
}

async function loadCal($: EngineInterface, st: Session): Promise<Cal> {
  if (st.cal) return st.cal
  const saved = (await $.store.get('cal')) as Cal | undefined
  st.cal = saved && typeof saved === 'object' && saved.usdPerPct ? saved : { usdPerPct: {}, tokPerUsd: null }
  return st.cal
}

async function publishEst($: EngineInterface, c: Cal) {
  const est: PerPct = {}
  for (const k of CAL_KINDS) {
    const t = tokensPerPct(c, k)
    if (t) est[k] = t
  }
  await update($, perPct, () => est)
}

export const register: Register = on => {
  const st: Session = { cal: null, anchors: {}, tokens: 0, ratioBase: null }

  // Count every model response as it lands (main loop and subagents), so a
  // turn's tokens are in before the measurement that follows it.
  on('turn.step', async function* ($, e, next) {
    const r = yield* next(e)
    try {
      st.tokens += sumUsage(r?.usage)
    } catch {}
    return r
  })

  on('session.start', async ($, e, next) => {
    const r = await next(e)
    await heartbeat($, await runtimeDir($), Math.floor((await $.clock.now()) / 1000))
    try {
      await $.command.register({
        name: 'usage-color',
        description: 'Set the usage bar color: /usage-color #ff8800, or /usage-color reset',
        argumentHint: '<hex> | reset',
      })
    } catch {
      // Name taken (e.g. the standalone usage-left mod is still loaded): keep going without it.
    }
    const saved = await $.store.get('color')
    await update($, color, () => (typeof saved === 'string' ? saved : null))
    // Display only: these figures may predate this session, so they are not persisted.
    const usage = await $.session.usage()
    await update($, limits, () => usage.rateLimits)
    await publishEst($, await loadCal($, st))
    return r
  })

  on('session.measure', async ($, e, next) => {
    await update($, limits, () => e.rateLimits)
    const dir = await runtimeDir($)
    const now = Math.floor((await $.clock.now()) / 1000)
    const c = await loadCal($, st)
    const usd = e.cost?.usd
    if (typeof usd === 'number') {
      let changed = false
      for (const kind of CAL_KINDS) {
        const l = e.rateLimits.find(x => x.kind === kind)
        if (l && calibrate(c, st.anchors, kind, l, usd)) changed = true
      }
      if (!st.ratioBase || usd < st.ratioBase.usd) st.ratioBase = { tok: st.tokens, usd }
      const du = usd - st.ratioBase.usd
      const dt = st.tokens - st.ratioBase.tok
      if (du >= MIN_USD && dt > 0) {
        c.tokPerUsd = dt / du
        changed = true
      }
      if (changed) {
        await $.store.set('cal', c)
        await publishEst($, c)
      }
    }
    if (e.rateLimits.length > 0) {
      const state: Record<string, unknown> = {
        updated_at: now,
        source: 'mod',
        five_hour: toWindow(e.rateLimits, 'five_hour', c),
        seven_day: toWindow(e.rateLimits, 'seven_day', c),
        spend_limit: toWindow(e.rateLimits, 'spend_limit'),
      }
      if (typeof e.context?.tokens === 'number') state.context_tokens = e.context.tokens
      // Diagnostics: this process's counted tokens and the session's cost.
      state.session_tokens = st.tokens
      if (typeof usd === 'number') state.session_usd = usd
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
    const text = describe(await read($, limits), await $.clock.now(), await read($, perPct))
    return <Box>{c ? <Text color={c}>{text}</Text> : <Text dimColor>{text}</Text>}</Box>
  })
}
