# PersianTrend transport fork

Based on `flutter_pear` 0.4.9, MIT, Andrew Loable:
https://github.com/andrewloable/flutter_pear

The source archive was verified against pub.dev SHA-256
`d8435c83e00a583e68cdda503b3adedfc71e1bf3b5f40831d3d1c243f9ea1dfd`.
The native binding remains pinned to upstream `flutter_pear_bare` 0.4.9 and
Bare Kit 2.5.5. Preserve LICENSE, NOTICE and THIRD_PARTY_LICENSES.

PersianTrend bundles `pear-end/persiantrend.js`, a transport-only entry point.
It exposes bounded Hyperswarm byte streams and private, bounded routing caches;
the broader storage, drive, pairing and multi-writer RPCs are not implemented.
Publisher verification and spam limits remain in PersianTrend's peer engine.

The public discovery namespace is shared by app installations. Discovery is
not anonymity, publisher trust or private group membership. No channel names,
subscriptions or publisher private keys are placed in the routing cache.

Cached reachable domestic peers can support reconnection when public entry
peers disappear. This still requires a connected, reachable domestic peer
network. It does not prove Iranian cross-provider reachability or provide a
route through a completely disconnected network.

The generated bundle is excluded from Git. Build it with
`tools/build-overlay.ps1` before building the application.
