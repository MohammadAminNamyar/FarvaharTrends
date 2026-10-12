# PersianTrend local patch

This directory vendors `flutter_background_service_android` **6.3.1** from the installed pub.dev package. Upstream repository: <https://github.com/ekasetiawans/flutter_background_service>. The original `LICENSE`, package metadata, README and changelog are retained. Only the Android implementation, Dart library and these package documents are included; examples, tests and generated build products are omitted.

The application selects this source reproducibly through its root `pubspec.yaml` path override. Editing a pub-cache copy is not required.

## Wake-lock correction

Upstream `BackgroundService.runService()` acquires a static, reference-counted partial wake lock, but its `onDestroy()` does not release that lock. A service stopped while its application process remains alive can therefore leave the CPU wake lock held. Repeated starts can add references. This would contaminate PersianTrend's active-versus-standard battery and idle comparison.

`BackgroundService.java` now records a single service-owned lock. A duplicate start does not acquire again. If `BootReceiver` already acquired the shared lock as a handoff, the service adopts that acquisition instead of adding a reference. Startup failure releases the owned lock and clears the partial engine state; service teardown releases it in `finally`. The lock remains held during successful active receiving, with its corresponding battery cost.

## Explicit session lifetime

`WatchdogReceiver.enqueue(context, int)` is intentionally a no-op in this measurement pilot. It schedules no restart alarms; `remove()` remains available to cancel any earlier pending alarm. The host application also removes the watchdog and boot receiver components from its merged manifest. An OS or user termination may therefore end receiving until the participant reopens the app and explicitly starts it again. This respects a Task Manager stop and exposes session loss during reliability testing.

These two corrections do not change discovery, networking or notification behavior. They do not make active receiving equivalent to ordinary Android background operation.

The Dart wrapper also has nonfunctional lint cleanups for the host project's current rules: explicit override annotations, an `isNotEmpty` check, an equivalent `for` loop, and removal of a redundant `const`.

## Validation

The root project must resolve the path override and rebuild the Android APK. On a physical Android device, verify active start → stop → standard mode, repeated start/stop cycles, and startup failure. Before untethered latency trials, confirm the plugin's named wake lock is absent after stop and present during active operation; use an awake, separately labeled diagnostic session for any USB/ADB inspection. Build checks cannot establish physical battery or power-policy behavior. No device measurements are claimed here.
