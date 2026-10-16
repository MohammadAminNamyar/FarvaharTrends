# Publisher-protection laboratory results — 16 October 2026 UTC

This is an interim evaluation. The publisher-protection objective is incomplete. There is no new
publisher-protection APK and no anonymity claim. FarvaharTrends 0.8.14 separately
contains production CPU/rendering optimizations; it does not include this
experimental protocol. Phone CPU samples for that update are not experimental
protocol resource or battery measurements.

## Encrypted envelope implementation (x2) — 16 October 2026 UTC

The implementation now uses RFC 9180 base mode with X25519, HKDF-SHA256 and
ChaCha20-Poly1305. `test/hpke_test.dart` checks Appendix A.2.1's exact ciphertext,
public keys and decryption, plus wrong keys, modified ciphertext/AAD, truncated
boxes and invalid X25519 shared secrets. This is a small local RFC construction
using the `cryptography` primitives, not an independently audited HPKE package.

`EnvelopeCryptoWorker` keeps each engine's private envelope key and crypto work
in a persistent separate isolate. The entry opens an 8192-byte outer box to get
an exit id and an 8112-byte inner box. The exit opens the inner box. The lab pins
recipient keys independently of network input. Every seal uses a fresh ephemeral
key. Domain separation and AEAD authenticate both layers. There is no cover
traffic, recipient-key rotation, recipient-compromise forward secrecy or claim
that two hops prevent timing correlation. A distinct `envelope-x2-stub` feature
selects the deliberately insecure comparison codec with the same sizes and IPC.

`protected_runtime.dart` adds a synthetic internal admission context sharing the
actual entry connection's allowance. It does not acquire a new budget slot or
charge received bytes twice. Decryption and object admission consume separate
receiver-wide budgets (256 and 64 per traffic window), including reserved shares
that reconnecting under new identities cannot replenish. Ordinary signature,
channel and retention checks still apply. Invalid opaque publisher data does not
become a transport strike against the forwarding entry.

Storage and lifecycle bounds:

- At most 100 publisher records, 2 MiB of private pending images; echoed records
  can make room, failed unsent publications are not silently discarded.
- At most 64 entry cells, at most 24 from one entry client; acknowledgement only
  follows durable append. Exit acknowledgements are accepted only from the
  selected exit; publisher acknowledgements only from its configured guard.
- At most 16 incomplete exit objects, four per physical entry, 24 fragments per
  object and 128 KiB per reconstructed bundle. Entry/exit state expires after
  ten minutes. Completed fragment bodies are removed from live state; bounded
  replay markers remain. Replays still consume decryption budget.
- Checksummed append journals, bounded compaction and backup recovery; only an
  incomplete final record is ignored. A corrupt committed record fails closed.
  Pending, entry and exit WAL caps are respectively 3, 3 and 4 MiB; state caps
  are 1, 1 and 1.5 MiB. Compaction temporarily needs snapshot/backup space too.
- Pending image bytes never enter the public media cache. Echo removes their
  private copy; the publisher downloads the public image like a reader. Files
  are app-private, **not encrypted at rest by this prototype**.

The image-reference scan is replaced by an admission/eviction index in
`PilotStore`. The regression exercises 6,400 hash lookups without reading any
cached bulletin envelope, and checks shared hashes, local publishing policy,
revocation, retention and reload.

### Measurement corrections

The long test now requires `FT_STAGING_RUN=1`; it is skipped in the ordinary
suite. Production 512 KiB per-peer egress is the default, and overrides are
recorded. The two arms have matching observation windows and payload lengths,
alternate phase order across sessions, and compare admission at the same reader.
Reported added delay is a per-pair subtraction; public release delay is separately
labelled. Startup, failures and recovery are separate from ordinary delivery.

The earlier harness also defaulted each engine's publisher key to its connection
key. Excluding raw identities from classifier inputs did **not** remove the
observable equality between these keys. Those runs cannot support a claim of no
tested publisher linkability. The corrected harness uses fresh, independent
connection and signing identities for both candidate publishers, as the app does,
and explicitly checks their separation in released objects. Earlier latency
numbers remain historical host measurements, not anonymity evidence.

The release boundary is now the exit's local admission timestamp, rather than
the observer's later receipt. A pre-release white-box inspection checks the
publisher's public object store, image index and public media cache. Four unrelated
public-id probes overlap publication/sealing; the old post-release duplicate probe
is still recorded separately. All six engines share their ordinary Dart isolate:
relative response timing cannot establish independent-device indistinguishability.
CPU includes all engines, workers, probes and runtime; it is not phone CPU or battery.

### Gates that remain

The normal application never constructs `EnvelopeExperiment`. No production
protected publishing UI, APK or automatic guard-key discovery is enabled here.
Recoverable channel creation, key management and policy/authority operations are
not yet staged by these laboratory entry points. Malicious-entry isolation,
access-link/carrier observation, field shutdown reachability, key rotation,
independent security review and phone energy measurements remain unresolved.
The lab must not describe publishers as anonymous or the five-second requirement
as a network-wide guarantee.

### Corrected exposure runs

The corrected harness completed three fresh sessions in each mode, with five
ordinary publications per phase per session (one channel, two text posts, two
image posts). Separate signing/transport identities, production egress limits,
public-id probes during sealing, equal observation windows and the actual local
release boundary were used. Raw files:

- Stub: `artifacts/privacy-lab/staging-9-2-2026-10-16T21-35-35.562094Z.json`.
- HPKE: `artifacts/privacy-lab/staging-9-2-2026-10-16T21-41-31.623933Z.json`.

Each mode detected the direct-publishing positive control, completed all 15
staged objects, had zero pre-release frame violations and 15 clean pre-release
public-state inspections. In HPKE, all six image publications were fetched by
both publisher and matched reader; all released signing identities differed
from the publisher's connection identity. First observer sighting was a relay
for all 15 HPKE objects. This does not mean a post-release publisher forward
must always arrive later than every relay's frame on every network.

HPKE publisher-first forwarding rates were 0.4, 0.4 and 0.6 across sessions;
the illustrative t-interval for the mean is 0.18–0.75. Median forwarding-latency
differences had an interval of −90 to +60 ms. These small runs are not an
equivalence test and do not exclude smaller or untested distinguishers. The
duplicate response probe again had zero median difference and remains
uninformative. Concurrent public-id probes are recorded, but the shared ordinary
engine isolate prevents interpreting them as independent handset timing evidence.
Degenerate point intervals in the saved summaries mean zero sample variation,
not zero uncertainty; the reporter now suppresses these intervals.

### Paired delivery instrument without observer probes

`test/protected_latency_test.dart` separately measures delivery using a local
publication-id hook and the same reader's durable-admission hook. No snapshot,
invented-id probe or observer classifier runs during a timed publication. Three
independent sessions each use the same identities and payload lengths across
three fresh-store arms, with Latin-square mode order. There are three unmeasured
warmups per arm and twelve measured posts, including two images. All 108 measured
deliveries completed (36 per mode), using production budgets and established
loopback TLS routes. This is a performance instrument, not an anonymity test.

Raw: `artifacts/privacy-lab/paired-envelope-2026-10-16T21-44-45.064604Z.json`.

| Same-reader admission, 36 posts per mode | Median | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Direct | 229 ms | 357 ms | 479 ms |
| Matched stub | 499 ms | 868 ms | 892 ms |
| HPKE | 588 ms | 1,075 ms | 1,259 ms |
| Stub minus its matched direct post | 284 ms | 615 ms | 639 ms |
| HPKE minus its matched direct post | **354 ms** | **867 ms** | **1,056 ms** |

Added delays are calculated per matched post, then summarized; they are not
differences between aggregate medians. These 36 pairs were below five seconds,
which is evidence for this host's warmed loopback path only. It does not bound
physical networks, discovery, failures, battery-saver scheduling or malicious
participants. The six HPKE image-completion pairs added 444 ms median and
950 ms maximum; these images use the small JPEG fixture, not the maximum size.

Whole-process CPU during the measured posts and equal 250 ms drains averaged
272 ms per post in direct mode, 391 ms in stub mode and 417 ms in HPKE mode.
This includes **all four engines**, their crypto workers and runtime. It is
additional work, not a claim of negligible phone cost. Setup after identity
generation took 1.7–1.9 seconds median by mode, with a 3.5-second maximum;
identity generation, peer discovery and handset startup are not included.

### Recovery and maximum-sized media

All five HPKE recovery scenarios completed with zero pre-release exposure, using
the normal 10-second acknowledgement and 30-second echo deadlines. Raw:
`artifacts/privacy-lab/staging-9-2-2026-10-16T21-49-16.272468Z.json`.

| Scenario | Reader admission from publish | Publisher attempts |
| --- | ---: | ---: |
| Entry resumes forwarding after acknowledgement | 0.93 s | 1 |
| Exit withholds; publisher retries another exit | 31.64 s | 2 |
| Publisher restarts before acknowledgement | 10.96 s | 2 |
| Publisher restarts after acknowledgement | 0.99 s | 1 |
| Exit restarts with a complete held image object | 7.06 s | 1 |

Reader admission is at the continuously running matched reader, so a reader can
receive while the publisher is restarting. These are recovery totals, not
ordinary-route added delays. The five-second requirement is **not** met across
these failures. No failure falls back to direct publication.

One additional run used a valid JPEG padded with comment segments to the
96 KiB image limit. The encrypted image post used one publisher attempt, reached
the reader in 4.48 seconds versus 0.83 seconds for its direct comparison (3.65
seconds added), and both publisher and matched reader fetched its public image.
No pre-release data appeared. This is one size-boundary sample, not a tail-latency
guarantee or a rendering/decoding benchmark. Raw:
`artifacts/privacy-lab/staging-9-2-2026-10-16T21-50-42.024969Z.json`.

### Reproduction and validation

Use the repository's `.tooling/flutter/bin/flutter.bat` and set `PUB_CACHE` to
`.tooling/pub-cache`. Run these serially; do not run the long experiments
concurrently with the suite or each other.

- Normal regression suite: `flutter test --no-pub --concurrency=1`.
  The continuous-spam workload now defaults to 180 seconds (three production
  traffic windows); its full-cache, progress and durability assertions remain.
- RFC, worker, journal, index and relay tests: `test/hpke_test.dart`,
  `test/envelope_crypto_worker_test.dart`, `test/bounded_journal_test.dart`,
  `test/image_reference_index_test.dart`, `test/connection_budget_test.dart`,
  `test/protected_relay_test.dart`.
- Exposure comparison: set `FT_STAGING_RUN=1`, `FT_STAGING_SESSIONS=3`,
  `FT_STAGING_PUBLICATIONS=4`, `FT_STAGING_IMAGE_EVERY=2`,
  `FT_STAGING_RETRY=0`, `FT_STAGING_RESTART=0`; run
  `test/protected_staging_experiment_test.dart` once with
  `FT_STAGING_CRYPTO=stub`, then with `FT_STAGING_CRYPTO=hpke`.
- Dedicated paired timing: set `FT_LATENCY_RUN=1`, run
  `test/protected_latency_test.dart` (defaults: three sessions, twelve samples).
- Recovery: use HPKE, one session, zero ordinary publications and both retry and
  restart flags set to `1`, leaving the default deadlines unchanged.
- Maximum image: HPKE, one session, one publication, `FT_STAGING_IMAGE_EVERY=1`,
  `FT_STAGING_IMAGE_BYTES=98304`, retry/restart flags `0`.
- Crypto microbenchmark: `dart run tools/privacy_lab/envelope_crypto_benchmark.dart`.

Unset the opt-in environment flags before the normal suite. The relay regression
checks authentication failures, replay, incomplete-object capacity across restart,
recovery without resubmission, rejection of envelope negotiation in the ordinary
engine, and discarding a bad signature instead of repeatedly re-verifying it.
Journal regression also checks that a failed compaction blocks further writes
until recovery reloads the committed state.

Validation on the final working tree:

- The serial full suite completed with **569 passed, two failed, two skipped**
  in `artifacts/privacy-lab/full-suite-x2.log`. The skipped cases are the two
  explicitly opt-in laboratory experiments, whose separate results are above.
- The 120-second continuous-spam run reached only 243 of 256 cache entries and
  failed its workload-saturation assertion. Its default duration was extended
  to 180 seconds, preserving all saturation, continuity, delivery and durable
  retention assertions. The rerun passed: 541 flood frames written, transport
  rotations `[3,2,2,2]`, cache 256, all 12 honest posts delivered and durable
  after reopening storage. Maximum observed honest delivery was 4,680 ms;
  the longest source write gap was 12,409 ms, below its unchanged 15-second
  bound. This is the existing ordinary-delivery stress test, not an encrypted
  envelope latency result. Log: `continuous-spam-recheck-x2.log`.
- The existing integrated radar test assumed a permanently scheduled Flutter
  frame. It now checks repaint activity and the unchanged zero-contact count,
  matching the already optimized timed-paint implementation. Its targeted rerun
  passed (`radar-integration-recheck-x2.log`); no radar implementation was changed.
- Four journal tests, five encrypted-relay tests and three radar regressions
  passed after the compaction-error safeguard (`final-rechecks-x2.log`). Including
  the two failure rechecks, **all 14 focused rechecks passed**. The complete
  29-minute suite was not rerun after these narrow fixes.
- `flutter analyze --no-pub` reported **no issues** (`analyze-x2.log`).

All logs named above are under `artifacts/privacy-lab/`. The initial failures
are retained as evidence; this is not a claim that the first full run was green.

### Isolated host cryptographic costs

`tools/privacy_lab/envelope_crypto_benchmark.dart` ran three independent worker
sessions per mode, with 20 warmup cells then 100 timed cells each. Every timed
cell includes two seals, entry and exit opens, IPC and JSON/base64 handling.
Modes alternate order across sessions. Raw output:
`artifacts/privacy-lab/envelope-crypto-2026-10-16T21-25-42.123111Z.json`.

| Host measurement | Matched stub | RFC 9180 HPKE |
| --- | ---: | ---: |
| Per-session median cell cycle | 4.26–4.65 ms | 24.36–26.10 ms |
| Per-session p95 cell cycle | 8.31–10.78 ms | 34.26–39.20 ms |
| Process CPU per cell | 5.78–6.88 ms | 23.59–26.41 ms |
| Ciphertext bytes across both hops | 16,304 | 16,304 |

These are host cryptography/IPC costs, not end-to-end added delay. They exclude
TLS, signing existing news, disk, rendering, radio activity and phone power.
The legacy RSA signer still uses the existing PointyCastle RSA engine; this
change does not establish constant-time or blinded signing. There is no added
idle cover traffic; ordinary discovery/inventory traffic still exists.

## Historical x1 section 9.2 staging experiment — 16 October 2026 UTC

The following records describe the earlier stub and its earlier harness, not the
current x2 implementation. In particular, apply the identity-reuse limitation above.

This is a laboratory result for the experiment specified in
`PUBLISHER-DESIGN-REVIEW.md` section 9.2 (as implemented, 9.2.1). It runs on loopback TLS
on one Windows host, with all six engines, the observers and the harness in **one Dart
isolate**, placeholder cell masking (a SHA-256 keystream anyone can remove), a
harness-configured guard and exit list, and the exit admitting relayed objects through
the ordinary receive path with the entry's link as the apparent sender. **No real
cryptography was measured. Nothing here concerns an observer of the publisher's
connection, carrier-level protection, or shutdown reachability; those remain
unresolved.** Production integration stays gated on these and later results. A pass
establishes only the tested reduction in exposure to ordinary peers at the stated
sensitivity.

