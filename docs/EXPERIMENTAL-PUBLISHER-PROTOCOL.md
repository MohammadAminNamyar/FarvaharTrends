# Protected publication experiment

Status: research in progress, not included in FarvaharTrends 0.8.14. No publisher
anonymity claim. The first candidate has a reproduced security failure.

## Objective and integration rule

Protect the association between a publishing device and its public signed news,
then use ordinary fast public distribution. Aim for no more than approximately
5 seconds of **additional** latency on a healthy reachable route. Delivery,
receiving and forwarding remain in one intended APK. Research executables are
temporary measurement tools, not a separate helper product. Preserve installed
data; do not modify host routing, VPN, firewall or adapters.

The goal covers measurement, threat model, design, prototype/adversarial tests,
evaluation, and conditional integration. A fast prototype is not an integration
approval. Missing security or resource evidence keeps integration closed.

### User priorities: security and delivery outcomes

The user's latest clarification makes membership and distributed membership
implementation options, not the objective. Evaluate every proposed component
against publisher protection, fast propagation, low CPU/storage/battery use,
channel authenticity and resistance to spam. Entering a password is acceptable;
this does not by itself authorize a shared network password, a central service,
or replacing the earlier automatic-joining requirement with approved people.

Keep transport participation separate from channel publication authority. A
phone forwarding news does not gain permission to create, replace or remove
another channel's signed content. Preserve and audit existing signing, editor
delegation/revocation and recovery-kit mechanisms before proposing replacements.
An authentic channel invitation must establish the expected channel key; a name
alone cannot distinguish the original from an imitation. Password protection of
a recovery kit does not hide the publisher's network origin. Signature validity
establishes authorization/integrity, not the factual truth of a news article.

The user explicitly accepts that authorized news may be false and that channel
authentication does not itself hide the writer's network origin. A network-wide
user registry is not required for channel authentication or public forwarding.
The current protected-round construction requires a consistent participant set;
that is a construction-specific requirement to evaluate, not a product goal.
Removing a registry does not establish that routing participants are independent
or prevent an adversary from controlling a publisher's available relays.

Prioritize bounded receiver-wide work and storage across changing identities,
cheap rejection before expensive processing, and public distribution after a
protected release. Keep protected-submission latency, startup/recovery costs and
anonymity evidence explicit. Do not add a replicated global membership ledger,
proof-of-work or credential infrastructure merely to satisfy a mechanism choice.
Any such component must demonstrate a necessary benefit within the resource and
latency gates. The experimental prototype remains excluded from the production
APK until its security, latency and resource gates pass.

### Frozen completion policy experiment (v22)

The opt-in `fpp1frozen` candidate separates admission of fresh news from completion
of work already selected for a round. Fresh reservation preparation retains the
original signed two-second window and 100 ms assumed clock bound. An explicitly
configured, signed v2 schedule grants exactly two additional seconds only to
coordinator commitments of the full authenticated input set and client bulk work
derived from the already pinned reservation. Fused acceptance still verifies
the unanimous reservation certificate before preparing bulk. Neither empty
clients nor clients with pinned news may select newer queue contents during
this completion interval. Legacy schedules and the strict default remain v1.

This changes a security-sensitive policy; it is not merely a speed optimization
or an inherited proof from Dissent. Full-set authentication, immutable payload
pins, exact descriptor/state checks, clock discontinuity fences, synchronized
checkpoints and replay bounds remain required. Restart cannot recreate the live
clock anchor. Exact committed replies may be retrieved, but new work still
requires admission to a new epoch, whose safe queue migration is not implemented.

The candidate also changes the pipeline's requested admission lead from four to
two seconds. Existing vote (at least one second remaining) and installation
(at least 100 ms remaining) checks are unchanged. Missed admission fails closed.
Startup observations are retained; reducing a configured wait is not evidence
of reduced cryptographic CPU. The previous strict-policy failures remain valid
results for their original binaries and are not reclassified as passes.

Adversarial component tests precede native/socket validation and the declared
300-pair timing trial. A functional pass still leaves response-work correlation,
independent membership/Sybil resistance, autonomous uniform traffic, physical
clock admission, shutdown recovery, all-action coverage and resource gates open.

### Combined reservation acceptance and bulk preparation (v14 experiment)

The opt-in `fpp1fused` adapter keeps the two-second signed schedule, 100 ms
assumed clock bound, cohort, output certificates and frozen queue eligibility.
After verifying the reservation certificate, each client derives the bulk
descriptor from that certified output and prepares its already pinned item in
the same journaled operation. Both state transitions and the exact retry
response are synchronized before a contribution can leave the process. The
common window is checked before disk work and again inside preparation.
Idle reservations do not create bulk contributions. The next coordinator
commit still requires every client's authenticated input.

This removes one controller/client RPC phase and one pending/state write pair
per active client round. It does not remove a signature, participant, durable
boundary, deadline or fail-closed rule. The former separate exchanges remain
available as `fpp1scheduled` for comparison. A crash before the combined commit
cannot release its contribution; a restart after commit can return the exact
cached ciphertext but cannot re-arm a fresh scheduled publication.

Before measuring this variant, the prediction is reduced round work, not a
passed latency or security gate. Retain failed attempts and all unattempted
pairs. Run the certificate/cutoff/restart/commit-failure regressions, socket
checks, then the identical paired application profile (5,000 kbps per direction,
80 ms added RPC delay). All acceptance thresholds remain unchanged.
Response-work correlation, clock admission, membership, autonomous traffic,
physical paths, continuous resource use and controlled battery remain open.

### Publication checkpoint experiment (v16)

The opt-in `fpp1atomic` adapter retains the fused phases and signed two-second
schedule, but uses one synchronized transaction for ordinary publication
operations. Its local configuration explicitly enables this behavior; peers
cannot enable it through a request. Only client prepare/accept/combined
acceptance-preparation and coordinator commit/release/finish are eligible.
Local enqueue, setup, clock admission, disclosure/control and unknown operations
retain their pending-operation records and interrupted-work limits.

The invariant is that `execute` has no external side effects for these allowed
operations: it computes an in-memory result. The journal then persists the
complete resulting state, bounded exact-response cache and outbox changes in a
single transaction, with database synchronization enabled. Only then can
`handle` return a response to the transport. Even a protocol error must commit
any state it consumed. A failed commit poisons the live role and prevents its
in-memory cached response from escaping.

