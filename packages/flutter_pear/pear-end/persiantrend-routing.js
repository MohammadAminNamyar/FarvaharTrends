'use strict'

// Public transport hints only. Never publisher keys, channels or subscriptions.
const MAX_NODES = 32
const MAX_PEERS = 8
const MAX_BYTES = 16 * 1024
const MAX_AGE = 7 * 24 * 60 * 60 * 1000

function publicV4 (host) {
  if (typeof host !== 'string' || !/^(?:\d{1,3}\.){3}\d{1,3}$/.test(host)) return false
  const parts = host.split('.').map(Number)
  if (parts.some(n => n > 255) || parts.join('.') !== host) return false
  const [a, b, c] = parts
  return !(a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && (b === 168 || b === 0 || b === 2 || (b === 88 && c === 99))) ||
    (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) ||
    (a === 203 && b === 0 && c === 113))
}

function validNode (node, allowLoopback = false) {
  return node && (publicV4(node.host) || (allowLoopback && node.host === '127.0.0.1')) &&
    Number.isInteger(node.port) && node.port > 0 && node.port <= 65535
}

function validTime (seen, now) {
  return Number.isSafeInteger(seen) && seen >= 0 && seen <= now + 30000 && now - seen < MAX_AGE
}

function hexKey (value) {
  return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value)
}

class RoutingCache {
  constructor (fs, path, directory, { now = Date.now, allowLoopback = false } = {}) {
    this.fs = fs
    this.filename = path.join(directory, 'persiantrend-routing.json')
    this.now = now
    this.allowLoopback = allowLoopback // Tests only; never read from a remote request/cache.
    this.nodes = new Map()
    this.peers = new Map()
    try {
      if (fs.statSync(this.filename).size > MAX_BYTES) return
      const value = JSON.parse(fs.readFileSync(this.filename, 'utf8'))
      if (value.version !== 1 || !Array.isArray(value.nodes) || value.nodes.length > MAX_NODES ||
          !Array.isArray(value.peers) || value.peers.length > MAX_PEERS) return
      for (const node of value.nodes) {
        if (validNode(node, allowLoopback) && validTime(node.seenAtMs, now())) {
          this.nodes.set(`${node.host}:${node.port}`, {
            host: node.host, port: node.port, seenAtMs: node.seenAtMs, appHelper: node.appHelper === true
          })
        }
      }
      for (const peer of value.peers) {
        if (hexKey(peer.key) && hexKey(peer.topic) && validTime(peer.seenAtMs, now())) {
          this.peers.set(peer.key, { key: peer.key, topic: peer.topic, seenAtMs: peer.seenAtMs })
        }
      }
    } catch { /* Missing/corrupt optional cache must not stop nearby delivery. */ }
  }

  bootstrapNodes () {
    return [...this.nodes.values()].filter(node => validTime(node.seenAtMs, this.now()))
      .sort((a, b) => Number(b.appHelper) - Number(a.appHelper) || b.seenAtMs - a.seenAtMs)
      .map(({ host, port }) => ({ host, port }))
  }

  peerKeys (topic) {
    return [...this.peers.values()].filter(peer => peer.topic === topic && validTime(peer.seenAtMs, this.now()))
      .sort((a, b) => b.seenAtMs - a.seenAtMs).map(peer => peer.key)
  }

  rememberNodes (nodes, appHelper = false) {
    for (const node of nodes.slice(0, MAX_NODES)) {
      if (!validNode(node, this.allowLoopback)) continue
      const id = `${node.host}:${node.port}`
      this.nodes.set(id, {
        host: node.host, port: node.port, seenAtMs: this.now(),
        appHelper: appHelper || this.nodes.get(id)?.appHelper === true
      })
    }
    this.nodes = new Map([...this.nodes.entries()]
      .filter(([, node]) => validTime(node.seenAtMs, this.now()))
      .sort((a, b) => Number(b[1].appHelper) - Number(a[1].appHelper) || b[1].seenAtMs - a[1].seenAtMs)
      .slice(0, MAX_NODES))
  }

  rememberPeer (key, topic) {
    if (!hexKey(key) || !hexKey(topic)) throw new Error('Invalid connection key/topic')
    this.peers.delete(key)
    this.peers.set(key, { key, topic, seenAtMs: this.now() })
    while (this.peers.size > MAX_PEERS) this.peers.delete(this.peers.keys().next().value)
  }

  forgetPeer (key) { this.peers.delete(key) }

  save () {
    const value = JSON.stringify({ version: 1, nodes: [...this.nodes.values()], peers: [...this.peers.values()] })
    if (Buffer.byteLength(value) > MAX_BYTES) throw new Error('Routing cache too large')
    this.fs.writeFileSync(this.filename + '.next', value, { mode: 0o600 })
    this.fs.renameSync(this.filename + '.next', this.filename)
  }
}

module.exports = { RoutingCache, publicV4, validNode, MAX_AGE, MAX_NODES, MAX_PEERS }
