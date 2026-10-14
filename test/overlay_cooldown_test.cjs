const { test } = require('node:test')
const assert = require('node:assert/strict')
const { TransportCooldown } = require('../packages/flutter_pear/pear-end/farvahartrends-cooldown')

test('ordinary network loss does not quarantine a remembered peer', () => {
  const cooling = new TransportCooldown()
  cooling.reject('peer', false)
  assert.equal(cooling.blocked('peer'), false)
})

test('temporary rejection expires and cannot become a permanent firewall ban', () => {
  let now = 100
  const cooling = new TransportCooldown({ now: () => now })
  cooling.reject('peer')
  assert.equal(cooling.blocked('peer'), true)
  now += 45000
  assert.equal(cooling.blocked('peer'), false)
  assert.equal(cooling.entries.size, 0)
})

test('cooldown identities remain bounded under churn', () => {
  const cooling = new TransportCooldown()
  for (let i = 0; i < 10000; i++) cooling.reject(String(i))
  assert.equal(cooling.entries.size, 64)
  assert.equal(cooling.blocked('0'), false)
  assert.equal(cooling.blocked('9999'), true)
})
