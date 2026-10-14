'use strict'

// Retry only while isolated. Never overlap lookups or spin during an outage.
class DiscoveryRefresh {
  constructor (refresh, needed, { setTimer = setTimeout, clearTimer = clearTimeout, random = Math.random } = {}) {
    this.refresh = refresh
    this.needed = needed
    this.setTimer = setTimer
    this.clearTimer = clearTimer
    this.random = random
    this.timer = null
    this.inFlight = false
    this.stopped = true
    this.generation = 0
    this.attempt = 0
    this.refreshes = 0
  }

  start () {
    this.stop()
    this.stopped = false
    this.attempt = 0
    this.schedule()
  }

  schedule () {
    if (this.stopped || this.timer !== null || this.inFlight || !this.needed()) return
    const generation = this.generation
    const delay = [15000, 30000, 60000, 120000][Math.min(this.attempt, 3)] + Math.floor(this.random() * 5000)
    this.timer = this.setTimer(async () => {
      this.timer = null
      if (this.stopped || generation !== this.generation || !this.needed()) return
      this.inFlight = true
      this.refreshes++
      try { await this.refresh() } catch { /* Later bounded refresh retries. */ }
      finally {
        this.inFlight = false
        if (!this.stopped) {
          if (generation === this.generation) this.attempt++
          this.schedule()
        }
      }
    }, delay)
  }

  connected () {
    if (this.timer !== null) this.clearTimer(this.timer)
    this.timer = null
    this.attempt = 0
  }

  disconnected () {
    this.attempt = 0
    this.schedule()
  }

  stop () {
    this.stopped = true
    this.generation++
    if (this.timer !== null) this.clearTimer(this.timer)
    this.timer = null
  }
}

module.exports = { DiscoveryRefresh }