Test: `test/protected_staging_experiment_test.dart`. In that version's regular suite it ran one
short session (6 publications per phase, retries on, restarts off, about three minutes);
the recorded runs used `FT_STAGING_SESSIONS=3 FT_STAGING_PUBLICATIONS=50
FT_STAGING_RETRY=1 FT_STAGING_RESTART=1` with `FT_STAGING_Z_MS` and
`FT_STAGING_IMAGE_EVERY` as stated per run; `FT_STAGING_ACK_MS` and `FT_STAGING_ECHO_MS`
default to the production 10,000 and 30,000. After the recorded runs the complete Flutter
suite was run with two workers: 551 passed, 3 failed; the two signed-spam loopback tests
passed when rerun in isolation (their failures were contention with the concurrent
twelve-minute experiment), and the live-radar widget test fails in isolation as well, in
UI code with uncommitted changes that predate and are untouched by this experiment. Code under test:
`lib/core/protected_publication.dart` plus hooks in `peer_engine.dart` and
`media_transfer.dart` that are inactive unless an `EnvelopeExperiment` is supplied; the
production APK does not supply one. The laboratory engines raise the per-link egress cap
from 512 KiB/min to 4 MiB/min because fifty publications in a few minutes exceeds any
real publisher; refused cells are counted and reported.

### Apparatus, detectors and unit of independence

Per session: fresh identities, keys and store directories for engines A, B, guard E and
exits R1 to R3; the publisher and control roles assigned to A or B at random; identical
link sets for A and B (E, R1, R2, R3, the observer P and the unrelated publisher Z); P
connected to all six engines as a pinned raw TLS peer that logs every frame and never
answers requests; Z pushing one unrelated signed post to A and B simultaneously at a
fixed cadence. Each session runs the positive control first (the current engine
publishing directly through `createChannel` and `publishToChannel`), then the staging
arm (`createProtectedChannel`, `publishProtected`), then the retry and restart
scenarios with the production 10 s acknowledgement and 30 s echo deadlines and three
attempts. The session is the unit of independence; comparative figures are per-session
medians with t-intervals across sessions and are marked inconclusive below three
sessions. Every publication carries a distinct image hash.

Deterministic detectors per publication: whether the first link at P to carry the
object is the publisher's; frames from the publisher's link mentioning the object id or
image hash before the first relay sighting, excluding the publisher's own requests for
ids the prober advertised (white-box pre-release rule); whether each role requests the
id when P advertises it right after composition (white-box, the harness knows the id);
whether each role completes a fetch of the post's image (white-box counters).
Comparative: which role forwards the object to P first and how long after release;
response latency to a probe inventory sent right after P pushes the object to both roles.

### Run 1 (3 sessions × 50 publications per phase, Z every 2.5 s, images every third post)

Run time 85 min 37 s; result `artifacts/privacy-lab/staging-9-2-2026-10-16T19-16-38.323068Z.json`,
log `staging-9-2-run1.log` (ignored directory). **The run overloaded the single test
isolate** and its comparative and latency figures are reported as invalid, not as
results. Whole-process CPU was 170 to 209 s in each positive-control phase and 358 to
552 s in each staging phase; the direct-publish baseline, which measured about 300 ms in
smoke runs, had a median of 827 ms, p95 8,515 ms and maximum 21,518 ms across 153
publications. The dominant cost is a production path, not the experiment: on every
inventory that advertises image hashes, `_requestImages` calls `_referencedImage` per
hash, which parses every stored bulletin (`lib/core/media_transfer.dart:44-55`), so with
up to 64 advertised hashes and 256 cached bulletins each inventory costs on the order of
ten thousand JSON parses per link. That is a production inefficiency worth fixing on its
own; it is not a privacy finding.

What run 1 does establish, because these detectors do not depend on timing:

| Detector | Positive control (current engine), 153 publications | Staging, 153 publications plus 8 scenario completions |
| --- | ---: | ---: |
| First link to carry the object is the publisher's | 153 / 153 | 0 / 103 released within the window; the other 50 had not released yet (slow, not exposed) |
| Frames from the publisher mentioning the object before any relay sighting | 153 / 153 | 0 / 156 |
| Request probe: control requests the id, publisher does not | 152 / 153 | agreement 155 / 156 (both request) |
| Own image not fetched by the publisher while the control fetched it | 32 / 48 image posts (16 undecided: control did not fetch in time under load) | fetched by both 16 / 33 decided image posts; rest undecided under load |

Scenarios under load: retry after entry withholding released in 34.7 and 56.9 s with
2 attempts; retry after exit withholding 31.4 and 38.9 s with 2 attempts; publisher
restart before acknowledgement released in 86 and 103 s with 3 attempts; publisher
restart after acknowledgement 85 s, 3 attempts; exit restart with a held image 72 s,
3 attempts; no pre-release exposure in any of them. Seven further scenario attempts did
not complete inside their 30 s waits and are recorded as inconclusive; one of them
exposed a real defect: two concurrent state changes tore a line of the pending journal,
which the restarted publisher could not parse. Journal appends are now serialized per
file and unparseable lines are counted and skipped. Resends were 102, 174 and 13 per
session, records that exhausted three attempts 8, 26 and 2, refused cell sends 3, 1 and
0. Storage at session end: publisher pending journal 322 to 379 KB, entry journal 1.35 to
2.49 MB (it retains every cell), exit journals 100 to 313 KB each. Publisher envelope
bytes sent 1.35 to 2.67 MB per session including resends, about 11 KiB per cell on the
current base64 JSON framing.

### Run 2 (3 sessions × 50 publications per phase, Z every 8 s, images every fifth post)

Result `artifacts/privacy-lab/staging-9-2-2026-10-16T20-13-38.103510Z.json`, log
`staging-9-2-run2.log`; test exit 0; about 53 minutes wall. Per session: 129 to 132
unrelated posts, publisher role A, A, B; startup to all links 2.5 to 4.5 s; positive
control phase 444 to 449 s wall with 76 to 83 s whole-process CPU, staging phase 280 to
285 s wall with 141 to 144 s CPU (the staging phase includes cell sealing and three
journals plus the harness; CPU is whole-process and not attributable).

**Positive control, 153 publications (3 channel creations, 120 text, 30 image).** First link
at P to carry the object was the publisher's in 153 / 153; the publisher's own frames
mentioned the object before any relay sighting in 153 / 153; the request probe showed the
control requesting and the publisher not requesting in 153 / 153; the publisher did not
fetch its own image while the control did in 30 / 30. Probe response latency, control
minus publisher, per-session medians +140, +116, +113 ms (95 % interval 86 to 160 ms over
three sessions). Direct delay from the publish call to the first sighting at P: text
median 288 ms, p95 872, p99 2,613, maximum 2,773; image median 307, p95 488, maximum 765.
The method detects every distinguisher listed in section 7.2 of the review at this scale.

**Staging, 153 publications plus 15 scenario completions.**

| Detector | Result |
| --- | ---: |
| Publisher frames mentioning the object before any relay sighting | 0 / 168 |
| First link at P to carry the object is a relay | 153 / 153 ordinary, 15 / 15 scenarios |
| Request probe agreement (both roles request the just-composed id) | 153 / 153 ordinary; the five disagreements in the summary are all restart scenarios where the probe reached the pre-restart link, an apparatus artefact |
| Own image fetched by both roles | 24 / 30; neither role within the window 5 / 30; publisher only 1 / 30; control only 0 / 30 |
| Publisher forwards its own article to P before the control | 0.519, 0.407, 0.353 per session; mean 0.426, 95 % interval 0.22 to 0.64: no preference detected, inconclusive for effects smaller than about 0.2 |
| Forwarding latency after release, control minus publisher | medians +29, −35, −57 ms; interval −132 to +90 ms: no difference detected |
| Probe response latency, control minus publisher | 0, 0, 0 ms; both roles were on the duplicate path, so this probe is weak in the staging arm |

Publish-to-release delay from the publish call to the first relay sighting at P (not paired added delay; stub, loopback,
shared isolate): text median 536 ms, p95 7,777, p99 9,950, maximum 12,052; image median
964, p95 9,570, maximum 9,926; channel creation 220, 316, 316 ms. 91 % of text and 87 % of
image publications were first seen within 5 s. Every slow case had a single attempt; the
tail is inside the `publishProtected` call itself (median 170 ms, p95 5.9 s, maximum
9.2 s, versus 138 ms and 547 ms for `publishToChannel`), that is, in the publisher's
serialized call path in the shared isolate before the first cell leaves, and the time
from sealing to the guard's acknowledgement reached 9 s in isolated cases. The cause is
not isolated here and must be profiled on the real implementation before any latency
statement. Resends 4, 5 and 6 per session from late acknowledgements; records exhausting
three attempts 0; refused cell sends 0.

Scenarios, three of each: entry withholding released in 34.1 to 35.8 s with 2 attempts;
exit withholding 30.9 to 31.4 s with 2 attempts; publisher restart before
acknowledgement 49.6 to 75.8 s with 2 or 3 attempts (the design's immediate resend after
restart did not occur: the resend waits for the guard link to come back and, in two of
three cases, the first resend was itself not acknowledged within 10 s; cause not
isolated); publisher restart after acknowledgement 43.3 to 47.1 s with 2 attempts (echo
deadline measured from restart plus restart time); exit restart with a held image 43.6
to 52.4 s with 2 or 3 attempts (the publisher's echo deadline elapsed before the restarted
exit released the held object, so a resend through another exit raced it; both released,
deduplicated downstream). No pre-release exposure in any scenario.

Storage at session end: publisher pending journal 306 to 310 KB for 56 objects, about
5.5 KB per object because every state line repeats the full object (write deltas);
pending image bytes 0 (deleted on echo); entry journal 1.07 to 1.13 MB because it keeps
every cell (needs pruning after the exit acknowledges); exit journals 75 to 123 KB.
Traffic: publisher envelope bytes 1.07 to 1.13 MB per session for 97 to 102 cells, about
11.0 KiB per cell on the current base64 JSON framing (an 8 KiB binary frame would be 27 %
less); the guard forwarded 94 to 99 of them, the rest withheld by scenario; the observer
received 0.51 to 0.59 MB per link over a session.

Two defects found and fixed during the runs, both in the experiment code: the exit did not
announce an image it received through a cell until its next periodic inventory (now
announced on admission, as after a completed download), and the publisher's echo
bookkeeping ran before its re-gossip and added about 80 ms to its forwarding latency (now
after). One production finding independent of privacy: the image-advertisement path
rescans every stored bulletin per advertised hash on every inventory
(`lib/core/media_transfer.dart:44-55`), which made run 1 unusable and would cost phones
with full caches on every inventory cycle.

### What this does and does not establish

- The positive control detects the first-source and request-probe distinguishers in
  every session, and the own-image distinguisher whenever the control's fetch completed;
  the method is sensitive to the known leaks at this scale.
- In the staging arm the pre-release rule held for every publication of every kind,
  including channel creation, images, retries and restart recovery; the first source was
  a relay for every object that released; the request probe agreed between roles. These
  are the tested leaks that disappeared.
- Comparative measures (who forwards first, forwarding latency, probe response latency)
  are reported with their intervals from run 2 only; where an interval includes zero
  the verdict is inconclusive, not a pass.
- These publish-to-release figures are stub figures on loopback with no cryptography in a shared
  isolate; they bound nothing about phones or carriers. The five-second requirement is
  not judged here; measurements with real encryption and storage must follow.
- CPU is whole-process per phase and confounded by phase duration, unrelated traffic
  and the image-inventory cost above; it is reported, not interpreted.
- The timing probe in the staging arm mostly compares duplicate-path responses, because
  the exit reaches both engines before the observer can push; it is weaker than in the
  positive control and must be repeated on the real implementation (E6).
- Not tested: real envelope cryptography and its timing, a dedicated relay ingress,
  guard-announced exit lists, cover traffic, any carrier or uplink observer, physical
  networks, battery.

## Frozen completion policy: v22

The opt-in candidate preserves the fresh reservation cutoff but permits exactly
two additional signed seconds to finish authenticated work already selected for
the round. It also requests a two-second schedule admission lead instead of four.
This is a security-sensitive experimental policy change, not a proven anonymity
improvement. Old strict-policy failures remain failures of their tested versions.

Native emulator regression passed **96 top-level tests, 243 including subtests
and fuzz seeds**, with no failures/skips. Real framed-TLS schedule checks passed
**19 checks and 9 messages**, including deliberately delayed completion without
selecting a new article. The independent native verifier checks 89 fingerprints.

The subsequent **300-pair run completed all 300 measured pairs**, plus both warmup
pairs, without failed or unattempted pairs. Each pair uses identical signed text
and channel objects through separate equivalent public stores, alternating direct
and protected order. Eleven private role processes share one Android x86_64
emulator; public stores and a single monotonic observer run on the host. Each
private RPC has configured 5,000 kbps per-direction pacing and 80 ms added delay.
These are shaped loopback/ADB measurements, not independently routed phones.

| Conservative added latency | Measured value |
| --- | ---: |
| Median | 2,950.658 ms |
| p95 | 3,907.773 ms |
| p99 | 4,135.477 ms |
| Maximum | 4,349.645 ms |
| First / second warmup | 3,376.223 / 3,060.373 ms |

No measured or warmup pair exceeded five seconds of additional latency. The
largest observation interval was 447.685 ms and is retained in the conservative
bounds. Bundles were 3,220–4,288 bytes. **This satisfies the local steady-session
text timing check only.** Cold anonymous setup took **6,050.279 ms** separately,
before these observations, excluding child launch. Discovery, cold/recovery
admission, signing, all-action coverage, real radios and UI are not represented
by the table; it does not establish five-second cold-start delivery.

The run is `android-pipeline-42a5264e0d1749a89c3594b984cc0ee8`; its pipeline is
`.local-only/privacy-lab/pipeline-8e562f7a/result.json`, role directory
`roles-3284200745`. `paired-300-analysis-v22.json` independently recomputes all
302 paired intervals and sample counts. `verification-v22.json` checks sealed
source/binary hashes, runtime policy, private telemetry, process cleanup and the
unchanged production APK. An initial verifier expected a nonexistent top-level
`candidate` field; it was corrected to check the sealed report's exact `experiment`
label plus the manifest selection and runtime signed policy. The raw result was
not changed. Final verification reports zero errors; all owned roles were reaped
and the temporary device directories removed.

No new CPU/traffic/battery claim follows from this timing run. Publisher-origin
protection, malicious-participant timing correlation, safe epoch recovery,
independent participant assumptions, all publisher actions and physical resource
acceptance remain incomplete. Production integration remains disabled.

## Framed transport over authenticated TLS: v21

The optional `cbor-framed-v1` laboratory transport removes HTTP headers while
retaining canonical CBOR bodies, the same pinned mutual TLS 1.3 identities and
all existing signatures, JSON cache hashes, checkpoints and common deadlines.
Each bounded frame carries a version, direction and length. A dedicated ALPN
prevents accidental protocol crossover; it is identifiable and does not hide
participation. Only one exchange per client connection and one protocol handler
per role may run at a time. Four connections per server, including incomplete
handshakes, plus handshake/header/body/idle/write deadlines bound socket work.
Ambiguous failures are returned without automatic resend or protocol fallback.

