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

const MAX_BOOTSTRAP = 16

// Operator DHT configuration. Defaults: ephemeral (this device is not a DHT
// routing node for strangers) and announced (discoverable on the topic).
// Bootstrap entries are strict public IPv4 host:port strings, never names.
function dhtOptions (p = {}) {
  if (p === null || typeof p !== 'object') throw new Error('Invalid DHT options')
  const bootstrap = []
  if (p.bootstrap !== undefined) {
    if (!Array.isArray(p.bootstrap) || p.bootstrap.length > MAX_BOOTSTRAP) throw new Error('Invalid bootstrap list')
    for (const entry of p.bootstrap) {
      const match = typeof entry === 'string' && entry.length <= 21 && /^([0-9.]+):([0-9]{1,5})$/.exec(entry)
      const node = match ? { host: match[1], port: Number(match[2]) } : null
      if (!validNode(node) || String(node.port) !== match[2]) throw new Error('Invalid bootstrap node')
      if (!bootstrap.includes(entry)) bootstrap.push(entry)
    }
  }
  for (const key of ['ephemeral', 'announce', 'publicBootstrap']) {
    if (p[key] !== undefined && typeof p[key] !== 'boolean') throw new Error('Invalid DHT option: ' + key)
  }
  return { bootstrap, ephemeral: p.ephemeral !== false, announce: p.announce !== false, publicBootstrap: p.publicBootstrap !== false }
}

// Separate routing state in peer-only mode: unrelated public routing entries
// never become its starting set. This does not classify geography or firewall
// later referrals; it removes the dependency on built-in public bootstrappers.
function networkOptions (network, cache, defaults) {
  const nodes = cache.bootstrapNodes()
  return {
    bootstrap: [...new Set([...network.bootstrap, ...nodes.slice(0, 8).map(n => `${n.host}:${n.port}`), ...(network.publicBootstrap ? defaults : [])])],
    nodes, ephemeral: network.ephemeral, maxSize: 256
  }
}

class RoutingCache {
  constructor (fs, path, directory, { now = Date.now, allowLoopback = false, publicBootstrap = true } = {}) {
    this.fs = fs
    this.filename = path.join(directory, publicBootstrap ? 'farvahartrends-routing.json' : 'farvahartrends-routing-peers.json')
    this.now = now
    this.allowLoopback = allowLoopback // Tests only; never read from a remote request/cache.
    this.nodes = new Map()
    this.peers = new Map()
    try {
      if (fs.statSync(this.filename).size > MAX_BYTES) return
      const value = JSON.parse(fs.readFileSync(this.filename, 'utf8'))
      if (![1, 2].includes(value.version) || !Array.isArray(value.nodes) || value.nodes.length > MAX_NODES ||
          !Array.isArray(value.peers) || value.peers.length > MAX_PEERS) return
      for (const node of value.nodes) {
        if (validNode(node, allowLoopback) && validTime(node.seenAtMs, now())) {
          this.nodes.set(`${node.host}:${node.port}`, {
            host: node.host, port: node.port, seenAtMs: node.seenAtMs,
            // Version 1 promoted unprobed claims. Do not migrate that claim
            // into evidence of a successful probe.
            appHelper: value.version === 2 && node.appHelper === true && hexKey(node.source),
            source: value.version === 2 && hexKey(node.source) ? node.source : null
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

  rememberNodes (nodes, appHelper = false, source = null) {
    for (const [id, node] of this.nodes) {
      if (!validTime(node.seenAtMs, this.now())) this.nodes.delete(id)
    }
    for (const node of nodes.slice(0, MAX_NODES)) {
      if (!validNode(node, this.allowLoopback)) continue
      const id = `${node.host}:${node.port}`
      const old = this.nodes.get(id)
      const confirmed = appHelper && hexKey(source)
      const owned = confirmed && !old?.source
        ? [...this.nodes.entries()].filter(([, n]) => n.source === source)
          .sort((a, b) => a[1].seenAtMs - b[1].seenAtMs) : []
      const replacement = owned.length >= 2 ? owned[0][0] : null
      // An authenticated peer can still advertise someone else's endpoint.
      // Limit both introducers and address prefixes; preserve successful routes
      // against a stream of ordinary routing entries.
      if (!old) {
        const prefix = node.host.split('.').slice(0, 3).join('.')
        if ([...this.nodes.entries()].filter(([key, n]) => key !== replacement && n.host.split('.').slice(0, 3).join('.') === prefix).length >= 4) continue
      }
      if (replacement) this.nodes.delete(replacement)
      this.nodes.set(id, {
        host: node.host, port: node.port, seenAtMs: this.now(),
        appHelper: confirmed || old?.appHelper === true,
        source: old?.source || (confirmed ? source : null)
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
    const value = JSON.stringify({ version: 2, nodes: [...this.nodes.values()], peers: [...this.peers.values()] })
    if (Buffer.byteLength(value) > MAX_BYTES) throw new Error('Routing cache too large')
    this.fs.writeFileSync(this.filename + '.next', value, { mode: 0o600 })
    this.fs.renameSync(this.filename + '.next', this.filename)
  }
}

module.exports = { RoutingCache, publicV4, validNode, dhtOptions, networkOptions, MAX_AGE, MAX_NODES, MAX_PEERS, MAX_BOOTSTRAP }