A process exit before commit leaves the last acknowledged state. There is no
new pending request to execute automatically after recovery, so unacknowledged
work can be lost. Previously committed queue contents remain. After commit,
an exact retry returns the saved response. Restarted scheduled roles still
cannot prepare fresh contributions using the old clock anchor; this change
does not implement epoch migration or remove that availability limitation.
The pending-operation interrupted-work counter does not apply to this new
publication path; fresh scheduled work is fenced on restart. Other operations
retain the prior counter. Physical storage rollback, repeated power-loss
behavior and compromised endpoints remain outside this crash-only experiment.

Validation includes actual child-process exits before and after commits for
all bulk operations, failed writes, exact-response retries, unchanged queue
eligibility, certificate/cutoff rejection, and complete active/idle rounds.
These tests do not establish publisher anonymity or a five-second latency
bound. The original `fpp1fused` mode remains available for comparison. Preserve
all failed timing attempts. This v16 comparison retains the original window and
synchronization. A later policy experiment must declare a distinct candidate,
retest its security invariants and retain all original failures; see v22 above.

## Native Android apparatus and emulator-first validation (v17)

The optional Android worker runs the complete private role path as native
processes while the paired public stores and monotonic observer remain on the
host. Source and binary snapshots bind each run. The native runtime and ABI are
checked before measurements; USB/control overhead remains in the protected arm.
Eleven roles on one device do not represent eleven independent phones, mobile
reachability, or a battery experiment.

At the user's request, further testing proceeds on the emulator until its
findings are addressed and the user is ready for physical validation. The
emulator's native regression suite covers controlled-clock boundaries, altered
messages, durable queues and actual child-process crashes. It is separate from
the real-time scheduled delivery test: the latter already missed its unchanged
common window on the emulator. Functional passes cannot replace that failure or
prove the five-second, resource or publisher-security gates.

## Measurement contract

Record the source tree hashes, toolchain, device, network class, sample count,
warm-up observations, all failed/unattempted samples and raw timestamps. Use
UTC for labels and monotonic clocks for durations. Do not subtract the wall
clock on one phone from another phone's wall clock.

Measure and label these endpoints separately:

1. User submission to local encrypted-outbox commit.
2. Submission to first public release after the protected path.
3. Submission to a reader's verified, flushed store.
4. Submission to UI visibility, when instrumented; storage is not UI rendering.

For local runs, one coordinator's monotonic clock covers the whole pipeline.
For separate devices, use coordinator-observed intervals or a returned
measurement receipt. A receipt round-trip is an upper bound, not one-way latency;
its delay is not halved or subtracted by assumption. Diagnostic acknowledgements
must stay in isolated lab traffic, not normal public news. A polling observer
records the last absent and first present observation, including read cost.

Direct and protected modes must use identical payloads, signing, storage,
public distribution, topology and load. Alternate their order across runs;
include idle cover time, setup separately, and disconnected/failed samples.
Comparing a crypto microbenchmark against full application delivery is invalid.
For interval-valued observations, paired overhead is bounded by
`[protected.lower - direct.upper, protected.upper - direct.lower]`.

CPU means kernel + user process CPU time over a documented phase, including all
threads; also report wall time, average cores and memory. Battery is a separate
physical measurement. TLS-stream byte counters exclude IP/TCP overhead,
retransmissions, radio signalling and discovery; report these exclusions.
Actual Android per-UID/radio accounting is a separate measurement.

Controlled battery comparison: physically unplug, keep screen state, signal,
temperature, other apps and message workload comparable, alternate baseline and
candidate in ABBA order, and repeat. Record charge-counter resolution, battery
temperature, network transitions, elapsed time and charging state. Reject
charging/streaming/mismatched trials; never simulate unplugging with `dumpsys
battery unplug`. Whole-phone percentage changes alone cannot establish a small
incremental app cost. Phone-powered CPU tests over USB are not battery tests.

## Provisional acceptance gates

The five-second requirement comes from the user. The other ceilings below are
initial engineering budgets, not user-approved security tolerances or results.
Changes require a recorded rationale before looking at a new candidate's result.

| Gate | Evidence required |
| --- | --- |
| Measurement | Reproducible source/build fingerprints; raw paired observations; correct endpoints; no hidden retries, dropped failures or cross-device clock subtraction. |
| Connected latency | At least 300 paired text submissions per supported healthy-route profile, including long Farsi text. All observed conservative overhead bounds <= 5,000 ms, and no unexplained failures. Report median/p95/p99/max, observation error and tail confidence; this is an empirical gate, not a universal deadline. |
| CPU | On supported physical phones, incremental steady-state publisher CPU <= 1% of one core averaged over the observation period; publication/relay spikes and other roles reported separately. |
| Bandwidth | Initial target <= 100 MiB/day incremental publisher traffic for the declared text workload, counting both directions and continuous covers; no extrapolation from publication bursts alone. Relay and image costs separately bounded. |
| Battery | Initial target <= 5 additional battery percentage points per 12 hours for the declared workload on both mobile data and Wi-Fi. Controlled repeated measurements and their uncertainty must support this; insufficient resolution means unproven. |
| Security | No demonstrated publisher-linking attack within the declared adversary assumptions. Negative tests are necessary, not a proof. Document protocol reasoning and independent review gaps before any real-publisher protection claim. |
| Resource/abuse | Bounded queues, retry work, replay retention, cryptographic work and disk use under churn/replay/spam. A full queue or lost protected path queues/rejects explicitly; never switches to direct public publication. |
| Shutdown | Test disabled external discovery, reachable domestic paths, lost routes, stale membership, complete partition and recovery. No publication leaks from recovery, image retrieval or management actions. |

## Threat model

Target adversary: observes relevant access links and public article releases;
knows public articles and channel identities; controls some peers; can inject,
replay, delay, drop or replace traffic and create many identities. It may correlate
events over many publications and exploit outages or membership changes.

An IP-hiding transport alone is insufficient. Public timestamps, writer names,
image sizes, repeated retries, channel creation, deletion and key rotation can
also link activity. Publisher connection keys and public signing keys must stay
separate. Signing establishes authorization, not human anonymity or news truth.