Targeted transport and codec checks passed eleven top-level tests, 51 including
subtests. They exercise fragmented/coalesced streams, truncation, oversize and
invalid headers, canonical decoder rejection, certificate/ALPN failures,
connection reuse, empty-message error handling, lost responses, concurrent busy
rejection, queued deadlines and cancellation during artificial link pacing.
The native emulator suite passed **89 top-level tests, 210 including subtests
and fuzz seeds**, with no failures or skips. These overlapping counts are not
additive. The real socket/common-schedule check passed all seventeen checks and
delivered all eight Persian messages, including an exact historical retry after
a role process restart. A subsequent guard ensures even an empty-message role
error remains a rejection; it is covered by the final targeted/native suites.

Evidence under `artifacts/privacy-lab`:

- `framed-final-tests-v21.jsonl`: eleven targeted tests.
- `android-pipeline-d3e781daf08b4923b1f90e00bde229e9`: scheduled framed checks.
- `android-pipeline-5c9da881372945669de6ba9776dbc262`: full native regression;
  `regression-verification-v21.json` independently checks 88 fingerprints.
- `plan-v21.json`: controls and measurements specified before the runs.

Fresh HTTP/CBOR and framed-CBOR runs each completed thirty idle rounds after five
warmups, with the same 5,000 kbps per-direction pacing and 80 ms added per RPC.

| Measurement | HTTP/CBOR | Framed CBOR |
| --- | ---: | ---: |
| Per-client TLS bytes, both directions, thirty rounds | 85,384–85,444 | 68,906–68,966 |
| Conditional idle client traffic | 117.31–117.42 MiB/day | 94.88–95.00 MiB/day |
| Per-client emulator CPU, one-core equivalent | 0.621–0.746% | 0.522–0.640% |
| Per-coordinator TLS bytes, same interval | 449,883–450,003 | 424,359–424,479 |
| Conditional idle coordinator traffic | 618.13–618.34 MiB/day | 584.33–584.65 MiB/day |

Client TLS traffic fell approximately 19%. The projection is under 100 MiB/day
for this narrow idle workload, but leaves only about 5 MiB/day for excluded
traffic. **This does not pass the full bandwidth/resource gate**: discovery,
public news, IP/TCP/radio overhead and active submissions are excluded, as are
phone energy measurements. A single sequential comparison also does not establish
a reproducible CPU saving or physical incremental app CPU. No clock, admission,
anonymity or shutdown assumption is improved merely by changing framing.

The runs are `android-pipeline-0102a19adaa148df929a53ad714c7199` (HTTP control)
and `android-pipeline-f95e58cfd9394bdeb028c53e58a26ecd` (framed transport).
`idle-comparison-v21.json` and `verification-v21.json` retain counter recomputation,
source/binary fingerprints, cleanup and unchanged-APK checks.

The subsequent framed **300-pair timing run failed after 81 measured pairs**.
Pair 81 was incomplete and 218 pairs were unattempted. Successful-pair conservative
additional delay was 2,891.237 ms median, 3,862.445 ms p95 and 4,168.009 ms maximum.
The first startup warmup added 5,261.133–5,287.122 ms; the second added at most
2,841.424 ms. Maximum observation-interval width was 35.829 ms. These survivor
quantiles do not establish sustained reliability or a causal latency improvement
over the earlier, separately timed runs. Startup still exceeds five seconds.

Failed round 188 started at cutoff +254.972 ms. Reservation phases took about
1,429.905 ms, followed by a 280.304 ms bulk commit phase that returned coordinator
zero's late-window rejection. The failed round ended at cutoff +1,965.256 ms,
beyond the locally checked cutoff +1,900 ms upper bound. Retained private operation
samples include checkpoint encoding, database write/spill and process CPU delays;
the evidence does not isolate a single storage operation or the transport as the
cause. Eleven roles share the emulator's CPU and storage, so this is also not a
measurement of eleven independent phones. No window, durability or fallback rule
was relaxed. The protected worker stopped with code 2; public/proxy errors were
empty. All owned roles were reaped and temporary directories removed.

The failed run is `android-pipeline-de9c7f7586954674933464943e55b033`, with results
in `.local-only/privacy-lab/pipeline-bd5bfe62/result.json` and failure details in
`device-runs/roles-4143326884/outbox-failure.json`. Independent calculations are
in `paired-300-analysis-v21.json`; bounded retained operation observations are in
`failed-round-operations-v21.json`. The full resource, timing and security gates
remain unpassed. The Samsung and production APK were untouched.

## Optional compact transport: v20

An opt-in CBOR RPC representation reduces binary-as-base64 and repeated field
name overhead. JSON remains the default control and the representation used for
signatures, request-cache hashes and encrypted checkpoints. The compact codec
does not negotiate or silently fall back. Its bounded, canonical decoder rejects
ambiguous, malformed and oversized input before protocol state handling.
Common round windows, synchronized storage and restart restrictions are unchanged.

Cross-codec tests preserve exact signed bytes and historical replies, including
reopening a journal, empty versus absent values, and idle, one-publisher and
eight-publisher rounds. Four targeted tests plus fuzz seeds passed (27 including
subtests/seeds). A separate 15-second fuzz campaign completed 98,001 executions
without a crash. The Android scheduled socket check passed all seventeen checks
and delivered eight Persian messages using the compact codec.

Fresh sequential JSON and CBOR idle runs each completed thirty measured rounds
after five warmups, at 5,000 kbps per role-link direction and 80 ms added per RPC.
The comparison uses the same source and changed only the selected codec. A fresh
JSON control was necessary because this revision explicitly sets response content
types, also affecting JSON HTTP byte counts relative to v19.

| Measurement | JSON | CBOR |
| --- | ---: | ---: |
| Per-client TLS bytes, both directions, thirty measured rounds | 121,751 | 85,384–85,444 |
| Conditional idle traffic per client | 167.24–167.29 MiB/day | 117.24–117.33 MiB/day |
| Per-client emulator CPU, one-core equivalent | 0.810–1.068% | 0.590–0.705% |
| Per-coordinator TLS bytes, same interval | 634,745 | 449,883–450,003 |
| Conditional idle traffic per coordinator | 871.91–872.13 MiB/day | 617.72–617.91 MiB/day |

The client traffic reduction is approximately 30%, but **idle traffic still
exceeds the provisional 100 MiB/day client budget**, before adding public news,
discovery and IP/TCP/radio overhead. These are short-run stationary projections,
not measurements of a full day. CPU was lower in the compact run, but one
sequential sample of each codec does not establish a reproducible CPU speedup or
physical incremental application cost. Emulator battery readings are not used.
No privacy, radio, physical CPU or battery gate passes from these observations.

Evidence under `artifacts/privacy-lab`:

- `codec-tests-v20.jsonl`, `codec-fuzz-v20.log`: bounded codec checks and fuzzing.
- `android-pipeline-88a09eb4ec01467b97d3f385a3f9e8c9`: compact socket checks.
- `android-pipeline-1fc05d19b67f4aaa90fa04a3d5956d91`: fresh JSON idle control.
- `android-pipeline-aa06781825a24a3a968cf996454c86bb`: compact idle measurement.
- `idle-comparison-v20.json`, `verification-v20.json`: counter recomputation,
  source/binary fingerprints, cleanup and unchanged production APK verification.

The full native Android regression passed **82 top-level tests, 181 including
subtests and fuzz seeds**, with zero failures or skips. This overlaps the targeted
codec suite and must not be added to it as a count of unique tests. Its archived
run is `android-pipeline-f53e19daa5264803a3097e40be4768a7`; independent verification
checked 86 source/binary/runner fingerprints and successful cleanup.

The subsequent **300-pair compact-transport timing trial failed**. Thirty-four
measured pairs completed, pair 34 failed on the protected arm, and 265 pairs were
unattempted. Successful-pair conservative added delay was 3,418.053 ms median,
4,362.701 ms p95 and 4,372.227 ms maximum. Its first startup warmup added
5,063.479–5,097.632 ms, exceeding five seconds even at the lower bound; its second
added at most 2,601.631 ms. Maximum observation-interval width was 28.330 ms.
These successful-pair quantiles do not pass sustained reliability or startup
latency, and the separate runs do not establish that CBOR improves latency.

Failed round 88 began at cutoff +254.826 ms. Reservation phases consumed about
1,414.184 ms, and bulk commit took another 348.388 ms before coordinator two's
late-window rejection. The round ended at cutoff +2,017.473 ms, beyond the local
acceptance window. This identifies cumulative critical-path overrun; it does not
isolate a single disk operation, host load or codec as the cause. The worker
exited with code 2, while public/proxy error lists remained empty. The protected
arm stopped without falling back; the separate direct control had received the
test post.

Evidence is `android-pipeline-370951dce5c043168de14bcbddbde4da`, with paired
observations in `.local-only/privacy-lab/pipeline-b2511f7f/result.json`, private
failure details in `device-runs/roles-2230325538/outbox-failure.json`, and independent
recomputation in `paired-300-analysis-v20.json`. All owned roles were reaped and
only the owned temporary directories removed. The Samsung and production APK
were untouched. Compact encoding remains optional laboratory work; the goal and
physical/security acceptance gates remain incomplete.

## Emulator storage attribution and completed-contribution retirement: v19

Testing remains emulator-only. Private, bounded laboratory diagnostics now
separate checkpoint encoding, database transaction duration, bbolt write/spill
time and allocated pages. They are absent from peer replies and saved protocol
state. bbolt's write duration includes successful page/meta writes and sync but
excludes file-growth sync; it must not be described as fsync-only. Allocation
counts describe transaction pages, not growth of the database file.

The initial eight-message check passed all seventeen checks. Seven retained
client bulk-accept observations showed approximately 188 KiB checkpoints and
200 KiB transaction allocations. Both write and spill work contributed to the
delays. A successfully accepted contribution is now retired after state advance;
the bounded exact-reply cache still supports historical retries. Invalid
certificates retain the active contribution, and fused acceptance/preparation
installs the new one. No synchronization, common cutoff or restart fence changed.

The next native check again passed all seventeen checks and delivered all eight
Persian messages. Its seven retained client bulk-accept checkpoints were
104,807–104,815 bytes, with 114,688 allocated bytes each. Client zero's deliberate
restart clears its private timing ring, so there are seven retained observations,
not eight. This directly establishes smaller checkpoints; differences between
the two runs' total phase times do not isolate a speedup. Cached ciphertext still
exists, so retirement is not secure erasure.

The subsequent paced run completed twenty measured pairs plus two warmups at
5,000 kbps per role-link direction and 80 ms added per RPC. Conservative additional
delay was 3,289.716 ms median, 3,696.405 ms p95 and 3,765.314 ms maximum. The first
startup warmup added **5,436.844 ms**, exceeding five seconds; the second added
2,453.853 ms. Warmups remain in the raw evidence. A twenty-pair steady-state
result is not acceptance of startup latency or sustained reliability.

Independent recomputation matched every interval and percentile. Maximum
last-absent/first-present observation width was 21.859 ms. The same signed bundles
were used in both arms, alternating short/long Persian text (3,220–4,288 bytes
including channel and signatures). Eleven native roles share one emulator;
public stores and the monotonic observer run on the host. These are verified
store receipt timings, excluding signing and UI rendering, not physical
phone-to-phone, battery or publisher-security results. All gates remain unpassed.

Targeted regressions passed in three overlapping suites: 4 top-level tests,
15 top-level / 51 including subtests, and 3 top-level tests. They include actual
child-process crash boundaries, exact retry/recovery, invalid certificates and
private diagnostic redaction. These counts must not be added as unique tests.
All three measurement attempts retained source/binary/runner fingerprints and
reaped all eleven owned roles. The production APK remains unchanged.

Evidence under `artifacts/privacy-lab`:

- `android-pipeline-81c99394da8545718ae7615a1592c462`: initial storage diagnostics.
- `android-pipeline-425fef05c37f49d8908387d444780f4f`: retirement check.
- `android-pipeline-52ff633520a84417810627f9ef8b7a6b`: twenty paired measurements;
  pipeline report `.local-only/privacy-lab/pipeline-c1eaaf5e/result.json`.
- `verification-v19.json`, `verify-v19.ps1` and `paired-recalculation-v19.json`:
  artifact, cleanup, private-counter and timing verification.

The longer, 300-pair trial of that unchanged workload **failed**: 76 measured
pairs completed, pair 76 failed on the protected arm, and 223 pairs were never
attempted. Successful-pair conservative overhead was 3,155.368 ms median,
3,945.237 ms p95 and 4,131.231 ms maximum. Its first startup warmup added
5,494.211 ms. These survivor-only quantiles do not satisfy the reliability gate.
Maximum observation width was 266.464 ms, retained in the conservative bounds.

The failed round 182 started at cutoff +250.075 ms. Reservation phases consumed
approximately 1,361.5 ms; the bulk commit phase took another 496.885 ms before
returning a coordinator's late-window rejection. The complete failed round ended
at cutoff +2,108.694 ms. Client state writes during fused acceptance/preparation
included 139–170 ms delays. The evidence shows a missed deadline across cumulative
work and transport; it does not isolate a single storage operation as the cause.
The window, synchronized writes and no-fallback rule remain unchanged. The worker
exited with an error; public/proxy error lists were empty. All eleven roles were
reaped and only the owned temporary run directory was removed.

The failed long run is `android-pipeline-37943690d92541eba61022cfc0417313`, with
private failure evidence in `device-runs/roles-3208347693/outbox-failure.json`,
paired observations in `.local-only/privacy-lab/pipeline-66fed179/result.json`
and independent accounting in `paired-300-analysis-v19.json`. No failed or
unattempted pair was replaced by a new attempt.

Earlier failures remain evidence; this change does not resolve
autonomous traffic scheduling, safe epoch recovery, admission/intersection
defenses, protected images/management, physical resource limits or security review.

### Separate idle cost and final emulator regression

A new emulator-only resource mode runs the same atomic/common-schedule candidate
with no submissions. Five warmups precede thirty measured rounds. CPU counters
are read through the existing private pipe, with monotonic request/response
intervals bounding the observation time. TLS counters are read at each role's
controller connection; their deltas sum exactly to the measured round totals.
CPU includes diagnostic work. Setup and warmups are excluded from those deltas.

At 5,000 kbps per role-link direction and 80 ms additional RPC latency, all thirty
idle rounds completed. Over approximately sixty seconds, each client used
375.510–459.453 ms process CPU (0.626–0.766% of one emulator core) and exchanged
122,291 TLS bytes in both directions combined. Each coordinator used
896.675–969.878 ms CPU (1.494–1.617% of one core) and exchanged 635,555 bytes.
These are process measurements on the shared emulator, not incremental physical
phone CPU, whole-phone CPU, radio use or battery measurements.

If this exact idle workload continued unchanged, the arithmetic traffic
projection would be about **168 MiB/day per client** and **873 MiB/day per
coordinator**. This is not a measured day or deployed peer-topology estimate.
It includes laboratory controller RPCs and excludes IP/TCP overhead, discovery,
private pipes, radio signalling and public news traffic. Even this restricted
projection exceeds the provisional 100 MiB/day publisher target; idle exchange
size needs improvement before a production bandwidth claim is possible.

Evidence: `android-pipeline-b2a998e4393145bc85abef2a2871399f/device-runs/roles-3431577440/idle-resources.json`
under `artifacts/privacy-lab`. `verification-v19.json` independently checks all
CPU interval arithmetic, daily projections, per-role/round byte totals, archived
hashes, private telemetry and cleanup for five measurement runs. The new helper
test rejects reversed/reset/nonfinite observations, overlapping windows and
counter overflow. The wrapper rejects physical-device idle runs before ADB access.

