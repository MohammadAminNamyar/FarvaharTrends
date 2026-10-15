# Protocol boundaries and evidence

Current readiness work is tracked in [READINESS-PLAN.md](READINESS-PLAN.md).
Versioned sections below include historical experiments; their platform,
transport, power state and build limitations remain part of each result.

## Discovery recovery, 0.8.5

Public bootstrap use is independently switchable. Off means no built-in public
HyperDHT bootstrap hosts and a separate routing cache, not country filtering.
Imported or shared addresses and subsequent DHT referrals can be outside Iran.
A cold, disconnected phone still needs a reachable introduction. No range scan,
central directory, or server deployment was added.

Routing assistance and router leases now require the separate helper opt-in
(off by default), plus announcement. Ordinary ephemeral clients can announce,
receive and forward news. Existing users are not silently opted into helping.
Damaged receiving preferences disable public bootstrap, announcement and helper
service and save that conservative policy for subsequent starts.

Peers negotiate `discovery-v1` before exchanging up to four signed discovery
contacts in a separate frame; older clients continue ordinary news exchange.
Each contact is at most 4 KiB, valid for five minutes, and signed by a connection
identity. A signature authenticates the endpoint claim, not ownership,
reachability, geography or publisher identity. Expired contacts remain local
probe hints for up to seven days and are never forwarded after lease expiry.
The optional store holds 16 hints, at most four per introducer and two per owner.
Newer owner leases can replace older addresses. Contact verification shares
the existing per-peer/global referral budgets.

The worklet probes at most two candidates concurrently and eight per minute,
with five-second deadlines, backoff and a 16-candidate bound. Only responding
endpoints gain helper priority in the 32-node routing cache. Source and IPv4
prefix caps reduce crowding; they are not Sybil resistance. DHT imports reject
unsupported IPv6 and reserved/private addresses consistently across Dart and JS.
Valid saved entries survive migration past unsupported legacy DHT entries.
Remembered peers regain explicit dialing after the transport cooldown rather
than waiting for another public-topic discovery. Details and test boundaries are
in [shutdown discovery checks](SHUTDOWN-DISCOVERY-TESTS.md).

## Correctness hardening, 13 October 2026

New identities use correctly encoded certificate validity from 2000-01-01 to
9999-12-31. Both TLS directions require TLS 1.3. Existing certificate fingerprints
and keys are preserved: older certificates keep their original validity dates.
These dates prevent common reset-clock failures; they are not a revocation
mechanism and do not cover clocks set before 2000.

Overlay records decode with an offset cursor and one compaction per input chunk.
Protocol penalties use a separate, session-local table of at most 64 identities,
retaining strike history for five minutes and cooldowns through contact eviction.
An unexpired penalty is not displaced by identity churn. At table saturation,
new identities still face the existing global handshake and traffic budgets.
IPv6 addresses within a /64 share the pre-TLS admission budget.

Locally followed, owned and managed channels are protected from channel-metadata
eviction. Other channels rotate by local accepted bulletin/policy arrival activity,
not signed wall time. Protection hints are never journaled, exported or gossiped.
This protects the channel entry from stranger-driven removal; global news/image
limits still apply and cannot retain an unlimited followed history. Automatic
LAN-origin contacts may attempt four new channels per minute; other contacts
retain the eight-channel budget and the global budget remains 32.

The unused owner-relay Dart API was removed because the production worklet did
not implement it. This change adds no relay service or new reachability path.
Interface errors use localized codes; raw details are bounded to 20 entries of
512 characters in the in-memory Temporary log. They are not included in the
shareable connection report or sent automatically. Corrupt reader settings now
show a warning that notifications and image downloads were disabled.

## 0.6.0 automatic discovery and phone forwarding

Receiving, publishing, discovery and forwarding run inside one APK. No separate helper application is needed. All networks adds a pinned Hyperswarm/HyperDHT transport with a single public application namespace. Public DHT bootstrap peers help first discovery and encrypted NAT traversal; this is infrastructure dependence, although there is no required central news backend. Channel names, follow/trust choices and publisher private keys are not discovery topics. Discovery participants can observe connection metadata. The existing pinned mutual TLS, publisher signatures and bounded gossip protocol run over the discovered stream.

Each phone can forward news over established links. A compatible Wi-Fi gateway can additionally grant the phone an automatically renewed TCP NAT-PMP lease, requested for 120 seconds and accepting grants of 60–120 seconds. Unsupported routers are left unchanged. This does not bypass carrier NAT or provider filtering. A signed connection contact is shared over authenticated transports and checked before admission; it authenticates a key, not address ownership or editorial trust. At most 16 contacts are retained. Fresh remote contacts expire within five minutes; previously verified private reconnect hints may remain for seven days and are never regossiped after expiry. Removing a peer removes its saved contacts. A stale address may fail; the dial still requires the pinned identity and never accepts a replacement certificate.

