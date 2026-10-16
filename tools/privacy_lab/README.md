# Local publisher-protection laboratory

These programs are isolated research tools. They are not loaded by Flutter,
included in the APK, or connected to public discovery. FPP-0 has a demonstrated
publisher-linking failure. A successful command does not mean it is safe.

The current design, measurement contract, gates and incomplete work are in
`docs/EXPERIMENTAL-PUBLISHER-PROTOCOL.md`. Characterization results are in
`docs/PUBLISHER-LAB-RESULTS.md`.

## Prerequisites and reproduction

Run from the repository root. Use the existing project Flutter/Dart dependencies.
The measured workstation has Dart 3.13.4 and portable Go 1.27.2 under
`.tooling/privacy-research/go`. Go SDK archive SHA-256 for the measured Windows
amd64 SDK is
`1314008898bd40df77af4b014f777f08873dbdfbcd3d92308728ee03304fe04f`.
Toolchain acquisition is separate from these measurement commands.

Sphinx uses pinned Katzenpost v0.0.90 revision
`d5a6349a34c4a2d4bca587f4be86ce92f2873b12` with a local portable HPQC registration
change. `prepare-sphinx.ps1` only narrows scheme registration; it does not change
the selected cryptographic implementations. It must not be described as an
unmodified stock Katzenpost build or a complete Katzenpost network.

```powershell
.\tools\privacy_lab\prepare-sphinx.ps1
$env:GOPATH = Join-Path (Get-Location) '.tooling/privacy-research/gopath'
$env:GOCACHE = Join-Path (Get-Location) '.tooling/privacy-research/gocache'
$env:CGO_ENABLED = '0'
$env:GOOS = 'windows'
$env:GOARCH = 'amd64'
Push-Location tools/privacy_lab/sphinxprobe
try {
    & ..\..\..\.tooling\privacy-research\go\bin\go.exe test ./...
    if ($LASTEXITCODE) { throw 'Laboratory checks failed' }
    & ..\..\..\.tooling\privacy-research\go\bin\go.exe build -o ../../../.tooling/privacy-research/sphinxprobe.exe .
    if ($LASTEXITCODE) { throw 'Laboratory build failed' }
} finally { Pop-Location }
& .\.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe run tools/privacy_lab/measurement_check.dart
& .\.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe run tools/privacy_lab/baseline.dart 40 1
& .\.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe run tools/privacy_lab/baseline.dart 40 3
& .\.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe run tools/privacy_lab/submission_pipeline.dart 40
```

Run timing workloads sequentially, without builds or other CPU-heavy experiments
in parallel. Baseline and pipeline reports print a fresh output path beneath
`.local-only/privacy-lab`. Each report retains source hashes, failed samples,
setup/warm-up scope, timing intervals and CPU/byte scope.

The paired pipeline uses the *same signed bytes* in separate equivalent public
stores. It alternates direct/protected ordering and checks the actual decrypted
payload before sending it through the current PeerEngine. Its measurement starts
after signing, so it is not a user-tap-to-screen test. It includes Go IPC, three
local Sphinx stages and two public TLS hops. Covers and client slot phases are
simulated per sample; continuous mobile traffic is not measured by this tool.

## Physical-device component tests

Select a device from `adb devices -l`, then pass its serial explicitly:

```powershell
.\tools\privacy_lab\measure-device.ps1 -Serial '<adb-serial>' -Module sphinxprobe -Samples 2000 -PayloadBytes 8192 -Scheme x25519
.\tools\privacy_lab\measure-device.ps1 -Serial '<adb-serial>' -Module shuffleprobe -Samples 3 -PayloadBytes 4096
.\tools\privacy_lab\measure-device.ps1 -Serial '<adb-serial>' -Module shuffleprobe -Samples 30 -PayloadBytes 32
.\tools\privacy_lab\measure-device.ps1 -Serial '<adb-serial>' -Module roundprobe -Samples 300 -PayloadBytes 4288
```

The script builds for the selected Android ABI, uses a fresh temporary device
directory, records binary/source hashes and charging/screen state, and removes
only that run's temporary device file/directory. It neither installs an app nor
changes device radio settings. Results/binaries remain in ignored
`artifacts/privacy-lab/device-<run-id>` for reproduction. These are computation
tests; USB-powered results cannot be cited as battery measurements.
New runs also retain an exact module-source snapshot in their evidence directory.
Older runs have hashes only; do not claim a changed current source tree is the
exact version measured by an older manifest.

## Verifiable-shuffle feasibility component

`shuffleprobe` pins DEDIS Kyber v4.0.2 and uses its existing Neff sequence-shuffle
and proof APIs. It encrypts full padded payloads as curve-point sequences,
shuffles/verifies them and checks that decryption yields the identical multiset.
The verifier samples its challenge after the output matrix exists in memory.
It checks changed-ciphertext and changed-context rejection.

