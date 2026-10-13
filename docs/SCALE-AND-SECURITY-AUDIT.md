# PersianTrend 0.8.0: delivery, storage and scale review

Review date: 2026-10-13. Scope: current Flutter/Dart application, Android
transport bridge, bundled Hyperswarm worklet, protocol, local persistence and UI.
This is an engineering review with automated tests and a small device trial,
not an independent security certification or a million-device deployment test.

## Decision

Continue controlled, consenting small-group tests. **Do not describe this build
as validated for one million users, nationwide shutdown delivery, anonymous
publishing, or guaranteed delivery within five minutes.** The main scale
blockers are discovery concentration, all-channel gossip, finite retention,
Sybil resistance and background availability. A million installations is not a
million reachable, awake forwarding devices.

## Changes made during this review

| Issue | Change | Verification |
| --- | --- | --- |
| Arrival order could affect the feed; mixed sequence/time comparison could cycle after a clock rollback | One deterministic timeline shared by channel view, channel preview and feed; each writer's signed sequence is preserved | 200 input permutations; multi-writer real TLS delivery in reversed order; equal times, rollback, duplicates, restart |
| Send and receive times were not clearly separated | Signed UTC send time and private first-receive time displayed in this phone's local timezone, including offset and seconds | Farsi/English widget tests; Samsung native display |
| A slow connection delayed sending news to other connections | Ordered sends per link, independent fanout, bounded background batches and write queues | Existing TLS relay, deadlines and rate-budget recovery tests |
| Network replacement left old transport sockets; application cooldown could become a permanent firewall ban | Sample the local network epoch, restart transport after changes, allow routine reconnects and expire application cooldowns outside the firewall; stale route teardown cannot disconnect a replacement | Network-epoch and cooldown tests; real-device recovery results below |
| Duplicate news repeated expensive signature/native-state work | Drop already admitted content hashes early; use the verified stored object for any diagnostic receipt | TLS duplicate and forged-repeat test; first receive timestamp unchanged |
| Outbound queue pressure could punish an innocent peer | Defer at our queue limit; reconcile later from inventories | Full protocol suite, egress recovery tests |
| Cached read/seen IDs could be evicted during unrelated churn | Preserve IDs of currently cached news when pruning private state | 3,000 unrelated arrivals, restart, no false unread/repeated alert |
| Repeated posts could generate repeated sounds | Aggregate news notification; at most one alert request per minute per process; silent updates respect dismissal | Android compile/device delivery; unit coverage of mute/global switches; acoustic behavior not instrumented |
| Diagnostic histories had count limits without sufficient byte limits | 8 KiB per sanitized event; compaction retains at most 512 KiB event data and 2 MiB receipt data | Variable-size history regression and local stress workload |
| A large snapshot could trigger compaction on every append | Compact after 4 MiB additional journal growth or 2,048 records; guard recovery record size; remove completed backup | Restart/byte-limit tests and stress run |
| Crash residue could retain unfinished images | Delete only known content-addressed `.next` image files at startup | Media/restart validation; image integrity tests |
| Very tall images could create excessive card layout | Bounded 360 logical-pixel image display height | UI inspection and layout suite |
| Numbers could imply total network knowledge | “Saved channels” means local cache; active connections, private unread counts and Farsi digits kept distinct; invalid/nonfinite numeric input handled | Connection-count UI tests; narrow/large-text layouts |
| Crowded composer and unclear mute control | Spaced channel/text/image/nickname controls, white fields, compact owner actions, explicit Mute/Unmute and reader settings shortcut | Farsi/English rendered review and layout tests |

Earlier changes in this release also cover independent protected channel keys,
encrypted recovery files, scoped editor grants/revocation, signed nicknames,
owner-signed news/channel removal, bounded compressed images and local unread
state. Recovery never intentionally stores the password. This is not a promise
that immutable strings or a compromised unlocked device can be securely erased.

## Time and ordering contract

