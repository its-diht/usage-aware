export type PerPct = Record<string, number>
// What the bars need for steps left per window: dollars per 1% (per window kind), and this
// session's dollars per step and context (null until known).
export type StepBasis = { usdPerPct: PerPct; usdPerStep: number | null; context: number | null }
export type Limits = { kind: string; percentUsed: number; resetsAt?: string }[]

declare module 'claude-code' {
  interface PluginState {
    'usage-aware': { limits: Limits; color: string | null; perPct: PerPct; stepBasis: StepBasis }
  }
}