Assumptions that must be justified: sufficient honest distinct participants,
authenticated consistent membership, at least the honest mixing/release roles
required by the chosen protocol, and some surviving route. A list of eight keys
is not evidence of eight independent people. Public discovery or IP diversity
alone is not Sybil resistance. New identities cannot automatically count toward
a security threshold.

The measured approximately 95 MiB/day/client idle TLS projection in v21 is a
resource observation, not a per-identity quota or an admission defense. The
100 MiB/day design target is likewise an acceptance target for resource use.
Changing a publisher key, channel, device ID, installation or emulated device
must not create additional allowance on a receiving phone. Proposed receiver
budgets must bound total concurrent work, queued bytes, retained state and
verification work across all senders, including admission/reconnection work.
Those bounds can limit local damage; they cannot prevent a sufficiently large
attacker from consuming capacity or blocking delivery. Traffic can consume
network/radio resources before the application rejects it.

Unique public keys identify signing credentials, not independent humans or
physical phones. Device identifiers, IP diversity and hardware attestation do
not establish independent ownership. A protected cohort therefore still needs
an explicit, justified honest-membership assumption and admission policy.
Multiple signatures or invitations help only if their issuers are sufficiently
independent and not compromised; a web of newly generated keys is not proof.
Open public reading/forwarding need not grant admission to a protected cohort.
This is a proposed separation, not an implemented Sybil defense or a claim that
controlled admission makes the present prototype anonymous.