It is deliberately a **component** experiment: one local process holds a central
decryption key. Authenticated distributed admission, committed challenge exchange,
distributed key generation, threshold release, network coordination and their
security analysis are not implemented. A tamper test does not establish an
end-to-end anonymity protocol.

To build on Windows, use the same Go environment above, change into
`tools/privacy_lab/shuffleprobe`, run `go test ./...`, and build to
`.tooling/privacy-research/shuffleprobe.exe` using the analogous relative path.
Run with `-samples 10 -payload 4096 -cohort 8 -hops 3`.

Dependency licenses are material to any later distribution: the pinned Sphinx
implementation is AGPL-3.0-or-later; DEDIS Kyber is MPL-2.0. Application integration
must resolve compatible distribution terms as well as technical gates. No
dependency from these probes has been added to the application.

## Reservation/bulk-round component

`roundprobe` uses Go's standard cryptographic library and no external module.
Run `go test -v ./...` in that module with the same toolchain/environment above.
The Android measurement command records 300 idle rounds, 300 single-publication
round pairs, and 300 eight-publication round pairs after warmups for each workload.
Each workload computes all eight clients and three coordinators sequentially in
one process. It measures computation and actual encoded message lengths, not
wire traffic, slot waiting, network latency or battery. Separate workloads do
not imply that eight roles run on a single production phone.

The fixture centrally assigns slot keys and client/coordinator seeds. This is
explicitly not anonymous setup. The protocol document describes missing key
exchange, durable state, membership policy, jamming recovery and intersection
analysis. Negative tests deliberately demonstrate both jamming and a Sybil case
in which the only honest client's message is recovered. Green tests mean those
limitations remain reproduced, not that the security gate passed.

The original two-slot policy is retained as a regression: eight simultaneous
publishers require four rounds. The measured revised policy has eight bounded
slots, avoiding that queue in this case at the cost of a 64 KiB peak vector.
No app dependencies, publisher actions, UI or network settings are changed by
these commands, and no updated protection APK is produced.

Build the Windows `roundprobe` executable to
`.tooling/privacy-research/roundprobe.exe`, then run:

```powershell
& .\.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe run tools/privacy_lab/submission_pipeline.dart 40 fpp1
```

This mode runs scheduled reservation/bulk computations even while no request is
pending, returns the actually recovered envelope bytes, and compares their
application-store arrival with the same direct signed bytes. Its private side
still has no sockets: it is a component-backed pipeline, not a phone-to-phone
latency result. The report marks that exclusion and retains exact source/binary
snapshots. `fpp0` remains the default for reproducing the earlier experiment.

## Separate-process TLS experiment

The same Go module now supports role nodes. Each client process receives only
its three shared seeds, its own participant signing key and its own anonymous
slot key. Each coordinator receives its column of shared seeds and its own
signing key. All other keys in a role configuration are public. Attempts to use
an unavailable seed fail. Roles maintain independent state and a bounded cache
of exact successful responses so an exact retransmission can recover a lost
reply without creating another ciphertext or advancing a round again.

After rebuilding `.tooling/privacy-research/roundprobe.exe` from this module:

```powershell
& .\.tooling\privacy-research\roundprobe.exe -mode network-checks
& .\.tooling\privacy-research\roundprobe.exe -mode network -samples 300 -payload 4288 -publishers 1
& .\.tooling\privacy-research\roundprobe.exe -mode network -samples 300 -payload 4288 -publishers 8
& .\.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe run tools/privacy_lab/submission_pipeline.dart 40 fpp1net
& .\.tooling\privacy-research\roundprobe.exe -mode network -samples 10 -payload 4288 -publishers 8 -kbps 5000 -rtt-ms 80
& .\.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe run tools/privacy_lab/submission_pipeline.dart 20 fpp1net 5000 80
```

Run these commands sequentially. The network mode records computation, actual
RPC transport and receipt certificates; it excludes scheduled slot waiting.
The `fpp1net` pipeline adds independently scheduled two-second rounds and the
real public PeerEngine/storage path, using a single controller clock.

The orchestrator creates eleven temporary child processes. Listeners are
restricted to loopback and require a fresh laboratory client certificate under
TLS 1.3. No proxy, public discovery, adapter or firewall configuration is used.
Raw encoded RPC requests are capped at 2 MiB, processing is serialized per role,
and reply caches retain at most eight entries. These bounds do not establish
resistance to a public Internet flood or durable restart recovery.

