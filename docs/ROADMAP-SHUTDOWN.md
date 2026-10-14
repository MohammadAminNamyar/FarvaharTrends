# Shutdown roadmap — design proposals and implementation status

Status as of 0.8.4. Each section below starts with what is now implemented in
the code and what remains design work. Nothing here establishes anonymity,
nationwide reachability, or five-minute shutdown delivery; the field evidence
listed under each section is still required.

| Area | Implemented in 0.8.4 | Still open |
| --- | --- | --- |
| Domestic discovery | Bootstrap document v2 with numeric operator DHT nodes; runtime import/export of starting-peer lists (paste, QR display) with a 90-day app-private store; DHT nodes handed to the worklet ahead of the hyperdht defaults | QR scanning, address-based direct dial of overlay peers, TCP/TLS fallback for blocked UDP, port randomization, any Iranian field measurement |
| Discovery observability | Beacon v2 and Wi-Fi Direct TXT carry a rotating session token instead of the certificate; certificates travel only inside TLS 1.3 via a bounded trust-on-first-connect dial; phones join the DHT as ephemeral clients; `announce` is a per-install setting | Threat-model review, passive-capture validation on real radios, BLE advertisement review, announcing-helper consent flow |
| Native loopback proxies | 32-byte per-flow prefaces on every loopback hand-off, single use, bounded failed attempts, invalidated on restart | Device test with a hostile co-installed app |
| Restart after process death | Opt-in "Keep receiving after reboot": boot receiver plus sticky service gated on the saved preference, disarmed by an explicit Stop | Physical-device reboot/kill/force-stop/OEM trials and overnight battery cost |
| Signing and key rotation | Nothing; RSA PKCS#1 v1.5 remains | Everything in that section; it changes the wire format and invalidates existing identities, so it needs its own versioned rollout |
| Maintainability and dates | Jalali calendar in Farsi date display, one localization/digit helper module, typed snapshot DTOs, `pilot_app.dart` split into per-screen files | ARB/intl migration, DTO adoption in the legacy diagnostics page |

None of the proposals below establishes
anonymity, nationwide reachability, or five-minute shutdown delivery. Keep the
one-APK design: each installation can consume and forward public signed news over
working links. Fixed domestic servers are not an assumed requirement; prioritize
consenting phones acting as temporary reachable helpers.

## Domestic discovery and transport recovery

**Current gap.** `packages/flutter_pear/pear-end/persiantrend.js` uses HyperDHT's
three public bootstrap hosts plus cached routing nodes. There is no evidence that
cached nodes are domestic or reachable across Iranian providers.
`assets/bootstrap.json` is empty. `GatewayPortLease.java` correctly refuses to
treat a non-public gateway address/CGNAT mapping as globally reachable. A CGNAT
phone can still forward over established outgoing links.

`PeerContactStore` already retains signed helper TCP addresses for bounded
reconnection for up to seven days. App-private storage does not mean private-IP
addresses: `PeerContact` requires public numeric addresses. This cache differs
from the worklet's cache of Noise keys and DHT nodes. LAN dialing addresses remain
temporary. Peer-card import exists, but domestic introduction, refresh and
reachability validation are incomplete.

**Proposal.** Add signed domestic peer cards through QR, nearby exchange and
optional manual file import, with exact connection-key pins, transport capabilities,
expiry and helper consent. Verify possession with mTLS; signatures do not prove
address ownership or geography. Maintain bounded validated TCP address hints and
separate on-link Wi-Fi hints, with expiry, retry limits and invalidation on network
changes. Remotely supplied cards must not become arbitrary private-network scan
targets. Never scan IP ranges or publish reader addresses merely for reading.

Support bounded operator-supplied bootstrap configuration distributed through
existing peers or nearby exchange. It introduces contacts and cannot sign news.
A consenting helper role belongs inside the same APK. Established outgoing links
carry news in both directions. A cold-start phone still needs a reachable initial
introduction; DHT code cannot manufacture connectivity through blocking NATs or
firewalls. Research randomized ports and a TCP/TLS fallback for blocked UDP, with
bounded queues and retries. A different port or self-signed TLS does not establish
traffic camouflage. The unsupported owner-relay Dart API was removed; a future
relay needs an actual implementation, operator consent and separate validation.

News from outside Iran needs a bridge with a surviving incoming path, such as a
consenting satellite-connected device. Software cannot replace that incoming path.

