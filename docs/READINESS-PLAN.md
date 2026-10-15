# Readiness workstreams

This tracks the six requested workstreams. A passing component test is not a
field result. On 14 October 2026 the project owner deferred longer battery and
background trials, Iranian cross-provider field trials, larger-device trials
and further routing/spam work, and independent security review from the current
update. Those items remain unverified follow-up work, rather than release gates
for 0.8.12. The implementation regressions, final APK checks, source publication
and APK delivery remain in scope. No CI or release automation is part of this work.

## 1. Reconnection and delivery

Implemented in 0.8.8: authenticated overlay peers gain explicit,
bounded reconnect intent immediately, including removal on cache eviction and
respect for quarantine. An isolated but answering worklet is restarted after
90 seconds with remembered peers, or 180 seconds on a fresh install. Repeated
isolation backs off to 15 minutes. Offline time does not consume the timer;
90 seconds of a live pinned link resets the backoff. A transport connection
alone is not a successful application link.

Evidence: real local HyperDHT/Hyperswarm peers reconnected after removing the
initial bootstrap and topic discovery, then exchanged Persian text. Policy
tests cover outage backoff, brief connections, offline periods and network
changes. A release-app Persian post became visible on the Samsung over mobile
data within 3.36 seconds of the emulator publish tap (one host monotonic clock).
A second post arrived after changing back to Wi-Fi while the phone was dozing;
device wall-clock timestamps differed by two seconds. The screen woke after
about two minutes, so this was a short screen-off check. Repeat interface
changes and stalled transport recovery over longer trials. Record failures and
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

On 14 October 2026, the release 0.8.11 Samsung S21 Ultra completed a physically
unplugged 30-minute receiving trial after the user stopped Telegram streaming.
The earlier interval with streaming was discarded as an idle battery test.
Android battery history covers the complete 19:35:31–20:05:31 local interval
without a screen-on or power-connected transition. It records `screen_doze`
and light device-idle periods, but no deep device-idle period. The three new
Persian posts have saved arrival times of 19:44:08, 19:51:06 and 20:05:01 on the
Samsung, all before
USB reconnection and screen-on at about 20:07:54. The first planned five-minute
send was delayed by emulator UI automation to roughly minute 8.6; actual send
times were retained. No network-latency claim is derived from two device clocks.

Battery history reports 97% at the start and 95% at the end, with approximately
118 mAh less reported charge. The phone was at 94% when reconnected later.
These are whole-phone readings without a control trial, not isolated app power
usage or a battery-life prediction. Wi-Fi and Bluetooth stayed enabled; all
three details sheets report the peer-network route. The foreground receiving
service was still active on reconnection. No radio settings were changed.

Still required: repeated 30-minute trials, two-hour and overnight trials;
battery saver and OEM restrictions; actual Bluetooth/Wi-Fi Direct pairs;
new-neighbor discovery during sleep. Observe battery charge/current, bytes,
service lifetime and delivery attempts without collecting private news or
subscriptions. Keep intentional force-stop effective. Record physical USB
power state; a simulated unplug is not a battery measurement.

## 4. Abuse, storage and scale

Existing bounds cover frame sizes, work, requests, connections, channel/news
caches and optional images. Version 0.8.8 also prioritizes locally followed
news within the shared cache; other public news keeps relay space subject to
the local outbox's existing priority. Follow choices are not added to envelopes
or journal records. This changes retention, not traffic-analysis guarantees.

The repeated-spam regression uses actual loopback TLS, signed Persian news,
four concurrent flooding connections and fresh transport keys in each of three
rounds. A separate legitimate publisher and receiving socket stay connected;
the relay locally follows that publisher's channel to exercise retention priority.
Paced batches force accepted cache pressure before bursts exercise queue limits;
the assertions require delivery during every flood, catch-up of all legitimate
posts, bounded cache/journal sizes and durable news plus new delivery after a
clean restart. Set `FT_SPAM_WINDOW_SECONDS=60` when running
`test/sustained_spam_delivery_test.dart` to use the production traffic window;
the default shortens it to three seconds. `FT_SPAM_WINDOWS` controls 3–10 rounds.
These are repeated bursts with recovery intervals, not continuous traffic for
the entire run. The fixture manually pins participants; it does not validate
automatic admission or resistance to an adversary creating many identities.

