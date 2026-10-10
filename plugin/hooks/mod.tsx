// Cache Clock mod: an optional layer over the sh hooks, for Claude Code 2.1.287+ (the terminal and
// the Desktop app's Code tab). Everything else works without it.
//   - Keep-alive by fork: waiter.sh asks for a ping by writing pings/<sid>.fork. The mod copies it
//     to pings/<sid>.ack and runs $.model.fork: one tool-less completion over the main transcript.
//     It reads the cache, which resets the TTL, without a turn: nothing lands in the conversation
//     and Claude isn't woken. With no ack in 6s the waiter wakes Claude as before.
//   - A band above the prompt in the last minutes before expiry: a live countdown and Keep warm.
// State stays in the sh core's session file. This module writes it through `sh cc.sh mod ...`.
import type { Register, EngineInterface } from 'claude-code'

const PROMPT = '[cache-clock] Keep-alive ping. Reply with exactly: ok'

type Session = { status?: string; expires_at?: number | null; ttl_s?: number }

let dir = ''        // the data folder, from cc.sh
let version = ''
let sid = ''
let session: Session = {}
let band = true
let polling = false
let forking = false
let ticks = 0
let shown = false

const safeId = (id: string) => id.replace(/[^A-Za-z0-9_-]/g, '_')

function cc($: EngineInterface, args: string[]) {
  return $.process.run(['sh', `${$.plugin.root}/scripts/cc.sh`, ...args], { timeoutMs: 15000 })
}

// Seconds until the cache expires; null when unknown.
async function secondsLeft($: EngineInterface): Promise<number | null> {
  const at = session.expires_at
  if (typeof at !== 'number') return null
  return at - Math.floor((await $.clock.now()) / 1000)
}

function warnAt(): number {
  return (session.ttl_s ?? 3600) <= 300 ? 120 : 900
}

async function readJson<T>($: EngineInterface, path: string): Promise<T | undefined> {
  try {
    return JSON.parse(await $.fs.read(path)) as T
  } catch {
    return undefined
  }
}

// One fork ping. A warm fork mostly reads; mostly writing means the cache was already cold.
async function forkPing($: EngineInterface, isManual: boolean) {
  if (forking) return
  forking = true
  $.ui.invalidate('ui.render')
  try {
    const r = await $.model.fork({ prompt: PROMPT })
    const u = 'usage' in r && r.usage ? r.usage : undefined
    const read = u ? u.cache_read_input_tokens : 0
    const write = u ? u.cache_creation_input_tokens : 0
    const isOk = r.isAnswered && read > write
    await cc($, ['mod', 'forked', sid, isOk ? 'ok' : 'fail', String(read), String(write)])
    if (!isOk) {
      const why = r.isAnswered ? 'the cache was already cold' : r.reason
      $.ui.toast(`Cache Clock: the keep-alive fork failed (${why}). The next ping wakes Claude instead.`)
    } else if (isManual) {
      $.ui.toast(`Cache Clock: cache kept warm (${Math.round(read / 1000)}k tokens read).`)
    }
  } finally {
    forking = false
    $.ui.invalidate('ui.render')
  }
}

async function poll($: EngineInterface) {
  const id = await $.session.id()
  if (id !== sid) {
    sid = id
    await cc($, ['mod', 'hello', sid, version])
  }
  const safe = safeId(sid)
  session = (await readJson<Session>($, `${dir}/sessions/${safe}.json`)) ?? {}
  if (ticks++ % 10 === 0) {
    const cfg = await readJson<{ band?: boolean }>($, `${dir}/config.json`)
    band = cfg?.band !== false
  }

  const req = `${dir}/pings/${safe}.fork`
  if (!forking && (await $.fs.exists(req))) {
    const text = (await $.fs.read(req)).trim()
    await $.fs.write(`${dir}/pings/${safe}.ack`, `${text}\n`)
    void forkPing($, text.endsWith('manual'))
  }

  // Redraw every second while the band shows, and once when it should appear or go.
  const left = await secondsLeft($)
  const shouldShow = band && session.status !== 'working' && left !== null && left > 0 && left <= warnAt()
  if (shouldShow || shown) $.ui.invalidate('ui.render')
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const res = await next(e)
    try {
      const r = await cc($, ['datadir'])
      dir = r.exitCode === 0 ? r.stdout.trim() : ''
      const manifest = await readJson<{ version?: string }>($, `${$.plugin.root}/.claude-plugin/plugin.json`)
      version = manifest?.version ?? ''
    } catch (err) {
      dir = ''
      $.ui.log(`cache-clock mod off: ${String(err)}`, { to: 'debug' })
    }
    if (dir) {
      $.clock.every(1000, () => {
        if (polling) return
        polling = true
        poll($)
          .catch(err => $.ui.log(`cache-clock poll: ${String(err)}`, { to: 'debug' }))
          .finally(() => { polling = false })
      })
    }
    return res
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const left = await secondsLeft($)
    const limit = warnAt()
    if (!band || e.props.hasSurvey || e.props.isWorking || session.status === 'working' ||
        left === null || left <= 0 || left > limit) {
      shown = false
      return next(e)
    }
    shown = true
    const { Box, Text, Button } = $.ui.resolve(e)
    const mmss = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`
    return (
      <Box>
        <Text color={left < limit / 3 ? 'error' : 'warning'}>Cache Clock: cache warm for {mmss} </Text>
        <Button
          key="keep-warm"
          label={forking ? 'Pinging...' : 'Keep warm'}
          onPress={() => forkPing($, true)}
        />
      </Box>
    )
  })
}