`createdAtMs` is signed UTC milliseconds supplied by the writer. The first
durably accepted `receivedAtWallMs` is recorded locally and never retransmitted
as an ordinary reader receipt. Duplicates do not overwrite it. Missing legacy
observations remain unavailable; local publications do not invent a receive
time. Both timestamps are converted to the viewing device's current timezone.

For the retained set, posts are grouped by channel and writer, ordered by signed
sequence, and assigned a derived nondecreasing send-time rank within that
writer. Writers are merged by that rank with stable writer/channel/sequence/ID
ties. Original signed timestamps remain unchanged. The same retained set yields
the same order regardless of arrival order or reader timezone. Channel chat
shows oldest above newest; the combined news feed shows newest first.

Clocks are untrusted. Uncoordinated writers cannot prove exact physical
chronology. A malicious writer can claim a misleading time; clock rollback
normalization is relative to the retained set and can change after eviction.
Conflicting posts with the same writer/sequence are deterministically ordered,
not proof of which was first. A future strict causal ordering protocol would
need signed logical clocks and a documented skew/abuse policy. A blockchain
does not fix incorrect sender clocks or disconnected devices.

Do not subtract two phones' wall clocks to measure delivery. In the device
trial the Samsung clock was about one second behind the emulator. Host
monotonic observation bounds are reported separately, with sampling/UI costs.

## Enforced per-device bounds

| Resource | Bound / behavior |
| --- | --- |
| Connected peers / known peers | 8 / 16 in the core; overlay also bounds its connections |
| Incoming simultaneous handshakes | 4; admission attempts 16 per address / 64 globally per window |
| Frames | 32 KiB; 600 per peer / 2,400 globally per default minute |
| Core input | 1 MiB per peer / 4 MiB globally per default minute |
| Core output | 512 KiB per peer / 4 MiB globally per default minute |
| Request items | 512 per peer / 2,048 globally per default minute |
| New channel signatures | 8 per peer / 32 globally per window |
| Unknown policy attempts | 32 per peer / 128 globally per window |
| Outbound writes / background batches | 32 queued writes per link / 16 gossip batches; absolute deadlines |
| News text / signed envelope | 1,024 UTF-8 bytes / 16 KiB |
| Public metadata | 128 channels, 16 per publisher; private managed channel keys protected separately |
| Cached news | 256 overall, 64 per channel, 96 per signing publisher |
| Outbox / diagnostic receipts / events | 256 / 2,048 / 800 rows, with additional diagnostic byte trimming at compaction |
| Reader state | 2,048 read and 2,048 seen IDs, 128 muted channels; currently cached IDs protected during observation |
| Channel key vault | 1 MiB serialized limit; 32 entries, 8 pending requests; new active managed channels limited to 16 |
| Editors / removal policy | 8 active editor grants; 24 individual removals, author floors and up to 64 retained IDs |
| Images | JPEG, 96 KiB, 1,280 pixels per dimension; optional, independent of text; no Bluetooth photo bytes |
| Image cache / transfers | 8 MiB / 96 files; 4 global and 2 per peer in-flight downloads; 4 KiB chunks; 120-second lifetime |
| DHT hints | 32 public nodes, 8 peer keys, 16 KiB saved routing file, 7-day hint lifetime |
| Journal | 16 MiB maximum recovery record; compaction after 4 MiB growth or 2,048 records; temporary generations consume extra space |

These are protection limits, not capacity promises. Rate limits can defer valid
news. Once cache history is evicted, this phone cannot guarantee recovery of
that history or a complete historical unread count. Storage figures exclude
the APK, extracted native libraries, Flutter/OS caches, user-exported encrypted
backups and temporary compaction generations. There is no universal total
installed-size cap. Disk-full handling must preserve keys, fail writes without
claiming delivery, and be included in physical-device field tests.

## Million-user architecture gaps and required work

