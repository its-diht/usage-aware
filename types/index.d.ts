export type PerPct = Record<string, number>
export type Limits = { kind: string; percentUsed: number; resetsAt?: string }[]

declare module 'claude-code' {
  interface PluginState {
    'usage-aware': { limits: Limits; color: string | null; perPct: PerPct }
  }
}
