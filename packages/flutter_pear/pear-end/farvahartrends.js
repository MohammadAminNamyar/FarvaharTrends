// FarvaharTrends's transport-only worklet. Adapted from flutter_pear 0.4.9 (MIT).
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
const { RoutingCache, validNode, dhtOptions, networkOptions } = require('./farvahartrends-routing')
const { DiscoveryRefresh } = require('./farvahartrends-discovery')
const { TransportCooldown } = require('./farvahartrends-cooldown')
const { PeerReconnect } = require('./farvahartrends-reconnect')
const { RoutingCandidates } = require('./farvahartrends-candidates')
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
  const filename = path.join(directory, 'farvahartrends-connection.seed')
  if (fs.existsSync(filename)) {
    if (fs.statSync(filename).size !== 32) throw new Error('Invalid transport identity file')
    return fs.readFileSync(filename)
  }
  const value = crypto.randomBytes(32)
  fs.writeFileSync(filename + '.next', value, { mode: 0o600 })
  fs.renameSync(filename + '.next', filename)
  return value
}

let cache = null
const cooling = new TransportCooldown()
const connections = new Map()
// The DHT is built lazily on the first join so the operator's options apply:
// ephemeral by default (no routing service for strangers), bootstrap list
// first, then cached nodes, then the hyperdht defaults.
let network = dhtOptions()
let dht = null
let swarm = null
let joinedTopic = null
let discovery = null
let reconnect = null
let candidates = null
const probeSessions = new Set()
const discoveryRefresh = new DiscoveryRefresh(() => discovery.refresh({ limit: 8 }), () => joinedTopic !== null && connections.size === 0)
let everConnected = false
let globalWindow = { start: Date.now(), bytes: 0, frames: 0 }

function state (value, reason) {
  if (joinedTopic) send({ ev: 'swarm.lifecycle', p: { topic: joinedTopic, state: value, ...(reason ? { reason } : {}) } })
}

function save () {
  if (!dht || !cache) return
  try {
    cache.rememberNodes(dht.toArray({ limit: 24 }))
    cache.save()
  } catch { /* Optional cache failure does not interrupt verified news. */ }
}
const saveTimer = setInterval(save, 30000)
if (saveTimer.unref) saveTimer.unref()

function openNetwork () {
  if (dht) return
  cache = new RoutingCache(fs, path, directory, { publicBootstrap: network.publicBootstrap })
  dht = new DHT(networkOptions(network, cache, BOOTSTRAP_NODES))
  dht.on('ready', save)
  swarm = new Hyperswarm({
    dht, seed: seed(), backoffs: [1500, 5000, 15000, 60000], maxPeers: 8, maxClientConnections: 8, maxServerConnections: 8, maxParallel: 2
  })
  swarm.on('connection', onConnection)
}

function startRecovery () {
  reconnect = new PeerReconnect({
    keys: () => joinedTopic ? cache.peerKeys(joinedTopic) : [],
    join: key => swarm.joinPeer(Buffer.from(key, 'hex')),
    leave: key => swarm.leavePeer(Buffer.from(key, 'hex')),
    blocked: key => cooling.blocked(key),
    active: () => joinedTopic !== null
  })
  candidates = new RoutingCandidates({
    probe: async node => {
      const session = dht.session()
      probeSessions.add(session)
      const timeout = setTimeout(() => session.destroy(new Error('Discovery probe deadline')), 5000)
      try {
        const response = await session.ping(node)
        return response?.from?.host === node.host && response?.from?.port === node.port
      } finally {
        clearTimeout(timeout)
        session.destroy()
        probeSessions.delete(session)
      }
    },
    accept: (node, source) => {
      cache.rememberNodes([node], true, source)
      dht.addNode({ host: node.host, port: node.port })
      save()
      if (joinedTopic && connections.size === 0) discovery.refresh({ limit: 8 }).catch(() => {})
    }
  })
}

const candidateTimer = setInterval(() => {
  if (joinedTopic) {
    reconnect?.sync()
    candidates?.tick().catch(() => {})
  }
}, 5000)
if (candidateTimer.unref) candidateTimer.unref()

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

function onConnection (conn, info) {
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
}

