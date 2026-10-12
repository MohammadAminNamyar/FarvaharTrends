# Try different connection paths

Start with [the friend guide](TEST-GUIDE.en.md): same current APK, harmless public news, consenting participants and both apps open. On the receiver, **Channels → Discover → Follow** the sender's channel so its news appears. No results dashboard or report export is needed.

Other people's channels start **Not assessed**. **Mark as trusted** is an optional private choice, separate from following and factual verification; **Remove trust** returns to Not assessed. No trust marks or votes are broadcast. **Block channel** hides it and clears follow and trust; these choices do not change relay traffic or the path being tested.

For each direction and setup, publish a **new unique marker after preparing that setup**, such as PT-BLE-A2B-03-Q7 : blue square. Check receiving is active on both devices; if paused, choose **Connection → Resume receiving**. Publishing saves an offline post without restarting receiving. Look for that exact marker on the other device. Old news, channel names and connection indicators do not prove fresh delivery.

## One path at a time

Use **Nearby only** for local Wi-Fi and Bluetooth. Select **Connection → All networks** before testing Wi-Fi Direct or Internet/domestic/mobile-data routes; switch back to Nearby only afterward if you want local paths only.

| Path | Setup |
| --- | --- |
| Local Wi-Fi | A and B on the same Wi-Fi; mobile data and Bluetooth off. Say whether a local PC helper was running. |
| Wi-Fi Direct | Select **All networks** on both Android devices; mobile data and Bluetooth off. Keep the **Wi-Fi radio on**, but disconnect both from the ordinary access point. Stop the local PC helper. Keep apps visible initially. |
| Bluetooth only | Wi-Fi and mobile data off on both Android phones; Bluetooth on. Allow nearby permissions through **Enable nearby connections**. Keep apps visible initially. |
| Optional PC/emulators | Ask the organizer to run the approved local PC helper. Same-Wi-Fi phone/PC tests use IP. A configured Windows Bluetooth helper can instead connect a physical Android phone through the PC's real adapter, then relay over IP to project emulators. Keep the PC awake. |

Publish A→B, then a different marker B→A. If a phone rejoins its saved Wi-Fi during the Wi-Fi Direct test, say so; do not call the path isolated. Android may request connection approval. Approve only an expected consenting test device; silent group formation is not guaranteed.

For a locked Wi-Fi receiving test, confirm both phones are connected to the access point before locking the receiver. An enabled Wi-Fi radio is not enough. If Wi-Fi is switched off/on while locked, record whether it actually reconnects: the development emulator sometimes remained disconnected until waking, so automatic locked reconnection is not established.

In **All networks**, preferred working routes are **Internet/domestic IP → local Wi-Fi → Wi-Fi Direct → Bluetooth**. Nearby only uses local Wi-Fi and Bluetooth. Wi-Fi Direct initiation pauses while a healthy higher-priority IP/Wi-Fi link exists. After removing that link, allow detection/retry before a fresh publication. To test cold fallback separately, publish immediately after the change and say discovery time was included. Restore Wi-Fi and use another fresh marker to check the return path.

## Read the arrival label

| Label below the received item | Meaning |
| --- | --- |
| **Received via local Wi-Fi** | Receiving link classified as local IP/Wi-Fi. |
| **Received via Wi-Fi Direct** | Receiving link used native Wi-Fi Direct. |
| **Received via Bluetooth** | Receiving link used the Bluetooth bridge. |
| **Received via Internet / domestic IP** | Ordinary IP delivery; this alone does not establish domestic versus international routing. |
| **Published on this device** | Local publication, not remote reception. |
| **Arrival path was not recorded for this older item** | Unknown path; try a fresh item. |

This is **the receiver's last hop**, not the entire journey. Phone→Bluetooth→PC→IP→emulator is relay testing, not direct phone→emulator Bluetooth. An emulator's virtual radio is not the PC's physical adapter. A capable adapter or a successful scan alone is not delivery evidence.

## Tell the organizer what happened

Say **arrived / did not arrive / unsure**, the fresh marker, approximate delay, enabled networks, arrival label, awake/locked state, any intermediate PC/phone, and any failure. Ordinary channel news sends **no automatic read receipts or delivery reports**. Verbal delay estimates are subjective, not measured proof of a five-minute deadline.

After awake tests work, leave the receiver locked and unplugged for 30 minutes before publication; later try two hours or overnight. Follow the friend guide's untouched-phone steps. Say whether the item was present on opening or appeared afterward; its earlier arrival time may be unknown. A connection surviving lock and finding a **new neighbor while locked** are different tests.

The prototype supports one BLE link per device, with bounded sessions rotating after about three minutes. A–B–C relaying can require B to reconnect and carry stored news; it is not a simultaneous many-phone Bluetooth mesh. Some phones can be central but cannot advertise as a peripheral. On Android 10/11, new BLE discovery is foreground-only unless the relevant background-location permission already exists. Active Android receiving uses a visible service and CPU wake lock; mention battery drain or an OS/user stop. Native iOS Wi-Fi Direct/Bluetooth is not implemented.

## Mobile data needs a reachable peer

First select **All networks** on the testing phones. **The general APK currently has no provisioned reachable Internet/domestic volunteer servers.** The local-test PC address is private to its Wi-Fi. Phones on unrelated mobile providers cannot reach that address: currently **route unavailable**, not a completed mobile test. Ordinary testers need not enter addresses. The organizer must first supply and prove a reachable consenting peer.

There is no NAT traversal in this build. Carrier NAT/firewall failure shows the tested direct path failed, not that all peer-to-peer communication is impossible. Local radios require nearby participants. A few successful phones cannot establish nationwide/shutdown reliability; an Iranian IP alone does not prove the physical path stayed inside Iran.

Compilation, host protocol tests and a working physical Windows BLE scanner are development checks, not real-phone delivery, locked-phone or Iranian field results. Report actual observations separately. Use harmless public content; signatures establish keys and integrity, not human identity, factual accuracy or anonymity.

## Optional developer measurement

Keep explicit diagnostic trials separate from ordinary news and verbal feedback. A recipient-signed ACK processed on the source's monotonic clock within 300 seconds after publication starts conservatively bounds durable delivery. Late/missing ACKs leave arrival time unproven. Fix the manually enrolled recipient roster before publication; do not subtract clocks from different phones. See [protocol limitations](PROTOCOL-LIMITATIONS.md). These diagnostics are not required of a friend trying the app.

## Version 0.5.0: connection choices

The default is **Nearby only**: Bluetooth and devices on the same local Wi-Fi. Mobile data can remain enabled for other apps; PersianTrend does not use it in this mode. Internet/domestic-network peer routes and Wi-Fi Direct are disabled. Choose **All networks** explicitly for direct network routes and Wi-Fi Direct. Direct peers see connection addresses.

Channel signing and connections now use separate persisted keys. Updating keeps existing channels and private preferences. Historical key linkage cannot be undone. Ordinary channel news has no automatic read/delivery receipts, and follow/trust choices stay local. Reading or forwarding does not establish original authorship. News from outside Iran does not itself protect readers' identities. The Connection screen has a short explanation and expandable Privacy details. No Tor is bundled.