Reports, exact source/binary snapshots, test-only role configurations, process
CPU totals, TLS-payload counters and child cleanup records live under ignored
`.local-only/privacy-lab/roles-*`. Keys in these configurations are fresh test
material, never application keys. The measurement controller provisions the
setup and knows the slot assignment. Controller-to-client commands inject test
payloads, so their lengths can expose which simulated client is being asked to
publish. The private exchange is a controller-mediated RPC topology, with
redundant batches and JSON encoding. **This is not an anonymity evaluation or
the intended production wire format.** Byte counters include that laboratory
control traffic and TLS framing, but exclude IP/TCP headers and radio signalling.

The network checks exercise real sockets: failed mutual authentication,
truncated/oversized requests, wrong rounds/epochs, missing or modified input,
inconsistent votes, missing shares, incomplete certificates, exact retry,
same-epoch recovery and coordinator loss. The final loss test must return an
error without public release. These add transport evidence to the existing
deliberate jamming and Sybil failures; they do not repair those failures.

The current transport retains each coordinator's exact validated batch until
finish, eliminating a repeated full-batch transfer. Finish supplies its root,
never replacement inputs. The retained copy is bounded to one batch and cleared
after success. An exclusive `.started` file makes each generated configuration
single-use; it is not a durable anti-rollback mechanism. Parent pipe closure
terminates listeners after controller loss. Cleanup records any unavailable
final stats and still reaps owned child processes.

Optional `-kbps` and `-rtt-ms` flags pace each role connection's encrypted socket
bytes in each direction and delay each RPC. The pipeline accepts these as its
third and fourth arguments, only with `fpp1net`. Zero disables that dimension.
These are application-level fixtures, not carrier or TCP emulation. Failures,
including warmup failures and unattempted measured rounds, stay in the reports.

## Verifiable contribution feasibility component

