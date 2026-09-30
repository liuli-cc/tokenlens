import { mkdir, rename, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

// Cordis plugin for DeepSeek Harness. Only the whitelisted status below is
// written; credentials, account IDs and conversation text never leave Harness.
export const name = 'tokenlens-dsh-status'
export const inject = ['deepseekAccount', 'sessionProjections']
const directory = process.env.TOKENLENS_DATA_DIR || (process.platform === 'win32'
  ? join(process.env.APPDATA || join(homedir(), 'AppData', 'Roaming'), 'TokenLens')
  : join(homedir(), 'Library', 'Application Support', 'TokenLens'))
const outputFile = join(directory, 'deepseek-status.json')
const displayNames = {
  'deepseek-flash': 'DeepSeek-V41-Flash', 'deepseek-v41-flash': 'DeepSeek-V41-Flash',
  'deepseek-chat': 'DeepSeek-V3', 'deepseek-reasoner': 'DeepSeek-R1',
}

export function apply(ctx) {
  let disposed = false, balanceInFlight = false, writeQueue = Promise.resolve()
  const status = { schemaVersion: 1, accountStatus: 'unknown', balanceStatus: 'unavailable',
    balance: [], bonusWallets: [], provider: null, model: null, modelLabel: null,
    reasoningEffort: null, workspacePath: null, modelUpdatedAt: null, balanceUpdatedAt: null, balanceFetchedAt: null, balanceAttemptedAt: null }
  const client = { version: process.env.DSH_CLIENT_VERSION || '0.2.0-rc.2', locale: 'zh-CN',
    timezoneOffsetSeconds: -new Date().getTimezoneOffset() * 60 }
  function select(value) {
    if (typeof value?.model !== 'string' || typeof value?.provider !== 'string') return
    status.provider = value.provider; status.model = value.model
    status.modelLabel = displayNames[value.model] || value.model
    status.reasoningEffort = typeof value.reasoningEffort === 'string' ? value.reasoningEffort : null
    status.modelUpdatedAt = new Date().toISOString()
  }
  function persist() {
    if (disposed) return Promise.resolve()
    const snapshot = JSON.stringify(status)
    writeQueue = writeQueue.catch(() => {}).then(async () => {
      if (disposed) return
      await mkdir(dirname(outputFile), { recursive: true, mode: 0o700 })
      const temporary = outputFile + '.' + process.pid + '.tmp'
      await writeFile(temporary, snapshot, { encoding: 'utf8', mode: 0o600 })
      await rename(temporary, outputFile)
    })
    return writeQueue.catch(() => {})
  }
  const wallets = values => (Array.isArray(values) ? values : []).filter(w =>
    typeof w?.currency === 'string' && (typeof w.balance === 'string' || typeof w.balance === 'number'))
    .map(w => ({ currency: w.currency, balance: String(w.balance) }))
  async function refresh() {
    if (disposed || balanceInFlight) return
    balanceInFlight = true
    try {
      const account = await ctx.deepseekAccount.getState()
      status.accountStatus = account.status
      if (account.status === 'signed-out') {
        status.balanceStatus = 'signed-out'; status.balance = []; status.bonusWallets = []
      } else {
        const result = await ctx.deepseekAccount.getBalance(client)
        status.balanceStatus = result?.status === 'ready' ? 'ready' : 'failed'
        if (result?.status === 'ready') {
          status.balance = wallets(result.value); status.bonusWallets = wallets(result.bonusWallets)
          status.balanceFetchedAt = new Date().toISOString()
        }
      }
    } catch { status.balanceStatus = 'failed' }
    finally { status.balanceAttemptedAt = new Date().toISOString(); status.balanceUpdatedAt = status.balanceFetchedAt; balanceInFlight = false; await persist() }
  }
  ctx.on('session/event', (session, event) => {
    // A delegated subtask must not replace the user's selected model.
    if (session?.header?.delegationDepth > 0) return
    if (typeof session?.header?.cwd === 'string') status.workspacePath = session.header.cwd
    if (event?.type === 'model/selection') select(event.data)
    else if (event?.type === 'request/header') select(event.data?.header?.config)
    else if (event?.type === 'assistant/message') select(event.data?.message)
    else if (event?.type === 'user/message') {
      const projection = ctx.sessionProjections.stateOf(session, 'modelSelection')
      select(projection?.pending || projection?.lastUsed)
    }
    void persist()
  })
  ctx.effect(() => {
    void refresh()
    const timer = setInterval(() => { void refresh() }, 60_000)
    return () => { disposed = true; clearInterval(timer) }
  })
}