On 14 October 2026 the one-minute-window run passed in 5 minutes 49 seconds:
1,320 signed spam frames were written to the test sockets across 12 transport
identities, all 18 legitimate posts reached the receiving socket after any
needed reconciliation, and a fresh post arrived after restart. The cache stayed
at or below 256 items with 255 evictions, and the reopened journal was 380,293
bytes. Socket writes are not counts of accepted or forwarded spam. These host
results do not establish phone throughput, battery cost or nationwide capacity.

The separate `test/continuous_spam_delivery_test.dart` keeps four signed-news
senders active with one attempted post per second per sender and staggered
transport-key changes. A legitimate writer sends every 15 seconds through the
same relay to a real receiving engine. The receiver uses normal inventory
reconciliation, without test-issued requests for the legitimate posts. Production
one-minute traffic windows stay enabled. The default workload lasts two minutes;
set `FT_CONTINUOUS_SPAM_SECONDS=600` for ten minutes. Assertions require delivery
during each complete minute, no legitimate post waiting two minutes, bounded
cache/journal sizes, continued offered traffic, and durable legitimate news after
both stores reopen. The fixture replaces manually pinned transport identities;
it does not exercise hostile automatic admission. This paced workload fills the
cache but is below the global frame limit, so it does not establish fair delivery
when attackers exhaust the shared ingress budget.

The ten-minute run on 14 October 2026 passed: four senders wrote 2,074 signed
spam frames across 36 transport-key changes, and all 40 legitimate posts reached
the reader and survived reopening both stores. At least one legitimate post
arrived in every minute of the workload. The largest observed delivery delay
was 22,708 ms, measured using one host monotonic clock; this includes polling
and host test overhead. The longest gap between any sender's successful socket
writes was 12,457 ms, including reconnection work. The cache reached 256 posts
and the largest sampled journal was 1,900,304 bytes. Socket writes still do not
count accepted spam, and host loopback timing is not a phone/carrier benchmark.

In the 0.8.11 implementation, the aggregate-budget regression passed its recovery
extension: after four
senders exhaust the shared frame allowance, an affected fifth peer reconnects
with the same identity after the fixture's 30-second window resets and delivers
new signed Persian news to another connected reader. No engine restart, cleared
store or identity replacement is needed. This checks recovery after the load
ends; it does not promise delivery while attackers repeatedly exhaust the budget.

The 0.8.12 change addresses that connection-level starvation: half of each global
traffic budget remains shared, while the other half is reserved across eight
connection slots. Retired slots keep their spending until the window resets,
preventing replacement identities from minting aggregate allowance. The new
TLS regression subjects four senders to the original frame-exhaustion workload
while a separate writer and reader exchange signed Persian news before reset.
It fails against the committed 0.8.11 engine and passes with reservations. It
also verifies that a limited sender can reconnect after reset without losing
its identity. Component checks cover all seven resource types, stale leases,
window resets, repeated connection churn and randomized aggregate accounting.
This protects connection allowances; it does not guarantee that useful content
wins against many valid spam publishers, or that a fresh peer gains a slot.

The append-failure regression obstructs the journal path only inside a disposable
fixture. A failed publication cannot enter the in-memory news/outbox, subsequent
writes remain blocked until recovery, committed posts survive reopening, and a
reserved sequence is not reused. Three additional host trials terminated the
writer process without a clean shutdown around its seventeenth save; all 16
previously acknowledged posts and outbox records survived each restart. These
checks cover filesystem errors and process termination, not a physically full
phone or loss of power during flash writes.

Still required: longer and higher-rate signed spam, including global-budget
exhaustion and hostile automatic admission while honest traffic continues;
recovery after resource exhaustion; real low-space/crash
tests; low-end Android CPU/memory/flash/radio measurements. The single global
discovery topic and bounded all-channel gossip need a scalable routing design
and benchmarks before mass rollout. Sharding must retain small-network and
partition recovery, avoid publishing subscription rosters, and limit lookup
traffic. Test 10–20 consenting devices before 100; do not describe a simulation
as million-device validation or rate limits as Sybil resistance.

## 5. Publisher authority and security

Legacy encrypted backups recover lost keys. Editor revocation is implemented.
Legacy backups do not revoke a stolen owner key. The experimental 0.8.9 upgrade precommits an
independent recovery authority before compromise, keeps its private key off the
publishing device after export, and authorizes replacement online keys through
signed increasing generations. A compromised online key must not be able to
advance those generations, replace the recovery authority or win with an
arbitrarily large ordinary policy revision.

