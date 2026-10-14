# FarvaharTrends local patch

This directory vendors `flutter_background_service_android` **6.3.1** from the installed pub.dev package. Upstream repository: <https://github.com/ekasetiawans/flutter_background_service>. The original `LICENSE`, package metadata, README and changelog are retained. Only the Android implementation, Dart library and these package documents are included; examples, tests and generated build products are omitted.

The application selects this source reproducibly through its root `pubspec.yaml` path override. Editing a pub-cache copy is not required.

## Wake-lock correction

Upstream `BackgroundService.runService()` acquires a static, reference-counted partial wake lock, but its `onDestroy()` does not release that lock. A service stopped while its application process remains alive can therefore leave the CPU wake lock held. Repeated starts can add references. This would contaminate FarvaharTrends's active-versus-standard battery and idle comparison.

`BackgroundService.java` now records a single service-owned lock. A duplicate start does not acquire again. If `BootReceiver` already acquired the shared lock as a handoff, the service adopts that acquisition instead of adding a reference. Startup failure releases the owned lock and clears the partial engine state; service teardown releases it in `finally`. The lock remains held during successful active receiving, with its corresponding battery cost.

## Explicit session lifetime

`WatchdogReceiver.enqueue(context, int)` is intentionally a no-op in this measurement pilot. It schedules no restart alarms; `remove()` remains available to cancel any earlier pending alarm. The host application removes the watchdog component from its merged manifest. Unless the opt-in restart mode below is enabled, an OS or user termination ends receiving until the participant reopens the app and explicitly starts it again. This respects a Task Manager stop and exposes session loss during reliability testing.

## Opt-in restart after process death or reboot

The Dart side persists an explicit preference and passes it as `AndroidConfiguration(autoStartOnBoot:)`, which this plugin stores as the SharedPreferences key `auto_start_on_boot` (default `false`). That single key drives every rearm path:

- `BackgroundService.onStartCommand` returns `START_STICKY` only while the key is true, and `START_NOT_STICKY` otherwise. From 0.8.7, `onCreate` only prepares the service; the actual start intent is checked before Dart runs. System restarts need a saved, active, foreground session plus restart opt-in. The UI explicitly commits the session state before requesting a start; a null/system intent cannot clear a saved Stop. Failed start requests restore the stopped state.
- Stop commits `is_manually_stopped=true` before acknowledging the request and calls `stopSelf()` even on a storage error. Restart-policy changes use synchronous commits, so a process death immediately after acknowledgement cannot lose the setting. `onDestroy` performs teardown without overwriting a newer session's state.
- `BootReceiver` is not exported to other applications. It accepts only the protected system broadcasts `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED`; unprotected vendor quick-boot actions are removed. The same `ServiceStartPolicy` gates boot and sticky restart. It starts only through `ContextCompat.startForegroundService`, never acquires a wake lock, and catches platform refusal. The notification's content intent is immutable.
- `updateNotificationInfo()` now returns `false` when `startForeground` throws `SecurityException` or, on API 31+, `ForegroundServiceStartNotAllowedException`/`ServiceStartNotAllowedException` (both `IllegalStateException` subclasses). During service startup that aborts the engine, releases the owned wake lock and calls `stopSelf()`; a later notification update failure only logs.

Android 14/15 and foreground services from boot: the host service declares `android:foregroundServiceType="connectedDevice"` with `FOREGROUND_SERVICE_CONNECTED_DEVICE`, and the app holds `CHANGE_NETWORK_STATE`, `CHANGE_WIFI_STATE` and `CHANGE_WIFI_MULTICAST_STATE`, which satisfy the Android 14 prerequisite for that type. Android 15 forbids `BOOT_COMPLETED` receivers from launching `dataSync`, `camera`, `mediaPlayback`, `mediaProjection`, `phoneCall` and (since Android 14) `microphone` foreground services; `connectedDevice` is not on that list, and `BOOT_COMPLETED`/`MY_PACKAGE_REPLACED` remain exemptions from the Android 12 background-start restriction. A `START_STICKY` re-creation after an OS kill is best-effort: if the platform refuses the foreground promotion at that moment the service fails soft as described above. Reboot, OS kill, force-stop, revoked permissions and OEM battery managers still need device validation on several manufacturers before any reliability claim; force-stop semantics are not bypassed.

These corrections do not change discovery, networking or notification behavior. They do not make active receiving equivalent to ordinary Android background operation.

The Dart wrapper also has nonfunctional lint cleanups for the host project's current rules: explicit override annotations, an `isNotEmpty` check, an equivalent `for` loop, and removal of a redundant `const`.

## Validation

The root project must resolve the path override and rebuild the Android APK. On a physical Android device, verify active start → stop → standard mode, repeated start/stop cycles, and startup failure. Before untethered latency trials, confirm the plugin's named wake lock is absent after stop and present during active operation; use an awake, separately labeled diagnostic session for any USB/ADB inspection. Build checks cannot establish physical battery or power-policy behavior. No device measurements are claimed here.
