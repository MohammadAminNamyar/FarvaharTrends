// PersianTrend's transport-only worklet. Adapted from flutter_pear 0.4.9 (MIT).
// Cryptography/NAT traversal remain Hyperswarm/HyperDHT implementations.
/* global BareKit, Bare */
'use strict'
const { IPC } = typeof BareKit !== 'undefined' ? BareKit : require('./desktop-ipc')
const Hyperswarm = require('hyperswarm')
const DHT = require('hyperdht')
const { BOOTSTRAP_NODES } = require('hyperdht/lib/constants')
const crypto = require('hypercore-crypto')
const fs = require('bare-fs')
const path = require('bare-path')
const { RoutingCache, validNode } = require('./persiantrend-routing')
const { DiscoveryRefresh } = require('./persiantrend-discovery')
const { TransportCooldown } = require('./persiantrend-cooldown')
const BUNDLE_VERSION = require('./version')
const nonce = crypto.randomBytes(16).toString('hex')
const directory = typeof BareKit !== 'undefined' ? Bare.argv[0] : Bare.argv[2]
if (!directory) throw new Error('Missing private transport directory')

function send (value) {
  const json = Buffer.from(JSON.stringify({ ...value, n: nonce }))
  const frame = Buffer.alloc(json.length + 5)
  frame.writeUInt32BE(json.length + 1, 0)
  frame[4] = 0
  json.copy(frame, 5)
  IPC.write(frame)
}

function seed () {
  const filename = path.join(directory, 'persiantrend-connection.seed')
  if (fs.existsSync(filename)) {
    if (fs.statSync(filename).size !== 32) throw new Error('Invalid transport identity file')
    return fs.readFileSync(filename)
  }
  const value = crypto.randomBytes(32)
  fs.writeFileSync(filename + '.next', value, { mode: 0o600 })
  fs.renameSync(filename + '.next', filename)
  return value
}

const cache = new RoutingCache(fs, path, directory)
const cached = cache.bootstrapNodes()
const dht = new DHT({
  bootstrap: [...cached.slice(0, 8).map(node => `${node.host}:${node.port}`), ...BOOTSTRAP_NODES],
  nodes: cached, ephemeral: false, maxSize: 256
})
const cooling = new TransportCooldown()
const swarm = new Hyperswarm({
  dht, seed: seed(), backoffs: [1500, 5000, 15000, 60000], maxPeers: 8, maxClientConnections: 8, maxServerConnections: 8, maxParallel: 2
})
const connections = new Map()
let joinedTopic = null
let discovery = null
const discoveryRefresh = new DiscoveryRefresh(() => discovery.refresh({ limit: 8 }), () => joinedTopic !== null && connections.size === 0)
let everConnected = false
let globalWindow = { start: Date.now(), bytes: 0, frames: 0 }

function state (value, reason) {
  if (joinedTopic) send({ ev: 'swarm.lifecycle', p: { topic: joinedTopic, state: value, ...(reason ? { reason } : {}) } })
}

function save () {
  try {
    cache.rememberNodes(dht.toArray({ limit: 24 }))
    cache.save()
  } catch { /* Optional cache failure does not interrupt verified news. */ }
}
dht.on('ready', save)
const saveTimer = setInterval(save, 30000)
if (saveTimer.unref) saveTimer.unref()

function validKey (value) { return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value) }

function allowance (entry, size) {
  const now = Date.now()
  if (now < entry.start || now - entry.start >= 60000) Object.assign(entry, { start: now, bytes: 0, frames: 0 })
  if (now < globalWindow.start || now - globalWindow.start >= 60000) globalWindow = { start: now, bytes: 0, frames: 0 }
  entry.bytes += size
  entry.frames++
  globalWindow.bytes += size
  globalWindow.frames++
  return size <= 256 * 1024 && entry.bytes <= 2 * 1024 * 1024 && entry.frames <= 2000 &&
    globalWindow.bytes <= 8 * 1024 * 1024 && globalWindow.frames <= 6000
}

swarm.on('connection', (conn, info) => {
  const key = info.publicKey.toString('hex')
  if (!joinedTopic || connections.size >= 8 || cooling.blocked(key)) { conn.on('error', () => {}); conn.destroy(); return }
  const old = connections.get(key)
  if (old) old.conn.destroy()
  const entry = { conn, topic: joinedTopic, start: Date.now(), bytes: 0, frames: 0 }
  connections.set(key, entry)
  discoveryRefresh.connected()
  everConnected = true
  send({ ev: 'swarm.connection', p: { topic: entry.topic, peer: key } })
  state('connected')
  // Raw Noise byte stream: no file/database/pairing protocols are exposed.
  conn.on('data', bytes => {
    if (!allowance(entry, bytes.length)) { conn.destroy(); return }
    send({ ev: 'connection.data', p: { topic: entry.topic, peer: key, data: bytes.toString('base64') } })
  })
  conn.on('error', () => {})
  conn.on('close', () => {
    if (connections.get(key) !== entry) return
    connections.delete(key)
    send({ ev: 'connection.close', p: { topic: entry.topic, peer: key } })
    if (connections.size === 0) { discoveryRefresh.disconnected(); state(everConnected ? 'reconnecting' : 'discovering') }
  })
})

