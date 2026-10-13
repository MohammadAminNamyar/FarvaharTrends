# PersianTrend

A Farsi-first Flutter application for following public channels and exchanging signed news between peers. English is available in the language menu. Android is the tested platform; the included iOS implementation has not been built or validated on an Apple device.

**Experimental software:** delivery during an Iranian Internet shutdown, five-minute delivery, and publisher anonymity have not been established. An independent security audit has not been completed.

## How it works

- **All networks** is the automatic default on a new installation: reachable Internet/domestic-network routes, local Wi-Fi, experimental Android Wi-Fi Direct and Bluetooth. Existing saved mode choices are preserved. Damaged or interrupted preferences recover to Nearby only.
- **Nearby only** is an optional boundary for Bluetooth and devices on the same local Wi-Fi. Android Wi-Fi sockets are bound to an eligible Wi-Fi network and checked against its on-link routes. Failure does not fall back to mobile data. Wi-Fi Direct is disabled in this mode.
- Channels and news items have digital signatures. Publisher and connection identities use separate persisted keys. Channel names are not unique identities, and signatures do not establish whether news is true.
- Readers choose which channels to follow, hide, block, or personally trust. These preferences remain local. Public news is cached and relayed independently of the feed, with bounded message, connection, request, and storage limits. Those limits do not defeat attackers creating many identities.
- New news is pushed to connected peers; bounded inventories reconcile missing items on reconnection and periodically. Objects are deduplicated by signed identity rather than overwritten by a newer phone timestamp.

There is no required central account service, analytics service, push notification backend, or remote configuration. Volunteer peers are real infrastructure: they forward and cache signed news and must remain reachable. The checked-in `assets/bootstrap.json` intentionally contains no starting peers. A deployment-specific APK can bundle several pinned peers through `PERSIANTREND_BOOTSTRAP_JSON`; testers do not enter addresses. Local discovery remains available alongside these peers. No public or Iranian volunteer host has been provisioned by this source checkout.

Version 0.6 adds opt-in TCP enrollment on volunteer relays so a phone can establish an outbound connection without UDP discovery or inbound port forwarding. Ordinary phones still reject unknown connection certificates. See the [volunteer peer deployment guide](docs/VOLUNTEER-PEERS.en.md). Configuring a numeric address does not prove it is reachable, and two relay processes on one computer do not provide independent hosting.

## Privacy and platform limits

Peer transport uses mutually authenticated TLS with pinned certificates, and accepted channel news must have a valid publisher signature. Ordinary news sends no automatic read or delivery receipts. These protections do not hide app participation, IP addresses, connection timing, or traffic volume from relevant observers. Separate keys do not erase historical identity linkage. **Tor, Katzenpost, and anonymous publisher submission are not implemented.**

Android receiving uses a visible foreground service and, in active mode, wake and multicast locks. Permissions, battery policies, radio availability, and network restrictions can interrupt receiving. Reopen the app after an ended session; there is no unlimited background-delivery guarantee. iOS nearby transports and equivalent background receiving are not implemented.

See [protocol limitations](docs/PROTOCOL-LIMITATIONS.md) before interpreting a connectivity or privacy result.

## Build and run

Install **Flutter 3.47.5 / Dart 3.13.4**, **JDK 17**, and the Android SDK, including **API 36** and its required build tools. Android minimum API is **26**. Configure your installed Flutter and Android SDK with `flutter doctor`; toolchains, downloaded dependencies, local SDK paths, signing keys, and APKs are not bundled in this repository.

From a clean checkout:

```sh
flutter doctor
flutter pub get
flutter analyze
flutter test
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

Keep `.signing/` private and backed up. A new signing key cannot update installations signed by someone else's key. The optional Windows helpers under `tools/` use this workstation's ignored project-local SDK layout; the standard Flutter commands above work without those helpers.

iOS requires a compatible Mac, Xcode, and signing configuration. The host deployment target is iOS 15.0. Follow the [iOS bridge notes](packages/pilot_platform/ios/README.md); compilation and device behavior remain unverified.

## Testing with other people

- [English field guide](docs/TEST-GUIDE.en.md)
- [راهنمای فارسی آزمایش](docs/TEST-GUIDE.fa.md)
- [Multi-network tests (English)](docs/MULTI-NETWORK-TEST.en.md)
- [آزمایش چندمسیره (فارسی)](docs/MULTI-NETWORK-TEST.fa.md)

Use harmless, fresh test messages with consenting participants. Follow the intended channel, establish a connection, and repeat trials with each network condition and with the receiver awake or locked. A local or emulator result does not establish Iranian domestic reachability, shutdown performance, or physical-phone battery behavior. No results screen or diagnostic export is required for ordinary testers.

## Source layout and assets

`lib/core/` contains the shared protocol and storage, `lib/ui/` contains the interface, and `packages/pilot_platform/` contains the native Android/iOS bridge. `test/` and the retained `tools/tests/` helpers contain regression checks. Generated files, local caches, captures, signing material, and distribution artifacts are excluded from Git.

The bundled Manrope and Vazirmatn fonts retain their SIL Open Font License files in `assets/fonts/`. The vendored background service retains its upstream MIT [license](packages/flutter_background_service_android/LICENSE). The supplied PersianTrend logo remains the project owner's asset. No project-wide source license has been declared.