Two independent Android installations (an emulator on the computer's Wi-Fi path and a Samsung on mobile data with Wi-Fi/Bluetooth disabled) passed the preliminary Hyperswarm transport test in Canada without entered peer IP addresses. Discovery took 21–25 seconds; fresh signed test news in each direction took 383 ms and 117 ms to acknowledgement. This was a disposable connection lab, not proof that the final integrated APK or Iranian routes work. A separate isolated loopback DHT test rediscovered a sender from a learned routing node after the initial entry node was removed; it is a component simulation, not a shutdown field trial.

The integrated Android release test variant subsequently passed normal UI channel creation/publication and delivery in both directions on those independent devices, using only the Hyperswarm route while the Samsung used mobile data with Wi-Fi/Bluetooth off. Fresh news also appeared with the Samsung locked and its screen off; the host observed it within 3.2 seconds of beginning the final publish action, including UI automation and polling. Device clocks differed, so subtracting publisher and receiver wall times would be invalid. An arrival-label regression found by that test was corrected and covered by a persistence test.

For a controlled recovery trial, the Samsung joined the home Wi-Fi and the same APK automatically acquired a router lease and shared its signed contact. Both test installations were updated and restarted with public discovery, LAN/UDP discovery and nearby transports disabled by a test-only compile flag. They reconnected using the saved contact and exchanged fresh news in both directions, including receipt while the Samsung was locked/screen off. The host observed delivery within 3.7 seconds, including automation. This exercises the cached TCP path and this router's public-address hairpin support; it does not simulate Iranian provider filtering or prove domestic routing during a real shutdown. Test flags and local diagnostic exports are disabled in the distributed APK. These short USB-assisted locked-screen trials are not natural overnight/Doze or battery measurements.

During a shutdown, private cached DHT routes and signed TCP contacts can provide alternatives to international discovery only while a reachable domestic peer network exists. Bluetooth/local Wi-Fi can introduce or refresh contacts and news. External news still needs a bridge with a remaining incoming connection. Ordinary handsets behind restrictive NAT cannot all become unsolicited inbound listeners. Iranian cross-provider reachability, natural overnight receiving, battery cost and delivery percentiles remain field-test questions.

New installations durably select **All networks** for automatic use of reachable IP, local Wi-Fi and nearby paths. Existing explicit choices are preserved. Corrupt, missing-after-initialization or interrupted preferences recover to **Nearby only**. This recovery is a transport boundary, not a promise of anonymity.

In **Nearby only**, Bluetooth and actual on-link local Wi-Fi remain available. Mobile data may stay on for other apps. Wi-Fi TCP/UDP sockets use a real Android Wi-Fi Network, validate numeric destinations against connected routes, and close on network changes. Native proxies carry opaque pinned TLS to loopback-only Dart listeners. Every loopback hand-off (local Wi-Fi, Wi-Fi Direct, Bluetooth and the Internet overlay, in both directions) requires a 32-byte random preface that is exchanged only in-process or over the private platform channel; a wrong, partial or replayed preface is dropped without consuming the flow, so another app on the same phone cannot hijack or exhaust a transport flow. Failed or missing Wi-Fi support never enables a default-network Internet socket. Private address ranges alone are insufficient. Client isolation and blocked multicast can still prevent delivery.

All networks accepts a bounded, signed connection beacon on TCP before the ordinary pinned mutual-TLS handshake. It is used only for a configured endpoint or validated signed contact with the TCP-enrollment capability. The preliminary beacon contains a public connection identity, not a publisher identity, subscriptions or news; observers can still recognize this traffic. A valid beacon is not enough to become an admitted client: TLS must prove possession of the same key. Nearby only rejects this remote enrollment path. Dedicated volunteer relays remain optional alongside phone forwarding.

Several reachable relay identities can be bundled at build time, without a central configuration service. The source template remains empty until an operator supplies actual peer certificates and addresses. Relays retain the pilot's bounded connection and traffic limits; this package does not establish large-scale capacity. Public/mobile-data/NIN delivery and host independence require field tests on the real deployed hosts. A local relay test is not that evidence.

Wi-Fi Direct is disabled in Nearby only because source-bound P2P sockets do not meet this build's Android Network binding requirement. **All networks** retains direct Internet/NIN, LAN, Wi-Fi Direct, Bluetooth priority and address visibility. No Tor is bundled. Nearby only reduces IP exposure, without concealing radio presence, first recipients, timing or compromised devices.

Publisher and connection keys are separate. Upgrades retain the historical publisher key for channel ownership and create a different connection key for TLS, discovery and peer cards. No new publisher-to-connection mapping is sent. Earlier connections may already have revealed the historical publisher key. Reading or forwarding is not proof of authorship; outside-Iran origin is not a consumer-safety guarantee. The sections below describe shared protocol behavior and All networks unless qualified here.

### Research direction: protecting the first publisher

Investigated 11 October 2026. A credible next architecture separates **anonymous encrypted submission** from **public distribution**. A publisher signs a news item offline, encrypts the signed item into an anonymity transport, and a release endpoint verifies it before inserting the public item into the fast peer network. Multiple independent release endpoints avoid a single news operator. A local Bluetooth courier would carry the encrypted submission rather than immediately exposing a readable signed article. This architecture is **not implemented or validated in the current APK**.

- [Katzenpost specifications](https://katzenpost.network/docs/specs/mixnet/) and [operator guide](https://katzenpost.network/docs/admin_guide/) provide an existing mixnet implementation/protocol and local deployment path. Deploying all required relays, gateways and directory authorities on reachable domestic networks could avoid dependence on international routing. That is an engineering inference, conditional on real NIN reachability and independently operated infrastructure; no Iranian deployment or censorship-resilience test has been performed.
- The [current Katzenpost project page](https://katzenpost.network/) lists thin clients in Go, Rust and Python and source-buildable client applications. It cautions that the threat model is evolving and must be read together with the newer Echomix paper. A Flutter/Android integration and an up-to-date threat assessment are separate engineering work; Katzenpost is not a dependency or routing path in this APK.
- [Loopix research](https://www.usenix.org/conference/usenixsecurity17/technical-sessions/presentation/piotrowska) evaluates anonymity with seconds-scale latency using layered encryption, cover traffic and random delays. It does not establish a five-minute guarantee for our topology. [Smartphone energy measurements](https://www.usenix.org/conference/usenixsecurity23/presentation/hugenroth) show why sustained cover traffic needs battery testing.
- [Briar's architecture](https://briarproject.org/how-it-works/) uses Tor for Internet metadata protection and nearby transports during outages. Its limited-nearby-monitoring and trusted-contact assumptions cannot be silently transferred to automatic stranger discovery.
- [Strong Anonymity for Mesh Messaging](https://arxiv.org/abs/2207.04145) offers relevant offline research, but its security model allows identifying a ciphertext's transmitting origin while hiding whether it is real/dummy. Public-channel adversaries can read public news, so directly copying it would not establish anonymity for readable first-hop publications. The paper's large-network performance is modeled; its small Android proof of concept does not certify FarvaharTrends's GATT paths.

A controlled mixnet test should isolate all international access, verify domestic bootstrap and relay reachability, measure fresh-message latency/battery, and assess colluding-relay and global-observer assumptions before making publisher-protection claims. No cryptographic scheme can restore missing physical connectivity or protect a compromised publisher device.

The follow-up investigation on 14 October 2026 also considered
[Dandelion++](https://arxiv.org/html/1805.11060) and
[Moby](https://petsymposium.org/popets/2022/popets-2022-0071.pdf).
Dandelion++ explicitly excludes ISP-level adversaries and does not stop targeted
attacks; forwarding through a few random phones is not sufficient protection
for the stated monitoring threat. Moby demonstrates a blackout-oriented Android
research prototype with prior trust establishment, but excludes a global observer
of its nearby network and does not hide participation. Neither result establishes
anonymity for this app's readable public-channel gossip.

A proposed protected-submission path would keep signed articles out of ordinary
inventories until release after mixing. It must also cover channel announcements,
owner/editor controls, images, retries and recovery from crashes; protecting text
alone leaves correlated publishing actions exposed. Unavailable protected routes
must leave submissions queued, never silently fall back to direct publication.
Peer selection needs resistance to malicious identity multiplication, and the
design must specify what timing, packet size and activity remain observable.
These are research requirements, not implemented APK features. Operating the
roles on phones does not conceal relay participation or establish enough
independent operators, available traffic or reliable background service. Old
publisher-to-connection observations cannot be erased by a protocol upgrade.

FarvaharTrends is an experimental public-news transport pilot. It has no measured field performance, nationwide coverage claim, or anonymity guarantee. Use benign test messages and consenting volunteers. The reader interface has no Results tab; ordinary testers provide verbal feedback.

This build implements separate identities and restricted local delivery; Tor and anonymous submission are not implemented. The research above describes a possible additional protection layer. This APK uses direct routes only. A connected peer sees the network address of its immediate neighbor; a government-operated peer may link a publisher's signing identity to that address. A provider with suitable connection records may associate it with a subscriber. Forwarding a public post alone does not prove authorship. TLS encryption and news signatures do not conceal network addresses, prevent traffic correlation, or protect a compromised phone.

There is no required central news backend or automatic central collection of follow/trust choices. Public signed news is cached and forwarded between reachable devices, which may include volunteer starting peers. Follow, hide and trust choices stay in the phone's private preferences; they are not public votes. The app does not read GPS coordinates. These properties do not provide anonymity, and this build must not be offered as protecting sensitive publishers' identities.

## Connectivity and identity

- Nearby peers can be found automatically through IPv4 multicast announcements on the local network. Since 0.8.4 the announcement (`farvahartrends/discovery/v2`) carries only a random session token that rotates on each engine start and at least every 30 minutes, the listening port and an expiry; it contains no certificate, fingerprint or signature. A receiver learns the certificate only by dialing the announced endpoint over TLS 1.3, where certificates are encrypted, so a passive observer on the network cannot enumerate or track installations from announcements alone. Dials are bounded per endpoint and per token (4 per 5 minutes), limited to on-link targets and to the existing automatic-admission budget, so a spoofed announcement pointing at another host cannot create more than that bounded, authenticated-only traffic. Older signed v1 announcements are still accepted from older peers but are no longer sent; v1-only peers cannot discover v2 peers. This remains trust on first contact for a certificate key, not verification of a human publisher, and an active adversary running the app can still learn certificates by connecting. UDP discovery uses a local multicast hop limit of one; it does not discover arbitrary phones across Iranian providers. Android also implements experimental local Wi-Fi Direct DNS-SD and BLE discovery. All networks additionally uses public DHT discovery; there is no address-range scanning or central news service.
- Explicit starting peers can optionally be bundled as numeric endpoints with pinned certificates. The general APK's explicit list remains empty; automatic Hyperswarm discovery operates independently of it. Earlier local-test builds bundled aliases for one PC identity, not independent Internet or Iranian volunteer infrastructure. Manual peer cards remain available for verified contacts and controlled trials.
- A pinned identity authenticates a key; it does not establish address ownership, honesty, or reachability. Carrier NAT, firewalls, changing addresses, blocked UDP, Wi-Fi client isolation, and asymmetric routing can defeat the implemented NAT traversal or direct routes.
- Two devices sharing Wi-Fi test a LAN. Separate Iranian providers test only the particular routes and conditions observed. Neither proves that all domestic networks remain connected during a shutdown.
- A failed direct TCP/TLS route is a failure of that route and configuration. It is not evidence that every peer-to-peer architecture is impossible.
- The protocol forwards signed channel announcements and bulletins through reachable contacts. Ordinary channel news has no automatic read/delivery report, and old cached channel-news measurement receipts are not advertised or relayed. Explicit paired developer diagnostic bulletins use a separate legacy measurement flow. An A–B–C topology still needs working A–B/B–C links; LAN discovery does not establish a cross-provider route.
- Fresh external news cannot enter an isolated network without an incoming communication path. The prototype creates no such path by itself.

## Phone-as-helper research, 12 October 2026

A separate, temporary Android test app established a real cellular-to-home-Wi-Fi TLS connection on one Samsung running Android 15 in Canada. The Wi-Fi listener automatically requested a short-lived TCP mapping from the home router using [NAT-PMP](https://www.rfc-editor.org/rfc/rfc6886.html); the client used Android's [explicit cellular Network binding](https://developer.android.com/reference/android/net/Network#bindSocket(java.net.Socket)). The listener observed a public source address, and the client's local address differed from the Wi-Fi listener's. No external STUN, TURN, DNS rendezvous or news relay was used for this path. The mapping was removed after each completed attempt. A prior browser WebRTC test across the PC's Wi-Fi and the phone's mobile data failed; this successful native path does not establish general hole-punching success.

The native test transferred a freshly generated Farsi channel announcement and bulletin signed with FarvaharTrends's actual content implementation. FarvaharTrends's verifier accepted both signatures and the exact received bytes. A completed round trip with the phone locked and its display off took 456 ms. In a separate test, a new signed bulletin was generated only after the TLS connection existed and the screen was switched off; the Wi-Fi server then pushed it to the cellular client, with publication-to-acknowledgement time of 187 ms. These are individual observations, not a latency percentile or a five-minute delivery guarantee. The test used a connected-device foreground service and bounded CPU/Wi-Fi locks, a throwaway laboratory TLS identity, and USB for setup/publication injection and result retrieval. It did not insert the fixture into the public news network.

A further fresh-publication test left the phone in artificially forced deep Doze for 30 seconds before generating the signed news. The screen was off and the keyguard locked at receipt; publication-to-acknowledgement time was 136 ms, and the content passed the same signature/exact-byte checks. The app was not battery-optimization exempt. The Samsung's UID network-policy state explicitly allowed the foreground service's traffic despite the device-wide Doze state. This is observed device behavior, not a general Android guarantee. The developer harness simulated unplugging and temporarily set the alarm-proximity test threshold to zero, because Samsung's scheduled system wakeup otherwise prevented forced idle. It restored the original threshold, battery reporting and idle state afterward. The run is a short forced-state experiment, not a natural unplugged overnight test; [Android's Doze guidance](https://developer.android.com/training/monitoring-device-state/doze-standby) still requires testing each relevant power condition.

That earlier native experiment used two explicitly selected network roles **on one physical phone**, not two independent phones, and was outside the main application. Its research APK embeds a disposable test credential and must not be distributed as FarvaharTrends. The 0.6.0 integration and later independent-device checks are described above; Iranian/NIN routes, natural overnight sleep, battery cost and actual shutdown resilience remain unverified.

The implemented design uses a changing population of reachable phones: compatible Wi-Fi phones can offer temporary incoming connections, and restricted mobile clients can maintain outgoing encrypted links to them. News flows in both directions over an outgoing connection. Learned, expiring connection contacts are cached and exchanged over existing peer links and nearby paths, with bounded admission, signature checks and rate limits. A cold-start device still needs at least one working discovery/contact path; an unsupported router, upstream carrier NAT, or blocked domestic route can prevent this method. A static IP is unnecessary when current reachable endpoints can be learned, but an accessible endpoint remains necessary. Reachable phones assume a forwarding role with observable addresses; moving that role onto phones does not provide anonymity or establish operator safety.

## Experimental native paths and route selection

The engine keeps multiple bounded route candidates for a peer's immutable certificate identity and selects one active TLS link per peer. It prefers ordinary Internet/domestic IP, then the discovered Hyperswarm stream, LAN, Wi-Fi Direct and Bluetooth, with retries and a promotion grace period. A priority label does not prove geographic routing, actual Internet access or radio concurrency. The recipient's `receivedVia` records its receiving hop; it does not attest the whole path or classify Iran's domestic/global boundary. Cached/local publications do not establish fresh remote delivery.

Wi-Fi Direct advertises this app's exact DNS-SD service and a rotating session token/port hint (TXT `v=2`, `sid`), not an identity fingerprint. A candidate needs matching service and TXT observations before automatic connection initiation. These advertisements remain spoofable hints, not peer or publisher authentication. Only the TLS handshake and exact certificate-pinned TLS establish the transport key. The adapter reports actual framework group state and only exposes a group route correlated with a detected app service. Android chooses the group owner and controls connection confirmation. Existing unrelated P2P groups are reported occupied and are not removed. Automatic initiation is paused while a working higher-priority IP/LAN link exists and has a finite per-activation prompt budget. Connection formation may interrupt ordinary Wi-Fi on phones without concurrent STA/P2P support. Pausing initiation does not override Android's incoming connection prompts.

The BLE GATT bridge transfers TLS bytes after both sides' public signed discovery beacons are admitted by the engine. Loopback bridge endpoints are ephemeral routing details and do not replace the expected remote certificate. The initial bridge supports one BLE link per device; it is not a simultaneous many-device Bluetooth mesh. Advertising/peripheral support varies by device. On Android 10/11, discovery in this implementation requires a visible app unless the relevant background-location permission already exists; retaining an established link is a separate experiment. The app does not read GPS. Older Android permission/location prerequisites still apply to radio discovery.

An optional Windows BLE helper lets a physical Android phone reach the local PC engine; the PC can then relay over IP to the two emulators. It requires working host hardware/helper dependencies and separate validation. Phone→BLE→PC→IP→emulator success would prove that mixed route, not a direct physical Bluetooth link to an emulator. Android native implementations, compiler success and emulator feature flags do not establish real-device throughput, locked behavior, five-minute latency or shutdown reachability. Use the [English](MULTI-NETWORK-TEST.en.md) / [Persian](MULTI-NETWORK-TEST.fa.md) matrix and record actual results separately.

## Channel ownership and source trust

Following, blocking and trust marks are private local preferences. The main feed shows followed, unblocked channels; other channels are available through Discover. Owned channels are followed unless blocked. Trust defaults to Not assessed; Trusted by you is a personal assessment, not a public vote or factual verification. Trust does not follow a channel; hiding clears both follow and trust. Unblocking someone else's channel does not restore either mark; an owned channel becomes automatically followed again, without restoring trust. These lists are never included in discovery, gossip, peer requests or diagnostic exports. The shared public cache may still carry other channels, so this is not a promise to download only followed content.

Public metadata is limited to 128 channels and 16 per publisher. Local-owned metadata and sequence counters are protected within that limit. Unprotected foreign metadata rotates by local arrival activity with its dependent cached news, so a full foreign directory cannot permanently prevent local channel creation. The news cache retains at most 256 bulletins, 64 per channel and 96 per publisher. Within a full channel window, the highest signed sequence numbers are retained with deterministic ID tie-breaking; stale replays cannot displace newer items there. Publisher retention uses insertion order.

At the global news bound, foreign items are evicted before local-authored news and
the local outbox; per-channel and per-publisher limits still apply. Locally
followed or managed channels receive retention priority. When more than 64
unfollowed foreign posts occupy the cache, one of those is evicted first;
otherwise the largest followed foreign feed supplies the eviction candidate.
This keeps room for relaying other public news, subject to local-outbox priority,
and reduces displacement of quieter followed feeds. These local retention hints
are not included in news envelopes or public journal records. Trust marks do not
change these quotas. There is no permanent replay history or unlimited archive.
Sustained multiple-key attacks can still displace foreign public content or
compete for automatic contacts.

## Traffic abuse limits

Each device enforces local elapsed-time budgets without broadcasting trust choices or accusations. Current experimental defaults per 60-second window are 1 MiB ingress and 600 frames per peer, 4 MiB/2,400 frames globally, 512 KiB egress per peer and 4 MiB globally, and 512 requested object IDs per peer/2,048 globally. Frames remain capped at 32 KiB. Repeated object responses are suppressed for 10 seconds with a bounded cache; budgets survive reconnects in the same engine session. Excess request/egress work is deferred to later inventory reconciliation, which can add delay under load. Ingress overrun can close a connection; global exhaustion alone does not mark an honest peer abusive.

Version 0.8.12 splits each aggregate traffic allowance into a shared half and
eight reserved connection shares. Per active connection, the reserved portions
are 256 KiB ingress, 150 frames, 256 KiB egress, 128 requested IDs, two new-channel
attempts, eight authority/policy checks and four contact checks per window.
Existing per-peer limits still apply. A quiet active connection's reservation
cannot be spent by another connection. A freed slot retains its spent allowance
until the same global window resets; a new connection inherits a free slot's
remaining allowance. Reconnecting or changing keys therefore cannot increase the
aggregate allowance. Share exhaustion can close ingress without a misconduct
strike, or defer outbound/request/metadata work for normal reconciliation.

This is resource isolation between active connections, not a promise of fair
content distribution. An attacker can still occupy connection slots, compete
for handshake/admission work, or send valid news that consumes a reader's own
allowance when forwarded. Newly admitted peers may inherit spent slots and need
to wait for a reset. The design does not distinguish useful news from signed
spam or provide Sybil resistance. Saturation of the network below TLS and CPU,
radio or operating-system scheduling can still interrupt delivery.

New channel admissions are limited to 4 attempts per automatic LAN-origin peer, 8 per other peer, and 32 globally per minute; excess metadata can be requested again later on the same TLS connection. Missing-channel news has at most four pending slots per peer, sixteen total, and expires after 45 seconds using a local monotonic clock. Incoming TLS work is limited before cryptographic processing to four concurrent handshakes, sixteen attempts per IPv4 source or IPv6 /64 and sixty-four globally per minute. This leaves room for outgoing connections during an incoming slow-handshake attack. Source-address budgets may also affect multiple legitimate devices behind one address. They do not prevent radio interference or saturation of the underlying network link.

There are at most 16 saved peers, including at most 8 automatic contacts, and 8 active links. Automatic admission permits 16 new identities per minute. When space is needed, a disconnected automatic contact without a pending connection/native route becomes replaceable after 60 seconds since admission or its last successful TLS adoption; repeated beacons alone do not renew it. Saved automatic pins are immediately eligible for replacement after engine restart. Manual contacts and configured starting peers are protected from this rotation. In-flight incoming TLS work delays replacement. An attacker maintaining active links can still compete for the finite slots. Outbound writes have bounded queues and deadlines, so an unresponsive reader cannot hold the gossip pipeline indefinitely; later inventory exchange can retry deferred content.

Three malformed-frame or peer-rate violations within five minutes cause a 30-second local cooldown. Invalid publisher objects are discarded with a separate bounded verification budget and do not create transport strikes against a relay. These are resource protections, not a judgment about news accuracy. Counters/cooldowns are session-local and reset with the engine; restarting or changing identities remains an evasion path. This application has not passed an independent adversarial load or security audit.

A channel announcement includes its public owner certificate and metadata signed in the separate `farvahartrends/channel/v1` domain. The owner ID is the certificate fingerprint; the channel ID hashes the exact signed metadata payload. Channel-linked news is accepted only when its channel ID and publisher ID match the announcement and the owner's key verifies the bulletin signature. A relay cannot claim another key's channel merely by forwarding it.

This identifies the signing key. It does **not** verify a publisher's name, affiliation, judgment, or the factual accuracy of news. Automatically discovered sources remain unverified as human/editorial identities. Different owners can choose the same channel name; compare full identities through a trusted channel when that distinction matters.

Channels and news can be created and stored offline; dissemination needs a connection. Publishing while receiving is stopped keeps the post locally and does not restart receiving or request radio permissions. Current channel creation uses a separate protected key for each managed channel. Password-encrypted recovery files restore ownership, scoped editor grants support additional writers, and signed policies revoke editors and remove news/channels. A legacy recovery file does not revoke a stolen owner key. Version 0.8.9 protected channels instead precommit a separate recovery authority: its encrypted kit can issue a new online-owner generation, enforced after readers receive it. This experimental v2 protocol has no global freshness guarantee or independent audit; see CHANNEL-OWNER-RECOVERY.md. Legacy channels using the shared publisher identity export a per-channel manager credential instead of that shared key. There is no account service or automatic recovery without a previously saved file. A different name/description creates a new channel ID; metadata remains immutable. Announcements/news are public, and foreign cache entries can be evicted. Each local channel has a durable independent sequence counter; a crash may leave gaps. Sequence numbers do not establish factual reliability or global chronology across writers. Signed display timestamps do not confer authority.

Android coordinates identity creation across the UI and receiving service with a process-wide native lease, then rereads protected storage before creating a key. An unreadable existing identity or storage error is reported; it does not silently reset the vault or generate a replacement identity. Signing uses an exportable RSA key in Dart memory, protected at rest by the secure-storage plugin; this is not hardware-backed nonexportable signing. App-private news/preferences use the OS application sandbox, not a separately encrypted content database. Journal recovery filters malformed records before installing a snapshot. Corrupt private preferences are quarantined locally and recover with empty follow/trust choices and a warning; recovery does not implicitly follow or trust received channels.

## Android and iOS execution

The app defaults to Persian and offers an English switch. On initialization, Android starts active receiving after loading its identity/settings; the OS may ask for notification permission. This automatically started foreground service remains visible. Its plugin holds a partial wake lock, enabling CPU execution with the display off and potentially increasing battery drain. This is not the ordinary default background state. **Standard mode** is a separate ordinary-process comparison without that CPU wake lock. Keep modes and battery measurements separate. Neither the service nor its wake lock guarantees unrestricted radio/network access, survival after termination, or operation under every power policy. A Wi-Fi multicast lock facilitates discovery and does not itself keep the CPU awake.

Battery-optimization exemption is a separate, voluntary test condition. It must not be silently assumed for normal settings. Low Power Standby, Battery Saver, OEM restrictions, radio state, and denied permissions can change behavior. Natural locked-phone tests and artificially forced Doze tests measure different conditions.

Force-stop, Task Manager Stop, process death, and reboot have different platform behavior. This pilot schedules no watchdog restart alarms. Automatic restart after a reboot, app update or OS kill is an opt-in reader setting ("Keep receiving after reboot", off by default): when enabled and receiving was running, the boot receiver starts the same visible foreground service and the service is sticky. An explicit in-app Stop disarms this until the next start, and force-stop or manufacturer battery killers still end the service; the behavior has not been validated on physical devices. Without the opt-in, OS or user termination may end an active session; initializing the app again starts a new session. The in-app stop action stops the current session; ordinary publishing remains available offline and does not resume it. The app does not bypass Task Manager Stop. Record an interrupted session rather than assuming continuous receiving. Only optional diagnostic receipts record lock-state evidence; a receipt-time sample does not independently prove the whole preceding idle interval. Initial iOS coverage is foreground testing only; there is no locked-phone background delivery claim. Local iOS building and installation need a Mac, Xcode, and suitable signing.

iOS automatic multicast discovery is unvalidated. Adding a local-network usage description alone does not establish parity: custom multicast needs Apple's multicast networking entitlement as well as local-network permission and device/platform validation. [Apple local-network requirements](https://developer.apple.com/videos/play/wwdc2020/10110/), [multicast entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast).

Relevant platform references: [background BLE](https://developer.android.com/develop/connectivity/bluetooth/ble/background), [foreground-service launch restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start), [power-resource limits](https://developer.android.com/topic/performance/power/power-details), [Low Power Standby](https://developer.android.com/reference/android/os/PowerManager#isLowPowerStandbyEnabled()). These describe platform behavior, not results obtained with this app.

## Optional developer diagnostics: what an ACK establishes

The following measurement details apply only to explicitly paired legacy diagnostic bulletins. Ordinary channel news creates no measurement ACK, recipient roster or locked-phone latency result. Its arrival route/network are stored locally for checking which path delivered a post. Verbal feedback does not establish a measured five-minute threshold.

A valid receipt is created only after the exact bulletin's publisher signature has been verified and its content durably committed. It binds the unique test ID, bulletin content hash, and recipient identity. Each ACK carries the recipient's signature, verified against the known certificate identity; measured recipients are deliberately paired before the publication roster is frozen. A forwarded ACK cannot inherit the final recipient's identity merely because its last transport hop used TLS.

The origin measures authenticated ACK processing against a native monotonic sample taken before preparing/storing publication. Including preparation and processing time makes this a conservative upper bound on durable delivery latency. Android's `SystemClock.elapsedRealtime()` includes suspend time; a wall clock, scheduled timer, or unverified runtime stopwatch must not be substituted. The measurement needs one continuous origin boot/timebase. Origin reboot or lost timing state makes the interval unverified. [Android clock contract](https://developer.android.com/reference/android/os/SystemClock#elapsedRealtime())

An authenticated ACK arriving within 300 seconds conservatively establishes receipt by the deadline, assuming an honest recipient implementation and correct durable-commit semantics. It measures delivery plus the return path and may overstate delivery latency. It is not proof that a person read the message or that a compromised recipient told the truth.

A late or missing ACK does not establish late or failed delivery. Return-path failure, sender suspension, or delayed processing can hide an earlier receipt. Treat timing as unknown unless calibrated receiver logs resolve it. Cross-device monotonic values have different origins; compare only with calibrated offsets and reported uncertainty. A log written after manually waking a receiver cannot establish earlier untouched receipt.

## Optional diagnostic counting and privacy

The measured publication roster consists of **all manually paired identities on the origin at publication**, including any manually paired relay. Automatic contacts, including radio contacts, and bundled starting peers are excluded unless explicitly manually paired. Fix/check the manual set before publishing. Later peer removal does not rewrite an old roster. Each fresh bulletin has a unique ID and new payload. Cached objects cannot establish fresh delivery. Keep all enrolled deliveries in the denominator, including unknowns. Report route failures separately without dropping them from an overall attempt report. Prove the configured route with both apps awake before locked-phone trials; inventory/channel/bulletin/ACK exchanges are automatic, with no manual sync action.

The initial 90% confirmed-receipt-within-300-seconds threshold is a chosen engineering target for specified conditions. Small volunteer trials, repeated observations on the same devices, and reachable-peer selection do not support a nationwide forecast or independent-trial confidence claims without further study.

TLS and signed content do not hide participation, addresses, timing, or stable pinned identities from communicating peers and network observers. Current LAN and Wi-Fi Direct discovery advertise rotating session tokens instead of stable certificate identities. Legacy signed beacons remain readable; TCP enrollment and BLE introductions still expose connection-certificate material before the application TLS link. These protections must not be generalized into anonymity. Runtime radio identifiers are not report fields. Peer cards contain IP addresses and certificate identities; app-private storage retains connection details and public content, while private identity keys use protected storage. Optional legacy diagnostic exports include device conditions, timings, run labels/IDs, event categories, truncated identity hashes, and **full public fingerprints within signed ACK envelopes**. The current manual connection report uses a separate allowlist without news, raw IPs or full certificates. Both forms remain identifying metadata. Save/share reports only deliberately with consenting testers. The Android foreground-service notification exposes active participation on the device.


## Channel controls and optional media (0.7.0)

The optional `channel-v2` inventory capability negotiates signed editor/manager
proofs, latest channel policy, signed writer bylines and separate photo chunks.
New posts without these features retain v1 compatibility. Older peers receive
compatible text, but cannot apply channel policy or v2 posts. Upgrading every
test device is necessary for removal and revocation tests.

The owner/authorized legacy manager signs revisioned policy for an exact channel.
It carries up to eight active invitation IDs, 24 news-removal records, and bounded
per-author sequence floors and up to 64 signed retained IDs for older, cached, unremoved posts. A known terminal channel-removal policy cannot be
replaced by a policy without removal. Revision ties resolve by content ID; owner
backups should not be used as concurrent publishing replicas. Unknown control
signatures are bounded separately from new-channel admission (32 per peer and
128 globally per traffic window). Signed policies survive journal compaction.
No finite cache or signature can remotely erase hostile/offline copies or prove
an unseen removal to a new isolated device.

Photo descriptors are in the signed bulletin; bytes are separate SHA-256 checked
JPEGs of at most 96 KiB and 1280 pixels. Chunk requests are at most 4 KiB, with
four global/two per-peer outstanding downloads and a two-minute lifetime. The
cache is 8 MiB/96 files. Bluetooth never transfers photo bytes. Downloads are
based on public relay-cache content and local transport preference, not followed
channel IDs. Wi-Fi-only is a data policy, not a measured bandwidth guarantee.

Unread IDs, mute choices and notification preferences stay local. A separate
Android notification channel allows news alerts to be disabled without disabling
the foreground receiving service's mandatory status notification. Article text
is never included in the news notification body.

An isolated Hyperswarm client now refreshes discovery with bounded 15–120 second
backoff plus jitter, pauses extra refreshes when connected, and automatically
restarts an unavailable worklet. Cached-peer retries no longer use the upstream
ten-minute final delay. These changes reduce avoidable waits; they cannot create
reachability through blocking, incompatible NATs or a disconnected national
network. Canada-to-Iran mobile/Wi-Fi delivery requires an available cross-border
path, or an external bridge followed by reachable domestic/nearby paths during
shutdown. No Iranian provider/shutdown result has been measured here.

## Timeline and reconnection (0.8.0)

Send time is signed UTC milliseconds from the writer. First-receive time is
private local state and is not overwritten by duplicates. Each writer's signed
sequence orders their retained posts; a deterministic, nondecreasing send-time
rank merges writers without using receipt order. Reader timezone only affects
formatting. This is not a trusted global clock or proof of real-world chronology.

Android's local network handle/address epoch is sampled every five seconds by
the active overlay. A changed network reopens transport sockets after a short
debounce, preserving identities, cached contacts and durable news. The epoch is
used locally, not sent as publisher metadata or included in diagnostic exports.
Routine connection loss does not quarantine a remembered peer. Temporary
application cooldowns are bounded and expire outside Hyperswarm's firewall,
which can otherwise retain a permanent ban after a firewall rejection. These
changes cannot overcome blocked or incompatible networks.