The final native Android emulator regression then passed **77 top-level tests /
154 including subtests**, with no skips or failures. Its source/binary/runner
fingerprints and cleanup are checked in `regression-verification-v19.json`;
the run is `android-pipeline-31dee6a3eb6a46d9a3635a73edd5d47e`. These functional
passes do not replace the failed long timing trial. No Samsung measurements,
production integration, network changes or APK updates occurred in this revision.

Next local work should reduce repeated wire representation and sequential phase
costs, preserving authenticated input sets, exact recovery and common eligibility
cutoffs. Any wire change needs adversarial/recovery regression coverage before
another sustained trial. Startup delay, idle bandwidth and missed-deadline
recovery remain concrete unmet requirements; simply extending the window or
repeating the same trial until one passes would not address them.

## Emulator phase diagnosis and contribution copying: v18

Testing remained emulator-only. The scheduled-check report now keeps a finite
private monotonic timeline, including the deliberate early-preparation attack,
eight sequential test enqueues and both reservations/bulk publication. The first
diagnostic attempt failed at the bulk coordinator commit. Its active reservation
started at cutoff +252.300 ms, so prior test enqueue work did not make that round
start late. Reservation work took 726.696 ms; JSON round-trip copying of the
encrypted contributions took 194.554 ms before coordinator commit began.

That copying now uses independent byte slices, including nested commitments,
without base64 encode/decode solely to clone data. Nil, empty and malformed field
representations remain unchanged for validation. All authentication, common
cutoffs, synchronized checkpoints and no-fallback behavior remain in place.
This is an optimization of the experimental controller's representation work,
not an established speedup of a deployed autonomous peer protocol.

Ten targeted regression tests passed (33 including subtests), covering ownership
in both directions, exact wire representation, altered contributions, late input,
certificate/cutoff rejection, failed writes and restart fences. The next native
emulator scheduled run passed all seventeen checks and delivered eight Persian
messages. Its encrypted-input copy took 10.519 ms. Other phase timings also
changed between attempts, so subtracting total run times would not isolate the
copy optimization's effect.

A subsequent attempt to start twenty paired measurements **failed its unpaced
prerequisite check**. The paired pipeline never started: zero warmup/measured
pairs completed and all twenty remain unattempted. Copying took 0.882 ms, but
combined client acceptance/preparation took 1,299.902 ms. Five clients spent
719.685–893.903 ms in database state updates. The active reservation started at
cutoff +256.855 ms and finished at +2,303.175 ms, before a bulk commit was rejected.
This preserves evidence of variable storage delays; one passing check is not
reliability or five-second acceptance.

All three attempts retain their source/binary/runner fingerprints and private
diagnostics; all eleven children were reaped in each. Verification found no hash,
timeline, telemetry-redaction or cleanup inconsistencies. The production APK is
unchanged. No sync option, round length, cohort size or security check was relaxed.

Evidence:

- `artifacts/privacy-lab/plan-v18.json`, `plan-copy-v18.json` and
  `plan-paired-v18.json` record the sequence and constraints before measurements.
- `android-pipeline-81bbc70ee781499fb7f04b12baf54f17/device-runs/roles-3520017178`
  under the same artifact root: original-copy diagnostic failure.
- `android-pipeline-291b726b3d684d2b91b04db5e879726c/device-runs/roles-3893769222`:
  direct-copy scheduled check pass.
- `android-pipeline-58769702beea4425b640653362d6c3cf/device-runs/roles-4263025394`:
  later prerequisite failure; not a completed paired trial.
- `copy-regressions-v18.jsonl`, `copy-test-summary-v18.json`, `verify-v18.ps1`
  and `verification-v18.json` provide raw regression and verification evidence.

Next, distinguish database page/write/sync time from growth, allocation and
encoding before changing storage. Keep durability and clock restrictions intact;
do not rerun until a concrete change or new diagnostic can explain the result.
Physical performance/battery trials remain deferred at the user's request.

## Native Android apparatus and emulator-first testing: v17

The private protocol can now run as eleven native Android processes while the
public reader stores and the monotonic observer run on the host. Every run
archives its Go sources and executable. The adapter verifies those hashes and
the runtime architecture; its configuration and shell-argument rejection checks
and Dart analysis passed. Android x86-64 required the installed NDK linker; the
initial pure-Go emulator build failed before any device files were created.

The linked emulator's real-time check failed at its first bulk publication
(round one), at a coordinator commit outside the unchanged common window. Five preceding
checks passed, including rejection of altered schedules and the delayed-client
cutoff attack. All eleven role processes were reaped and their private diagnostic
reports retained. No paired delivery sample or latency percentile resulted.

The Samsung subsequently completed all seventeen preliminary checks and
released the eight queued Persian messages. The user then requested emulator-only
testing. The paired phone measurement was stopped with exit 143 and its files
collected and removed. That interruption is **neither a protocol timing failure
nor a successful measurement**. A separate executable-path inspection confirmed
no owned test processes remained. No phone measurements should resume merely
because USB is connected; emulator findings must be addressed and the user ready.

The emulator regression mode compiles the existing Go suite as an Android
executable and uses an eight-minute timeout. Controlled-clock and crash tests
remain functional evidence, separate from the failed real-time schedule. Its
first invocation failed argument parsing before any test ran; quoting the dotted
test flags corrected the launcher. Android's process listing also proved to
strip executable directories from ARGS, so cleanup now verifies /proc/PID/exe
after selecting candidate names. Basename matching alone never authorizes a kill.

The corrected native emulator suite passed **74 top-level tests / 151 including
subtests**, with exit zero, no skips and no failed cases. Its temporary directory
was removed and an independent executable-path inspection found no owned test
processes left. Archived source/binary hashes for all five attempts, both complete
role cleanup records and the interrupted pipeline snapshot were verified;
`verification-v17.json` contains zero verification errors. The production 0.8.14
APK hash is unchanged. These functional passes do not erase the scheduled timing
failure above.

Evidence is under `artifacts/privacy-lab/android-pipeline-*`:

- `e6abf02a113b449e86dc3f11964dd5c0`: external-linker build prerequisite failure.
- `4657062ef52c4fcd8e017ffb916a675c`: native emulator schedule failure.
- `7d203466d089484a8afc3fd1e7991ac9`: phone preliminary checks and user interruption.
- `b8230fd80fcc4c4fbe23a5618a66105b`: regression launch argument failure.
- `91d48475f61e48b89502afac069cbbb7`: corrected emulator regression invocation.

`emulator-first-v17.json` records the revised testing order. The five-second,
resource and publisher-security gates remain unpassed, and no experimental APK
has been produced. Emulator correctness cannot establish physical radio behavior,
CPU cost on a phone or battery use.

## One synchronized publication checkpoint: v16

The opt-in `fpp1atomic` candidate uses one synchronized transaction for the
resulting publication state and its exact reply cache. Setup, schedule admission,
disclosure/control and local enqueue retain their original pending records.
The prior `fpp1fused` implementation remains available. No production source or
APK changed in this experiment.

The recovery tradeoff is explicit: a pre-commit process exit can lose work that
has not been acknowledged, leaving the prior saved state without a pending
publication request to auto-execute. Committed queues survive; failed writes
fence live caches; a post-commit retry returns the identical saved response.
The existing lost-clock-anchor restriction still prevents fresh scheduled
publication after restart. This is process-crash evidence, not proof of physical
power-loss behavior or malicious rollback resistance.

Validation passed:

- The five new test groups cover configuration restrictions, all six allowed
  operation names, actual synchronized commit counts, exact retries, retained
  intent records for other operations, altered certificates, cutoffs, failed
  writes and restart fencing. Ten real child-process crashes exercise each
  bulk operation before and after commit, including certified queue removal.
- The full Go suite passed **74 top-level tests / 151 including subtests** in
  195.626 seconds. Vet, build and Dart adapter analysis passed.
- Eleven separate processes passed **17 socket checks** and delivered all eight
  queued Persian messages. These checks use unpaced loopback and do not establish
  a delivery-latency gate.

The preregistered timing attempt at 5,000 kbps per role-link direction with
80 ms added per RPC **failed its first warmup**. No protected warmup completed;
zero measured pairs completed and all twenty remain unattempted. The worker
exited with code 2 without direct fallback. No 300-pair extension was started
and there is no delivery-overhead percentile to report.

Round zero started at cutoff +250.898 ms. Combined client acceptance/preparation
took 924.445 ms as observed by the controller. Bulk coordinator commit was then
rejected outside the unchanged window; the failed round occupied 1,900.018 ms
and ended at cutoff +2,150.919 ms. **Failed-round work is not delivered-message
latency.** Anonymous setup took 5,603.950 ms, reported separately.

Private diagnostics confirm one synchronized commit, with no pending write, for
each non-cached publication operation that reached storage. Four clients spent
536.872–547.548 ms in their state database updates during combined preparation.
Another client occupied 670.864 ms total, of which 101.958 ms was measured in
the database update; that remainder is still unassigned. The relevant Windows
CPU deltas were 0 or 15.625 ms, so they cannot resolve short processing costs
or prove no CPU activity. Reducing the transaction count is verified; an
end-to-end speedup is not. The unsuccessful v14/v15/v16 runs remain preserved.

The next measurement should run the complete scheduled native role path on
Android, including its outboxes, setup, sockets and synchronized checkpoints.
The v15 Android component test excluded those features. Any host-controlled
Android trial must include its control/USB overhead in the observer's timing
and label it as a local apparatus, not evidence of delivery across mobile
providers. Keep the five-second limit and common cutoff unchanged.

Evidence:

- `artifacts/privacy-lab/plan-v16.json` — design invariant, unchanged paths,
  validation and timing profile recorded before measurement.
- `atomic-tests-v16.jsonl`, `round-tests-v16.jsonl`, `round-test-summary-v16.json`,
  `round-build-v16-status.json`, `pipeline-analysis-v16.log` under the same
  artifact directory — test and tool results.
- `.local-only/privacy-lab/roles-2260900402/schedule-checks.json` — socket checks.
- `.local-only/privacy-lab/pipeline-b33b9e30/result.json` and
  `roles-3223662967/outbox-failure.json` — preserved timing failure.
- `artifacts/privacy-lab/pipeline-atomic-analysis-v16.json`, `verification-v16.json`
  and `verify-v16.ps1` — recomputation and verification of 145 pipeline hashes
  and 78 source/binary hashes for each role run. Both runs returned all eleven
  private diagnostic reports and reaped all eleven children. The 0.8.14 APK
  hash remains unchanged.

## Samsung storage and processing characterization: v15

With the user leaving the Samsung idle on its home screen, the native Android
ARM64 component completed three workloads: idle, one publisher and eight
publishers, with 4,288-byte payloads. Each workload alternated memory and durable
state in ABBA order, with six measured rounds and one warmup per mode. Eleven
roles execute sequentially in one process. This uses the v14 source snapshot,
before the v15 verification optimization below.

| Simultaneous publishers | Memory all-role wall P50 / maximum | Durable all-role wall P50 / maximum | Durable all-role CPU P50 / maximum |
| --- | --- | --- | --- |
| 0 | 16.49 / 48.22 ms | 96.31 / 112.20 ms | 89.95 / 110.58 ms |
| 1 | 152.88 / 168.57 ms | 377.30 / 387.53 ms | 417.97 / 426.62 ms |
| 8 | 245.64 / 298.02 ms | 952.35 / 1,054.93 ms | 910.63 / 1,033.39 ms |

P50 uses the nearest-rank definition used by the probe. With only six samples
per mode/workload, P95 and P99 equal the maximum; these are not reliable tail
estimates. CPU is process time and can exceed wall time when multiple threads
execute. Role observations within a round are not independent devices.

An idle durable client averaged 3.40 ms wall and 3.04 ms CPU per round across
48 role observations. At one publisher, client averages were 18.65 ms wall /
19.73 ms CPU, and coordinator averages were 74.88 ms wall / 83.46 ms CPU.
This short component workload did not reproduce the long Windows database-call
delays observed in v14. It does not prove those delays cannot occur on a phone,
or that the full protocol meets the CPU budget.

This test excludes private outboxes, common-schedule wait, anonymous setup,
network sockets, radio behavior, UI and steady continuous workload. The phone
was USB-powered, awake and at 100%; temperature was 32.4°C before and 32.2°C
after. **It supplies no battery or end-to-end latency acceptance evidence.**
The temporary device files and test databases were removed. All 74 archived
source hashes and the binary hash verified, and the reported distributions were
independently recomputed from raw rows.

Code inspection also found that coordinator finalization verified the same
eight input signatures twice. The v15 implementation performs the complete
input/vote/share verification once and returns its authenticated root with the
output. A failed check returns neither output nor root. No validation cache,
weaker signature requirement, relaxed clock window or disabled synchronization
was introduced. Private diagnostics now include whole-process CPU deltas for
each operation; these may include concurrent local work and remain excluded
from peer responses and durable protocol state.

Evidence:

- `artifacts/privacy-lab/plan-v15.json` — preregistered phone workload.
- `artifacts/privacy-lab/device-e6a2cce9854647e694db217c0bf334d5/` — raw result,
  manifest, binary and archived source.
- `artifacts/privacy-lab/device-analysis-v15.json` and `analyze-device-v15.ps1`
  — hash verification and independent recomputation.
- `artifacts/privacy-lab/plan-diagnostic-v15.json` — next diagnostic timing
  attempt with unchanged limits and explicit retention of failures.

The v15 full Go suite passed **69 top-level tests / 132 including subtests** in
132.026 seconds. Vet and the research build passed. This includes fifteen cases
for authenticated-root output, malicious signed equivocation, missing or
duplicated participants/votes/shares, and private diagnostic isolation. The
earlier intermittent v14 scheduling watchdog failure remains in the record;
this successful run does not establish that it has been eliminated.

The one planned paced diagnostic attempt still **failed**. It completed its
first warmup with an added receipt interval of **6,518.967–6,550.994 ms**, then
stopped in round one. There were zero measured completed pairs and twenty
unattempted pairs; no 300-pair extension was started. The completed warmup
included 3,565.100 ms before the first reservation round started and
2,931.851 ms of round work. That initial admission wait must not be presented
as a steady-state latency percentile.

The first round's work exceeded the two-second cadence. The next round started
at cutoff +1,183.158 ms and failed at +1,974.321 ms when a client rejected
combined acceptance/preparation outside its window. Its 791.162 ms of work did
not recover the previous delay. The Go worker exited with code 2; the later
Dart write encountered the already-closed pipe. No direct fallback occurred.
Anonymous setup took 5,924.216 ms, reported separately from publication timing.

All eleven private diagnostic reports were received. The nine coordinator
finish operations ranged from 51.248 to 235.588 ms wall; observed process CPU
deltas were 0–31.25 ms. Windows reported CPU in coarse 15.625 ms increments,
so zero is not evidence of zero processing. The prior unexplained two-second
finish delay was not reproduced. This does not attribute a speedup to removing
duplicate validation: the runs are neither a controlled ABBA comparison nor
equivalent successful workloads.

The full path still needs a shorter critical path and a cadence that can be
sustained without missing the authenticated cutoffs. A next implementation
experiment should examine whether publication-only state transitions can use
fewer durable commits while preserving exact replay, crash safety and response
release ordering. Any such change requires failure-injection tests before
timing. The phone results justify measuring that cost on Android; they do not
justify disabling synchronization or widening cutoffs to hide failures.

Additional evidence:

