'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const { PeerReconnect } = require('../packages/flutter_pear/pear-end/farvahartrends-reconnect')
const { RoutingCandidates } = require('../packages/flutter_pear/pear-end/farvahartrends-candidates')
const { RoutingCache, dhtOptions, networkOptions } = require('../packages/flutter_pear/pear-end/farvahartrends-routing')

test('new authenticated peers gain bounded reconnect intent immediately, without bypassing cooldown', () => {
  let keys = []
  const joined = [], left = []
  const blocked = new Set()
  const reconnect = new PeerReconnect({
    keys: () => keys, join: key => joined.push(key), leave: key => left.push(key),
    blocked: key => blocked.has(key), active: () => true,
    setTimer: () => 1, clearTimer: () => {}
  })
  reconnect.sync()
  assert.equal(joined.length, 0)
  keys = ['a'.repeat(64)]
  reconnect.sync(); reconnect.sync()
  assert.deepEqual(joined, keys)
  reconnect.pause(keys[0]); reconnect.sync()
  assert.deepEqual(left, keys)
  assert.equal(joined.length, 1)
  // Replacement/expiration removes explicit retries as well as disk hints.
  keys = ['b'.repeat(64)]
  blocked.add(keys[0]); reconnect.sync()
  assert.equal(reconnect.pending.size, 0)
  assert.equal(joined.length, 1)
  blocked.clear(); reconnect.sync()
  assert.equal(joined.length, 2)
  keys = Array.from({ length: 1000 }, (_, i) => i.toString(16).padStart(64, '0'))
  reconnect.sync()
  assert.equal(reconnect.requested.size, 8)
  reconnect.stop(); reconnect.sync()
  assert.equal(reconnect.requested.size, 0)
  assert.equal(joined.length, 10)
})

test('cooldown restores a remembered peer without another topic discovery', () => {
  let now = 0
  const timers = new Map()
  const joined = []
  const keys = ['a'.repeat(64), 'b'.repeat(64)]
  const reconnect = new PeerReconnect({
    keys: () => keys, join: key => joined.push(key), active: () => true,
    blocked: () => now < 45000, now: () => now,
    setTimer: (fn, delay) => { timers.set(fn, delay); return fn },
    clearTimer: fn => timers.delete(fn)
  })
  reconnect.pause(keys[0])
  reconnect.pause('unknown')
  assert.equal(reconnect.pending.size, 1)
  assert.equal([...timers.values()][0], 45000)
  now = 45000
  const callback = timers.keys().next().value
  timers.delete(callback); callback()
  assert.deepEqual(joined, [keys[0]])
  reconnect.pause(keys[1]); reconnect.forget(keys[1]); reconnect.stop()
  assert.equal(timers.size, 0)
})

test('unverified hints cannot replace successful routes and candidates are bounded', async () => {
  let now = 1000
  const cache = new RoutingCache({ statSync () { throw Error('none') } }, { join: () => 'unused' }, '', { now: () => now })
  cache.rememberNodes([{ host: '11.1.1.1', port: 1 }], true, 'a'.repeat(64))
  let calls = 0
  const candidates = new RoutingCandidates({
    now: () => now,
    probe: async () => { calls++; return false },
    accept: (node, source) => cache.rememberNodes([node], true, source)
  })
  for (let i = 0; i < 1000; i++) candidates.offer({ host: `11.2.${i % 200}.1`, port: 1 }, 'b'.repeat(64))
  assert.equal(candidates.entries.size, 2)
  await candidates.tick()
  assert.equal(calls, 2)
  assert.deepEqual(cache.bootstrapNodes(), [{ host: '11.1.1.1', port: 1 }])
  await candidates.tick(); assert.equal(calls, 2)
  now += 30000; await candidates.tick(); assert.equal(calls, 4)
  candidates.stop(); now += 600000; await candidates.tick(); assert.equal(calls, 4)
})

test('only responsive hints are promoted; stopping cannot promote an in-flight probe', async () => {
  const accepted = []
  let complete
  const candidates = new RoutingCandidates({
    probe: () => new Promise(resolve => { complete = resolve }),
    accept: node => accepted.push(node)
  })
  candidates.offer({ host: '11.0.0.1', port: 1 }, 'a'.repeat(64))
  const pending = candidates.tick()
  assert.equal(accepted.length, 0)
  complete(true); await pending
  assert.equal(accepted.length, 1)
  candidates.offer({ host: '11.0.1.1', port: 1 }, 'b'.repeat(64))
  const second = candidates.tick(); candidates.stop(); complete(true); await second
  assert.equal(accepted.length, 1)
})

test('peer-only routing has separate state and never appends the public bootstrappers', () => {
  const filenames = []
  const fs = { statSync (name) { filenames.push(name); throw Error('none') } }
  const path = { join: (_, name) => name }
  const publicCache = new RoutingCache(fs, path, '')
  const privateCache = new RoutingCache(fs, path, '', { publicBootstrap: false })
  publicCache.rememberNodes([{ host: '11.0.0.1', port: 1 }])
  assert.notEqual(filenames[0], filenames[1])
  const opts = networkOptions(dhtOptions({ publicBootstrap: false, bootstrap: ['11.0.1.1:1234'] }), privateCache, ['foreign.example:1234'])
  assert.deepEqual(opts.bootstrap, ['11.0.1.1:1234'])
  assert.deepEqual(opts.nodes, [])
})

test('one source and one prefix cannot displace all responsive cache entries', () => {
  let now = 100
  const cache = new RoutingCache({ statSync () { throw Error('none') } }, { join: () => 'unused' }, '', { now: () => now })
  cache.rememberNodes([{ host: '11.1.1.1', port: 1 }], true, 'a'.repeat(64))
  for (let i = 0; i < 100; i++) { now++; cache.rememberNodes([{ host: `11.2.${i}.1`, port: 1 }], true, 'b'.repeat(64)) }
  assert.equal(cache.nodes.size, 3)
  for (let i = 0; i < 100; i++) { now++; cache.rememberNodes([{ host: `11.3.${i}.1`, port: 1 }]) }
  assert(cache.bootstrapNodes().some(n => n.host === '11.1.1.1'))
})

test('changed helper addresses replace failed hints and old responsive addresses within caps', async () => {
  let now = 1000
  const source = 'a'.repeat(64)
  const candidates = new RoutingCandidates({ now: () => now, probe: async () => false, accept: () => {} })
  candidates.offer({ host: '11.0.0.1', port: 1 }, source)
  candidates.offer({ host: '11.0.0.2', port: 1 }, source)
  await candidates.tick()
  assert.equal(candidates.offer({ host: '11.0.0.3', port: 1 }, source), false)
  now += 30000
  assert.equal(candidates.offer({ host: '11.0.0.3', port: 1 }, source), true)
  assert.equal(candidates.entries.size, 2)
  const cache = new RoutingCache({ statSync () { throw Error('none') } }, { join: () => 'unused' }, '', { now: () => now })
  for (let i = 1; i <= 8; i++) {
    now++
    cache.rememberNodes([{ host: `11.0.0.${i}`, port: 1 }], true, source)
  }
  assert.equal(cache.nodes.size, 2)
  assert.equal(cache.bootstrapNodes()[0].host, '11.0.0.8')
})