Background: [Douceur, The Sybil Attack (2002)](https://www.microsoft.com/en-us/research/publication/the-sybil-attack/).

### Automatic mesh membership: clarified user requirement

Unknown phones must be able to join protected groups automatically. A design
requiring preapproved human membership does not satisfy this requirement. The
current laboratory's supplied roster is therefore an apparatus limitation, not
an acceptable final admission mechanism. No central or foreign membership
service may be introduced as a hidden dependency.

The research direction is to distribute membership state while separating it
from an article's public signing identity. Phones can exchange signed membership
claims and locally verify cached records. A new public key establishes control
of that key, not another person, device, vote or allocation of scarce resources.
Replicating the claims cannot establish those missing properties. Automatically
counting signatures from a self-created cluster would reproduce the attack.

Candidate components to evaluate, rather than an implemented secure protocol:

1. Bounded signed membership advertisements carried through reachable IP paths,
   nearby radios and store-and-forward. Keep replicated records finite; handle
   conflicting claims explicitly. Do not publish a directory connecting channel
   authors to device/IP identities or social contacts.
2. Receiver-wide admission, connection, verification and storage budgets, shared
   across all incoming identities. Reconnection, failed work and key replacement
   cannot refund consumed work. These bound application workload but cannot stop
   upstream/radio flooding or ensure legitimate traffic wins under saturation.
3. Automatically acquired, renewable participation evidence based on a declared
   scarce resource, as a hypothesis to compare against identity-only admission.
   Computational puzzles impose attacker cost but also cost honest phone energy;
   they do not prove personhood or resist an unbounded resource adversary. Any
   work must be measured against the existing CPU/battery gates. Do not claim
   identity age, forwarding receipts or witness signatures are scarce unless
   colluding peers cannot cheaply manufacture them.
4. Established anonymous credentials may decouple authorization from subsequent
   presentations. Coconut demonstrates threshold issuance and unlinkable showing;
   it assumes an issuer threshold and does not solve selection of independent
   issuers. Privacy Pass similarly separates attestation/issuance/redemption and
   explicitly retains trust and network-metadata assumptions. Neither is a
   drop-in solution to unrestricted automatic membership on phones.
5. Keep admission outside ordinary article processing where possible, while
   measuring first-use and renewal delays separately and retaining all startup
   observations. Protected routing, cover traffic and timing-correlation defenses
   are still needed: an anonymous credential alone does not hide a source IP.

During complete partitions there is no instantaneous global membership or spent
token state. Cached credentials can be verified within their scope, but globally
unique spending or immediate revocation cannot be promised independently in both
partitions. Prefer explicitly bounded local allocation and reconciliation over
silently assuming global agreement. Safe protected-cohort formation and recovery
remain open, including the attacker capturing every candidate peer a publisher
can reach. At least the protocol's required non-colluding participants must exist;
there is currently no evidence that automatic discovery supplies them.

The next adversarial evaluation must cover mass fresh keys/emulated devices,
fabricated referral/work histories, flooding across reconnects, eclipse/cohort
capture, split/rejoined membership views and resource-ticket replay. Report
attacker-resource assumptions and attack success separately from CPU/latency.
These are research hypotheses, not permission to integrate or advertise anonymity.

Primary sources: [Coconut](https://sonnino.com/papers/coconut.pdf),
[SybilControl](https://arxiv.org/abs/1201.2657),
[Privacy Pass architecture](https://www.rfc-editor.org/rfc/rfc9576.html),
[Gilbert and Lynch on partition tradeoffs](https://www.comp.nus.edu.sg/~gilbert/pubs/BrewersConjecture-SigAct.pdf).

Non-goals: hide a phone/SIM's existence from its provider; survive a compromised
publisher endpoint; make nearby radios physically invisible; protect against
every relay colluding; guarantee reader/subscription anonymity through ordinary
public gossip; guarantee delivery through a permanent physical partition.
These exclusions must not be expanded later merely to make an attack pass.

## Proposed architecture

An isolated, versioned submission envelope carries a signed application action
inside established layered encryption. A publication path mixes equal-size
cells with scheduled cover traffic. The schedule must not start or change only
because someone publishes. A release role verifies and releases the original
signed application action; it does not acquire publisher signing authority.
Only then does ordinary deduplicated public gossip begin.

All publisher actions use this boundary: channel creation, text, writer/owner
changes, deletion/recovery, image descriptors and image chunks. Fragmentation,
image retrieval and retries must not make the original phone an identifiable
public content server. Until an action is supported, retain/reject it explicitly
instead of sending it outside the protected path. Public timestamps and local
composition timestamps need separate treatment; exact private event times must
not be included by accident in public signed actions.

Domestic operation needs locally retained authenticated membership and contact
information, nearby exchange of updates and a defined expiry/revocation policy.
Cached addresses are connectivity hints, not authority. If the membership view
cannot be validated, protected publication waits. No mandatory live foreign
directory lookup. NAT restrictions can still remove a route.

When only nearby links remain, carry sealed submissions between phones and
resume the protected protocol when its prerequisites are satisfied. Holding
encrypted bytes is not itself proof of anonymity. A message originating outside
the disconnected region still needs a surviving link or physical transfer into
it. Restored connectivity must not trigger a distinctive publisher retry burst.

## Candidate FPP-0: useful negative result

Implemented only under `tools/privacy_lab/sphinxprobe`: upstream Sphinx packets,
three local mix transformations, eight simulated inputs, two-second client slot
waits and 500 ms per-hop hold. This is not the complete Katzenpost/Echomix
protocol, and the sample-driven cover generator is not continuous real-world
cover traffic. Its timing result cannot validate battery or anonymity.

The malicious entry retains a target input and replaces the other seven inputs
with fresh valid covers for the remaining route. Downstream batch counts and
freshness still pass. Public release identifies the retained target. This
defeats the candidate even when later hops are honest. Adding hops, shortening
the slot, counting distinct keys or adding a replay cache does not repair it.

The next design question is whether accountable batch admission and an audited
verifiable shuffle/release construction can prevent selective release without
introducing unacceptable latency, coordination or phone costs. A signed batch
receipt alone does not prove an output is a permutation of committed inputs.
Do not implement a homemade shuffle proof or claim that Sphinx solves this.
Compare established constructions and preserve adversarial regressions before
choosing the next candidate.

## Evidence and remaining work

- `baseline.dart`: actual current PeerEngine, isolated pinned TLS loopback,
  source fingerprints, monotonic receipt bounds, CPU and metered TLS bytes.
- `measurement_check.dart`: independent exact byte-count and CPU apparatus checks.
- `sphinxprobe`: pinned upstream crypto cost on Windows/Android and a local
  FPP-0 candidate with a reproduced active isolation attack.
- `submission_pipeline.dart`: identical signed bundles through FPP-0 or a direct
  control, followed by equivalent actual PeerEngine distribution; observer
  intervals and both Dart and Go CPU costs retained. Not a full UI/outbox trial.
- `shuffleprobe`: established verifiable sequence-shuffle cost and component
  tamper checks on Windows/Samsung; no threshold release or production security.
- `roundprobe`: fixed-cohort reservation and DC-net bulk-round component, with
  authenticated common input sets, negative attack tests and Samsung computation
  measurements. Centrally assigned slots/seeds are a fixture, not secure setup.
  A further mode runs eleven separate role processes over mutually authenticated
  local TLS. Each role receives only its own secrets and maintains its own state;
  the setup and orchestration remain centrally controlled laboratory fixtures.
- Raw reports live under ignored `artifacts/privacy-lab` and
  `.local-only/privacy-lab`; they are measurements, not integration approval.
- See `PUBLISHER-LAB-RESULTS.md` for measured scope and failed/unproven gates.
- Still required: complete protected/direct application pipeline including UI/outbox;
  physical-network timing and resource trials; controlled battery runs;
  stronger candidate design; correlation/churn/replay/spam/shutdown/recovery
  evaluation; full gate audit and only then conditional application integration.

References: [Echomix design and threat model](https://arxiv.org/html/2501.02933v2),
[smartphone energy study](https://www.usenix.org/system/files/usenixsecurity23-hugenroth.pdf),
[Moby blackout research](https://petsymposium.org/popets/2022/popets-2022-0071.pdf).
These systems' security guarantees do not automatically transfer to this design.

## Candidate FPP-1: reservation and bulk rounds (experimental)

This is a new application composition of established ideas, **not a new proven
cryptographic primitive**, a complete Dissent implementation, or publisher
protection ready for deployment. `tools/privacy_lab/roundprobe` measures the bulk
component. The initial experimental group has eight clients and three
coordinating roles. A phone could perform either role in the intended one APK;
being a phone does not hide its address, eliminate trust assumptions or ensure
that its route remains available.

Proposed setup is an authenticated roster, pairwise client/coordinator key
establishment, and a verifiable shuffle of small anonymous slot public keys.
Do expensive setup before accepting time-sensitive publication. Report cold
setup, membership replacement and reconnection delays separately; do not hide
them from the user-facing experience. The implemented fixture generates shared
seeds and assigns slots centrally. The separate small-key shuffle benchmark
does not supply distributed key generation, threshold release or authenticated
setup to this component.

The component implements the following round rules:

1. Every client contributes an equally sized masked reservation vector, whether
   it has news or not. Each anonymous slot is 96 bytes. Active slots include a
   signed request. Round number, phase, roster-derived random epoch and the
   preceding agreed reservation output are bound into cryptographic contexts.
2. Each coordinator validates the complete fixed input set and signs its hash.
   It releases its aggregate mask only after seeing all three signatures on
   that same set. Missing clients, substitutions, contradictory sets or a lost
   coordinator stop the round. There is no automatic smaller group or public
   submission fallback.
3. The public reservation result determines the same bulk layout for everyone.
   All clients contribute to that layout, including those with nothing to send.
   Active slots contain padded signed payloads; other contributions are masks.
   The prototype uses 8 KiB per active slot and checks exact recovered bytes.
4. Payloads are accepted only after all required contributions and slot
   signatures validate. An output certificate authenticates this result. It
   does not make intermediate mask shares secret or provide threshold release.
5. Ordinary public news dissemination would start after this boundary. Channel
   creation, owner/writer actions, recovery, deletion and images must enter the
   same opaque envelope path. The application adapter and encrypted durable
   outbox for these operations have **not** been implemented. Unsupported or
   oversized actions must be queued/rejected, never leaked through public gossip.

The experimental pad construction uses standard HMAC-SHA-256 and AES-CTR with
a distinct derived key per round descriptor; signatures use standard Ed25519.
This describes the component implementation, not a security recommendation.
Durable anti-rollback state, authenticated key exchange, secure key handling and
an independent analysis of the composition are still required.

### Capacity and schedule

Two-second reservation intervals are a proposed operating point, not a measured
radio schedule. The original two-slot cap fails a simultaneous-eight-publisher
case: four rounds are needed, allowing an eight-second wait even before network
and computation costs. A regression reproduces the four actual protocol rounds.
The revised experimental capacity allows all eight clients one bounded 8 KiB
slot each in the next bulk round. Its peak vector is 64 KiB. Both policies are
retained in tests; widening capacity is not a guarantee under arbitrary load.
More than one pending message per writer, fragmented images, slow links or
spam can still require queuing. Deadline and load assumptions must be measured
and visible rather than silently discarding difficult observations.

### Active attacks and remaining failures

Tests exercise real signed/masked component data. They reject omitted/replaced
inputs, duplicated identities, oversized input, validly signed conflicting input
sets, cross-round/cross-epoch replay and unexpected bulk schedules. These tests
are not an anonymity proof or a simulation of national network monitoring.

Two deliberate negative tests remain essential:

- A legitimate client can submit a signed but invalid mask and jam a round.
  Signature verification cannot prove that a contributor used the correct
  private pads or slot. The component detects invalid output but cannot safely
  identify the disruptor or recover. An established proactive proof or accountable
  blame protocol is needed; simply removing suspects risks anonymity.
- Seven colluding clients and two colluding coordinators recover the eighth
  client's contribution despite the third coordinator being honest. They
  subtract the seven masks known to those clients from the honest coordinator's
  aggregate. A group of eight keys is not eight honest people. Admission must
  justify an honest anonymity set; public discovery alone cannot do that.

The fixed cohort also sacrifices availability when a member leaves. That is a
real gap for mobile phones and shutdowns, not a passed churn test. A new epoch
rejects old inputs, but safe membership changes, durable recovery and defense
against intersection of participant sets across publications remain open.

### Legacy role-separated transport experiment

The isolated role RPC mode now exchanges actual messages over loopback TLS 1.3.
It rejects unauthenticated controllers and bounds request bodies, per-role
processing concurrency and successful-reply caches. Exact retries return the
same cached response without creating another masked contribution. Socket tests
cover missing/altered contributions, invalid commitments, incomplete certificates
and coordinator loss. These tests establish laboratory behavior, not public
Internet flood resistance or persisted phone-restart safety.

Role separation removes the requirement for each running role to hold everyone's
secret material. It does **not** remove the trusted fixture that initially assigns
slots and seeds. All processes run under the same host account without an OS
sandbox. The controller supplies simulated user input over RPC, so command sizes
expose the simulated sender; the harness is not an anonymity trial. Its repeated
full-batch transfers and JSON serialization also inflate traffic. Production
topology, local user input, anonymous key setup, peer discovery and authenticated
key establishment must replace those fixtures before an anonymity assessment.

The current cache revision retains one exact validated batch through finish and
clears it afterward; finish rejects replacement inputs and a different root.
An exclusive configuration marker prevents accidentally starting the same test
epoch twice, but does not prevent copying the configuration or rolling back its
filesystem. Parent pipe closure stops child listeners. These are laboratory
resource/lifecycle safeguards, not mobile durable state.

Measured traffic dropped about 29% with caching. Application-level paced tests
still failed at 1 Mbps / 150 ms additional RPC RTT with eight publishers. The
5 Mbps / 80 ms single-publisher paired test stayed under five seconds in twenty
observations, but it does not satisfy the physical-route acceptance gate. No
anonymity or resource requirement is relaxed to make the timing test pass.

### Domestic connectivity and observability

The intended roster and its authenticated updates must be available locally;
foreign discovery cannot be required for every round. Cached addresses and
nearby exchanges supply route hints only. The crypto component has no discovery
implementation and does not solve NAT or blocked domestic routes. If only nearby
transport survives, it must preserve the same protected round rules or carry
queued encrypted data until those rules can be satisfied. The latency target
cannot be guaranteed across a physical partition.

A regular client schedule must run independently of publishing. Radio wakeups,
reconnections, retransmissions, joining/leaving a group and image fetches can
still expose activity. Neither the current component nor its USB-powered CPU
test establishes resistance to those observations or acceptable battery use.

Prior work: [Dissent in Numbers](https://www.usenix.org/conference/osdi12/technical-sessions/presentation/wolinsky),
[later Dissent security analysis](https://bford.info/pub/sec/dissent-analysis/),
[Verdict](https://bford.info/pub/sec/verdict/).

## Verifiable contribution component: scope and decision

The new `verdictprobe` is an isolated implementation of the published ElGamal
primitive in Verdict section 5.2, using Kyber's proof APIs. It tests whether a
small control message can have checked contributions before release. It is
neither the complete Verdict system nor a novel, reviewed cryptographic scheme.
All identity and slot keys remain centrally provisioned in the fixture.

Every client supplies a signed, fixed-shape contribution for one slot. A proof
shows either a correctly formed cover or knowledge of that slot's key. Each
server verifies the entire fixed roster before producing a proved cancellation
share; one recipient verifies all contributions and shares and checks the
actual recovered payload. Contexts bind epoch, sequence, slot, size, participant,
public statement and, for a share, the input-set root. Setup includes proof of
server-key knowledge. Encodings have fixed limits, canonical scalars and prime
subgroup checks, including proof commitments. The pinned generic proof encoding
must be re-reviewed before any library upgrade.

Signed malformed covers and shares are rejected in the component tests. This
only establishes tested primitive behavior: safe accusation, exclusion,
consistent membership changes and preventing repeated disruption are separate
protocol work. An absent client still stops the fixed-roster round. Cross-context
proof replay is rejected; **the primitive has no stateful same-context replay
journal**, anonymous setup, network agreement or crash recovery. It cannot be
substituted for those missing parts of FPP-1.

On the Samsung, the 32-byte one-slot workload had a median 182.863 ms and maximum
361.700 ms across 30 measured rounds. A 4,288-byte workload had a median
12,416.028 ms across only three measured rounds, including about 3.3–3.4 seconds
at the final verifier alone. These totals compute every role sequentially and
are not distributed network latency. They exclude radio and slot wait.

Decision: do not put this full-message construction on the publication path.
The small-message construction remains a candidate for an occasional anonymous
control/accusation path, following the established hybrid direction, subject to
composition analysis and further measurements. No battery savings, five-second
deadline under attack, or anonymity result follows from this microbenchmark.
The initial hybrid design and the published literature do not eliminate the
remaining admission, intersection, reachability and radio-resource constraints.

## Role-local verifiable setup integrated into the bulk experiment

The optional `network-setup` / `fpp1setup` experiment replaces central slot and
mask-seed assignment with role-local generation. It connects
`setupprobe/setup` to the existing round protocol through `node_setup.go`.
Legacy modes remain for reproducibility. This combines established primitives;
it is not a reviewed cryptographic construction or inherited anonymity proof.

1. Each process generates its identity, session nonce and X25519 key locally.
   Each coordinator also generates an ElGamal decryption-share key and proves
   knowledge of it. Signed hellos are checked against an explicit roster.
2. Each client encrypts its independently generated Ed25519 slot public point
   under the aggregate coordinator key and proves knowledge of the encryption
   scalar and encrypted slot-key scalar. No owner mapping is transmitted.
3. Three coordinators sequentially rerandomize/shuffle these ciphertexts using
   Kyber's Neff shuffle. Signatures, proofs and chained roots bind the fixed
   input set, epoch, stage and output. Each role accepts one input transcript;
   exact retries return its original result.
4. All three coordinators verify and sign the final transcript before releasing
   proved partial decryptions. Missing participants, skipped stages or conflicting
   votes fail. This is all-three release, not threshold availability.
5. Every role verifies the result. Clients find their own slot locally; no
   coordinator gets a slot-private key or owner map. Signed X25519 hellos and
   transcript-bound HKDF derive matching mask seeds. The verified result binds
   the bulk-round epoch and public slot keys.

New startup configurations contain temporary TLS credentials but no protocol
identity private keys, slot-private keys or mask seeds. Those remain inside
the role processes. The controller now validates payload multisets without an
owner map. It still supplies the roster and injects simulated publishing input,
so laboratory control traffic exposes the simulated sender. Processes share a
host account. This remains functional/latency evidence, not an anonymity trial.

Proof parsing retains Kyber's proof algorithm and Fiat–Shamir framing, adding
canonical re-encoding, subgroup checks and complete-consumption checks to proof
reads. Random streams preserve upstream sampling. Tests reject signed input,
shuffle and decryption alterations; malformed/trailing proofs; duplicate slots;
epoch changes; missing shares; and conflicting commits. The node adapter refuses
pre-setup publication and prevents late finalization retries from resetting
consumed masks even after response-cache eviction.

Substantive constraints remain: the supplied roster is not Sybil resistance;
an honest mixing/decryption role and multiple honest clients are assumptions;
all-three release loses availability when a coordinator disappears. State is
memory-only, without durable recovery, anti-rollback or a key-erasure guarantee.
Roster changes need a fresh session and a safe transition policy. Bulk jamming,
anonymous accusation, intersection protection, real domestic discovery/NAT,
all application actions and physical resource measurements remain unfinished.
No application dependency or APK has changed.

Cold setup is reported separately. The paced local run needed 1,976.642 ms for
setup before publication timing began. Its 4,308.932 ms maximum observed added
publication delay does not establish a five-second cold-start publication bound.

## Witness-bit accountability work (round wire v2)

This revision addresses an active-adversary prerequisite of retrospective blame.
Previously, coordinators committed to the client input set but not to their own
mask outputs. A last-moving coordinator could learn the clear output and choose
only 1-to-0 changes, leaving no safe 0-to-1 witness. Wire v2 binds every signed
coordinator vote to the hash of its own mask before any masks are released.
Recipients check shares against the previously accepted commitments. The role RPC
stores a deep copy of these votes until output verification completes.

Every owned slot now contains a fresh 16-byte random seed followed by the signed
inner cell XORed with an AES-generated pad. Empty owned slots are randomized too.
This follows the witness-bit motivation in
[Dissent section 3.9](https://www.usenix.org/system/files/conference/osdi12/osdi12-final-115.pdf).
The seed is public after a successful round; this layer is not confidentiality
encryption. It makes pre-release bits unpredictable to a disruptor who lacks an
honest coordinator's mask. It costs 16 bytes of application capacity, reducing
the 8 KiB cell maximum from 8,126 to 8,110 bytes.

The additional `faultAudit` state machine is deliberately limited to an isolated
investigation. It accepts a complete, authenticated, committed round whose output
fails decoding. A slot owner may sign a single bit position where its original
randomized cell contained zero and the faulty output contains one. The state
machine binds that accusation to the complete failed transcript and allows at
most one position per slot, with exact retries. Only the indicated bit of each
pairwise mask may be reported. There is no general mask-dump operation.

Signed coordinator reports are compared with the committed aggregate masks and
client inputs. A direct coordinator contradiction is evidence of inconsistency.
A client mismatch is only a candidate: a coordinator may have lied about two
pairwise bits while preserving its aggregate, thereby framing an honest client.
The new tests reproduce exactly this attack. A rebuttal must remain possible;
absence of a response is not proof of malicious behavior.

For a narrowly verifiable rebuttal, each input and coordinator vote also commits
to the relevant **descriptor-specific AES key**. Both sides' commitments must
match before release. A client reveals that one-round key only when a signed,
context-bound coordinator report disagrees with the key's generated bit. Anyone
can check the prior commitments and the discrepancy. The accused coordinator
already possessed this key. No session seed or other round key is disclosed;
correct, unsigned or context-mismatched reports cannot trigger an opening.
This refinement is experimental and requires composition review.

The complaint itself must travel anonymously. At the initial wire-v2 checkpoint,
the local component had no such transport or new-session transition. The published
[Verdict hybrid design, section 4.4](https://www.usenix.org/system/files/conference/usenixsecurity13/sec13-paper_corrigan-gibbs.pdf)
is the reference for the proposed verifiable control path. Crash-safe disclosure
budgets, an honest-member admission assumption, persistent publication state and
safe cohort transitions remain open. Removing a non-responsive participant or
restarting with a smaller set automatically is not an accepted recovery policy.

## Verifiable control channel composition

The next experimental layer, `verdictprobe/control`, carries eight fixed-size
128-byte slots in every contribution. Clients use the anonymous Ed25519 slot
keys established by setup; each coordinator creates eight fresh, independent
control encryption keys with signed proofs of possession. These keys are also
separate from the setup shuffle's decryption keys.

A negative test first exposed a dangerous composition: reusing the earlier
single-slot experiment's server key across slots allowed a malicious owner to
borrow another client's ciphertext and use its own slot-key proof to obtain
decryption. The new path additionally requires a proof of knowledge of the
ephemeral scalar for **every** ciphertext, including owner ciphertexts. This
blocks the borrowed-ciphertext case before any control share is released.
The evidence concerns this repository's fixture composition, not an evaluation
of a deployed Verdict implementation.

Clients independently generate and sign their complete eight-slot contribution.
All three coordinators verify all contributors, commit to the same descriptor
and input root, and only then generate proved shares. Every client checks that
its own contribution was included unchanged. A role may retry its exact input,
commitment, release or acceptance, but may not generate a second input set for
the same control descriptor. Rebinding the same control session after RPC cache
eviction does not reset this state. Missing contributions, votes or shares keep
the round pending. A malformed plaintext authorized by a malicious slot owner
is confined to that slot; other correctly proved slots remain recoverable.

The network adapter now uses unanimous output certificates at clients. Each
coordinator first verifies the full input proof set and every decryption proof,
then signs the descriptor, input root, and exact ordered outputs. Clients check
the complete input identities, unchanged inclusion of their own contribution,
all three input-root votes, and all three output certificates. This follows the
verification allocation of [Verdict section 4.1](https://www.usenix.org/system/files/conference/usenixsecurity13/sec13-paper_corrigan-gibbs.pdf)
and retains the existing requirement that at least one coordinator is honest.
It removes repeated expensive client proof checks; it does not remove any of
the three coordinator checks. Two colluding coordinators cannot complete the
certificate set for altered output. No signer can be silently omitted.

Coordinator state allows at most three expensive input-proof attempts and three
share-proof attempts for the active control context. Fixed shape and all outer
signatures are checked before those attempts. Missing/unsigned messages do not
consume the curve-verification budget. Exact completed retries use cached output;
rebind/reopen cannot reset the budget. Exhaustion leaves the round blocked. This
bounds curve work in this component, not total denial-of-service exposure: cheap
RPC floods, initial setup, memory-only state, and malicious withholding still
need transport/session defenses. The standalone fully verifying client method
remains for comparison; the RPC adapter uses only certified client acceptance.

The `roundprobe` adapter accepts control activation only for an authenticated
failed bulk-round transcript that matches the local prepared/committed input.
It binds the control descriptor to that transcript, creates a witness complaint
locally when possible, otherwise creates cover, and sends the same-shaped
encrypted batch either way. A controller cannot supply plaintext complaint data
through the prepare RPC. After verified output, the adapter checks slot
authorization and the witness budget before allowing signed coordinator bit
reports. Client mismatches remain candidates; no timeout-based expulsion or
automatic release under a smaller membership is implemented.

This composition now runs across separate processes using loopback mutual TLS
and application-level network pacing. The laboratory controller still supplies
the roster and mediates messages. Equal packet lengths have been checked, but
the immediate RPC response timing is not a uniform anonymous sending schedule.
The component requires serialized calls and has only in-memory replay state.
At that checkpoint it did not close timing, crash recovery, admission,
intersection, physical connectivity, battery, or full-application protection gates.

## Durable local roles (experimental checkpoint revision 1)

The opt-in `Durable` laboratory role now stores its entire private state using
[bbolt 1.5.0 transactions](https://pkg.go.dev/go.etcd.io/bbolt@v1.5.0), with the
normal synchronization settings retained. Values are sealed with XChaCha20-
Poly1305 and bound to the original role configuration and record type. The
experiment uses a separate local random key file, **not Android Keystore**.
Possession of the whole directory includes that key; this is not protection
against device seizure or malicious filesystem rollback.

Before executing a new non-cached operation, the role commits an encrypted
pending-operation record. Before returning any protocol result, it atomically
commits the resulting checkpoint and removes that pending record. Error results
are included because verification failures can consume disclosure/work budgets.
If a write fails, the role becomes unavailable, including its in-memory response
cache; no newly computed response may escape without its state commit.

While setup is unfinished, the checkpoint includes its role-local identity/DH/
shuffle keys and encrypted-slot inputs/proofs. Completed setup objects are retired
after the live role has copied its bulk secrets; only the final public receipt and
request hash remain for setup retries. Older authenticated local checkpoints can
be restored into that compact state. This is not a secure erasure guarantee.
The checkpoint also includes control keys, exact prepared ciphertexts, committed batches,
expected descriptors, round counters, accepted control output, witness-bit
budgets and reports, proof-attempt counters, and the bounded response cache.
No checkpoint API is exposed through the peer RPC. Setup and control codecs
restore generated randomness instead of generating a replacement for a message
that may already have been emitted. All restoration goes through authenticated
local storage; these codecs do not validate a remote state import.

After an ordinary process crash, an already committed response is retried exactly.
An interrupted operation may resume from its preceding checkpoint because its
uncommitted response was never released. Each pending operation has a durable
three-attempt limit, including the original execution. Further interruption keeps
the session blocked; it does not reset the limit or reduce membership. Missing
database/key files, wrong keys, altered ciphertext, changed configuration and
simultaneous writers are rejected. Existing non-durable one-shot configurations
cannot be adopted as fresh durable sessions at the same path.

The native Samsung test exposed a platform distinction: bbolt's Android
process-associated file lock permits another journal handle in the same process.
The Android adapter now also holds an exclusive, nonblocking `flock` lease on a
persistent `session.lock` file. It closes the database before releasing that
lease; the lock file is never unlinked. Tests check simultaneous opens in one
process and separate processes, reopening after close, and cleanup after a crash.
The laboratory Android tests pass after this correction. Other untested host
platforms cannot inherit that validation merely from the Windows pass.

The maximum encoded checkpoint is 8 MiB and the database file is capped at 64 MiB
per role. Its response cache remains eight entries. Runtime statistics count
commits and encoded plaintext bytes submitted for sealing; these are **not**
physical NAND write counts. Counters cover the current process only. The store
retains the latest state and one pending operation, not an unbounded history.
Disk commit cost is included in the `fpp1durable` paired publication variant.

The long durable run did not meet the connected-latency gate: 266 completed pairs,
two overhead violations (maximum 7,150.020 ms), followed by a missed-deadline
failure; 33 of 300 requested pairs were unattempted. A later instrumented attempt
failed during warmup as well. Phase timings and journal wall-time counters now
support investigation, but there is no accepted latency result. Disabling sync,
discarding slow samples or increasing the deadline does not satisfy this gate.

This closes a specific process-restart gap within an unchanged cohort. It does
not implement a complete application's article outbox, safe membership changes,
fault expulsion/resumption, rollback-resistant counters, key erasure, backup
migration, Android storage integration or power-loss guarantees. The laboratory
controller still chooses addresses and drives traffic. Equal persisted results
are not evidence of anonymous timing, domestic reachability or battery safety.

## Native journal cost apparatus

The `journal-compare` component executes the same role adapters as the RPC path,
but sequentially within one Android process with fixture-provisioned independent
epochs. It alternates memory/durable/durable/memory rounds and records each role's
process-CPU and wall-time deltas, actual commit counts and encoded bytes. A
calibration test requires the expected commits for every phase and verifies the
released payloads. Shared runtime/GC work means per-role CPU is approximate.
The mode excludes transport, scheduled waiting, anonymous setup, application
signing/outbox, UI, radio and battery. It must not be substituted for a complete
per-phone steady-state or delivery acceptance measurement.

## Role-local publication queue (experimental revision 11)

The optional `RoleLocalOutbox` client accepts plaintext only through a private
local interface. Its peer RPC rejects injected payloads and does not expose queue,
CPU or storage-write counters. The laboratory adapter uses a bounded parent/child
pipe; this is not a new Internet endpoint or a separate end-user helper app.
Legacy measurement modes still inject fixture payloads and are labeled separately.

The queue holds at most 64 items / 256 KiB, with an 8,110-byte per-item limit and
128 bounded release receipts. A caller must durably retain a monotonically
increasing local sequence and retry the **same sequence and bytes** after an
uncertain acknowledgement. Existing retries return the saved status; changed
bytes, gaps, exhausted counters, expired receipts and full queues are rejected.
No rejection switches to direct publication. The application-side retry adapter
and action validation are not implemented by this opaque-byte laboratory API.

An enqueue is journaled before acknowledgement. Reservation preparation pins
either the current queue head or an empty choice; later enqueues cannot change
it. Only the exact certified bulk output releases that head and replaces it with
a local receipt. The receipt records protocol release, not delivery to a reader.
It does not contain a peer-visible enqueue identifier. Subprocess tests cover
crashes before execution, before commit and after commit for both enqueue and
release. Restored queue state must agree with the protocol phase, prepared
ciphertext and completed receipts. This is ordinary process recovery, not
anti-rollback storage or a guarantee of secure deletion.

The `fpp1outbox` pipeline puts a two-second round timer in an independent worker
from its private submission reader. The timer sees certified reservations and
outputs, not local input/owner maps; idle reservations continue without news.
All clients receive the same payload-free preparation request for a descriptor.
The observer can join a private acknowledgement and a public release in either
order. It does not feed those observations back into the round schedule.
Queue acknowledgement, scheduled wait, protocol work, IPC and the ordinary
verified/flushed reader store are included in the paired latency measurement.
Signing and composition precede its start. Enqueue timing includes local-pipe
acknowledgement; it is not a measurement of database commit time alone.

**This is still a controller-mediated experiment.** A client's selection cutoff
is currently the arrival of its preparation RPC, not an independently enforced
cohort deadline. An untrusted scheduler can stagger those cutoffs. Local queue
size and work can also influence response timing. Removing plaintext and explicit
counters does not resolve those timing channels. Locally enforced common round
boundaries, authenticated membership/time agreement, timing/correlation analysis,
safe fault resumption and intersection/admission defenses remain required.
The laboratory controller knows the test publishers and all process addresses.

The outbox currently carries opaque bytes; channel creation, publication,
revocation, recovery, writer changes and images still require one authenticated
application boundary, with bounded fragmentation and no public fetch from the
original publisher. Continuous radio use, daily traffic, controlled battery and
actual shutdown routes remain unmeasured for this revision. Integration is closed.

## Common-cutoff experiment (15 October, revision 13)

The old outbox mode above remains a negative control. A reproduced attack sends
preparation requests to seven clients before local news is queued, but delays
the eighth request until afterwards. All eight clients then have news, yet only
the delayed client's article is released. No signature, input-set or release
certificate forgery is needed. The scheduler can associate that output with its
chosen client. A separate `RequireCommonSchedule` mode addresses this specific
RPC-controlled cutoff; it does not establish publisher anonymity.

Before accepting news, all three coordinators durably sign the same epoch/roster
bound schedule. Each coordinator refuses a second schedule for that epoch.
Clients verify every signature and cannot replace an installed schedule. The
experimental policy uses two-second rounds and a **100 ms clock-error assumption**.
Signed agreement is not clock synchronization and does not prove that bound.
No foreign time service is added, but a safe domestic clock-admission protocol
remains required before this assumption could be relied on outside the lab.

Each locally committed queue item retains its first eligible round, calculated
using the upper bound on local time. A preparation request must be within the
locally checked round window and may select only already eligible items. Early
requests do not consume a selection or cause journal writes. Late preparation
cannot pull newer news into an older round. The durable pending-enqueue record
contains eligibility, so crash recovery cannot recompute it from a later clock.

An admitted process anchors wall time to a local monotonic reading. A detected
clock jump or elapsed-time discontinuity fences new submissions/preparations.
The anchor is never restored from disk: after restart, the old certificate and
exact cached replies remain valid historical facts, but they cannot re-arm a
new live clock. Queued news and receipts are retained. Fresh publication needs
a safely admitted new epoch; authenticated queue migration/resumption is not yet
implemented. This deliberately loses availability instead of guessing a clock
or falling back to direct publication. Device suspend, gradual clock drift and
physical inter-phone clock uncertainty still need measured handling.

The new socket check uses the actual private outboxes, anonymous slot setup,
durable role processes and mutually authenticated loopback sockets. It passed
17 checks, including all eight queued articles releasing in the next round.
The existing `fpp1outbox` pipeline still uses the older schedule. A new
`fpp1scheduled` paired pipeline measures the common-cutoff variant. Both initial
attempts failed: one during its first warmup; the other after five completed
measured pairs, at a late bulk commit in round 19. Its five completed pairs had
a 3,255.716 ms median and 4,049.917 ms maximum conservative added delay. Those
survivor-only timings do not satisfy the delivery/reliability gate. Raw failures,
unattempted pairs and the diagnostic phase timings are retained. No window or
security rule was relaxed in response, and no five-second or battery gate passes.
Uniform autonomous traffic, queue-work timing, admission/Sybil and intersection
defenses, protected application actions/images and safe cohort recovery remain
open. The new common-cutoff mode stays outside the APK.
