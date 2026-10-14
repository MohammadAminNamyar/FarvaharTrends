'use strict'

// Application cooldowns must not use Hyperswarm's firewall: rejection there
// permanently bans PeerInfo. Apply this bounded, expiring policy after Noise
// connection establishment; all TLS/content admission limits remain in force.
class TransportCooldown {
  constructor ({ now = Date.now, duration = 45000, limit = 64 } = {}) {
    this.now = now
    this.duration = duration
    this.limit = limit
    this.entries = new Map()
  }

  reject (key, penalize = true) {
    if (!penalize) return
    this.entries.delete(key)
    this.entries.set(key, this.now() + this.duration)
    while (this.entries.size > this.limit) this.entries.delete(this.entries.keys().next().value)
  }

  blocked (key) {
    for (const [peer, until] of this.entries) {
      if (until <= this.now()) this.entries.delete(peer)
    }
    return this.entries.has(key)
  }
}

module.exports = { TransportCooldown }