| Priority | Gap | Required evidence or change before mass rollout |
| --- | --- | --- |
| P0 | One public discovery topic concentrates announcements/lookups | Design and benchmark partitioned discovery with rendezvous diversity, small-network compatibility, bounded lookup rates and cold-start recovery; obtain infrastructure capacity evidence |
| P0 | Every phone relays a bounded selection of all public channels | Design a scalable content-routing/retention scheme and quantify interest leakage; followers must reliably obtain their channels without turning subscriptions into a public roster |
| P0 | Many valid identities can consume connection/cache/admission budgets | Adversarial tests and a Sybil/eclipse mitigation design; per-key caps or trust votes do not establish unique people |
| P0 | Iran shutdown ingress/domestic reachability unmeasured | Consenting field tests on multiple providers, fresh/cached discovery, international blocking and real remaining ingress; avoid treating geography as evidence of domestic routing |
| P0 | Addresses, timing and app participation remain observable | An explicit threat model and independent assessment before any high-risk safety/anonymity claim; current mode is direct delivery, without Tor or Katzenpost |
| P1 | Android background availability and battery drain | Unplugged 30-minute, two-hour and overnight trials across Android/OEM versions, battery saver, Doze, force-stop and permission changes; distinguish existing links from finding new neighbors |
| P1 | Publisher clock lies, duplicate sequences and restored owner replicas | Define publisher conflict and future-clock policy; prefer distinct scoped editor keys over copying an owner's recovery file to concurrent writers |
| P1 | Offline or new peers may not know revocation/removal | Define retention and distribution of tombstones, revocation freshness and rollback policy; maintain explicit limits on remote erasure claims |
| P1 | UDP blocked, restrictive NAT, routing-cache poisoning and provider partitions | NAT/provider matrix, peer diversity/rotation and reconnection testing; cached hints are untrusted reachability hints, not authorization |
| P1 | CPU, flash-write amplification, native runtime memory and radio overhead | Profile low-end Android devices under valid signed spam and long sessions; account for DHT traffic outside the core's byte budget |
| P1 | Update/signing/recovery operational risks | Reproducible build verification, signing-key backup/rotation plan, dependency/CVE review, independent crypto/native audit and authenticated release distribution |
| P1 | Total storage under full disk/crashes | Physical-device low-space/power-loss testing; verify encrypted-key preservation and application/OS cache behavior, not only host journal tests |
| P2 | iOS and physical Bluetooth/Wi-Fi Direct matrix | Apple-device implementation/validation and several real Android radio pairs; emulator Internet success does not validate a Bluetooth mesh |

For a staged rollout, freeze a protocol/build and test with 10–20 consenting
devices, then 100, then a larger group after the discovery/routing blockers are
resolved. Record all attempts, missing deliveries, discovery delays, per-route
failures, retention loss, CPU/memory, battery and byte counts. Define a delivery
SLO for each condition before the trial. Stop increasing scale when those
thresholds fail; do not infer national coverage from a few successful phones.

## Recorded workload and capacity results

The local stress run used 1,536 signed near-limit text posts from three signing
keys across 24 channels, followed by 900 deliberately large diagnostic events.
It retained exactly 256 news items, 24 channel records and 84 events after
compaction. All retained news IDs survived restart. The compacted journal was
1,183,749 bytes; journal growth during news insertion peaked at 3,553,088 bytes.
The complete run took 622,963 ms, including signing, durable writes and restart
signature verification. This is a desktop workload, not an Android throughput
result; measured cost varied with cache size and host activity. Verification of
1,000 editor posts took 3,539 ms on the same host and is not a low-end phone
performance guarantee.

Measured bulletin frames for the model were 1,576 bytes for owner text and
5,710 bytes for an editor post including its authorization. With seven outgoing
copies and the current per-link/global budgets, optimistic forwarding ceilings
are about 333 owner posts/minute or 92 editor posts/minute **before** discovery,
inventories, metadata, policy, image and transport overhead.

| Global publishing workload | Ideal 256-item cache turnover | Owner-text demand / per-link budget | Editor demand / per-link budget |
| --- | --- | --- | --- |
| 100 publishers, one post each per ten minutes | 25.6 minutes | 0.03× | 0.11× |
| 1,000 publishers, one post each per minute | 15.36 seconds | 3.01× | 10.89× |
| 20,000 publishers, one post each per minute | 0.768 seconds | 60.12× | 217.82× |
| 1,000,000 publishers, one post each per ten minutes | 0.154 seconds | 300.60× | 1,089.10× |