- `artifacts/privacy-lab/round-tests-v15.jsonl`, `round-vet-v15.log`,
  `round-build-v15-status.json` — regression and build outcomes.
- `.local-only/privacy-lab/pipeline-48e276fb/result.json` and
  `roles-2967276435/outbox-failure.json` — both warmup rows and failed-round
  timing, including the underlying worker failure.
- `artifacts/privacy-lab/pipeline-diagnostic-analysis-v15.json` and
  `verification-diagnostic-v15.json` — independent recomputation, all 143
  pipeline hashes and 76 role-source/binary hashes verified, all eleven roles
  reaped. The production 0.8.14 APK hash is unchanged.

## Combined reservation acceptance and preparation: v14

The `fpp1fused` experiment combines a client's verified reservation acceptance
and preparation of its pinned bulk contribution. It saves one controller RPC
phase and two synchronized database transactions per client in an active round.
All participants, signatures, cutoff checks and durable response boundaries
remain required. This is a protocol-phase optimization, not a publisher-security
claim. The original `fpp1scheduled` path is retained for comparison.

The initial full Go regression suite (65 top-level entries), vet and Dart adapter analysis passed. The
eleven-process socket run passed all 17 assertions and released all eight queued
Persian messages in the next eligible round. A subsequent targeted regression
also passed for late news from the existing publisher and a different publisher:
neither item entered the already active publication round. Altered certificates
or bulk contributions, missed cutoffs, failed commits and restarts preserve the
queued publication and do not release an unauthorized fresh contribution.

The first paced 20-pair attempt **failed its first warmup**. It completed zero
measured pairs; all 20 remain unattempted. At round zero, client preparation
took 1,292.914 ms, followed by 858.630 ms for coordinator commit attempts. The
round began at cutoff +251.242 ms and failed at +2,402.791 ms. Coordinator 2
rejected work outside the local window. This happened before the combined phase,
so the failure does not measure its speedup. No overhead percentile can be
reported from this run, and it does not qualify for the planned 300-pair extension.
The worker exited with code 2 and no direct-publication fallback.

The profile is still local loopback at 5,000 kbps per role-link direction with
80 ms added delay per RPC. Anonymous setup took 8,547.250 ms, separate from the
signed-bytes-ready to verified/flushed reader-store endpoint. It is not an
Android, physical network or battery measurement.

Evidence:

- `artifacts/privacy-lab/plan-v14.json` — prediction and unchanged gates recorded
  before the timed run.
- `artifacts/privacy-lab/round-tests-v14.jsonl`, `round-vet-v14.log`,
  `fused-pipeline-analysis-v14.log`, `fused-active-cutoff-v14.log` — validation.
- `.local-only/privacy-lab/roles-631269775/schedule-checks.json` — socket checks.
- `.local-only/privacy-lab/pipeline-34a2cd33/result.json` and
  `roles-1432031491/outbox-failure.json` — preserved failed timing attempt.
- `artifacts/privacy-lab/pipeline-fused-analysis-v14.json` — independent raw-row
  recomputation; null distributions mean no measured completed pairs.

The diagnostic follow-up adds a fixed sixteen-operation local timing ring and
an explicit private parent/child-pipe read. Lock wait, encoding and synchronized
write durations are collected locally after the experiment. They are excluded
from peer responses and durable protocol checkpoints. This is intended to
locate the delay, not to waive the failed attempt or any acceptance requirement.

With those diagnostics, the full suite passed 67 top-level entries and failed
one: the existing independent-scheduler test exceeded its ten-second per-cycle
watchdog. Its targeted rerun passed with the watchdog unchanged; only
failure-reporting code was added. Both outcomes remain in
`round-tests-diagnostic-v14.jsonl` and `schedule-watchdog-diagnostic-v14.jsonl`.
The diagnostic privacy/bounds/read-only checks passed, as did vet and the research
build. The intermittent scheduling failure remains unresolved; a subsequent
diagnostic experiment is not an integration approval or a fully green suite.

The diagnostic attempt also failed its first warmup: zero measured pairs,
20 unattempted. At round zero the controller observed 4,760.297 ms of work;
clients rejected combined acceptance/preparation outside the local window.
Private diagnostics arrived from all eleven roles. Client preparation occupied
389.479–675.331 ms locally, with negligible measured lock wait and almost all
of that duration inside the two synchronized database updates. These are wall
durations of database calls, not proof of the underlying disk-service cause.
They do not establish the corresponding cost on separate Android phones.

There is also a separate unexplained long operation: coordinator 0's finish
occupied 2,166.438 ms, of which only 380.782 ms was in those database updates
and 0.528 ms in measured encoding. The remainder must not be labeled disk time
or CPU without additional evidence. Coordinator finish dominated this run's
controller phase at 2,316.748 ms. Anonymous setup occupied 16,318.676 ms,
separate from publication timing. No latency percentile or speedup is supported
by either failed warmup.

Evidence for the follow-up:

- `.local-only/privacy-lab/pipeline-28a0639/result.json` and
  `roles-2353106774/outbox-failure.json` — failure and raw phase durations.
- `roles-2353106774/lifecycle.json` under the same lab directory — private local
  operation timings, redacted peer stats and all eleven processes reaped.
- `artifacts/privacy-lab/pipeline-fused-diagnostic-analysis-v14.json`,
  `local-operation-analysis-v14.json`, `verification-initial-v14.json` and
  `verification-diagnostic-v14.json` — recomputation and snapshot verification.

Next, characterize one role's storage work on the phone and investigate the
unaccounted coordinator execution time before choosing a crash-safe reduction
in write amplification. Do not disable synchronization, widen cutoffs, discard
failed warmups or infer security from a faster successful sample. The 300-pair,
continuous-resource, battery, shutdown and security gates remain unmet. The
production 0.8.14 APK is unchanged by these experiments.

## Previous experiment: common cutoff, preserved privacy attack and failed timing gate

The legacy test reproduces a concrete attack: a scheduler asks seven clients to
prepare before news is queued, then asks the eighth afterwards. All eight have
news, but only the eighth article releases with valid certificates. The new
opt-in common-cutoff mode binds a schedule to all three coordinator signatures
and the epoch/roster. Each local enqueue retains its earliest eligible round;
later preparation cannot move newer news into an earlier round. This addresses
that specific request-arrival attack, subject to the stated clock assumption.

The initial Windows suite passed 58 top-level test entries (including subprocess
helpers). After additional first-cover restoration and preflight checks, all six
affected top-level tests passed, including every possible target client. These
are separate runs, not a claim that a final 59-entry suite was run in one pass.
The independent-process socket check passed 17 assertions and delivered all eight
Persian messages together in the next eligible round. Altered/incomplete schedule
certificates, equivocation, early/late requests and restart clock re-arming are
rejected. Go vet and Dart pipeline analysis passed. These are functional checks,
not an anonymity proof or an Android measurement of this revision.

The new `fpp1scheduled` comparison uses identical signed news in alternating
direct/protected order, independent two-second rounds, private local enqueue,
durable role state and verified/flushed application reader stores. Pacing is
5 Mbps per role-link direction plus 80 ms per RPC on loopback. All times are
same-clock observations; signing and UI are excluded. Cold anonymous setup is
separate, and a four-second schedule-admission lead follows it.

| Run | Warmups | Measured pairs | Result |
| --- | --- | --- | --- |
| Initial common-schedule attempt | First warmup failed | 0 completed; 20 unattempted | Client preparation outside the local window |
| Follow-up with local failure diagnostics | Both passed | 5 completed; 1 failed; 14 unattempted | Round 19 bulk coordinator commit outside the local window |

Among only the five completed pairs, conservative additional delay had median
**3,255.716 ms** and maximum **4,049.917 ms**. Maximum receipt-observation width
was 21.163 ms. Five survivors do not establish a tail percentile or a five-second
bound. The failed publication is a failed reliability gate, not a missing sample
to discard. Neither attempt used direct-publication fallback. Previous failed
long runs, including the 300-pair attempt, also remain in the evidence.

The follow-up started round 19 at cutoff +254.151 ms and observed failure at
+2,141.900 ms. Reservation client acceptance alone took 678.567 ms at the
controller; bulk prepare/commit took another 221.249/219.794 ms. These include
RPC pacing, OS scheduling, processing and durable state work; they do not isolate
disk latency or phone CPU. The check rejects fresh work after the local
upper-bound guard reaches the next two-second cutoff. No window was widened,
durability disabled or security rule removed to obtain a passing sample.
Anonymous setup took 12,077.010 ms and 5,698.776 ms respectively, separate from
the paired steady-path endpoint and excluding child-process launch.

All eleven child processes were reaped for both attempts and the socket check.
Source/binary snapshots are retained; the diagnostic change adds only local
failure observations, not peer-visible queue or clock telemetry. No phone data,
host networking or production code was changed for this experiment.

**Integration remains closed.** The 100 ms clock-error bound is assumed, not
established by signatures. Restart retains queued news but fences fresh
publication; safe clock admission and new-epoch queue migration are still
missing. Next work must reduce or safely pipeline the measured phase work while
retaining the frozen publication set, then repeat long paired trials with all
failures counted. Autonomous uniform traffic, timing/intersection/Sybil defenses,
every application action/image, physical routes and controlled battery remain
required. The production animation/CPU improvements are separate.

Evidence:

- `artifacts/privacy-lab/scheduler-cutoff-before-v13.log` — successful reproduction
  of the legacy attack, retained as a negative control.
- `artifacts/privacy-lab/round-tests-v13.jsonl` and
  `scheduler-cutoff-tests-final-v13.jsonl` — initial full and final affected tests.
- `.local-only/privacy-lab/roles-776391087/schedule-checks.json` — 17 socket checks,
  sources, binary and cleanup record.
- `.local-only/privacy-lab/pipeline-a5abcd40/result.json` and `roles-1171051643/`
  — failed warmup and original measured source/binary.
- `.local-only/privacy-lab/pipeline-b397c657/result.json` and `roles-398517460/`
  — diagnostic follow-up, including `outbox-failure.json` with phase timings.
- `artifacts/privacy-lab/pipeline-scheduled-failed-analysis-v13.json` and
  `pipeline-scheduled-diagnostic-analysis-v13.json` — raw-row recomputation,
  failed/unattempted counts and conservative paired intervals.

## Previous measured revision: private durable queue and independently timed measurement

The new opt-in role-local outbox removes plaintext publishing commands from the
peer RPC. Local enqueue/release acknowledgements follow synchronized encrypted
commits. Exact retries cannot create another publication; late arrivals wait for
the next reservation. Bounds are 64 queued items / 256 KiB, 8,110 bytes per item
and 128 release receipts. Queue, CPU and storage activity are hidden from peer
statistics. Application-level action validation remains unimplemented.

The process-separated check passed **15 assertions**, delivered three Persian
messages and performed **26 process restarts**: 25 identical committed-response
replays plus one restart before reservation. Its 18,688.039 ms total includes
negative tests and intentional crashes; it is not a delivery latency sample.
Both all 51 initial and all **53 updated native test entries** passed on the
Samsung (three entries are subprocess helpers). The updated suite additionally
checks queue/round consistency on restoration and timer-driven idle publication
cycles. Tests on Windows and `go vet` passed; Dart pipeline analysis passed.

The new `fpp1outbox` paired comparison includes local enqueue/commit, private IPC,
independently timed two-second rounds, durable role state, public distribution
and verified/flushed reader storage. The timer runs without consulting the local
submission stream. Signing is before the measurement start, and UI rendering is
not measured. The direct arm uses the same signed bundle and public path.

| Observation | Result |
| --- | --- |
| Measured paired submissions | 20 completed, zero failed/unattempted; two warmups separately |
| Additional conservative delay, median / p95 / maximum | **3,169.546 / 3,873.937 / 4,169.210 ms** |
| Direct reader receipt, median / maximum upper bound | 177.773 / 468.467 ms |
| Protected reader receipt, median / maximum upper bound | 3,314.909 / 4,301.418 ms |
| Maximum receipt-observation interval width | 27.502 ms; included in conservative paired bounds |
| Local enqueue acknowledgement, median / maximum | 42.063 / 127.062 ms; includes private IPC, not just database work |
| Cold anonymous setup | **8,607.906 ms**, separate; excludes child-process launch |

The link profile is still application-level pacing at 5 Mbps per direction plus
80 ms per RPC on loopback. All eleven child roles were reaped, and the pipeline
exited successfully with no public/proxy error. No physical route or controlled
battery was measured. The earlier failed 300-pair run remains evidence against
accepting the latency gate; twenty later successes do not replace it. The cold
setup delay also prevents presenting this as a five-second first-use experience.

**Publisher security remains open.** The controller still issues preparation
RPCs. Their arrival controls each client's queue cutoff, and queue-dependent
work can affect response time. The private pipe and independently running timer
are useful boundary changes, but do not establish a decentralized schedule,
resistance to timing correlation, safe fault resumption or Sybil/intersection
defense. Every application action and image path still needs the same protection.

The new client's peer statistics intentionally contain zero-valued CPU/storage
fields. These are redacted values, **not zero resource use**. The two retained
outbox run lifecycles also derived a misleading zero CPU delta from them; those
raw files are preserved, but no CPU conclusion is drawn. A subsequent metadata
fix suppresses that derived delta and labels the counters as redacted. That
reporting-only change is not a new timing measurement. The native CPU comparison
in the previous section does not measure this complete outbox/scheduler version.

Evidence:

- `.local-only/privacy-lab/roles-624932019/outbox-checks.json` and lifecycle/source
  snapshots — private enqueue, restart, idempotency and output checks.
- `artifacts/privacy-lab/device-journal-3f6aa64bb4294734acf471b6b6876bbc/` and
  `device-journal-529200c078b74b6484f3b7a6521987cc/` — 51/53 native entries and
  successful removal of their temporary device files.
- `.local-only/privacy-lab/pipeline-956a4e6d/result.json`, associated
  `roles-2438515936/`, and `artifacts/privacy-lab/pipeline-outbox-analysis-v11.json`
  — paired observations, setup, exact sources/binaries and recomputed statistics.
- `artifacts/privacy-lab/verification-v11.json` — evidence/cleanup verification.

Five host temporary directories from an initial failed-test cleanup remain
because automatic approval review rejected their deletion with “blocked by
policy.” They are test fixtures outside the repository; device test cleanup and
child-process cleanup succeeded. No host networking or installed application was
changed. The goal is active and integration remains closed.

## Previous revision: native storage costs and smaller completed-setup state

The Samsung now has a direct resource comparison of the actual memory and durable
role adapters. Each workload used eight measured rounds per mode in ABBA order,
after one warmup per mode, with independent epochs and 4,288-byte fixture payloads.
All eleven roles ran sequentially in one native process. The journals retained
normal synchronized writes. This is component cost, not network delivery time.

| Workload | Mean client CPU, memory / durable | Mean coordinator CPU, memory / durable | Durable all-role wall time, median / maximum |
| --- | --- | --- | --- |
| Idle reservation | 1.250 / 4.534 ms | 10.550 / 23.073 ms | 109.611 / 157.910 ms |
| One publication | 3.321 / 19.131 ms | 43.873 / 88.105 ms | 393.339 / 418.711 ms |
| Eight publications | 7.609 / 38.197 ms | 66.250 / 177.760 ms | 929.347 / 1,116.315 ms |

