# PersianTrend

A Farsi-first Flutter application for following public channels and exchanging signed news between peers. English is available in the language menu. Android is the tested platform; the included iOS implementation has not been built or validated on an Apple device.

**Experimental software:** delivery during an Iranian Internet shutdown, five-minute delivery, and publisher anonymity have not been established. An independent security audit has not been completed.

## How it works

- **All networks** is the automatic default on a new installation: reachable Internet/domestic-network routes, local Wi-Fi, experimental Android Wi-Fi Direct and Bluetooth. Existing saved mode choices are preserved. Damaged or interrupted preferences recover to Nearby only.
- **Nearby only** is an optional boundary for Bluetooth and devices on the same local Wi-Fi. Android Wi-Fi sockets are bound to an eligible Wi-Fi network and checked against its on-link routes. Failure does not fall back to mobile data. Wi-Fi Direct is disabled in this mode.
- Channels and news items have digital signatures. Publisher and connection identities use separate persisted keys. Channel names are not unique identities, and signatures do not establish whether news is true.
- Readers choose which channels to follow, hide, block, or personally trust. These preferences remain local. Public news is cached and relayed independently of the feed, with bounded message, connection, request, and storage limits. Those limits do not defeat attackers creating many identities.
- New news is pushed to connected peers; bounded inventories reconcile missing items on reconnection and periodically. Objects are deduplicated by signed identity rather than overwritten by a newer phone timestamp.

Receiving, publishing, discovery and forwarding are in **one application**. There is no required central account service, analytics service, push notification backend, or remote configuration. In All networks, the bundled Hyperswarm transport uses its public DHT entry peers to discover other installations and attempt encrypted connections across networks automatically. Users do not enter IP addresses. This uses shared discovery infrastructure; it does not mean that there are no servers anywhere. NAT and provider restrictions can still prevent a route.

Every installation can receive and forward verified public news. On compatible Wi-Fi routers the same app also requests a short-lived TCP port lease automatically and shares a signed connection contact. Private cached contacts allow reconnection without public discovery when those phones remain reachable. Contacts can arrive over Bluetooth or local Wi-Fi as well. Nearby only disables Internet discovery, remote contacts and router leases. No separate helper app is required. Dedicated volunteer peers are optional; the checked-in `assets/bootstrap.json` is empty. See the [volunteer peer deployment guide](docs/VOLUNTEER-PEERS.en.md).

During a shutdown, this requires reachable domestic routes between participating phones. A bridge with a remaining external connection must bring fresh news into that network; Bluetooth/local Wi-Fi can carry it onward. Neither cached contacts nor Hyperswarm can create a route between completely isolated networks. Iranian provider reachability and shutdown performance still require field tests.

## Privacy and platform limits

Peer transport uses mutually authenticated TLS with pinned certificates, and accepted channel news must have a valid publisher signature. Ordinary news sends no automatic read or delivery receipts. These protections do not hide app participation, IP addresses, connection timing, or traffic volume from relevant observers. Separate keys do not erase historical identity linkage. **Tor, Katzenpost, and anonymous publisher submission are not implemented.**

Android receiving uses a visible foreground service and, in active mode, wake and multicast locks. Permissions, battery policies, radio availability, and network restrictions can interrupt receiving. Reopen the app after an ended session; there is no unlimited background-delivery guarantee. iOS nearby transports and equivalent background receiving are not implemented.

See [protocol limitations](docs/PROTOCOL-LIMITATIONS.md) before interpreting a connectivity or privacy result.

## Build and run

Install **Flutter 3.47.5 / Dart 3.13.4**, **JDK 17 or newer**, Node.js with npm, and the Android SDK, including **API 36** and its required build tools. Android minimum API is **29 (Android 10)**, required by the pinned native network runtime. Configure your installed Flutter and Android SDK with `flutter doctor`; toolchains, downloaded dependencies, local SDK paths, signing keys, and APKs are not bundled in this repository.

From a clean checkout:

```sh
flutter doctor
flutter pub get
# PowerShell: build the pinned transport bundle before Flutter builds.
powershell -NoProfile -File tools/build-overlay.ps1
flutter analyze
flutter test
node --test test/overlay_discovery_test.cjs
flutter devices
flutter run -d <android-device-id>
```

