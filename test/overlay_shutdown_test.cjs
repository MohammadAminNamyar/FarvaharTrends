'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const dgram = require('node:dgram')
const { once } = require('node:events')
const DHT = require('../packages/flutter_pear/pear-end/node_modules/hyperdht')
const Hyperswarm = require('../packages/flutter_pear/pear-end/node_modules/hyperswarm')
const { networkOptions } = require('../packages/flutter_pear/pear-end/farvahartrends-routing')
const { RoutingCandidates } = require('../packages/flutter_pear/pear-end/farvahartrends-candidates')
const { DiscoveryRefresh } = require('../packages/flutter_pear/pear-end/farvahartrends-discovery')
const { PeerReconnect } = require('../packages/flutter_pear/pear-end/farvahartrends-reconnect')

async function port () {
  const socket = dgram.createSocket('udp4')
  socket.bind(0, '127.0.0.1'); await once(socket, 'listening')
  const value = socket.address().port
  await new Promise(resolve => socket.close(resolve))
  return value
}

async function until (predicate, timeout = 45000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise(resolve => setTimeout(resolve, 50))
  }
  throw Error('Isolated discovery deadline exceeded')
}

test('real HyperDHT discovers fresh and restarted peers after initial bootstrap loss without public services', { timeout: 180000 }, async t => {
  const seed = DHT.bootstrapper(await port(), '127.0.0.1', { host: '127.0.0.1' })
  const swarms = []
  const refreshes = []
  t.after(async () => {
    for (const refresh of refreshes) refresh.stop()
    for (const swarm of swarms.reverse()) await swarm.destroy()
    await seed.destroy({ force: true })
  })
  await seed.ready()
  const topic = Buffer.alloc(32, 71)
  const seedAddress = { host: '127.0.0.1', port: seed.address().port }
  async function peer (nodes, keySeed, remembered = []) {
    // Loopback is test-only; production imports reject it. Exercise the exact
    // options constructor used by the worklet, with no global bootstrap hosts.
    const options = networkOptions({ bootstrap: nodes.map(n => `${n.host}:${n.port}`), ephemeral: false, publicBootstrap: false }, { bootstrapNodes: () => [] }, ['must-not-be-used.invalid:49737'])
    assert(options.bootstrap.every(n => n.startsWith('127.0.0.1:')))
    const dht = new DHT({ ...options, host: '127.0.0.1', firewalled: false })
    const swarm = new Hyperswarm({ dht, seed: keySeed, backoffs: [1500, 5000, 15000, 60000], maxPeers: 8, maxParallel: 2 })
    swarms.push(swarm)
    swarm.on('connection', socket => socket.on('error', () => {}))
    await dht.ready()
    const discovery = swarm.join(topic, { server: true, client: true })
    const refresh = new DiscoveryRefresh(() => discovery.refresh({ limit: 8 }), () => !swarm.destroyed && swarm.connections.size === 0)
    refreshes.push(refresh)
    swarm.on('connection', socket => {
      refresh.connected()
      socket.on('close', () => { if (!swarm.destroyed) refresh.disconnected() })
    })
    refresh.start()
    for (const key of remembered) swarm.joinPeer(key)
    await discovery.flushed()
    return { swarm, dht, discovery }
  }
  const aSeed = Buffer.alloc(32, 1)
  const a = await peer([seedAddress], aSeed)
  const b = await peer([seedAddress], Buffer.alloc(32, 2))
  const fromA = await until(() => [...a.swarm.connections].find(s => s.remotePublicKey.equals(b.swarm.keyPair.publicKey)))
  const atB = await until(() => [...b.swarm.connections].find(s => s.remotePublicKey.equals(a.swarm.keyPair.publicKey)))
  const first = once(atB, 'data')
  fromA.write(Buffer.from('before-cut'))
  assert.equal((await first)[0].toString(), 'before-cut')

  const helper = { host: '127.0.0.1', port: b.dht.address().port }
  const response = await a.dht.ping(helper)
  assert.equal(response.from.port, helper.port)
  await seed.destroy({ force: true })
  await a.swarm.destroy()
  await b.discovery.refresh()
  const restarted = await peer([helper], aSeed, [b.swarm.keyPair.publicKey])
  const afterCut = await until(() => [...restarted.swarm.connections].find(s => s.remotePublicKey.equals(b.swarm.keyPair.publicKey)))
  const receiver = await until(() => [...b.swarm.connections].find(s => s.remotePublicKey.equals(restarted.swarm.keyPair.publicKey) && s !== atB))
  const second = once(receiver, 'data')
  afterCut.write(Buffer.from('after-cut-and-restart'))
  assert.equal((await second)[0].toString(), 'after-cut-and-restart')

  const fresh = await peer([helper], Buffer.alloc(32, 3))
  await until(() => fresh.swarm.connections.size > 0)
  // A cold worklet can start empty, then learn an introduction over an
  // independent app link (the signed-link exchange is tested in Dart).
  const introduced = await peer([], Buffer.alloc(32, 4))
  const candidates = new RoutingCandidates({
    allowLoopback: true,
    probe: async node => {
      const response = await introduced.dht.ping(node)
      return response.from.host === node.host && response.from.port === node.port
    },
    accept: node => introduced.dht.addNode({ host: node.host, port: node.port })
  })
  candidates.offer(helper, b.swarm.keyPair.publicKey.toString('hex'))
  await candidates.tick()
  await introduced.discovery.refresh()
  await until(() => introduced.swarm.connections.size > 0)
  candidates.stop()
  assert.equal(seed.destroyed, true)
})

