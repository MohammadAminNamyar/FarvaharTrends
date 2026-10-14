'use strict'
const test = require('node:test')
const assert = require('node:assert/strict')
const { DiscoveryRefresh } = require('../packages/flutter_pear/pear-end/farvahartrends-discovery')
test('production Dart API does not promise an unsupported owner-relay RPC', () => {
  const fs = require('node:fs')
  const path = require('node:path')
  const source = fs.readFileSync(path.join(__dirname, '../packages/flutter_pear/lib/src/pear.dart'), 'utf8')
  assert.doesNotMatch(source, /setRelayKey|normalizeRelayKey|PearMethod\.relaySet/)
})
function clock () {
  let next = 0
  const tasks = new Map()
  return { tasks, setTimer (fn, delay) { const id = ++next; tasks.set(id, { fn, delay }); return id }, clearTimer (id) { tasks.delete(id) }, async fire () { const [id, task] = tasks.entries().next().value; tasks.delete(id); await task.fn() }, delay () { return tasks.values().next().value.delay } }
}
test('isolated discovery retries promptly, with bounded backoff and no overlap', async () => {
  const c = clock(); let calls = 0
  const refresh = new DiscoveryRefresh(async () => { calls++; assert.equal(c.tasks.size, 0) }, () => true, { ...c, random: () => 0 })
  refresh.start()
  for (const delay of [15000, 30000, 60000, 120000, 120000]) { assert.equal(c.tasks.size, 1); assert.equal(c.delay(), delay); await c.fire() }
  assert.equal(calls, 5); refresh.stop(); assert.equal(c.tasks.size, 0)
})
test('an established connection stops extra discovery; disconnect resumes it', async () => {
  const c = clock(); let needed = true
  const refresh = new DiscoveryRefresh(async () => {}, () => needed, { ...c, random: () => 0.9 })
  refresh.start(); assert.ok(c.delay() >= 15000 && c.delay() < 20000)
  needed = false; refresh.connected(); assert.equal(c.tasks.size, 0)
  needed = true; refresh.disconnected(); assert.equal(c.tasks.size, 1)
  refresh.stop(); refresh.disconnected(); assert.equal(c.tasks.size, 0)
})
test('stop during an outstanding query prevents rescheduling; restart stays live', async () => {
  const c = clock(); let complete
  const refresh = new DiscoveryRefresh(() => new Promise(resolve => { complete = resolve }), () => true, { ...c, random: () => 0 })
  refresh.start(); const pending = c.fire(); assert.equal(refresh.inFlight, true)
  refresh.disconnected(); assert.equal(c.tasks.size, 0)
  refresh.stop(); refresh.start(); assert.equal(c.tasks.size, 0)
  complete(); await pending; assert.equal(c.tasks.size, 1); assert.equal(c.delay(), 15000)
  const again = c.fire(); refresh.stop(); complete(); await again; assert.equal(c.tasks.size, 0)
})