The single-publication row averages all eight client roles, including cover
senders. The actual publishing client's mean CPU in that workload was
4.044 ms in memory and 17.349 ms with the journal; durable maximum 24.459 ms.
Those eight owner observations are derived from the retained loop's deterministic
per-arm round number modulo eight. Shared runtime/GC work can cross call
boundaries, and the per-role observations are nested within rounds, not separate
phones. These short runs establish neither a steady-state CPU pass nor battery
cost. The Samsung was awake, USB charging, at 87%, 31.9°C before and 32.0°C after.

Journal diagnostics now separate encoding/sealing from synchronized database
updates. On the phone, maxima for a pending/state database update were
5.345/5.010 ms when idle, 14.976/9.078 ms with one publication, and
44.396/30.680 ms with eight publications. These include initialization and
warmups, and the timed database call also includes OS scheduling. They do not
measure the hardware's `fsync` latency alone or reproduce the Windows stalls.

Two subsequent changes reduce avoidable work without changing the protocol or
disabling synchronization:

- Reuse the already computed request digest instead of encoding the same request
  again inside the journal.
- Retire completed setup objects after their bulk keys have been copied into the
  live role. Keep the exact final public receipt and request hash for retries.
  New and old authenticated local checkpoints both restore without reviving
  retired setup objects. This is not secure memory/disk erasure.

The Android regression fixture measured an immediate post-setup client checkpoint
reduction from 17,298 to 10,980 bytes, and coordinator checkpoints from about
30,746 to 18,084 bytes. Those are particular snapshots, not a general reduction
percentage for later bulk rounds. The phone CPU comparison above predates these
two optimizations and cannot establish their CPU benefit.

After the changes, all **45 native round-probe test entries** passed on the
Samsung, including two subprocess workers. Windows tests and `go vet` passed.
Six Persian messages again survived **30 forced process restarts** with identical
responses. The fault investigation retained **19 passing checks**, seven recovered
complaints and **14 identical crash replays**; it still did not resume failed news
or remove a participant. Investigation time including injected failures/restarts
was 7,389.330 ms; separate control-key setup 969.516 ms.

A **20-pair local follow-up** completed with no delivery failure or overhead above
five seconds: conservative additional delay median **3,024.247 ms**, p95
**3,430.318 ms**, maximum **3,516.867 ms**. Maximum receipt-observation width was
27.405 ms. Initial setup was separately 2,410.594 ms. The profile remained
5 Mbps/direction plus 80 ms added per RPC, with scheduled waiting, durable
transactions and verified/flushed application reader stores. This short follow-up
does not replace the previous failed 300-pair attempt or meet the physical-route
acceptance gate. Different runs, sample counts and host conditions also prevent
claiming that the code changes caused a specific latency improvement.

Evidence for this revision:

- `artifacts/privacy-lab/device-b491498418db41a786dc869a89849cf1/` — native ABBA
  component comparison, source/binary and recorded phone conditions.
- `artifacts/privacy-lab/device-journal-analysis-v10.json` — raw-row aggregation
  and publishing-client observations with their derivation.
- `artifacts/privacy-lab/device-journal-aa019b7ac1b24c07a3665595b857f941/` —
  corrected/optimized native tests, including compact and legacy checkpoint recovery.
- `.local-only/privacy-lab/roles-1860171387/durability-checks.json` and
  `roles-2516352019/control-checks.json` — repeated network crash checks.
- `.local-only/privacy-lab/pipeline-ee2f0427/result.json`, `roles-4136585727/`
  and `artifacts/privacy-lab/pipeline-durable-analysis-v10.json` — 20 paired trials.
- `artifacts/privacy-lab/verification-v10.json` — source/binary and cleanup checks.

The goal remains incomplete and production integration remains closed. Next work
must move local submissions and the sending schedule into the roles themselves;
the current controller-mediated RPC exposes laboratory publishers. That security
gap, admission/intersection defenses, safe fault resumption, all application
actions, physical routes and controlled battery still require work. A fast local
sample does not establish anonymous publication or shutdown reachability.

## Previous revision: committed local state and process-crash recovery

The opt-in durable role commits an encrypted pending operation before execution,
then atomically commits its exact response/state before returning it. This covers
anonymous setup, ordinary publication rounds and the fault-control state. A
failed storage write fences even an in-memory cached response. Missing, altered
or mismatched storage cannot trigger fresh keys or reset the session. bbolt 1.5.0
provides the database transactions with normal synchronization enabled; the
laboratory key is a separate file, not Android Keystore or anti-rollback storage.

| Check | Observation | Limits |
| --- | --- | --- |
| Subprocess exits before execution, before commit and after commit | All passed. A committed ciphertext is returned identically; unfinished operations recover without advancing a round twice. | Process crashes, not power loss. No malicious filesystem rollback claim. |
| Normal publication through eleven durable TLS roles | Six Persian messages delivered across three reservation/bulk cycles with **30 forced process restarts**. All 30 committed responses were identical on retry. Total 12,908.201 ms including the restarts. | 5 Mbps/direction plus 80 ms added per RPC; local controller updates restarted addresses. This is not a delivery latency estimate or autonomous discovery. |
| Fault-control investigation with durable roles | **19 checks passed**, seven complaints recovered and **14 forced restarts** preserved identical responses. Investigation 7,141.749 ms including injected failures/retries/restarts; control-key setup separately 997.917 ms. | Failed news remained blocked; no participants removed or publication resumed after the injected corruption. Does not establish a five-second recovered-delivery limit. |
| Storage failures and misuse | Parallel writer, missing database, wrong key, modified ciphertext, changed role configuration, oversized checkpoint and exhausted interrupted-operation budget rejected. | Laboratory files and keys; not device seizure, backup restore or production storage integration. |

The first live restart run failed after one successful replay because a JSON
`null` client-state field was mistaken for a client checkpoint when restoring a
coordinator. The coordinator stopped without releasing a new message. The decoder
was corrected and a both-role regression test added before the successful runs.
That failed run is retained; it is not counted as a passed trial.

Validation ran the test suites and `go vet` for `roundprobe`, `setupprobe` and
`verdictprobe`; Dart analysis of the paired pipeline also passed. After the
Android lock regression below there are 74 Go test entries across the three
modules, including two subprocess worker helpers. The changed `roundprobe`
suite and vet were rerun on Windows.
The response cache remains bounded to eight entries, encoded checkpoints to
8 MiB and each database to 64 MiB. The storage statistics report current-process
commit counts, encoded bytes submitted to storage and file size. They do not
measure physical flash writes, wear or power use.

**The attempted 300-pair durable publication run failed the latency/reliability
gate.** It completed 266 measured pairs, then failed on pair 267; the remaining
33 were unattempted. Both warmups completed. Two completed pairs exceeded five
seconds of additional delay, and the scheduler then stopped after a missed round
deadline. The protected submission was not sent directly. There were no public
reader or proxy errors. All eleven role processes were reaped.

| Paired result | Observation |
| --- | --- |
| Conservative additional delay, completed pairs only | Median **2,436.124 ms**, p95 **3,644.620 ms**, p99 **4,472.361 ms**, maximum **7,150.020 ms** |
| Two overhead violations, lower to upper bounds | **5,029.799–5,113.440 ms** and **7,083.728–7,150.020 ms**; both exceed five seconds even at the lower bound |
| Direct reader-store receipt, completed pairs | Median 222.128 ms; maximum 820.279 ms |
| Protected reader-store receipt, completed pairs | Median 2,635.783 ms; maximum 7,420.655 ms |
| Receipt-observation interval width | Maximum 285.622 ms; all intervals retained in the raw rows |
| Separate initial setup | 2,221.704 ms; 573,491 aggregate TLS bytes; excludes child launch |
| Run duration including setup, warmups and failure cleanup | 1,134,478 ms (about 18.9 minutes) |

These are same-clock measurements of identical signed Farsi bundles through the
current application's verified/flushed reader store, with alternating direct/
protected order. Eleven role processes use loopback TLS, 5 Mbps per direction
application pacing and 80 ms added per RPC. The protected path includes scheduled
waiting and normal durable transactions, without forced crashes. This is not a
physical mobile-network test, a cold-publication measurement or a UI/outbox test.
The 266 successful-pair percentiles do **not** include the failed pair as a finite
latency; its failure and all unattempted pairs are reported separately.

The final slow publication spent 5,960.310 ms in round work, plus 1,128.680 ms
waiting. The retained revision has no phase-level timing that can establish
whether disk, scheduling, crypto or transport caused the stall. Do not attribute
it to storage or host contention without evidence. The next revision adds
reservation/bulk phase timings and per-process pending/checkpoint timing totals
and maxima. It retains the same deadline and five-second gate.

Resource observations for this failed run: each client committed 3,317 database
transactions and submitted about 72.8 MB of encoded plaintext to sealing/storage;
each coordinator committed 4,975 transactions and submitted about 233.8 MB. These
are **not physical flash-write counts**. The final files were 256 KiB per client
and 1 MiB per coordinator (5 MiB total). Client process CPU deltas were
5,500–6,234.375 ms; coordinator deltas were 15,906.250–16,125 ms. These desktop
process observations include laboratory work and do not establish incremental
Android CPU or battery usage. Each client exchanged about 8.9 MB of TLS payload
and each coordinator about 52.2 MB, including laboratory RPC traffic; no daily
phone bandwidth claim follows from that workload.

