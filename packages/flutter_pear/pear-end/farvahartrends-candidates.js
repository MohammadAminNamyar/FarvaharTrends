'use strict'

const { validNode } = require('./farvahartrends-routing')

// A referral is a candidate, not a successful route. Bound probes separately
// from news traffic; repeated inventories do not refresh a failed candidate.
class RoutingCandidates {
  constructor ({ probe, accept, now = Date.now, allowLoopback = false }) {
    Object.assign(this, { probe, accept, now, allowLoopback })
    this.entries = new Map()
    this.inFlight = 0
    this.windowStart = now()
    this.attempts = 0
    this.stopped = false
  }

  offer (node, source) {
    if (this.stopped || !validNode(node, this.allowLoopback) ||
        typeof source !== 'string' || !/^[a-f0-9]{64}$/.test(source)) return false
    const id = `${node.host}:${node.port}`
    if (this.entries.has(id)) return true
    const now = this.now()
    for (const [key, entry] of this.entries) {
      if (!entry.busy && now - entry.added > 15 * 60000) this.entries.delete(key)
    }
    const sameSource = [...this.entries.entries()].filter(([, v]) => v.source === source)
    const pool = sameSource.length >= 2 ? sameSource : this.entries.size >= 16 ? [...this.entries.entries()] : []
    if (pool.length) {
      // An address change must not wait fifteen minutes behind failed hints.
      // Only replace an old failed probe; the global probe budget still applies.
      const replace = pool.filter(([, v]) => !v.busy && v.failures > 0 && now - v.added >= 30000)
        .sort((a, b) => a[1].added - b[1].added)[0]
      if (!replace) return false
      this.entries.delete(replace[0])
    }
    this.entries.set(id, { host: node.host, port: node.port, source, next: 0, failures: 0, added: this.now() })
    return true
  }

  async tick () {
    if (this.stopped) return
    const now = this.now()
    if (now < this.windowStart || now - this.windowStart >= 60000) {
      this.windowStart = now
      this.attempts = 0
    }
    const jobs = []
    for (const [id, entry] of this.entries) {
      if (entry.busy) continue
      if (now - entry.added > 15 * 60000) { this.entries.delete(id); continue }
      if (entry.next > now || this.inFlight >= 2 || this.attempts >= 8) continue
      this.inFlight++
      this.attempts++
      entry.busy = true
      jobs.push((async () => {
        try {
          if (!await this.probe({ host: entry.host, port: entry.port })) throw new Error('No matching response')
          if (!this.stopped) this.accept(entry, entry.source)
          entry.failures = 0
          entry.next = this.now() + 60000
        } catch {
          entry.failures++
          entry.next = this.now() + [30000, 120000, 600000][Math.min(2, entry.failures - 1)]
        } finally {
          entry.busy = false
          this.inFlight--
        }
      })())
    }
    await Promise.all(jobs)
  }

  stop () { this.stopped = true; this.entries.clear() }
}

module.exports = { RoutingCandidates }