test('remembered peers reconnect after a dropped stream with topic discovery and initial bootstrap removed', { timeout: 120000 }, async t => {
  const seed = DHT.bootstrapper(await port(), '127.0.0.1', { host: '127.0.0.1' })
  const swarms = [], policies = []
  t.after(async () => {
    for (const policy of policies) policy.stop()
    for (const swarm of swarms.reverse()) await swarm.destroy()
    await seed.destroy({ force: true })
  })
  await seed.ready()
  const topic = Buffer.alloc(32, 72)
  async function peer () {
    const dht = new DHT({ bootstrap: [`127.0.0.1:${seed.address().port}`], host: '127.0.0.1', ephemeral: false, firewalled: false })
    const swarm = new Hyperswarm({ dht, backoffs: [1500, 5000, 15000, 60000], maxPeers: 8, maxParallel: 2 })
    swarms.push(swarm)
    swarm.on('connection', socket => socket.on('error', () => {}))
    const keys = []
    const policy = new PeerReconnect({
      keys: () => keys, join: key => swarm.joinPeer(Buffer.from(key, 'hex')),
      leave: key => swarm.leavePeer(Buffer.from(key, 'hex')),
      active: () => !swarm.destroyed, blocked: () => false
    })
    policies.push(policy)
    await dht.ready()
    await swarm.join(topic).flushed()
    return { swarm, dht, remember (key) { keys.push(key.toString('hex')); policy.sync() } }
  }
  const a = await peer(), b = await peer()
  const firstA = await until(() => [...a.swarm.connections][0])
  const firstB = await until(() => [...b.swarm.connections][0])
  // The production caller does this only after pinned application TLS. Here
  // we test transport retrying, separately from the Dart admission tests.
  a.remember(b.swarm.keyPair.publicKey)
  b.remember(a.swarm.keyPair.publicKey)
  await Promise.all([a.swarm.leave(topic), b.swarm.leave(topic)])
  await seed.destroy({ force: true })
  firstA.destroy()
  const recoveredA = await until(() => [...a.swarm.connections].find(s => s !== firstA && !s.destroying))
  const recoveredB = await until(() => [...b.swarm.connections].find(s => s !== firstB && !s.destroying))
  const received = once(recoveredB, 'data')
  recoveredA.write(Buffer.from('بازیابی خودکار پس از قطع ارتباط'))
  assert.equal((await received)[0].toString(), 'بازیابی خودکار پس از قطع ارتباط')
  assert.equal(seed.destroyed, true)
  assert.equal(a.swarm.status(topic), null)
  assert.equal(b.swarm.status(topic), null)
})