The first native Android run found a real platform-specific exclusion gap:
opening the same journal twice inside one process succeeded. The pinned
[bbolt Android implementation](https://raw.githubusercontent.com/etcd-io/bbolt/v1.5.0/bolt_android.go)
uses a process-associated `F_SETLK` lock. The adapter now also holds an Android
`flock` on a persistent session lock file for the journal's entire lifetime.
The lock file is not unlinked; the kernel releases the held lock on process exit.
Checks now cover both same-process and separate-process exclusion, reopening
after close, and recovery after an unclean process exit.

After the fix, all **44 native round-probe test entries** passed on the Samsung
SM-G998W, Android 15 / ARM64 (including the two worker helpers). Temporary device
files were removed. The earlier failed Android output and source remain retained.
The test runner also changed from `adb exec-out` to shell-v2 status reporting:
transport exit zero alone did not mean the original native tests passed. Both
exit status and the native PASS marker are required. These are adb-shell native
tests, not APK integration, power-loss, malicious rollback, radio or battery tests.

A subsequent **five-pair diagnostic attempt also failed during warmup**, before
any measured pair. The first warmup completed with additional delay bounded by
7,632.098–7,665.792 ms; the second did not complete after the same deadline stop.
Its phase trace shows 6,060.025 ms of reservation/bulk work, including 1,262.734 ms
for bulk client acceptance. Across roles, the largest pending-operation time was
386.003 ms and checkpoint-commit time 514.996 ms. These wall-time counters include
encoding/sealing/database work and scheduling; they do not isolate `fsync` or
prove that disk alone caused the stall. The separate setup was 7,232.152 ms.
The instrumentation worked, but this run contributes **zero passing latency
samples**. The deadline and normal database synchronization were not relaxed.

Evidence:

- `.local-only/privacy-lab/roles-616220743/` — retained failed first restart run.
- `.local-only/privacy-lab/roles-3384750060/durability-checks.json` — publication
  recovery, with per-process termination/restart evidence in `lifecycle.json`.
- `.local-only/privacy-lab/roles-2402295549/control-checks.json` — fault-control
  recovery. Its older `scopeExcludes` label says “durable recovery”; this run
  verifies local process recovery only, not expulsion/resumed publication.
- `.local-only/privacy-lab/pipeline-5308399a/result.json` — failed 300-pair attempt;
  role directory `roles-651428501` contains resource and cleanup observations.
- `artifacts/privacy-lab/pipeline-durable-analysis-v9.json` — independent
  recomputation from the raw rows, including failed and unattempted counts.
- `artifacts/privacy-lab/device-journal-1a875852d6aa4cf89d3f9c6a9e5b714f/` —
  retained Android parallel-writer failure.
- `artifacts/privacy-lab/device-journal-46dd885b259f40dd9c261d6c84971e02/` —
  passing Android lock/recovery checks and source/binary snapshot.
- `artifacts/privacy-lab/verification-v9.json` — source/binary hashes and cleanup
  verification; a valid evidence hash does not turn a failed experiment into a pass.
- `.local-only/privacy-lab/pipeline-44b25688/result.json` and
  `roles-3307436888/lifecycle.json` — failed diagnostic warmup, phase timing and
  journal timing counters; all eleven role processes reaped.

Complete publisher anonymity, protected application actions, autonomous cover
timing, admission, safe membership changes, physical-route latency and battery
acceptance remain open. The application and APK have not been changed.

## Previous revision: verifiable fault-control transport and certified outputs

The experiment now carries locally generated witness complaints through eight
encrypted control slots across eleven separate TLS processes. All three
coordinators verify every input proof and decryption proof. Clients authenticate
their inclusion, all contributors, all three input commitments and unanimous
signed output certificates. This retains the existing at-least-one-honest-
coordinator assumption while removing redundant client proof verification.
It is **not a complete recovery protocol or an anonymity result**: the failed
news round remains blocked, nobody is expelled, and no reduced cohort publishes.

A negative test demonstrated a decryption oracle when composing this repository's
earlier single-slot fixture with shared server keys across slots. The new control
library uses independent per-slot server keys and mandatory knowledge proofs for
every ephemeral encryption scalar, including owner contributions. Tests reject
that borrowed-ciphertext attack before release. This finding is about our fixture
composition, not a claim about a deployed Verdict implementation.

| Experiment | Result | Scope |
| --- | --- | --- |
| Paced fault investigation, full client proof verification | 17 checks passed; seven honest witness complaints recovered; 5,489.291 ms total; 2,470,463 aggregate TLS bytes. | One injected corruption across eleven local TLS processes, 5 Mbps/direction and 80 ms added per RPC. Includes deliberately rejected requests/retries; excludes setup and resuming news. |
| Paced fault investigation, certified client outputs | 19 checks passed; seven complaints recovered; 4,024.646 ms total; 2,609,630 aggregate TLS bytes. Control-key setup separately 285.027 ms and 55,950 TLS bytes. | Same stated link profile; two additional rejection checks. Separate runs, not a paired latency estimate. Initial anonymous slot setup is also outside this timer. |
| Samsung certified control component, five measured rounds after one warmup | All eleven roles sequentially: p50 3,990.404 ms; maximum 4,064.027 ms. Process CPU p50 4,130.952 ms; maximum 4,193.486 ms. | No sockets, radio, actual fault transcript, scheduled wait or application delivery. USB powered and awake. |
| Samsung in-process ABBA comparison, four rounds per mode after two warmups | Full-verification mean all-role CPU 13,179.022 ms; certified mean 4,122.770 ms, **68.7% less** in this small sample. Certified maximum wall time 4,111.342 ms. | One executable, same live roster, fresh round randomness; full/certified/certified/full repeated twice. This comparison, not the separate earlier run, supports the CPU improvement estimate. |
| Client acceptance within that ABBA component | Mean process CPU 1,137.593 ms with full proofs; 13.632 ms with certificates. Certified contribution creation separately averaged 58.813 ms per client. | 32 role observations per mode nested within four rounds, not 32 independent devices/trials. Runtime/GC costs are included. No steady-state CPU or battery pass. |

The initial five-round phone run before certification took p50 31,168.570 ms
for all eleven roles. Unchanged server operations also ran substantially slower
in that run, so attributing the entire 31-to-4-second difference to the code would
be misleading. The ABBA comparison above reduces that temporal confounding.
Its full-verification p50/max wall time was 12,813.414/13,153.210 ms;
certified p50/max was 3,970.260/4,111.342 ms. Percentiles use nearest rank;
four observations per mode do not characterize tail reliability.

The Samsung was Android 15 / SM-G998W. The ABBA comparison ran USB powered,
awake, at 68% battery, with reported temperature 30.9°C to 31.9°C. The earlier
unoptimized run was at 33.3°C and 63–64%; the separate certified run was at
31.8–32.0°C and 67%. These are recorded conditions, **not battery results**.
No radio or host-network settings were changed.

Validation: **54 Go test functions passed across `roundprobe` and `verdictprobe`,
and both passed `go vet`**. New checks cover signed proof corruption, missing
ephemeral proofs, borrowed ciphertexts, malformed/subgroup encodings, replay,
conflicting roots, forged/missing/duplicate output signers, altered output,
two valid malicious signers without the third, and retry state preservation.
Expensive coordinator proof attempts are capped at three per input/share phase;
missing or unauthenticated batches are rejected before that budget. Exhaustion
keeps the round blocked. This bounds curve verification, not all resource attacks.

The latest normal-publication result remains the previous revision's **20 paired
local application trials with maximum conservative additional delay 3,258.228 ms**,
described below. The new control path activates only after a failed round; its
four-second figures must not be substituted for normal publication latency or
added to it and presented as a successful recovered-delivery measurement.
No safe exclusion/resumption is implemented yet. The physical-route latency,
battery, admission, timing/intersection and complete application-action gates
remain open. Production application source/dependencies and APK remain unchanged.

Evidence retained and hash-verified:

- `.local-only/privacy-lab/roles-4266054430/` — first control investigation.
- `.local-only/privacy-lab/roles-2702699555/` — certified-output investigation,
  19 checks, public transcript and lifecycle for all eleven reaped processes.
- `artifacts/privacy-lab/device-6663b250c33844c8b6310b9782ff33c7/` — original
  full-verification control component, including the slower observations.
- `artifacts/privacy-lab/device-54d8f556f0e841fa8980ac00945311dc/` — certified run.
- `artifacts/privacy-lab/device-4ff1c1a04fe4477b841c23704a469f63/` — ABBA comparison,
  per-role wall/CPU observations, source snapshot, binary and device conditions.
- `artifacts/privacy-lab/verification-v8.json` — all retained source/binary
  hashes matched; device temporary files removed; no research worker left running.

## Previous revision: committed masks and bounded witness investigation

Round wire v2 adds coordinator mask commitments before reveal, pairwise
descriptor-specific key commitments, and randomized cells. The local fault
investigation component verifies slot-authorized witness bits and narrowly
checks rebuttals to false coordinator reports. At this checkpoint it had no
complaint transport, expulsion, or safe session recovery. Production integration remains
disallowed. Earlier rows in this document describe earlier source revisions.

| Current experiment | Result | Limits |
| --- | --- | --- |
| 300 eight-publisher rounds over eleven local TLS roles | All 2,400 measured messages recovered. Median 184.043 ms; p95 891.936 ms; p99 1,391.192 ms; maximum 4,084.325 ms. Mean aggregate role-link TLS payload 4,995,503.32 bytes per reservation/bulk cycle. | No scheduled wait or public delivery; host contention observed nearby. Outliers retained. |
| 20 paired application trials, 5 Mbps per direction and 80 ms added per RPC | All received. Conservative added delay median 2,839.534 ms; p95 3,253.378 ms; maximum 3,258.228 ms. Maximum receipt-observation width 37.170 ms. | Already-established session; same-clock local comparison with application-level link pacing, not mobile/physical network evidence. |
| Initial setup for that paced run | 5,493.734 ms; 573,480 aggregate TLS bytes | Separate from paired publication timings; cannot claim a five-second cold start. |
| Samsung idle component, 300 rounds | All roles sequential: median 8.355 ms; p95 45.677 ms; maximum 59.336 ms. Mean process CPU 14.922 ms/round. | No sockets, radio, scheduled cover workload or battery measurement. |
| Samsung single-publication component, 300 rounds | All roles sequential: median 50.508 ms; p95 92.547 ms; maximum 110.021 ms. Mean process CPU 50.079 ms/round. | Not a per-publisher CPU measurement or end-to-end delay. |
| Samsung eight-publication component, 300 rounds | All roles sequential: median 203.046 ms; p95 247.492 ms; maximum 268.625 ms. Mean process CPU 209.489 ms/round. | Same component limitations; 20 warmups precede each workload. |

The desktop reported 100% processor load during follow-up diagnostics. A
3.259-second process-CPU snapshot during the paced run showed substantial
non-laboratory browser/editor activity. This supports noting contention, but
does not establish its duration or explain every outlier. No user application
was closed and no host networking was changed. These separate runs cannot
establish a causal speed improvement/regression against earlier revisions.

Samsung measurements used Android 15 on SM-G998W with USB power and screen awake,
59% battery before/after, and reported temperature 34.5°C to 34.4°C. An unchanged
charging percentage says nothing about incremental battery cost. At a hypothetical
continuous two-second interval, idle encoded publisher traffic is 1,044 bytes up
plus 1,112 down per round, approximately **88.8 MiB/day**, excluding transport
headers, retransmissions and radio costs. Aggregate inter-coordinator encoded
traffic is 25,650 bytes per idle round. These are projections from the component,
not measured daily usage or a passed resource gate.

Validation: **34 Go test functions and `go vet` passed**, including ten new
accountability/randomization tests. The authenticated adaptive-share test signs
the malicious replacement with the real coordinator key and confirms that the
prior commitment still rejects it. Another test preserves a malicious server's
aggregate bit while framing an honest publisher; the valid one-round-key rebuttal
exposes the lying server. Correct/unsigned reports never authorize opening,
changed local secrets fail closed, and witness disclosure is bounded. **29 socket
fault checks** also pass with role-local setup and wire v2. These checks are not
an anonymity proof; client candidates cannot be automatically expelled on silence.

Evidence retained:

- `.local-only/privacy-lab/roles-3222593177/result.json` — 300 local burst rounds.
- `.local-only/privacy-lab/pipeline-f955d4d9/result.json` — 20 paired trials;
  worker role directory `roles-2417333597`, 29 idle cycles, no worker/public errors.
- `.local-only/privacy-lab/roles-3578145443/network-checks.json` — 29 socket checks.
- `artifacts/privacy-lab/device-2963d1d2da7c47dc90b6d249a3fa7819/` — device source,
  executable, raw rows, hashes, and charging/temperature state.
- `artifacts/privacy-lab/host-load-v7.json` and `verification-v7.json` — contention
  observation and source/binary verification. All retained snapshots match their
  hashes; all eleven children in each role run were reaped and temporary device
  files removed. No test process remains running.

## Measurements collected

| Experiment | Observations | Result and scope |
| --- | --- | --- |
| Current PeerEngine, one local TLS hop | 40 measured posts, 5 warm-ups | Median observed upper bound 143.380 ms; p95 179.565 ms; maximum 194.249 ms. Publication call to verified/flushed reader store visibility. |
| Current PeerEngine, three local TLS hops | 40 measured posts, 5 warm-ups | Median upper bound 269.678 ms; p95 379.502 ms; maximum 423.656 ms. Same endpoint; all engines on one Windows machine. |
| FPP-0 matched protected/direct pipeline | 40 measured pairs, 2 warm-up pairs | Median conservative additional-latency bound 2,568.600 ms; p95 3,485.947 ms; maximum 3,569.062 ms. Identical signed payload, alternating order, two equivalent public-distribution paths. |
| Samsung Sphinx component, 8 KiB payload, 3 unwraps | 2,000 measured packets, 50 warm-ups | Packet creation median 2.647448 ms; creation plus all three unwraps median 4.589740 ms, p95 5.594688 ms. Consumed process CPU 9,996.542 ms over the whole measured phase. No network, cover schedule, app storage or battery measurement. |
| Verifiable shuffle component on Windows | 10 batches after 1 warm-up; 8 clients, 4 KiB each, 3 stages | Median 7,529.491 ms for **all roles computed sequentially**; maximum 7,668.557 ms. This is not a distributed-route latency estimate. |
| Same shuffle component on Samsung | 3 batches after 1 warm-up | Median 6,991.268 ms, maximum 7,146.815 ms for all roles sequentially. Too few samples to characterize tails; no radio/coordination/threshold-decryption cost included. |
| Small slot-key shuffle on Samsung | 30 batches, 32 bytes per client, 8 clients, 3 stages | Median 216.353 ms, p95 279.505 ms, maximum 293.560 ms for all roles sequentially. Still a centralized-key component, not anonymous distributed setup. |
| FPP-1 reservation/bulk component on Samsung, original two-slot variant | 300 idle and 300 single-publication rounds after warmups | Single-publication median 24.378 ms, maximum 73.492 ms for all roles. Source hashes retained; no source snapshot for this earlier run. |
| FPP-1 eight-slot variant on Samsung | 300 observations per workload, 20 warmups each | Idle median 5.393 ms; one publication median 63.175 ms, p95 98.801 ms, maximum 128.372 ms; eight simultaneous publications median 215.080 ms, p95 250.559 ms, maximum 285.409 ms. All roles sequentially; no network or slot wait. Exact source snapshot retained. |
| FPP-1 component-backed matched application pipeline on Windows | 40 measured pairs, 2 warm-up pairs | Median conservative additional bound 1,463.990 ms; p95 1,913.473 ms; maximum 2,071.378 ms. Includes independently scheduled two-second in-memory rounds and real public PeerEngine/storage; **private network transport and distributed setup are excluded**. |
| FPP-1 separate-role TLS application pipeline on Windows | 40 measured pairs, 2 warm-up pairs | Median conservative additional bound 1,417.409 ms; p95 1,680.539 ms; maximum 1,802.340 ms. Includes scheduled rounds, eleven local role processes, actual TLS RPC and real public PeerEngine/storage. Central setup/controller topology remains; physical networks are excluded. |

All publication and paired-pipeline samples in the table above arrived. Maximum receipt observation
interval width was 25.529 ms for the one-hop baseline and 29.627 ms for the
three-hop baseline. The pipeline retains its individual receipt bounds rather
than subtracting the two phones' wall clocks. It starts with signed bytes ready;
publisher signing/outbox and UI rendering are excluded. The independent baseline
starts at the application publish call and must not be interchanged with it.

The local full-application baseline used 4,640.625 ms of process CPU over
18,018.911 ms for one hop, and 9,015.625 ms over 23,640.662 ms for three hops.
That includes every local engine, polling observer and byte-meter task. These
figures are not per-phone CPU use or steady idle overhead.

The paired pipeline's mean Windows CPU costs per measured sample were
103.125 ms for its direct Dart phase and 111.719 ms for its protected Dart phase,
plus 39.063 ms for all simulated mixing roles. Scheduling and observer variation
are retained; these are not isolated CPU instruction costs.

## Bandwidth and security findings

Metered TLS counters passed a separate bidirectional test with known byte
counts. Both application baselines used 63,776 additional TLS-stream bytes per
link during 40 measured posts. IP/TCP headers and retransmissions are excluded.

For the matched experiment, signed channel-plus-news bundles occupied 3,220 to
4,288 bytes. FPP-0 therefore used an 8 KiB padded application cell, whose Sphinx
packet occupies 8,536 bytes. Eight simulated participants through three hops
produced **204,864 TCP payload bytes per batch**, independently counted at reads
and writes. This is aggregate across three links, not per-client usage.

At a continuous two-second client slot, one such cell would cost approximately
351.7 MiB/day **outbound per publisher**, before replies or network headers.
This is an arithmetic projection, not measured daily radio traffic; the present
sample-driven covers do not implement that continuous schedule. It exceeds the
provisional 100 MiB/day incremental publisher budget.

FPP-0's malicious-entry experiment still links the retained input to its public
article after replacing other users' inputs with fresh covers. It therefore
fails the security gate irrespective of its timing. Additional tests verify
actual payload traversal, exact aggregate bytes, replay rejection, corrupted
packet rejection and failure after an interrupted frame. They do not repair
the isolation attack or establish anonymity against traffic correlation.

The verifiable-shuffle component accepts valid proofs and rejects changed
ciphertexts and wrong proof contexts. Its output for the 4 KiB case is a
72,704-byte ciphertext batch plus 9,504 bytes of proofs across three stages.
It still uses a local central key and no network admission/release protocol, so
it has **no end-to-end security pass**. Computing every client sequentially
overstates a distributed route's critical path; missing coordination,
threshold proofs and slot wait understate it. Do not interpret the 7-second
component total as a measured complete route.

## Evidence locations

Raw source fingerprints, individual observations and manifests are kept in
ignored local evidence directories:

- `.local-only/privacy-lab/baseline-a2fbe4c7/result.json`
- `.local-only/privacy-lab/baseline-c8011514/result.json`
- `.local-only/privacy-lab/pipeline-dfff8e37/result.json`
- `artifacts/privacy-lab/device-41245b9ecd244fa7a7a555610d6bbdc5/`
- `artifacts/privacy-lab/windows-shuffle-4096-v1.json`
- `artifacts/privacy-lab/device-4b9d233f509747fb85cfbb9157298f71/`
- `artifacts/privacy-lab/device-6b3abcb78fa440c094f7476ef860ec3a/` (small-key shuffle)
- `artifacts/privacy-lab/device-9b6d67b49f36423cad0f30981dc7c68e/` (earlier round component)
- `artifacts/privacy-lab/device-48ca46c0515342979bf60bbcfd036b26/` (eight-slot component, source snapshot)
- `.local-only/privacy-lab/pipeline-8d2f47ef/result.json` (FPP-1 component-backed pipeline, source/binary snapshot)

The Samsung component runs were awake and USB powered. Their manifests record
temperature and charge state. The listed runs' temporary device directories were removed.
They are explicitly **not controlled battery evidence**. The newer eight-slot
run began at 34% charge and 27.1 C, and ended at 35% and 27.3 C while USB charging.
The older round run and the newer one have different source revisions and
operating conditions. Their timing difference cannot be attributed solely to
the slot-capacity change. Component samples are not paired device/radio trials.

## FPP-1 computation, capacity and resource limits

The revised component's mean process CPU per complete round pair was 63.863 ms
for one publication and 247.840 ms for eight simultaneous publications. Idle
reservation rounds averaged 11.913 ms of process CPU. These aggregate all client
and coordinator roles, signing, validation, serialization and measurement work.
They are not per-phone steady-state CPU percentages or battery predictions.

The original two-slot policy required four rounds to drain an eight-publisher
burst. At a two-second interval, that permits eight seconds of waiting for an
arrival just after a slot, even with zero network/computation time. The revised
eight-slot policy delivers all eight fixture payloads in one round; tests retain
the earlier limitation and verify the revised behavior. Its peak bulk vector is
64 KiB, so network bandwidth may still dominate the five-second target.

Encoded message lengths, measured from actual component serializations:

| Round workload | Each client's upload | Each client's download | Aggregate coordinator-to-coordinator traffic |
| --- | ---: | ---: | ---: |
| Idle reservation | 948 bytes | 1,112 bytes | 22,386 bytes |
| Reservation plus one publication | 9,306 bytes | 9,634 bytes | 207,708 bytes |
| Reservation plus eight publications | 66,664 bytes | 66,992 bytes | 1,469,668 bytes |

These are **encoded model bytes**, not packets measured on a network. At one
idle reservation every two seconds, the client projection is 84.87 MiB/day
bidirectionally, before transport framing, retransmissions and discovery. Each
single-publication round adds about 16.48 KiB per client above its idle round.
For example, 1,000 such group publications per day give about 100.97 MiB per
client, already above the provisional budget before transport overhead. The
coordinators would exchange about 922.27 MiB/day in aggregate while idle under
this deliberately unoptimized full-input-exchange model. These are arithmetic
projections, not mobile-data or energy observations. They identify concrete
traffic costs to address before phone deployment.

The component rejects inconsistent signed input sets, replay, missing shares,
unexpected schedules and malformed/oversized contributions. It can resume an
in-memory round when a previously missing exact signed contribution returns.
That is not a persisted restart, real shutdown or discovery test.

It still deliberately reproduces anonymous jamming by a valid member and
publisher recovery when seven clients and two coordinators collude. It has no
anonymous distributed setup, admission proof, durable state, safe blame protocol,
real private transport or intersection defense. Therefore **security and
integration remain failed/unproven**, regardless of the computation results.

## Next design and measurements

### Role-local verifiable setup and combined protocol

The `fpp1setup` variant connects independently generated role secrets, verified
encrypted slot inputs, three Neff shuffles, all-coordinator agreement and proved
decryption to the existing bulk rounds. Signed X25519 hellos and context-bound
HKDF establish the mask seeds. The controller receives public setup material;
its supplied roster and payload-injection commands remain laboratory fixtures.

| Experiment | Observations | Measured result |
| --- | --- | --- |
| Complete setup on Samsung | Ten setups after one warmup; all eleven roles sequentially | Median wall time 2,829.804 ms; maximum 2,912.282 ms; median process CPU 2,867.259 ms. No network/battery measurement. |
| Setup and single-publication rounds | One setup; 30 measured rounds after five warmups | Setup 900.880 ms and 573,488 aggregate TLS payload bytes. Ready-session round median 15.179 ms, maximum 17.107 ms; no scheduled wait/public delivery. |
| Setup and eight-publisher rounds | One setup; 300 measured rounds after five warmups | All 2,400 measured payloads recovered. Round median 52.174 ms, p95 65.227 ms, maximum 78.830 ms; no scheduled wait/public delivery. |
| Paired application delivery, 5 Mbps/direction and 80 ms added RPC RTT | 20 measured pairs, two warmup pairs | All arrived. Median conservative additional bound 1,651.762 ms; p95 3,216.825 ms; maximum 4,308.932 ms. Setup took another 1,976.642 ms and 573,480 aggregate TLS bytes, measured separately before trials. |

The maximum remains included: its protected pre-public phase was 2,797.451 ms
and receiver-store upper observation was 4,384.665 ms. Much of this sample's delay
occurred after protected release; the measurements do not isolate public
transport, storage and observer causes. Separate-run medians cannot establish
setup's causal effect on steady latency. Maximum receipt observation width was
27.450 ms and 21 idle rounds completed. The archived report's broad `continuous
covers` exclusion means no continuous mobile-radio workload; local idle socket
rounds did run. The current harness makes that distinction explicit.

Ten setup component test functions pass. The node adapter additionally verifies
standard Ed25519 compatibility, matching endpoint seeds, role-secret separation,
pre-setup publication refusal and late-finalization retry safety. All 29 socket
fault checks also pass with the new setup, including coordinator loss without
public release. These are not Sybil, intersection or anonymous-recovery proofs.

Evidence:

- `artifacts/privacy-lab/device-7ccd8e4dbebe4edf843aff2d17032c40/manifest.json`
- `artifacts/privacy-lab/device-7ccd8e4dbebe4edf843aff2d17032c40/result.json`
- `.local-only/privacy-lab/roles-984926973/result.json`
- `.local-only/privacy-lab/roles-3140049886/result.json`
- `.local-only/privacy-lab/roles-3676184922/network-checks.json`
- `.local-only/privacy-lab/pipeline-986cfc1f/result.json`
- `.local-only/privacy-lab/roles-1831414061/anonymous-setup-result.json`

Snapshots include the setup module and pinned dependency manifests. The Samsung
was USB-powered and awake at 48%, with temperature 28.1→28.6°C; the temporary
probe was removed. This is not battery evidence. Ready-session paired results
exclude cold setup, signing/outbox, physical routes and UI. The complete
five-second acceptance gate remains unproven.

### Cached inputs and constrained-link characterization

Coordinators now retain the exact authenticated input batch from their commitment
through release, instead of receiving that entire batch again at finish. Finish
must name the committed root and must not supply replacement inputs. Tests cover
caller-buffer mutation, conflicting roots, exact retry and clearing the bounded
retained batch. A fresh configuration can start only once; the exclusive marker
prevents accidental reuse of that exact file, **not** copying or rollback attacks.
A parent-held pipe closes child listeners if the controller disappears.

New unpaced TLS measurements (300 measured rounds per workload, five warmups):

| Publishers | Median round | p95 | Maximum | Mean aggregate TLS payload |
| --- | --- | --- | --- | --- |
| One | 15.137 ms | 16.792 ms | 23.314 ms | 723,076.84 bytes |
| Eight | 40.595 ms | 57.397 ms | 73.863 ms | 4,974,822.03 bytes |

This removes 28.75% and 29.97% of measured aggregate TLS payload, respectively,
against the earlier uncached runs below. Separate-run timing differences are not
an isolated causal estimate of cache speedup. Transport remains the laboratory
RPC topology, including control traffic. These are not per-publisher daily costs.

Application-level pacing was then applied independently to each role's upload
and download; an additional delay was split before/after each RPC. It does not
simulate TCP congestion, loss, mobile radios or carrier routing and makes no
changes to host networking.

| Profile and workload | Observations | Outcome |
| --- | --- | --- |
| 5,000 kbps each direction, 80 ms additional RPC RTT, eight publishers | 10 measured rounds, five warmups | Median 3,184.460 ms; maximum 3,395.891 ms. **Excludes slot wait and public distribution**; this alone cannot satisfy a five-second total-overhead gate. |
| Same profile, one publisher, scheduled rounds and paired application delivery | 20 measured pairs, two warmup pairs | All arrived. Median conservative additional bound 2,139.773 ms; p95 3,197.178 ms; maximum 3,290.949 ms. Signed bytes ready to verified/flushed store; physical network, signing/outbox and UI excluded. |
| 1,000 kbps each direction, 150 ms additional RPC RTT, eight publishers | Requested ten measured rounds | First warmup failed after 7,006.680 ms; zero measured rounds attempted, ten unattempted. A diagnostic rerun identifies HTTP 400 from a coordinator's bounded commit-request reader. No release or direct fallback. The five-second server read deadline remains in force; failure was not discarded or changed into a successful sample. |

The cached transport has 29 passing socket checks, including parent-lifeline
loss. All eleven children were reaped after each recorded run; successful runs
ended with zero retained input bytes. Exact source/binary snapshots were checked
against their recorded hashes. Evidence:

- `.local-only/privacy-lab/roles-4276033963/result.json`
- `.local-only/privacy-lab/roles-3341552016/result.json`
- `.local-only/privacy-lab/roles-1948132622/result.json`
- `.local-only/privacy-lab/pipeline-5c2581df/result.json`
- `.local-only/privacy-lab/roles-1781884560/lifecycle.json`
- `.local-only/privacy-lab/roles-4198703679/result.json`
- `.local-only/privacy-lab/roles-2335661779/result.json` (diagnostic rerun)
- `.local-only/privacy-lab/roles-2196233065/network-checks.json`

None of these measurements establishes publisher anonymity, a five-second
carrier-route bound, or a battery result. The slower-link failure also shows
why eight-slot capacity cannot be accepted based only on fast local sockets.

### Verifiable contribution primitive on Samsung

The new `verdictprobe` uses the published Verdict ElGamal-style primitive and
Kyber v4.0.2 proofs. Eight clients, three verifying servers and one verifying
recipient execute sequentially in one process. It measures **one anonymous slot**,
not eight slots, reservation/bulk scheduling or a complete hybrid protocol.

| Payload | Measured rounds (after three warmups) | Median all-role wall time | p95 | Maximum | Median process CPU |
| --- | --- | --- | --- | --- | --- |
| 32 bytes | 30 | 182.863 ms | 277.053 ms | 361.700 ms | 184.627 ms |
| 4,288 bytes | 3 | 12,416.028 ms | Insufficient tail sample | 12,527.106 ms | 12,606.493 ms |

The full-payload runs spent 2.39–2.60 seconds in each server's verification/release
phase and 3.30–3.42 seconds in the final recipient. This is a substantial compute
cost even before any network or slot wait. It does not justify putting this
construction on every news payload. The smaller control-message direction
remains worth investigating; these measurements are not an implementation of
safe anonymous accusation or recovery.

Encoded input/share arrays were 6,033/1,417 bytes for the small payload and
265,329/40,687 bytes for the full payload. These are JSON lengths before actual
transport, not total delivered traffic. Setup was measured separately and is
retained in each raw result. The tests reject signed malformed client/server
contributions, proofs from nonowners attempting nonzero covers, changed contexts,
missing/duplicate participants, altered input roots, invalid setup proofs,
noncanonical proof scalars and small-order/mixed-torsion points. An additional
test after these measurements re-signs a contribution under another context to
check the proof binding independently of its outer signature.

Evidence (source/binary snapshots and device state included):

- `artifacts/privacy-lab/device-c596dec9aaca450bb72269860f0130ff/manifest.json`
- `artifacts/privacy-lab/device-c596dec9aaca450bb72269860f0130ff/result.json`
- `artifacts/privacy-lab/device-64dd7ff63dcb41f6bcccfe51c807c328/manifest.json`
- `artifacts/privacy-lab/device-64dd7ff63dcb41f6bcccfe51c807c328/result.json`

Both runs were USB-powered with the screen awake. The small run recorded 39%
charge and 27.4°C before/after; the full run recorded 40% charge and 27.4→28.6°C.
**Neither is a battery test.** Exact test files are snapshotted; later added
tests do not change the measured production component code.

### Separate-role transport evidence

The role-separated experiment uses eight client processes and three coordinator
processes, each with only its own private key material. They exchange actual
TLS 1.3 messages through a laboratory controller on loopback. It retains the
centralized setup fixture and public slot mapping; it does not provide anonymous
setup or independent operating-system security on the shared test computer.

| Workload | Measured rounds | Median | p95 | Maximum | Mean aggregate TLS payload |
| --- | ---: | ---: | ---: | ---: | ---: |
| One publisher, 4,288-byte application payload | 300 after 5 warmups | 25.418 ms | 34.765 ms | 67.621 ms | 1,014,894.72 bytes |
| Eight publishers, 4,288 bytes each | 300 after 5 warmups | 82.037 ms | 105.143 ms | 119.985 ms | 7,104,119.82 bytes |

These durations cover reservation and bulk RPC phases through the final clients'
acceptance certificates. They exclude slot waiting, public gossip/store/UI,
physical networks and battery. Every measured round succeeded with zero failed
or unattempted samples. All owned child processes were reaped after each run.

The byte counts are real encrypted TCP payload counts across **all eleven role
links**, counted once at the controller, and include JSON, TLS records and
laboratory commands. They are not per-publisher traffic. The controller sends
complete input batches repeatedly and injects source messages over control
connections. That topology adds traffic and exposes the simulated sender to an
observer of control-command lengths. It cannot be used as evidence of production
bandwidth or publisher anonymity. It identifies a concrete need to reduce
redundant exchanges before evaluating a phone deployment.

Twenty-eight socket checks passed, including failed mutual authentication,
oversized/truncated JSON, inconsistent contributions/votes, incomplete release
certificates, exact retry and resuming a round when missing packets return.
Killing one owned coordinator stopped the pending bulk publication; no public
release occurred. This is a local process-loss test, not an Iran shutdown test.
There is still no durable phone-restart recovery or malicious-member blame.

Evidence:

- `.local-only/privacy-lab/roles-3754744542/result.json` (single publisher)
- `.local-only/privacy-lab/roles-1117425434/result.json` (eight publishers)
- `.local-only/privacy-lab/roles-1782855640/network-checks.json` (socket checks)

Each role-run directory includes source hashes/snapshots, the executable and
`lifecycle.json` with child CPU/counter and cleanup records. Child CPU totals
include warmups and control operations; they are not directly the per-trial
controller CPU field.

The subsequent matched application pipeline used these separate roles with an
independent two-second round timer. All 40 measured pairs arrived, with no worker,
public-path or proxy errors. The worker exited normally and all eleven child
processes were reaped. The maximum protected-store observation width was
52.324 ms. Twenty idle rounds also ran over actual local sockets. Mean aggregate
TLS payload for each publication round was 1,014,061.7 bytes, including the
laboratory control traffic described above. Exact source/binary snapshots were
verified. Evidence is `.local-only/privacy-lab/pipeline-bb38a500/result.json` and
its role directory `.local-only/privacy-lab/roles-2056109334/`.

Its median direct-store upper bound was 201.959 ms and protected-store upper
bound 1,582.438 ms. The earlier in-memory run had different observations and
scheduling phases; these independent runs are not evidence that adding sockets
made the protocol faster. The matched additional bounds apply only to this
controlled run. The five-second physical-route gate remains unproven.

The FPP-1 component-backed application run used one Dart monotonic clock and
identical signed bundles in separate equivalent public stores. It varied request
phase against an independently running two-second component timer, which also
processed 19 idle rounds during the run. All 40 measured pairs arrived. Maximum
protected-store observation width was 42.482 ms; the worker exited normally with
no public-path or proxy errors. Its archived source/binary hashes were verified.
Median direct-store upper bound was 160.089 ms and protected-store upper bound
1,589.995 ms. Conservative overhead quantiles are recorded in the table above.

This is **not a private-network delivery measurement**. The application public
path uses real local TLS and storage, while all private roles and their common
state live in one Go process. Idle rounds are computations, not radio cover
traffic. FPP-0 included local private TCP stages and different waiting rules, so
subtracting the two candidates' medians would not isolate an algorithmic speedup.
Publisher signing, durable outbox, UI visibility and real radio remain excluded.
The later local-batch preflight regression is newer than this archived binary;
the evidence snapshot identifies exactly which source was measured.

The FPP-1 experiment moves toward expensive anonymity setup outside each news
item and a lighter bulk-publication phase. Dissent's authenticated group
setup and scheduled DC-net transmission are relevant prior work; its dependency
on a stable set of coordinating participants would have to work on phones.
Moving those roles into one APK does not solve reachability or churn.

Before treating that direction as viable, measure its slot-reservation/setup,
per-publication CPU, **idle radio schedule**, bandwidth and failure recovery.
Test selective omission, inconsistent participant sets, replay across epochs,
malicious participants jamming slots and repeated membership changes. Public
release must depend on the same authenticated input set; an isolated client
must not silently publish or recover through ordinary gossip.

The bulk component is implemented, but the complete candidate and its security
properties are not. Prior work does not provide an inherited proof:
[Dissent in Numbers](https://www.usenix.org/conference/osdi12/technical-sessions/presentation/wolinsky),
[Dissent's later security analysis](https://bford.info/pub/sec/dissent-analysis/),
[Verdict](https://bford.info/pub/sec/verdict/).

Still open: full cold-start/signing/outbox/UI timing; physical Wi-Fi/mobile
routes; 300-pair acceptance profiles; controlled battery ABBA trials; complete
membership/discovery/management/image design; sustained spam/churn and shutdown
recovery; correlation evaluation; independent review and conditional integration.
The four-part legacy readiness deferral does not waive these new experiment gates.