async function handle ({ m, p = {} }) {
  switch (m) {
    case 'attach.info': return { nonce, bundleVersion: BUNDLE_VERSION }
    case 'dht.status': return dht ? { online: dht.online, firewalled: dht.firewalled, randomized: dht.randomized } : { online: false, firewalled: true, randomized: false }
    case 'dht.configure': {
      // Validated before the DHT exists; a later change needs a new worklet.
      if (dht) throw new Error('DHT already started')
      network = dhtOptions(p)
      return { bootstrap: network.bootstrap.length, ephemeral: network.ephemeral, announce: network.announce, publicBootstrap: network.publicBootstrap }
    }
    case 'swarm.join': {
      if (!validKey(p.topic) || (joinedTopic && joinedTopic !== p.topic)) throw new Error('Only one public network namespace is allowed')
      if (!joinedTopic) {
        if (!dht) network = dhtOptions({ ...p, announce: p.announce !== undefined ? p.announce : p.server !== false })
        openNetwork()
        startRecovery()
        joinedTopic = p.topic
        discovery = swarm.join(Buffer.from(joinedTopic, 'hex'), { server: network.announce, client: true, limit: 8 })
        discoveryRefresh.start()
        reconnect.sync()
      }
      for (const [peer, entry] of connections) send({ ev: 'swarm.connection', p: { topic: entry.topic, peer } })
      state(connections.size ? 'connected' : 'discovering')
      return { joined: joinedTopic }
    }
    case 'swarm.leave': {
      if (p.topic === joinedTopic && swarm) {
        const previous = joinedTopic
        discoveryRefresh.stop()
        reconnect?.stop()
        candidates?.stop()
        for (const session of probeSessions) session.destroy(new Error('Discovery stopped'))
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
    case 'farvahartrends.network-state': {
      // A helper must be announced, persistent (non-ephemeral) and reachable.
      const own = dht ? { host: dht.host, port: dht.port } : null
      const helper = !!dht && network.announce && !dht.ephemeral && !dht.firewalled && validNode(own)
      return { discoveryStage: !dht ? 'idle' : !dht.online ? 'bootstrapping' : swarm.connecting > 0 ? 'connecting' : 'discovering', discoveryRefreshes: discoveryRefresh.refreshes, cachedRoutingCount: cache?.bootstrapNodes().length || 0, cachedPeerCount: cache?.peers.size || 0,
        reachableHelper: helper, ownContact: helper ? { ...own, publicKey: swarm.keyPair.publicKey.toString('hex') } : null, ephemeral: dht ? dht.ephemeral : network.ephemeral, announce: network.announce, bootstrapCount: network.bootstrap.length,
        publicBootstrap: network.publicBootstrap, candidateCount: candidates?.entries.size || 0 }
    }
    case 'farvahartrends.remember-peer': {
      if (!connections.has(p.peer) || p.topic !== joinedTopic) throw new Error('Connection is not active')
      cache.rememberPeer(p.peer, p.topic)
      // Pin reconnect intent immediately after application TLS succeeds.
      // Waiting until the next app start leaves newly discovered peers on
      // Hyperswarm's shorter-lived topic-only retry policy.
      reconnect.sync()
      if (validNode(p.node)) {
        const node = { host: p.node.host, port: p.node.port }
        candidates.offer(node, p.peer)
      }
      save()
      return null
    }
    case 'farvahartrends.disconnect': {
      if (!validKey(p.peer)) throw new Error('Invalid connection key')
      if (p.forget === true) { cache?.forgetPeer(p.peer); reconnect?.forget(p.peer) }
      if (p.cooldown !== false && swarm) swarm.leavePeer(Buffer.from(p.peer, 'hex'))
      cooling.reject(p.peer, p.cooldown !== false)
      if (p.forget !== true && p.cooldown !== false) reconnect?.pause(p.peer)
      connections.get(p.peer)?.conn.destroy()
      save()
      return null
    }
    case 'farvahartrends.discovery-candidates': {
      if (!joinedTopic || !Array.isArray(p.nodes) || p.nodes.length > 4) throw new Error('Invalid discovery candidates')
      for (const node of p.nodes) candidates.offer(node, node.source)
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