async function handle ({ m, p = {} }) {
  switch (m) {
    case 'attach.info': return { nonce, bundleVersion: BUNDLE_VERSION }
    case 'dht.status': return { online: dht.online, firewalled: dht.firewalled, randomized: dht.randomized }
    case 'swarm.join': {
      if (!validKey(p.topic) || (joinedTopic && joinedTopic !== p.topic)) throw new Error('Only one public network namespace is allowed')
      if (!joinedTopic) {
        joinedTopic = p.topic
        discovery = swarm.join(Buffer.from(joinedTopic, 'hex'), { server: p.server !== false, client: true, limit: 8 })
        discoveryRefresh.start()
        for (const key of cache.peerKeys(joinedTopic)) swarm.joinPeer(Buffer.from(key, 'hex'))
      }
      for (const [peer, entry] of connections) send({ ev: 'swarm.connection', p: { topic: entry.topic, peer } })
      state(connections.size ? 'connected' : 'discovering')
      return { joined: joinedTopic }
    }
    case 'swarm.leave': {
      if (p.topic === joinedTopic) {
        const previous = joinedTopic
        discoveryRefresh.stop()
        joinedTopic = null
        for (const entry of connections.values()) entry.conn.destroy()
        await swarm.leave(Buffer.from(previous, 'hex'))
      }
      return { left: p.topic }
    }
    case 'connection.write': {
      const entry = connections.get(p.peer)
      if (!entry || typeof p.data !== 'string' || p.data.length > 65536) throw new Error('Invalid transport write')
      const bytes = Buffer.from(p.data, 'base64')
      if (bytes.length === 0 || bytes.length > 32773) throw new Error('Transport write exceeds record limit')
      if (!entry.conn.write(bytes)) await new Promise((resolve, reject) => {
        const clean = () => { entry.conn.removeListener('drain', drained); entry.conn.removeListener('close', closed) }
        const drained = () => { clean(); resolve() }
        const closed = () => { clean(); reject(new Error('Transport closed during write')) }
        entry.conn.once('drain', drained)
        entry.conn.once('close', closed)
      })
      return null
    }
    case 'persiantrend.network-state': {
      const own = { host: dht.host, port: dht.port }
      const helper = !dht.ephemeral && !dht.firewalled && validNode(own)
      return { discoveryStage: !dht.online ? 'bootstrapping' : swarm.connecting > 0 ? 'connecting' : 'discovering', discoveryRefreshes: discoveryRefresh.refreshes, cachedRoutingCount: cache.bootstrapNodes().length, cachedPeerCount: cache.peers.size,
        reachableHelper: helper, ownContact: helper ? own : null }
    }
    case 'persiantrend.remember-peer': {
      if (!connections.has(p.peer) || p.topic !== joinedTopic) throw new Error('Connection is not active')
      cache.rememberPeer(p.peer, p.topic)
      if (validNode(p.node)) {
        const node = { host: p.node.host, port: p.node.port }
        cache.rememberNodes([node], true)
        dht.addNode(node)
      }
      save()
      return null
    }
    case 'persiantrend.disconnect': {
      if (!validKey(p.peer)) throw new Error('Invalid connection key')
      if (p.forget === true) cache.forgetPeer(p.peer)
      if (p.cooldown !== false) swarm.leavePeer(Buffer.from(p.peer, 'hex'))
      cooling.reject(p.peer, p.cooldown !== false)
      connections.get(p.peer)?.conn.destroy()
      save()
      return null
    }
    default: throw new Error('Unsupported transport command')
  }
}

let pending = Buffer.alloc(0)
let inFlight = 0
IPC.on('data', chunk => {
  if (pending.length + chunk.length > 256 * 1024) { Bare.exit(1); return }
  pending = pending.length ? Buffer.concat([pending, chunk]) : chunk
  while (pending.length >= 4) {
    const size = pending.readUInt32BE(0)
    if (size < 2 || size > 128 * 1024) { Bare.exit(1); return }
    if (pending.length < size + 4) break
    const frame = pending.subarray(4, size + 4)
    pending = pending.subarray(size + 4)
    if (frame[0] !== 0) continue
    let request
    try { request = JSON.parse(frame.subarray(1).toString()) } catch { continue }
    if (!Number.isSafeInteger(request.id) || typeof request.m !== 'string' || inFlight >= 32) continue
    inFlight++
    Promise.resolve().then(() => handle(request)).then(
      ok => send({ id: request.id, ok: ok ?? null }),
      () => send({ id: request.id, err: { code: 'TRANSPORT_COMMAND_FAILED', message: 'Transport operation failed' } })
    ).finally(() => { inFlight-- })
  }
})

for (const event of ['uncaughtException', 'unhandledRejection']) Bare.on(event, () => {
  try { send({ ev: 'worklet.crash', p: { kind: event, message: 'Transport runtime failed' } }) } finally { Bare.exit(1) }
})
