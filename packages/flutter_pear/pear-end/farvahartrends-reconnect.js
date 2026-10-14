'use strict'

// Restore explicit reconnect intent after a temporary quarantine. Only the
// small set of authenticated, remembered peers is eligible; no discovery or
// protocol failure can enqueue an unlimited list of new dialing targets.
class PeerReconnect {
  constructor ({ keys, join, leave = () => {}, blocked, active, now = Date.now, setTimer = setTimeout, clearTimer = clearTimeout }) {
    Object.assign(this, { keys, join, leave, blocked, active, now, setTimer, clearTimer })
    this.pending = new Map()
    this.requested = new Set()
    this.timer = null
    this.stopped = false
  }

  sync () {
    if (this.stopped || !this.active()) return
    const allowed = new Set(this.keys().slice(0, 8))
    for (const key of this.requested) {
      if (!allowed.has(key)) { this.leave(key); this.requested.delete(key) }
    }
    for (const key of this.pending.keys()) {
      if (!allowed.has(key)) this.pending.delete(key)
    }
    for (const key of allowed) {
      if (this.requested.has(key) || this.pending.has(key) || this.blocked(key)) continue
      this.join(key)
      this.requested.add(key)
    }
  }

  pause (key, delay = 45000) {
    if (this.stopped || !this.keys().includes(key)) return
    if (this.requested.delete(key)) this.leave(key)
    this.pending.set(key, this.now() + delay)
    while (this.pending.size > 8) this.pending.delete(this.pending.keys().next().value)
    this.schedule()
  }

  forget (key) {
    this.pending.delete(key)
    if (this.requested.delete(key)) this.leave(key)
  }

  schedule () {
    if (this.timer !== null) this.clearTimer(this.timer)
    this.timer = null
    if (this.stopped || !this.active() || !this.pending.size) return
    const delay = Math.max(1000, Math.min(...this.pending.values()) - this.now())
    this.timer = this.setTimer(() => {
      this.timer = null
      if (this.stopped || !this.active()) return
      const allowed = new Set(this.keys())
      let attempts = 0
      for (const [key, due] of this.pending) {
        if (!allowed.has(key)) { this.pending.delete(key); continue }
        if (due > this.now()) continue
        if (this.blocked(key) || attempts >= 2) { this.pending.set(key, this.now() + 1000); continue }
        this.pending.delete(key)
        attempts++
        this.join(key)
        this.requested.add(key)
      }
      this.schedule()
    }, delay)
    if (this.timer?.unref) this.timer.unref()
  }

  stop () {
    this.stopped = true
    if (this.timer !== null) this.clearTimer(this.timer)
    this.timer = null
    this.pending.clear()
    for (const key of this.requested) this.leave(key)
    this.requested.clear()
  }
}

module.exports = { PeerReconnect }
