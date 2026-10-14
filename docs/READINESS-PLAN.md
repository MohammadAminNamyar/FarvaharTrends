# Readiness workstreams

This tracks the six requested workstreams. A passing component test is not a
field result. Each workstream remains open until its listed evidence exists.
No CI or release automation is part of this work.

## 1. Reconnection and delivery

Implemented for the next build: authenticated overlay peers gain explicit,
bounded reconnect intent immediately, including removal on cache eviction and
respect for quarantine. An isolated but answering worklet is restarted after
90 seconds with remembered peers, or 180 seconds on a fresh install. Repeated
isolation backs off to 15 minutes. Offline time does not consume the timer;
90 seconds of a live pinned link resets the backoff. A transport connection
alone is not a successful application link.

Evidence: real local HyperDHT/Hyperswarm peers reconnected after removing the
initial bootstrap and topic discovery, then exchanged Persian text. Policy
tests cover outage backoff, brief connections, offline periods and network
changes. Repeat emulator-to-cellular delivery, interface changes and stalled
transport recovery on the rebuilt APK. Record every failed attempt as well as
successful deliveries; compare host-monotonic observations rather than two
phones' wall clocks. Aim for automatic reconnection within two minutes when a
known route is reachable; measure the proportion of news arriving within five
minutes rather than claiming a guarantee.

## 2. Discovery during shutdown

Available: public discovery switch, private routing caches, signed and probed
TCP/DHT introductions, Bluetooth/LAN contact exchange, bounded hints and an
optional helper role in the same APK. Local tests cover bootstrap loss, a fresh
peer introduced through another participant, cached reconnect and TCP delivery
without UDP discovery. No IP-range scan or mandatory server is used.

Still required: real carrier UDP blocking and NAT/address churn; fresh-phone
introduction over actual nearby links; consenting Iranian participants on
different providers, with international discovery unavailable and a remaining
news ingress. A reachable participant and an available physical path remain
necessary. Importing an address does not prove domestic routing. Do not replace
this field requirement with loopback results or assume an IP is safe to expose.

## 3. Background receiving and battery

Available: foreground receiving, saved Stop/restart consent, balanced service
wake locks and emulator process-death/reboot checks. A short locked Samsung
trial passed, with USB power and screen wake during inspection.

Still required: unplugged 30-minute, two-hour and overnight trials; screen kept
off; battery saver and OEM restrictions; actual Bluetooth/Wi-Fi Direct pairs;
new-neighbor discovery during sleep. Observe battery charge/current, bytes,
service lifetime and delivery attempts without collecting private news or
subscriptions. Keep intentional force-stop effective. Record physical USB
power state; a simulated unplug is not a battery measurement.

## 4. Abuse, storage and scale

Existing bounds cover frame sizes, work, requests, connections, channel/news
caches and optional images. The next build also prioritizes locally followed
news within the shared cache; other public news keeps relay space subject to
the local outbox's existing priority. Follow choices are not added to envelopes
or journal records. This changes retention, not traffic-analysis guarantees.

Still required: sustained signed spam and peer-identity churn with honest
traffic continuing; recovery after resource exhaustion; real low-space/crash
tests; low-end Android CPU/memory/flash/radio measurements. The single global
discovery topic and bounded all-channel gossip need a scalable routing design
and benchmarks before mass rollout. Sharding must retain small-network and
partition recovery, avoid publishing subscription rosters, and limit lookup
traffic. Test 10–20 consenting devices before 100; do not describe a simulation
as million-device validation or rate limits as Sybil resistance.

## 5. Publisher authority and security

Current encrypted backups recover lost keys. Editor revocation is implemented.
Backups do not revoke a stolen owner key. A protocol upgrade must precommit an
independent recovery authority before compromise, keep its private key off the
publishing device after export, and authorize replacement online keys through
signed increasing generations. A compromised online key must not be able to
advance those generations, replace the recovery authority or win with an
arbitrarily large ordinary policy revision.

The upgrade must preserve v1 channel access, explicitly migrate existing
channels, reject rollback and cross-channel proofs, define competing recovery
actions, survive cache eviction/restart, and tell offline readers when authority
is unknown. Test recovery followed by replay of the stolen key, policy deletion,
old backups, concurrent editors and a fresh receiver. Historical news retention
after compromise needs an explicit rule; timestamps cannot prove pre-compromise
authorship. Do not silently reinterpret v1 metadata as protected by a new key.

The separation of offline trust and online authority is informed by the
[TUF specification](https://theupdateframework.github.io/specification/latest/).
This is a channel-protocol design task, not a claim to implement TUF. It remains
unimplemented until its protocol, UI/export flow and tests are complete.

Independent review is still needed for cryptography, native transport boundaries,
active/passive probing and traffic correlation. The current Dart RSA private
operation has no explicit blinding; do not replace it with unreviewed custom
cryptography. Direct delivery does not provide publisher anonymity.

## 6. Final verification and publication

Run the complete Flutter, overlay and native suites after the final source
changes, plus analysis and the physical-device checks above. Verify APK signer,
version and source fingerprint; update devices in place without clearing their
channels or keys. Reconcile superseded documentation, review the diff and ensure
APKs, credentials, generated files and assistant notes remain ignored. Commit
and push source to the renamed repository after validation. Keep device evidence
local and report outstanding field/security gates alongside the APK.