`flutter run` uses the normal Android debug signing configuration when no workstation-specific debug keystore exists. To create a debug APK without installing it:

```sh
flutter build apk --debug
```

The local override of `flutter_background_service_android` under `packages/` is required. Its source and [patch notes](packages/flutter_background_service_android/PATCH-NOTES.md) are included so a checkout does not depend on edits to a developer's package cache.

Release signing is optional local configuration. Without `.signing/key.properties`, the Android release configuration is unsigned; it does not reuse a debug key. To make an installable release, supply your own local signing configuration. On Windows, with the JDK's `java` and `keytool` available, the included helper creates a new key and properties file without replacing existing material:

```powershell
.\tools\create-pilot-key.ps1
flutter build apk --release
```

For a smaller sideloaded download, use `flutter build apk --release --split-per-abi`. Each resulting APK is a complete app for one CPU architecture, not a helper component. Most current phones use `arm64-v8a`; the x86_64 build is for emulators. Native libraries are compressed in the APK and extracted during installation, so installed storage is larger than download size. Runtime downloads are not required to start the app. The native dependency's approximately 400 MB archive is a build-time download, not the APK size.

Keep `.signing/` private and backed up. A new signing key cannot update installations signed by someone else's key. The optional Windows helpers under `tools/` use this workstation's ignored project-local SDK layout; the standard Flutter commands above work without those helpers.

iOS requires a compatible Mac, Xcode, and signing configuration. The host deployment target is iOS 15.0. Follow the [iOS bridge notes](packages/pilot_platform/ios/README.md); compilation and device behavior remain unverified.

## Testing with other people

Version 0.8.1 includes password-encrypted per-channel recovery, scoped editor invitations, signed writer nicknames, owner-signed news/channel removal, local unread counts and optional notifications. Compressed images travel independently of text, with Wi-Fi-only downloads by default and no Bluetooth image transfer. News cards share a source header, selectable reading area and tinted writer/time footer across the feed and channel timeline. Tap a compact time to see its full local date and UTC offset. The timeline preserves each writer's sequence and merges writers by signed send time rather than arrival order. Clocks remain untrusted, so these times are not a measured delivery duration. See [channel and media instructions](docs/CHANNELS-AND-MEDIA.en.md) or [راهنمای فارسی کانال و تصویر](docs/CHANNELS-AND-MEDIA.fa.md). All testers should use this version for these controls.

The [scale and security review](docs/SCALE-AND-SECURITY-AUDIT.md) documents resource limits, measured local tests, an offline million-node sensitivity model and remaining rollout blockers. The model is not a million-device network test. This build is intended for controlled small-group testing while discovery, routing, Sybil resistance and background availability are evaluated.

- [English field guide](docs/TEST-GUIDE.en.md)
- [راهنمای فارسی آزمایش](docs/TEST-GUIDE.fa.md)
- [Multi-network tests (English)](docs/MULTI-NETWORK-TEST.en.md)
- [آزمایش چندمسیره (فارسی)](docs/MULTI-NETWORK-TEST.fa.md)

Use harmless, fresh test messages with consenting participants. Follow the intended channel, establish a connection, and repeat trials with each network condition and with the receiver awake or locked. A local or emulator result does not establish Iranian domestic reachability, shutdown performance, or physical-phone battery behavior. No results screen or diagnostic export is required for ordinary testers.

## Source layout and assets

`lib/core/` contains the shared protocol and storage, `lib/ui/` contains the interface, and `packages/pilot_platform/` contains the native Android/iOS bridge. `test/` and the retained `tools/tests/` helpers contain regression checks. Generated files, local caches, captures, signing material, and distribution artifacts are excluded from Git.

The bundled Manrope and Vazirmatn fonts retain their SIL Open Font License files in `assets/fonts/`. The vendored background service retains its upstream MIT [license](packages/flutter_background_service_android/LICENSE). The transport fork retains its [license and provenance](packages/flutter_pear/FORK.md). The supplied PersianTrend logo remains the project owner's asset. No project-wide source license has been declared.