The implementation preserves v1 channel access and provides an explicit new-channel
migration choice. Its tests exercise
rollback and cross-channel proofs, competing recovery actions, restart and
independent proof persistence. The UI identifies unknown/conflicting authority.
Recovery, old-owner replay, deletion, stale backups and a fresh receiver through
a relay have local test coverage. Old-generation news leaves the active cache
after recovery; timestamps cannot prove pre-compromise authorship. V1 metadata
is not reinterpreted as protected by a new key. Android file-picker checks now
confirm cancellation leaves authority unchanged, and saving a replacement kit
rotates authority and prunes old-generation news on a mobile-data Samsung.
Independent review remains required.

The separation of offline trust and online authority is informed by the
[TUF specification](https://theupdateframework.github.io/specification/latest/).
This is a separate channel protocol, not an implementation of TUF. See
[owner recovery](CHANNEL-OWNER-RECOVERY.md) for implementation limits, including
the bounded permanent proof store and offline freshness.

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

The 0.8.9–0.8.10 reader review adds compact news cards with a details sheet, a consistent
local unread counter and unread-only channel filter, less crowded channel
actions, and Farsi/English narrow-screen checks at larger text sizes. Channel
timelines identify their source once, followed channels leave Discover, and
literal web addresses open externally only when tapped. Link rendering leaves
the signed/copied text intact and never requests automatic previews.
Settings now groups reader and network preferences outside Connection. Unread
is part of the top channel selector; the advanced guide and diagnostic counters
respect the selected Farsi/English language. News details groups local times,
delivery route and signature information in separate sections.
Version 0.8.11 stores an optional public writer nickname in Settings and reuses
it for new posts across channels. Restart, validation, failed saves and composer
review have regression checks. Advanced test-message metadata starts collapsed.

The 14 October follow-up adds the signed-spam regression without changing app
code or the 0.8.11 APK. Static analysis passed and the complete Flutter suite
passed all 534 tests with two concurrent test workers after adding the storage
failure regression (533 passed before that addition). The first full run had
one timeout in the existing UDP discovery test; its six-test file passed in
isolation and the subsequent full run passed. This intermittent failure remains
recorded rather than being counted as a clean first run. Overlay/native code
was unchanged from the previously verified build.

The subsequent continuous-load check passed at both two and ten minutes. All nine
traffic-limit tests passed after extending the aggregate-budget recovery case,
and static analysis passed. These targeted runs follow the 534-test full-suite
run above; that earlier full run predates the new continuous-load test. Only tests
and documentation changed, so the verified 0.8.11 application and APK are unchanged.

The first 0.8.12 full run had 545 passes and one repeated-spam failure: an honest
connection closed with an incomplete frame while APK compilation was running
concurrently. That fixture passed in isolation before adjustment. Its synchronous
transport-key/signature preparation was moved before live connections, avoiding
test-induced relay event-loop stalls. Its socket reader now accepts only
newline-terminated frames, while assertions still require the honest links to
remain connected and deliver during every flood. Application deadlines and the
offered flood workload were not relaxed. The original close reason was not
recorded, so it cannot be attributed conclusively to host load; disconnect events
now retain the bounded local reason code for future diagnosis.

On the final 0.8.12 source, static analysis passed and all 546 Flutter tests passed
with two workers in 7 minutes 29 seconds, with APK compilation run separately.
The repeated-spam case delivered all 18 legitimate posts across three rounds and
a new post after restart; the cache stayed at 256 items or fewer. All 22 overlay
checks and 18 native JUnit tests in eight suites also passed. These are local
regression results; the deferred field and independent-review work above remains
unverified.

Release 0.8.12 was installed in place on the Samsung S21 Ultra (ARM64, version
code 2023) and the API 36 emulator (x64, version code 4023), using the existing
signing certificate. The phone APK is 32,261,817 bytes. The existing recovery
channel published a fresh Persian test post from the emulator; it appeared on
the Samsung with one local unread item, a valid signature and a saved peer-network
receive time of 21:12:25 local time. Existing channel rows and earlier news remained
available. This is a reachable-peer update check, not a new shutdown or carrier
isolation trial. No app data was cleared and no radio settings were changed.
Temporary input/dump files were removed from the devices after inspection.