**Required evidence.** Real Iranian cross-provider trials with international
bootstrap blocked: cold/cached starts, CGNAT, blocked UDP, changed IPs, restart,
Wi-Fi/mobile switching and locked phones. Measure success rates and latency
percentiles using one test clock. Canadian emulator tests are not shutdown proof.

## Discovery observability

**Current gap.** `lib/core/peer_discovery.dart` advertises the public connection
certificate every ten seconds. A public DHT topic with non-ephemeral announcement
can expose participants and addresses. Separate publisher keys do not hide IPs.

**Proposal.** Rotate short-lived discovery keys/nonces and disclose certificates
inside encrypted, bounded challenge/response, with replay prevention and proof
binding the discovery session to mTLS. Define migration for pinned caches without
silently replacing channel ownership. Research ephemeral/client-only DHT readers
with an explicitly consenting announcing helper role. Making every phone
client-only removes discoverable announcers and can break discovery.

Public challenges do not exclude an adversary running the app. These changes
reduce passive tracking; they do not create anonymity from providers or active
peers. Validate passive capture, active probing, replay, identity substitution,
key rotation and discovery liveness across helper proportions. A separate threat
model must cover compromised phones and network-wide observers before safety
claims change.

## Native loopback proxies

**Current gap.** Wi-Fi/BLE bridges and the overlay ingress can accept another local
app before the intended client. mTLS still protects content; flow theft can deny
service or reveal timing. Loopback alone is not an application identity.

**Proposal.** Prefer app-private Unix domain sockets with filesystem/UID checks
where supported. Otherwise use random per-flow preface tokens passed only through
private platform-channel/IPC paths. Enforce exact bounded prefaces, short deadlines,
single use, limits on failed attempts, and invalidation on replacement/restart.
A wrong first caller must not consume the legitimate flow. Never log/gossip tokens;
keep mTLS after local authentication. Test with a hostile separate app racing each
proxy, partial/wrong/replayed tokens and late connections, while checking that the
legitimate app reconnects and queues remain bounded.

## Restart after process death/reboot

**Current gap.** The merged app removes boot start; the patched service uses
`START_NOT_STICKY` and a no-op watchdog. Locked-screen receiving differs from
process death, reboot, force-stop and OEM restrictions.

**Proposal.** An opt-in production receiving preference, visible foreground
notification and Stop action, persisted before arming work. Design supported
foreground-service/WorkManager rearm paths for the target SDK. Recheck permissions
and radios; startup must be idempotent across engines, keys and locks. Explicit
Stop cancels every rearm path. Do not bypass force-stop semantics or promise
five-minute wakeup from scheduled work. Validate reboot, OS kill, force-stop,
revoked permissions, deep idle, repeated UI opens and overnight unplugged battery
cost on multiple manufacturers.

## Signing and key rotation

**Current gap.** Application signatures use exportable RSA keys with PKCS#1 v1.5
in Dart and no explicit blinding at the app call site. This requires side-channel
review; it is not evidence that signatures have been forged.

**Proposal.** Audited Ed25519 for future application signatures, RSA retained only
for TLS if required. Specify new domain-separated formats and a mixed-version
rollout before any wire-version change. Use signed successor-key statements bound
to the old identity/channel, new key, revision and purpose, with anti-replay rules
and nearby recovery. Historical news stays verifiable without granting unknown
successors authority. A compromised old key can sign an attacker's successor:
define precommitted offline recovery/revocation authority separately. Encrypted
password backups are not automatic public revocation. Test mixed versions,
downgrades, old/replayed statements, revoked editors and tampered recovery files.

## Maintainability and dates

**Current gap.** `lib/ui/pilot_app.dart` combines legacy diagnostics and reader UI;
localization/digit conversion are duplicated. Snapshots are loose maps and dates
use the Gregorian calendar.

**Proposal.** Separate legacy diagnostics, split reader screens, migrate copy to
ARB/intl and introduce typed snapshot DTOs at engine/service/UI boundaries. Add
explicit Jalali presentation while preserving signed UTC timestamps, local time
zones and per-writer ordering. Calendar formatting cannot invent a trusted clock
or alter signatures. Cover Farsi RTL, English, large text, long/many channels,
calendar/time-zone boundaries and legacy/missing snapshot fields. Separate this
refactoring from network/protocol migrations.

## Order and constraints

Measure domestic reachability and helper consent first, then design discovery
recovery and local proxy authentication. Treat anonymity and restart behavior as
separate changes with explicit threat/lifecycle tests. Preserve one APK, resource
bounds, private channel choices and existing keys. Release tooling and CI are
excluded from this requested change.
