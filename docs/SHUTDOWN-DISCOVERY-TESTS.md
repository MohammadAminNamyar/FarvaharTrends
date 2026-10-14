# Shutdown discovery checks — 0.8.5

These measurements predate the 0.8.6 package and branding change. The in-place
updates and data retention described here refer to 0.8.5; 0.8.6 has a new
application ID and installs separately.

The implementation reduces dependency on public starting nodes. It does not
establish nationwide availability, anonymity, or a five-minute delivery promise.
One APK contains the reader, publisher, forwarding and optional helper roles.

## Local evidence, 14 October 2026

`flutter analyze` completed without issues. All 468 Flutter tests and 20 Node
tests passed. The reset-clock Java TLS fixture had a shutdown race: it waited
for the JVM to exit before closing the client socket. Closing the client after
the authenticated response fixed the circular wait; the full suite passed again.

Signed release APKs were updated in place on a Samsung S21 Ultra (Android 15,
ARM64) and the project's peer emulator (API 36, x86_64). Both report 0.8.5,
with ABI version codes 2016 and 4016. Existing identities, channels and news were
preserved. No entered peer IPs, ADB forwarding/reverse tunnels, new central peer,
or changes to Windows networking were used.

| Device check | Observed result |
| --- | --- |
| Samsung mobile data, Wi-Fi/Bluetooth off; emulator on the host's Internet connection | Automatic peer-network connection; fresh `PT085-MOBILE-EMU-001` received on Samsung, confirmed within 105 seconds of starting the publish action |
| Return path on the same independent connections | Fresh `PT085-MOBILE-SAM-001` confirmed on emulator within 20 seconds |
| Samsung back on home Wi-Fi, helper opt-in enabled; public discovery off on both | Both connected via the learned TCP contact; emulator force-stop/relaunch reconnected automatically |
| Fresh publication after that restart with public discovery still off | `PT085-NO-PUBLIC-001` confirmed on Samsung within 8 seconds |

These are conservative host-observation intervals that include UI navigation,
not network latency measurements or percentile estimates. The local TCP check
depends on this router and reachable cached contact. Internet access was not
blocked at the operating system; the app's public-bootstrap setting was disabled.
The separate loopback DHT test supplies the controlled isolated-topology check.
These trials do not prove NIN reachability. No new physical Bluetooth or
unplugged overnight receiving result is claimed for this build.

At the end, public discovery and announcement were restored on both devices,
helper participation was off, and Samsung Wi-Fi/Bluetooth/mobile data were on.
Farsi remained selected. The three clearly labeled test messages remain in the
existing test channels; no channels were deleted or newly created for these checks.

APK SHA-256 (verify the complete file, not its filename):

```text
ARM64  41a214013a42f444e2688b2bb3e17e1ea646ae0e62604b5a4950bb2920bf0220
x86_64 785f495bfaf1d61371c43815ce351a80259d0e4e995570645ea89bcf4b318f2c
```

## What changed

- Saved peers regain explicit reconnect intent after a temporary cooldown.
- DHT bootstrap imports accept the same public IPv4 format as the worklet.
  Unsupported legacy entries are removed without losing valid saved contacts.
- Reader settings separate public bootstrap use from opt-in routing assistance.
  Turning public discovery off uses a separate routing cache. This excludes the
  built-in bootstrap hosts; subsequent referrals are not filtered by country.
- Announced, reachable helpers share signed discovery contacts over existing
  authenticated links. Nearby links can carry these in All networks mode.
  Nearby only remains a boundary that disables remote discovery/contact use.
- Signed contacts are unverified hints until a bounded DHT probe succeeds.
  Short leases, per-introducer/owner/prefix limits, probe deadlines, retry backoff,
  expiry and bounded storage reduce stale routes and discovery spam.
- Damaged receiving settings do not silently re-enable public discovery or
  helper participation on recovery or the following launch.

## Repeatable automated checks

Use the normal local Flutter and pinned Node dependencies; no CI is required.

```powershell
powershell -NoProfile -File tools/flutter.ps1 analyze --no-pub
powershell -NoProfile -File tools/flutter.ps1 test --no-pub --concurrency=2
node --test test/*.cjs tools/tests/*.cjs
```

`overlay_shutdown_test.cjs` runs actual HyperDHT/Hyperswarm sockets, bound to
loopback, with no public bootstrap hosts. It removes the initial discovery node,
restarts a peer with a remembered key and remaining helper, connects a fresh
peer, then introduces a peer that started with no seeds. The test uses the same
options, candidate probing and discovery-refresh components as production.
Loopback endpoints are allowed only in the test; production imports reject them.
This verifies a local topology, not provider NAT traversal or an Android radio.

`peer_referrals_test.dart` exercises actual PeerEngine pinned TLS and persistence:
A sends news and a signed discovery hint to B; A stops; B restarts; C receives
the saved news and the original signed hint through B. The hint's fixture address
is not dialed. Separate tests cover contact tampering, expiry, storage limits,
settings migration, poisoned imports, cooldown recovery and candidate flooding.

## Small-group field protocol

1. Keep public discovery on initially. Volunteers who agree to share their
   reachable connection address enable “Help other phones reconnect”. Record
   whether the app reports a reachable helper; enabling the switch alone is
   not evidence that a carrier allows it.
2. Exchange fresh text in both directions on different providers without entering
   IP addresses. Record a unique test marker and elapsed time from one observer.
3. After contacts have been learned, turn public discovery off on the test
   participants. Restart one phone, then the remaining phones individually;
   repeat fresh publication and verify the actual arrival transport.
4. Introduce a fresh phone through local Wi-Fi or Bluetooth in All networks mode.
   Move it to another provider and check whether a learned helper is reachable.
   Compare this with a cold phone having no saved or nearby introduction.
5. Repeat with international routes unavailable in a controlled test environment.
   The public-discovery switch alone is not a network-level shutdown simulation.
   Do not change a tester's system-wide network settings without their agreement.
6. Test screen-off receiving, natural unplugged idle, Wi-Fi/mobile changes,
   disappeared helpers and changed addresses. Keep failures and unknown outcomes
   in the result denominator. Record battery cost and delivery percentiles.

The emulator's Bluetooth support cannot establish a physical phone-to-phone
Bluetooth result. A second real handset is needed for that test. Restrictive
carrier NAT, blocked UDP, inaccessible domestic routes, a completely isolated
cold start and the loss of every helper remain possible delivery failures.
Fresh outside news still requires a bridge with a surviving incoming path.
Helpers and ordinary direct peers are observable to network participants;
signatures, encryption and moving the helper role onto phones do not hide IPs.
