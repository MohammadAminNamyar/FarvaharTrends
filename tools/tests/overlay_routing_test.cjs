const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { RoutingCache, publicV4, MAX_AGE, MAX_NODES } = require('../../packages/flutter_pear/pear-end/persiantrend-routing')
const projectRoot = path.resolve(__dirname, '../..')
const scratchRoot = path.join(projectRoot, '.tooling', 'test-tmp')
fs.mkdirSync(scratchRoot, { recursive: true })
function scratch (t) {
  const directory = fs.mkdtempSync(path.join(scratchRoot, 'overlay-cache-'))
  t.after(() => {
    assert(path.resolve(directory).startsWith(scratchRoot + path.sep))
    fs.rmSync(directory, { recursive: true, force: true })
  })
  return directory
}
test('Remote cache entries cannot become private-network scan targets', () => {
  for (const host of ['127.0.0.1', '10.1.2.3', '172.16.0.1', '192.168.0.1',
    '100.64.0.1', '169.254.0.1', '192.0.2.1', '198.18.0.1', '198.51.100.1',
    '203.0.113.1', '224.0.0.1', '255.255.255.255', '1.01.1.1', '1.1.1.999',
    '::1', '::ffff:127.0.0.1', 'example.com', '1.1.1.1:80']) assert.equal(publicV4(host), false, host)
  assert.equal(publicV4('1.1.1.1'), true)
  assert.equal(publicV4('8.8.8.8'), true)
})
test('Cache survives restart, prefers helper contacts and expires old hints', t => {
  const directory = scratch(t)
  let now = 1800000000000
  const cache = new RoutingCache(fs, path, directory, { now: () => now })
  cache.rememberNodes([{ host: '1.1.1.1', port: 1234 }], true)
  cache.rememberNodes([{ host: '8.8.8.8', port: 4321 }])
  cache.rememberPeer('a'.repeat(64), 'b'.repeat(64))
  cache.save()
  const restored = new RoutingCache(fs, path, directory, { now: () => now })
  assert.deepEqual(restored.bootstrapNodes()[0], { host: '1.1.1.1', port: 1234 })
  assert.deepEqual(restored.peerKeys('b'.repeat(64)), ['a'.repeat(64)])
  assert.deepEqual(restored.peerKeys('c'.repeat(64)), [])
  now += MAX_AGE + 1
  assert.deepEqual(restored.bootstrapNodes(), [])
  assert.deepEqual(restored.peerKeys('b'.repeat(64)), [])
})
test('Toxic ports, future timestamps, corrupt and oversized caches fail closed', t => {
  const directory = scratch(t)
  const filename = path.join(directory, 'persiantrend-routing.json')
  const now = 1800000000000
  for (const contents of ['{', 'x'.repeat(16385), JSON.stringify({ version: 1, peers: [], nodes: [
    { host: '1.1.1.1', port: 65536, seenAtMs: now },
    { host: '1.1.1.1', port: 1234, seenAtMs: now + 30001 },
    { host: '127.0.0.1', port: 1234, seenAtMs: now },
    { host: '1.1.1.1', port: 1.5, seenAtMs: now }
  ] })]) {
    fs.writeFileSync(filename, contents)
    assert.deepEqual(new RoutingCache(fs, path, directory, { now: () => now }).bootstrapNodes(), [])
  }
})
test('Bounded cache retains only public route fields and connection keys', t => {
  const directory = scratch(t)
  const cache = new RoutingCache(fs, path, directory)
  for (let index = 1; index <= 100; index++) cache.rememberNodes([
    { host: '11.0.0.' + index, port: 1234, extraField: 'should-not-be-retained' }
  ])
  for (let index = 1; index <= 100; index++) cache.rememberPeer(index.toString(16).padStart(64, '0'), 'b'.repeat(64))
  cache.save()
  assert.equal(cache.bootstrapNodes().length, MAX_NODES)
  assert.equal(cache.peerKeys('b'.repeat(64)).length, 8)
  const text = fs.readFileSync(path.join(directory, 'persiantrend-routing.json'), 'utf8')
  assert(!text.includes('extraField'))
  assert(!text.includes('should-not-be-retained'))
  assert(Buffer.byteLength(text) <= 16384)
})
test('Operator DHT options default to ephemeral+announced and validate bootstrap nodes', () => {
  const { dhtOptions, MAX_BOOTSTRAP } = require('../../packages/flutter_pear/pear-end/persiantrend-routing')
  assert.deepEqual(dhtOptions(), { bootstrap: [], ephemeral: true, announce: true })
  assert.deepEqual(dhtOptions({ topic: 'x', server: false }), { bootstrap: [], ephemeral: true, announce: true })
  assert.deepEqual(dhtOptions({ bootstrap: ['1.1.1.1:49737', '8.8.8.8:1', '1.1.1.1:49737'], ephemeral: false, announce: false }),
    { bootstrap: ['1.1.1.1:49737', '8.8.8.8:1'], ephemeral: false, announce: false })
  assert.equal(dhtOptions({ bootstrap: Array.from({ length: MAX_BOOTSTRAP }, (_, i) => `1.1.1.${i + 1}:1`) }).bootstrap.length, MAX_BOOTSTRAP)
  for (const bad of [
    { bootstrap: Array.from({ length: MAX_BOOTSTRAP + 1 }, (_, i) => `1.1.1.${i + 1}:1`) },
    { bootstrap: 'not-a-list' }, { bootstrap: ['example.com:1234'] }, { bootstrap: ['192.168.0.1:1234'] },
    { bootstrap: ['127.0.0.1:1234'] }, { bootstrap: ['1.1.1.1:0'] }, { bootstrap: ['1.1.1.1:65536'] },
    { bootstrap: ['1.1.1.1:01'] }, { bootstrap: ['1.1.1.1'] }, { bootstrap: [{ host: '1.1.1.1', port: 1 }] },
    { bootstrap: ['1.1.1.1:1 '] }, { bootstrap: [null] }, { ephemeral: 'yes' }, { announce: 1 }, null, 'x'
  ]) assert.throws(() => dhtOptions(bad), undefined, JSON.stringify(bad))
})
test('The worklet builds its DHT lazily from the operator options, never as a persistent node by default', () => {
  const source = fs.readFileSync(path.join(projectRoot, 'packages/flutter_pear/pear-end/persiantrend.js'), 'utf8')
  assert.doesNotMatch(source, /ephemeral: false/)
  assert.match(source, /let dht = null/)
  assert.match(source, /case 'dht\.configure'/)
  assert.match(source, /bootstrap: \[\.\.\.network\.bootstrap, \.\.\.cached/)
  assert.match(source, /ephemeral: network\.ephemeral/)
  assert.match(source, /reachableHelper: helper/)
  assert.match(source, /network\.announce && !dht\.ephemeral && !dht\.firewalled/)
  assert.match(source, /server: network\.announce/)
})
