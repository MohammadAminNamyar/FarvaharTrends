# Try PersianTrend with a friend

Use two consenting Android testers and harmless, invented news. See whether a **new** message reaches the other phone, then tell the organizer what happened. You do not need a results dashboard or an exported report.

## Install and open

1. Install the same current test APK on both phones. **Android 8.0 or newer** is required. If Android asks, allow **Install unknown apps** for the particular browser or file app opening the APK. You can disable that installation permission afterward.
2. Open PersianTrend. Persian is the default; **EN** switches to English and **فارسی** switches back. The main tabs are **Connection**, **Channels**, and **News**.
3. Receiving starts automatically on Android, using a visible foreground service. For radio tests, **Enable nearby connections** requests the relevant permissions and can show Android's Bluetooth-enable prompt. Older Android may also require location permission/settings for discovery; the app does not read GPS. Denied radio permission need not prevent a working IP/Wi-Fi connection.

## First try the same Wi-Fi

Keep both apps open and phones awake. Automatic exchange needs a working path; a searching animation alone is not delivery.

1. On A, open **Channels → Create a channel** and choose a short test name. Creating a channel works offline; another phone learns about it after contact.
2. On B, open **Channels → Discover**, find A's channel and choose **Follow**. **News shows followed, unblocked channels.** Search by name or channel ID if needed; different publishers can use the same name.
3. On A's own channel, choose **Write news**, enter a fresh harmless marker such as PT-A1-7Q : blue square, then **Review news → Sign & publish**. This stores the item on A; it does not confirm delivery to B. Publishing also works offline and leaves paused receiving paused. Use **Connection → Resume receiving** on both phones before testing delivery.
4. On B, find that exact marker in **News** and check the arrival-path label. **Published on this device** is local publication, not reception.
5. Reverse roles using B's own channel and a **different new marker**. An old message does not prove that today's connection works.

Other people's channels start **Not assessed**. In the channel's options menu, **Mark as trusted** saves your personal assessment; it does not follow the channel or verify the news. **Remove trust** returns it to Not assessed without recording a negative vote. These choices stay on your device; no trust marks or votes are broadcast. **Block channel** hides it and clears follow and trust. Unblocking does not restore someone else's follow or trust marks.

If checking the sender, open **Channel ID & publisher key** and compare the full channel ID and publisher fingerprint through a route you already trust. Matching display names alone are insufficient.

Ordinary channel news sends **no automatic delivery reports or read receipts**. Simply tell the organizer:

- Arrived, did not arrive, or unsure; include the marker.
- Rough delay: immediately, about 20 seconds, more than five minutes, or unknown.
- Enabled Wi-Fi/mobile/Bluetooth and the displayed arrival path.
- Receiver awake or locked; whether the item appeared only after opening the app.
- Permission, connection, battery or app-stopping problems. Failed attempts help too.

These are **subjective observations**, not measured proof of a five-minute deadline.

## Then try a locked phone

After awake delivery works, leave B locked, unplugged and untouched for **30 minutes**. Only then publish a new marker on A. Allow five minutes before checking B. Say whether the item was present when you opened the app or appeared afterward. Opening can restart work; this alone does not prove unattended delivery or its earlier arrival time. Later try two hours or overnight if useful. Avoid charging, USB debugging, screen checks and notification taps during the wait.

Active receiving holds a partial CPU wake lock and can use extra battery. This selected active mode is not ordinary Android background behavior or a guarantee. OS/user termination or reboot can end the session. Reopen the app to start again; there is no automatic device-boot start.

## Other paths and limits

Use [the network-path guide](MULTI-NETWORK-TEST.en.md) for Wi-Fi Direct, Bluetooth and optional PC tests. Select **Connection → All networks** before a Wi-Fi Direct or Internet/domestic/mobile-data test; **Nearby only** remains suitable for local Wi-Fi and Bluetooth. **The general APK currently has no provisioned reachable Internet/domestic volunteer servers.** The local-test PC's private Wi-Fi address is unreachable from unrelated mobile data. Even in All networks, switching both phones to mobile data alone therefore leaves **route unavailable** until a reachable consenting peer is provided. Ordinary testers do not need to enter addresses.

Use public test material only. A signature verifies its key and message integrity, not a person's identity, factual accuracy or anonymity. Following/blocking changes this phone's feed; cached public news may still be relayed. The cache is bounded: older foreign channels/news can rotate out, while recent local-authored news is protected within its own limits. Keep participant identities and connection details private. This pilot claims no nationwide or shutdown reliability.

Optional instrumented developer trials are separate from verbal feedback; see [protocol limitations](PROTOCOL-LIMITATIONS.md).

## Version 0.5.0: connection choices

The default is **Nearby only**: Bluetooth and devices on the same local Wi-Fi. Mobile data can remain enabled for other apps; PersianTrend does not use it in this mode. Internet/domestic-network peer routes and Wi-Fi Direct are disabled. Choose **All networks** explicitly for direct network routes and Wi-Fi Direct. Direct peers see connection addresses.

Channel signing and connections now use separate persisted keys. Updating keeps existing channels and private preferences. Historical key linkage cannot be undone. Ordinary channel news has no automatic read/delivery receipts, and follow/trust choices stay local. Reading or forwarding does not establish original authorship. News from outside Iran does not itself protect readers' identities. The Connection screen has a short explanation and expandable Privacy details. No Tor is bundled.

The **News** screen has one **Showing news from** button. Tap it to search your followed channels by name or ID, choose a channel, or return to **All followed channels**. The list scrolls even with many channels. Following and discovering channels remain in **Channels**. The Connection screen's radar and **Active connections** card show the same live count; saved or previously discovered peers do not count as active.