These turnover values assume every global post is admitted. Actual bounded
admission rejects/defers/evicts posts and does not provide that coverage. They
demonstrate why changing numeric limits alone cannot make all-channel gossip
scalable. A million mostly-readers is a different workload from a million
publishers, but hot-topic discovery and awake/reachable peer availability still
need real measurements.

The offline graph uses four independent reciprocal random cycles, at most eight
neighbors per node, ten initially informed active nodes and independent edge
availability. It omits real discovery, rate limits and correlated partitions.
With 90% nodes active and 80% links usable it reached 900,352 nodes; with 50%/50%
it reached 412,833; with 20%/50% it reached only 76. With zero ingress seeds it
reached zero. These are sensitivity examples for an idealized graph, **not**
delivery predictions for PersianTrend or Iran.

The Samsung mobile-data trial observed a fresh emulator publication within
3,859 ms, with Samsung Wi-Fi and Bluetooth off. The installed test build
displayed signed send time, local receipt time and a signed nickname. Generic
news notification output contained no article text. Earlier in this review,
locked mobile-data receipt was observed within 3,000 ms and an optional
compressed image within 17,187 ms; those earlier trials preceded the final
reconnection patch. The first two offline/network-change trials failed to
reconnect within 120 seconds and prompted that patch. They remain failed
attempts in the record, regardless of later successful trials.

After the final reconnection changes, a new offline publication reached the
Samsung automatically within 73,829 ms of restoring the emulator's Wi-Fi. No
application restart or manual synchronization was used during that recovery.
A fresh reverse-direction Samsung mobile-data publication reached the emulator
within 3,562 ms. Samsung Wi-Fi and Bluetooth were off in both trials.

The final emulator idle smoke test confirmed deep idle before publication and
after observing a new post. The screen remained off and the post was observed
within 3,922 ms, without a permanent battery exemption for the test package.
The emulator had no secure keyguard, so screen-off is not evidence of a locked
physical phone. This was a short forced-idle trial over USB/ADB, not an OEM
overnight or low-power-standby result; temporary OS allowlists were not fully
characterized. Its previously disabled deep-idle setting was restored afterward.

The final automated run passed 321 Flutter tests; the discovery, cooldown and
routing-cache Node suites passed ten tests. Static analysis reported no issues.
The distribution binary uses the production package/topic and omits the test
device-probe export path. Its signing certificate matches the installed release.

Hosted Pub advisory lookup checked 73 pinned packages and returned no matching
advisory; npm audit returned zero advisories for the pinned overlay dependency
tree. These scans exclude the SDK, native artifacts, Android Gradle components
and local forks and do not prove the absence of vulnerabilities.

## Reproducing the local workload and offline model

Run from the project root after dependency installation:

```text
dart run tools/scale_audit.dart
python tools/scale-model.py
```

The Python model requires NumPy. All generated data stays under
`.local-only/scale-audit/`, excluded from Git. The Dart workload creates only
disposable local signing keys in memory and public cache records; it does not
open network connections. The Python model constructs a fixed one-million-node,
eight-neighbor random graph locally. It is **not** a load test of the APK or
HyperDHT. Its single-message graph omits discovery delay, correlated partitions,
queue budgets, CPU, radio sleep and cache loss; its results are optimistic
sensitivity examples, not forecasts. A separate model uses measured frame sizes
to expose the forwarding/cache limits of all-channel gossip.

## Platform references

Android documents that Doze restricts background network/CPU access and provides
explicit idle/standby tests. A foreground service alone is not a universal
five-minute delivery guarantee. [Android power-management guidance](https://developer.android.com/training/monitoring-device-state/doze-standby)

Hyperswarm uses topics for discovery and attempts peer connections. HyperDHT
documents bootstrapping and NAT traversal. Those mechanisms depend on reachable
network paths; they cannot connect a disconnected national partition by
themselves. [Hyperswarm](https://github.com/holepunchto/hyperswarm),
[HyperDHT](https://docs.pears.com/p2p/reference/building-blocks/hyperdht/)
