# Shutdown resilience and security status

Updated for 0.8.9. This is an implementation status, not an independent security audit or evidence of nationwide delivery. See SHUTDOWN-DISCOVERY-TESTS.md for the earlier isolated-network experiments and READINESS-PLAN.md for all six active workstreams.

## Finding peers without international infrastructure

Each APK can receive and forward public, signed news. Public HyperDHT discovery is enabled by default. It can be disabled without disabling nearby transport or direct TCP reconnection. Runtime starting-peer imports, signed introductions over authenticated links, and separate public-bootstrap-off routing state are implemented. Reachable helper operation remains an explicit opt-in inside the same APK.

Direct TCP/TLS routes are independent of the UDP DHT. A consenting helper's signed address is initially a claim. From 0.8.7, a phone forwards or newly persists that claim only after an outbound connection proves the exact endpoint and connection certificate. Existing outbound seed connections can supply that proof. A signature at one port does not validate a different port. New unverified claims are limited to four in total, four per introducer, and four per IPv4 /24 or IPv6 /48. Unverified claims time out after one minute; repeated signed updates do not keep them alive. Existing authenticated links and configured contacts remain protected by the engine's retention rules.

Previously saved contacts remain available for pinned reconnection for up to seven days after lease expiry. Expired contacts are never forwarded. On process restart, cached fresh contacts also need a new connection check before forwarding. A partially committed first cache write can be recovered from its bounded, signature-checked pending file. A valid committed empty cache takes precedence. Cache-write errors do not stop current delivery or classify an honest peer as abusive.

This does not create a route where none exists. A fresh phone needs at least one reachable contact, introduction over Bluetooth/local Wi-Fi, or an accessible discovery network. Cached addresses can change, and CGNAT may prevent incoming TCP connections. A helper's public address does not prove that it is inside Iran or reachable across Iranian providers. No IP-range scanning is used. Fixed domestic servers are not required by this design, but some reachable initial participant remains necessary for distant phones to connect. Overseas news must cross the shutdown through a surviving link before domestic peers can redistribute it.

Still needed: Iranian cross-provider field measurements; UDP-blocked real mobile networks; cold-start trials with nearby introductions; cached-address churn; QR scanning; overnight operation and realistic helper proportions. Loopback isolation tests demonstrate application behavior, not carrier reachability.

From 0.8.8, a newly authenticated overlay peer is registered for persistent retrying in the same session rather than only after app restart. Retry intent is bounded by the eight-peer authenticated cache, respects cooldown and is removed on eviction. An answering but isolated worklet receives a bounded restart opportunity: 90 seconds with remembered peers, 180 seconds without them, then backoff to 15 minutes during continued isolation. A live pinned application link must stay healthy for 90 seconds to reset the backoff. No-network samples suppress these isolation restarts. The tests exercise real HyperDHT reconnection after the starting node and topic discovery are removed; this remains local-loopback evidence.

## Android receiving and restart

A visible connected-device foreground service supports active receiving. Restart after process death or reboot is opt-in. From 0.8.7, a shared native policy checks saved consent before starting Dart; a null/system intent cannot clear a saved Stop. Stop and restart settings are committed before acknowledgement, and teardown cannot overwrite a newer session. The boot receiver is not exported to other apps and accepts only protected boot/package-update broadcasts. Startup refusal releases the service-owned wake lock and stops the service. Notification content intents are immutable.

Android force-stop remains effective. The app's explicit Stop disarms restart until receiving starts again. The service holds a CPU wake lock while active, so battery use must be measured on unplugged physical phones. A successful emulator reboot or short locked-phone trial is not an overnight battery result or evidence for other manufacturers. Android/OEM policies may still refuse or kill receiving.

References: https://developer.android.com/develop/background-work/services/fgs/service-types and https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start

## Hostile peers and identity protection

The app retains separate publisher and connection identities, pinned TLS 1.3 links, signed channel content and editor revocation, local follow/hide/trust choices, bounded frames/queues/storage, global and per-peer work limits, and authenticated single-use loopback hand-offs. The new referral limits reduce amplification and contact-pool exhaustion. They do not defeat an attacker controlling many independent addresses and identities, nor an attacker who occupies every available contact at first launch.

Reader and publisher stores also share a bounded per-isolate queue before acquiring the native cross-engine identity lease. Concurrent stores cannot bypass ownership checks or fail merely because another operation in the same engine currently owns that lease.

LAN and Wi-Fi Direct discovery use rotating session tokens. This must not be generalized to all protocols: the TCP enrollment path still introduces a connection certificate before mutual TLS. Public news is public; link encryption prevents undetected modification but does not hide connection IPs or traffic timing. Publishing, forwarding, and reading are not anonymous. Tor, mix-network anonymity, and protection against a global observer have not been implemented.

Still needed: separate-app attacks against native loopback proxies on real phones; passive capture and active probing of each radio; independent review of parsers, native bridge boundaries, traffic correlation and resource-exhaustion behavior. Maintain bounds and test recovery after attacks, not just rejection of a single malformed packet.

## Publisher compromise and cryptography

Editors can be revoked by the owner and their later posts rejected. Legacy encrypted backups recover the same authority and cannot revoke a stolen legacy owner key. New 0.8.9 protected channels precommit a separate recovery key and export it only in an encrypted kit. Recovery authorizes a new online owner generation; readers enforce it after receiving the signed proof. Policies and editor permissions sign the exact generation-grant ID. Same-generation conflicts fail closed until a higher recovery grant arrives. Existing v1 channels keep their identity and can explicitly create a new protected channel. This experimental protocol needs independent review; see [owner recovery](CHANNEL-OWNER-RECOVERY.md) for offline freshness, storage and compatibility limits.

Application signatures currently use RSA PKCS#1 v1.5 with SHA-256. The installed Dart RSA engine uses CRT private operations without explicit blinding. This warrants specialist side-channel review; it is not evidence of an observed forgery. Changing algorithms or introducing offline recovery requires a versioned protocol, a reviewed key hierarchy, migration of existing channels, and downgrade/replay tests. Do not silently replace keys or invalidate users' channels as a hardening shortcut.

## Scope

Keep existing keys, channel data, one APK, bounded resource use and private reader choices. No release tooling or CI is included. The app is suitable for controlled testing; results here do not certify safety for high-risk publishers or establish million-user capacity.
