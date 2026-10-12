# iOS platform bridge

This local Flutter plugin supplies device observations and a deliberate JSON share sheet. It does not add push delivery, background execution, or a locked-phone delivery guarantee. No audio, location, or other unrelated background mode is configured.

`elapsedRealtimeMs`, `bootId`, and `isLocked` are unknown on this bridge. `lockStateKnown` is false. The shared `screenOn` field means the application is active on iOS; it must not be treated as evidence that the physical display is on or that the device is unlocked. Use iOS only for foreground pilot tests initially.

`requestNotifications` is a no-op. The settings action opens this app's iOS settings only after the user invokes it; it does not claim a battery-optimization exemption. The export action requires an active foreground scene, validates JSON, rejects recognized private-key fields/PEM material, and presents a share sheet. It writes only the supplied report to the application's temporary directory and removes the temporary file after completion/cancellation. It never picks a sharing destination or sends automatically. `true` means UIKit reported the user's selected share/save operation completed; it does not prove a remote person received the report. Report generation must itself exclude all secrets; field-name filtering cannot identify arbitrary secret bytes.

The plugin podspec declares iOS 13.0 because these bridge APIs support that version. The host app must also satisfy the installed Flutter engine's deployment target; the installed Flutter template currently uses iOS 15.0. The homepage is an intentionally nonresolving placeholder for this unpublished path dependency.

Swift/CocoaPods compilation and device behavior are **unverified on Windows**. On a Mac, use the root app's Flutter setup, resolve pods, select the appropriate signing team, and build/run through Xcode or Flutter. Verify iPhone and iPad export, cancellation, repeated export, inactive-app rejection, settings navigation, and null measurement fields before a pilot. An iOS build needs a compatible Mac/Xcode toolchain and signing.