`verdictprobe` implements the **primitive** in section 5.2 of the published
[Verdict paper](https://www.usenix.org/system/files/conference/usenixsecurity13/sec13-paper_corrigan-gibbs.pdf)
with pinned Kyber v4.0.2 proof APIs (MPL-2.0). It is not the upstream Verdict
system. Eight simulated clients contribute to one anonymous slot, three servers
independently verify every contribution before releasing a proved cancellation
share, and one recipient verifies and recovers the actual payload. All roles
run sequentially in one process. Group proofs, fixed rosters, signatures and
contexts reject tested corruption; missing participants stop release.

Tests cover signed client/server corruption, an invalid proof made by a member
who does not own the slot, replay context, missing/duplicate identities, changed
input roots, setup proof-of-key knowledge, proof bounds, noncanonical scalars,
small-order and mixed-torsion points. Proof encoding checks are tied to the
pinned Kyber version. They require review if the library changes.

Build/test as for `shuffleprobe`, from `tools/privacy_lab/verdictprobe`. Physical
computation examples (sequentially):

```powershell
.\tools\privacy_lab\measure-device.ps1 -Serial '<adb-serial>' -Module verdictprobe -Samples 30 -PayloadBytes 32
.\tools\privacy_lab\measure-device.ps1 -Serial '<adb-serial>' -Module verdictprobe -Samples 3 -PayloadBytes 4288
```

The module measures one slot, not eight slots or a full reservation/bulk cycle.
It centrally assigns all keys and knows the owner. Anonymous setup, network
agreement, active identity attribution, safe participant exclusion, recovery,
Sybil policy, intersection protection, radio/battery and application integration
remain absent. These primitive checks **do not fix FPP-1's deployed security**;
there is no deployment or inherited anonymity proof. Using this as a small
anonymous accusation/control component is a hypothesis requiring composition
analysis; it must not be described as a working hybrid based on a microbenchmark.

## Role-local verifiable setup

`setupprobe/setup` provides isolated client/coordinator state machines for signed
hellos, X25519/HKDF seed establishment, proved encrypted slot keys, Kyber Neff
shuffles, all-coordinator commitments and proved partial decryptions. Every role
generates its own secrets. Membership is an explicit supplied trust input; this
does not implement Sybil resistance, discovery, durable recovery or safe roster
changes. The standalone probe measures all eleven roles sequentially.

After testing `setupprobe` and rebuilding `roundprobe` with the environment above:

```powershell
.\tools\privacy_lab\measure-device.ps1 -Serial '<adb-serial>' -Module setupprobe -Samples 10 -PayloadBytes 32
& .\.tooling\privacy-research\roundprobe.exe -mode network-setup-checks
& .\.tooling\privacy-research\roundprobe.exe -mode network-setup -samples 300 -payload 4288 -publishers 8
& .\.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe run tools/privacy_lab/submission_pipeline.dart 20 fpp1setup 5000 80
```

Run measurements sequentially. `roundprobe` has local module dependencies
on `setupprobe` and `verdictprobe`, with pinned Kyber (MPL-2.0); the application
does not. New network snapshots preserve all three module trees, so their relative
Go module replacement is reproducible. New device manifests similarly record
module-prefixed source paths; older manifests retain their original layout.

The new network variant generates protocol secrets inside its eleven processes.
Startup files contain temporary TLS credentials, while protocol private keys,
slot-owner mappings and shared seeds never appear in setup responses. Public
setup transcripts and separate setup timings are retained beside round results.
The laboratory controller still supplies membership and injecting user input
reveals simulated publishers. All listeners remain loopback-only.

`fpp1setup` measures publication after setup completes. Cold setup is reported
separately and must be included in a future cold-publication test. Role loss
halts release; there is no silent direct fallback. No anonymous accusation,
intersection defense, production discovery, battery acceptance or APK is implied.

## Round wire v2 and witness investigations

The current `roundprobe` wire domain is `FT-ROUND-COMPONENT-v2`. Old measurements
remain reproducible from their retained source snapshots; do not compare their
byte counts as if the current protocol were identical. The new round adds:

- A signed hash of each coordinator's aggregate mask, committed before release.
- Client and coordinator commitments to each descriptor-specific AES mask key.
  All commitments must agree before an honest coordinator releases its mask.
- A fresh 16-byte random seed and AES randomization inside each owned slot,
  including idle slots. This is padding for unpredictable witness bits, not
  encryption of the publicly released article. Maximum application payload is
  now **8,110 bytes** within the 8 KiB cell; larger inputs are rejected.

`accusation.go` implements a **local investigation component** inspired by the
[Dissent accusation procedure, section 3.9](https://www.usenix.org/system/files/conference/osdi12/osdi12-final-115.pdf).
The owner may authorize one zero-to-one witness bit per slot in a failed round.
Coordinators disclose signed pairwise bits. Aggregate contradictions can expose
a coordinator; client mismatches are candidates requiring a rebuttal opportunity.
A false coordinator report can be disproved with the jointly committed AES key
for that one round. The session seed is never disclosed. Correct or unsigned
reports cannot trigger that key opening.

The investigation by itself does not carry complaints, expel a participant,
reinterpret silence as guilt, or resume publication. Sending the complaint
directly from the publisher would reveal the publisher. The protected control
experiment below follows the direction of
[Verdict's hybrid mode, section 4.4](https://www.usenix.org/system/files/conference/usenixsecurity13/sec13-paper_corrigan-gibbs.pdf),
with additional composition constraints. Legacy modes keep disclosure budgets
in memory; the opt-in journal below preserves them across process crashes.
Admission and safe session transitions remain necessary.

## Verifiable control composition

`verdictprobe/control` is a role-local, eight-slot control experiment. Each
coordinator generates a distinct encryption key for each slot, separately from
anonymous setup keys. Every contribution carries a mandatory proof of knowledge
of its ephemeral encryption randomness, including the slot owner's branch.
Do not omit this proof or reuse the original single-slot fixture across slots:
`TestSharedServerKeyAcrossSlotsExposesBorrowedClientCiphertext` reproduces a
decryption-oracle failure in that hypothetical composition.

`roundprobe -mode network-control-checks` composes this component with role-local
setup and the witness audit over eleven loopback TLS processes. Only one lab
role's startup configuration enables deliberate input corruption. Each honest
client constructs its own complaint inside its process; the controller receives
only a fixed-shape contribution for all eight slots. Coordinators must agree on
the verified input root before release. Missing messages can be retried without
regenerating inputs or shrinking membership. Malformed owner plaintext affects
that owner's slot; it does not erase another slot's valid complaint.

```powershell
& .\.tooling\privacy-research\go\bin\go.exe -C tools/privacy_lab/verdictprobe test ./...
& .\.tooling\privacy-research\go\bin\go.exe -C tools/privacy_lab/roundprobe test ./...
& .\.tooling\privacy-research\go\bin\go.exe -C tools/privacy_lab/roundprobe build -o ../../../.tooling/privacy-research/roundprobe.exe .
& .\.tooling\privacy-research\roundprobe.exe -mode network-control-checks -kbps 5000 -rtt-ms 80
.\tools\privacy_lab\measure-device.ps1 -Serial '<adb-serial>' -Module verdictprobe -ProbeMode control -Samples 5 -PayloadBytes 128
```

Use the Go environment variables specified earlier; run measurements sequentially.
New round-probe snapshots retain the sibling `verdictprobe` module as well.
The device control benchmark computes all eleven roles sequentially. Coordinators
check all proofs and sign outputs; clients check unchanged inclusion, all input
identities, all votes and all three output signatures. This uses the existing
at-least-one-honest-coordinator assumption. Missing or altered certificates fail
closed. Expensive coordinator proof attempts are bounded per active context.
It is neither network latency nor a battery test.

For an in-process ABBA comparison with the previous full client verification,
use `-ProbeMode control-compare -Samples 8 -PayloadBytes 128` with the same device
command. Samples must be divisible by four. Two warmups (one per mode) precede
complete full/certified/certified/full blocks. One live roster and executable
serve both modes; fresh randomness is generated every round. Raw per-role wall
and process-CPU deltas and separate summaries are retained. This reduces temporal
confounding but does not control Android thermal/frequency scheduling or establish
per-phone battery usage. Both modes compute all roles sequentially.

The RPC experiment has **no independent anonymity claim**. Uniform packet lengths
do not establish uniform packet timing: the current controller RPC replies as
soon as computation finishes. Admission, autonomous scheduling, production storage,
safe exclusion/reconfiguration, physical radios and application actions remain
unfinished. A suspected client is a candidate requiring a rebuttal opportunity;
the experiment keeps the failed news round blocked rather than removing it and
publishing with a reduced cohort. Production source/dependencies remain separate.

## Durable role experiment

`roundprobe` can opt its local roles into encrypted bbolt checkpoints. This
research-only Go dependency is not added to the application. Default legacy
experiments retain their one-shot configuration safeguard. Use these modes after
the normal Go tests/build above:

```powershell
& .\.tooling\privacy-research\roundprobe.exe -mode network-durability-checks -kbps 5000 -rtt-ms 80
& .\.tooling\privacy-research\roundprobe.exe -mode network-control-durable-checks -kbps 5000 -rtt-ms 80
& .\.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe run tools/privacy_lab/submission_pipeline.dart 300 fpp1durable 5000 80
```

The first mode terminates and restarts an owned client/coordinator process at
publication phase boundaries, then compares each repeated response with the
original. The control mode does the same during an injected fault investigation.
Their elapsed times include deliberate process crashes and retries; they are
not healthy-route latency samples. The paired `fpp1durable` mode includes normal
disk transactions without deliberate crashes, and reports cold setup separately.

`journal_test.go` also launches a subprocess that exits without cleanup before
execution, before commit, and after commit. Other checks reject parallel writers,
missing/wrong/tampered state, repeated interrupted operations and oversized
checkpoints. A failed commit fences cached responses too. All private snapshots
are encrypted, but the laboratory storage key is a local file; Android Keystore,
malicious rollback and complete application-outbox recovery remain unimplemented.
Do not copy the state directory as a live session or treat it as a safe backup.

Run the native role tests on an attached Android device with:

```powershell
.\tools\privacy_lab\check-device-durability.ps1 -Serial '<adb-serial>'
```

This builds a temporary native test executable, saves the source/binary hashes
and complete output, and removes its device scratch directory afterwards. It
does not install an APK or alter radios. Android has an additional per-open-file
`flock` lease because bbolt's Android process-associated lock alone allowed two
journal handles in one process. Both same-process and cross-process tests are
required; successful Windows tests cannot substitute for the Android run.

For completed paired results, independently recompute the receipt intervals,
percentiles, failed/unattempted pairs and five-second violations:

```powershell
.\tools\privacy_lab\summarize-pipeline.ps1 -Result '<run-directory>/result.json'
```

The analyzer is read-only. A terminated trial can have no built-in summary but
still contain useful raw rows; completed-pair percentiles must accompany the
failure counts. The 300-pair attempt `pipeline-5308399a` stopped after 266 completed
pairs, with two overhead violations and a missed round deadline. It is a retained
failure, not a passing result. New network-pipe observations include timings for
each reservation/bulk phase; final role statistics include aggregate and maximum
pending/commit time. These diagnostics do not relax the deadline or establish
which component caused the older run's stall.

For a native ABBA comparison of the actual role adapters with and without the
synchronized journal:

```powershell
.\tools\privacy_lab\measure-device.ps1 -Serial '<adb-serial>' -Module roundprobe -ProbeMode journal-compare -Samples 16 -PayloadBytes 4288
```

Use 4–40 total samples per workload in complete blocks of four. Half belong to
each mode; one warmup per mode precedes the measured blocks. Idle, one-publisher
and eight-publisher workloads run sequentially, with independent epochs per arm.
The same round logic validates every output; per-role call/commit counters verify
that this really exercises durable storage. Per-role CPU is process CPU around
sequential calls and can include shared runtime work. No transport, anonymous
setup, scheduled wait, radio, full-app CPU or battery conclusion follows.
The fresh temporary databases are closed and removed before a successful result;
the runner retains sources, binary, output and device conditions. It uses shell-v2
to propagate the native exit status.

Completed setup objects are now retired from live state/checkpoints once the
role has copied its bulk keys. Exact final acknowledgements still work after
restart, including restoration from the older local checkpoint shape. The journal
also reuses the request digest from the outer handler. Neither optimization
changes synchronized commit ordering, response fencing or the crash attempt cap.

## Role-local private outbox

After rebuilding `roundprobe`, run sequentially:

```powershell
& .\.tooling\privacy-research\roundprobe.exe -mode network-outbox-checks -kbps 5000 -rtt-ms 80
& .\.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe run tools/privacy_lab/submission_pipeline.dart 20 fpp1outbox 5000 80
```

This opt-in mode uses private local pipes to commit a bounded encrypted outbox
inside each client role. Plaintext enqueue and queue/CPU/write counters are not
peer RPC operations. Exact local retries do not republish an acknowledged item.
Interrupted enqueue/release operations, invalid saved phase state, full queues,
stale receipts and late arrival after reservation have regression checks.
`network-outbox-checks` includes deliberate process restarts, so its total elapsed
time is not delivery overhead. Its report/lifecycle record the actual restart count.

`fpp1outbox` runs its timer independently from the submission reader and uses
payload-free peer preparation requests. It includes private queue commit/ack,
scheduled waiting, durable protocol state and the real public reader-store path.
The direct arm uses the identical signed bundle without the protected queue.
The per-request `localEnqueueAckMs` includes local pipe scheduling. A
`reservationRoundStartOffsetMs` can be negative if enqueue occurred during a
reservation before that client's preparation; it must not be mislabeled as
negative queue delay. The analyzer leaves absent timing fields null, not zero.

This does not make the schedule decentralized: the controller still issues role
RPCs, and their arrival controls each client's selection cutoff. Publisher-linked
work/queue size may affect response timing. No anonymity or five-second acceptance
claim follows from this adapter. It carries opaque app bytes and does not yet
validate/route every application action, implement app-side persistent retries,
measure steady phone CPU/radio/battery, or recover safe membership after a fault.

## Common reservation cutoff experiment

After rebuilding `roundprobe`, run from the repository root:

```powershell
& .\.tooling\privacy-research\roundprobe.exe -mode network-schedule-checks
& .\.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe run tools/privacy_lab/submission_pipeline.dart 20 fpp1scheduled 5000 80
```

This separate opt-in mode requires a three-coordinator schedule certificate,
freezes queue eligibility locally, rejects requests outside the local common
round window, and refuses fresh publication after a clock discontinuity or
process restart. It uses eleven durable processes, anonymous slot setup and
actual mutually authenticated loopback sockets. It does not change phone or
host networking. The report and cleanup record are retained in the role directory.

`TestLegacySchedulerCutoffCanIsolateLateClient` intentionally reproduces the old
mode's privacy failure. Common-schedule tests exercise every target client,
certificate alteration/equivocation, early/late requests, retained eligibility,
clock fencing and restoration. A passing check is not a privacy proof.

The 100 ms inter-role clock-error bound is an assumption, not something signatures
establish. No domestic clock admission, automatic new-epoch migration, uniform
autonomous traffic or physical timing/battery acceptance is provided. The
`fpp1outbox` pipeline remains the older comparison. `fpp1scheduled` measures the
common-cutoff variant with the same signed payloads, direct control and receiver
store. Its timer starts from the signed schedule, independently of submissions;
the controller still drives the role RPCs. Four seconds of schedule-admission
lead are added after anonymous setup; readiness can precede the first eligible
round, so initial waiting is retained in the warmup. Restarted clients retain queued news but cannot silently
resume new publication using the old epoch. This is a known availability gap.

Both initial scheduled pipeline attempts failed. One stopped in its first
warmup; a diagnostic follow-up completed five measured pairs before a late bulk
commit stopped publication. These are not passing five-second trials. A failed
round now retains controller-observed phase/window timings in
`outbox-failure.json`, without adding peer telemetry or relaxing the window.
See `docs/PUBLISHER-LAB-RESULTS.md` for the complete failure counts and evidence.

## Atomic publication checkpoint experiment

After rebuilding `roundprobe`, run from the repository root:

```powershell
& .\.tooling\privacy-research\roundprobe.exe -mode network-schedule-atomic-checks
& .\.tooling\flutter\bin\cache\dart-sdk\bin\dart.exe run tools/privacy_lab/submission_pipeline.dart 20 fpp1atomic 5000 80
```

This opt-in variant combines reservation acceptance/preparation and uses one
synchronized state-and-reply transaction for ordinary publication steps. Setup,
clock admission, disclosure controls and local enqueue keep their pending
records. A response leaves the role only after durable commit; a write failure
fences the live cache. Pre-commit process exits lose unacknowledged work, retain
the previous saved state and do not auto-reexecute a pending publication.
Committed exact replies remain replayable. The existing restart clock fence
still blocks fresh scheduled publication; safe migration is not implemented.

`fpp1fused` retains the earlier two-transaction implementation. The atomic mode's
configuration is recorded in private checkpoints and test reports. Its tests
cover real child-process crashes at commit boundaries, queue retention, retry
identity, failed-write fencing and the full active/idle protocol. This does not
establish power-loss/rollback resistance, anonymity, phone energy or a latency
gate. The same paired timing limits and failure-retention rules apply.

## Native Android scheduled-path apparatus

The host can drive the complete native private protocol on a USB-connected
Android device while retaining one host monotonic clock and the same two public
reader-store arms. This includes anonymous setup, local outboxes, signed
schedule, eleven role processes, loopback TLS and durable checkpoints. All
eleven private roles share one device; this is not a physical peer group.

```powershell
& .\tools\privacy_lab\measure-android-pipeline.ps1 -Serial emulator-5556 -Pairs 2 -Kbps 0 -RttMs 0
& .\tools\privacy_lab\measure-android-pipeline.ps1 -Serial emulator-5556 -EmulatorRegression
& .\tools\privacy_lab\measure-android-pipeline.ps1 -Serial emulator-5556 -ChecksOnly
```

Current testing is emulator-first at the user's request. Resume physical-device
measurements only after emulator findings have been addressed and the user is
ready. `-EmulatorRegression` rejects physical-device serials, compiles the native
Go test executable from the archived sources and runs the complete regression
suite with an eight-minute timeout. Its controlled-clock and process-crash
checks are functional evidence, separate from the unchanged real-time schedule
and paired latency gates. Failing timing runs must remain visible even when
these regression checks pass.

`-ChecksOnly` runs the scheduled seventeen-check path and collects evidence
without starting paired measurements afterward. `schedule-checks.json` includes
a finite private controller timeline for the deliberate delayed-client test,
its enqueue work, and the two reservations/bulk publication. Durations and cutoff
offsets use a local monotonic anchor; these are neither peer telemetry nor
delivered-message latency. Each run also archives and hashes its PowerShell
runner. The fused-input copy preserves byte ownership directly, avoiding a JSON
encode/decode round trip; signatures, cutoffs and durable commits are unchanged.

Use a currently connected serial from `adb devices -l`. The script archives and
builds the native worker from its source snapshot, verifies the transferred
binary, runs the seventeen separate-process checks, then the paired pipeline.
Android ARM64 uses the existing pure-Go build; the x86-64 emulator target needs
the installed NDK linker. Architecture and toolchain are recorded, so emulator
and phone results must not be pooled.

Temporary files reside in a fresh `/data/local/tmp/farvahar-protocol-<UUID>`
directory. Only executables under that exact directory may be stopped during
cleanup. Evidence is pulled before removal; both the resolved absolute path and
an ownership marker must match. If collection or ownership verification fails,
the directory is retained and cleanup is reported incomplete. No APK install,
app data clear, ADB forwarding, radio changes or host network settings are used.

The optional fifth argument to `submission_pipeline.dart` is the generated
`worker-config.json`. It binds the launch to archived source and binary hashes
and bounded serial/path/argument syntax. The Android worker's ready frame must
report its expected native architecture. Host public stores and the observer
remain unchanged; USB/ADB request and response overhead stays in the protected
measurement. This hybrid apparatus is not a phone-to-phone latency gate, radio
workload, battery trial or anonymity result. Host CPU samples exclude the native
Android processes; their private local diagnostics are separate evidence.

The private operation ring also records bbolt transaction allocation, spill,
rebalance and write counters. Write time includes successful page/meta writes
and their synchronization, but excludes file-growth synchronization; it cannot
be called an fsync-only measurement. Allocated transaction bytes are not the
database file's size or a complete count of disk bytes written. These fields
are neither returned by peer statistics nor stored in protocol checkpoints.

After a client verifies a complete output certificate and advances the phase,
it drops the standalone completed contribution before checkpointing. Exact
replies remain in the bounded cache; fused preparation installs its new active
contribution. Invalid certificates retain the active contribution. This reduces
serialization/allocation after acceptance without changing storage format,
synchronization, cached retries or restart clock restrictions. It is not secure
erasure and does not reduce the still-active prepared checkpoint by itself.

### Separate idle-resource characterization

`measure-android-pipeline.ps1 -Serial emulator-5556 -IdleRounds 30 -Kbps 5000
-RttMs 80` runs the opt-in atomic/common-schedule candidate without submissions.
It creates fresh roles, excludes five warmup rounds and records thirty scheduled
idle rounds. This mode is currently restricted to an emulator and cannot be
combined with regression or checks-only modes. It uses the existing hash-bound
archive, process ownership checks and temporary-directory cleanup.

The `idle-resources.json` report records CPU counters through the private local
pipe and TLS bytes at the controller's role connections. Request/response times
bound each CPU-counter observation; the resulting one-core percentage is an
interval. Diagnostic work can contribute to CPU. Every failed and unattempted
round remains visible. No peer-facing statistics or application behavior change.
Daily MiB values are conditional projections of the declared unchanged idle
schedule, not a measured day, radio traffic or battery use. The controller-mediated
topology includes laboratory protocol RPCs and excludes private pipes, discovery,
public news and IP/TCP/radio overhead. It cannot pass the physical resource gates.

### Optional compact RPC transport

The native laboratory worker accepts `-wire json` (default) or `-wire cbor-v1`.
The Android wrapper exposes the same choice as `-WireCodec`. The sixth argument
to `submission_pipeline.dart` selects the codec; an empty fifth argument means
no Android worker configuration. Only network candidates accept the compact
codec. Compare fresh JSON and CBOR runs from the same source snapshot and link
profile; preserve failed runs and startup observations.

CBOR uses pinned `fxamacker/cbor/v2` 2.9.1 with deterministic encoding, numeric
RPC field keys and native byte strings. It changes transport representation
only: signatures, JSON request-cache digests and encrypted checkpoint formats
remain unchanged. There is no codec negotiation or automatic JSON fallback.
The receiver requires a single canonical map, with bounded bytes, nesting and
collection sizes, and rejects duplicate/unknown fields, tags, indefinite
lengths, invalid UTF-8, non-finite numbers and trailing data. Failed decoding
never reaches protocol state handling. Decoders must receive fresh objects and
discard partially populated values after errors.

This is still the controller-mediated TLS laboratory transport. Smaller wire
messages neither establish anonymous traffic nor solve missed common deadlines,
clock admission, shutdown recovery or physical-device resource acceptance.

`-wire cbor-framed-v1` / `-WireCodec cbor-framed-v1` adds an explicitly selected
framed transport for the same CBOR bodies. It uses the same pinned mutual TLS
1.3 identities with the dedicated `farvahar-lab-cbor/1` ALPN. Each frame has an
eight-byte magic/version/direction/length header and a 1–2,097,152 byte body.
One outstanding exchange per connection avoids response ambiguity. No HTTP,
codec or connection retry is attempted automatically after an exchange fails.
An explicit later retry remains subject to the role's durable exact-reply rules.

Servers limit connections (including incomplete handshakes) to four and dispatch
only one protocol handler at a time. Handshake, partial-header, body, write and
idle deadlines bound socket work. Closing or cancelling interrupts the underlying
counted/paced socket; cleanup does not wait for a TLS close-notify write. Truncated
frames cannot become accepted responses. Restarts close the old client and bind
a new one to the validated new loopback endpoint. Canonical decoding, certificate
checks and signed protocol/state transitions remain required.

This deliberately identifiable laboratory ALPN is not a camouflage mechanism.
Connection framing does not provide autonomous uniform traffic, publisher
anonymity, real-device clock admission or shutdown reachability. Compare its
measured TLS byte counts with fresh HTTP CBOR controls, and continue to include
startup failures and deadline overruns when evaluating latency.

### Signed frozen-completion experiment (v22)

`fpp1frozen` / `-FrozenCompletion` explicitly enables a new signed schedule policy.
Fresh reservation selection retains its original cutoff. Only full authenticated
commitments and already pinned bulk work receive two seconds of completion slack.
No additional queue selection is permitted. The paired pipeline requests a
two-second admission lead while retaining the original vote/install deadlines;
startup remains in the recorded observations. Strict `fpp1atomic` remains the
default and retains its four-second admission lead. This is a security-sensitive
policy experiment, not an anonymity or latency claim.

```powershell
& tools/privacy_lab/measure-android-pipeline.ps1 -Serial emulator-5556 -EmulatorRegression -WireCodec cbor-framed-v1
& tools/privacy_lab/measure-android-pipeline.ps1 -Serial emulator-5556 -ChecksOnly -FrozenCompletion -WireCodec cbor-framed-v1
& tools/privacy_lab/measure-android-pipeline.ps1 -Serial emulator-5556 -Pairs 300 -Kbps 5000 -RttMs 80 -FrozenCompletion -WireCodec cbor-framed-v1
```

Run these sequentially. Regression covers both policies; do not combine its
switch with `-FrozenCompletion`. Frozen socket checks add a deliberately late
reservation/bulk completion and receipt check: nineteen checks and nine messages,
compared with seventeen/eight for the strict policy. Do not count these deliberate
fault checks as latency samples. The signed completion slack and requested
startup lead are recorded and checked by the paired adapter. Component tests
cover post-cutoff isolation attempts, pin replacement, omitted/forged inputs,
grace expiry, clock jumps, policy mismatch and restart fencing. All artifacts
remain experimental; the production APK is not changed by these commands.
