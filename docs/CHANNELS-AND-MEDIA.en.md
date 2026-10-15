# Channels, reading and images — Android 0.8.11

## Temporary log

The **Temporary log** tab shows this phone's successful connections, disconnections
and signed-news arrivals, with the transport and local time. It retains up to 200
activity entries. Short connection fingerprints identify connections, not
publishers or people. Consenting testers can compare their own displayed
connection fingerprint with your local log manually.

This is local troubleshooting: IP addresses, peer names, article text and channel
details are omitted from this view. It does not track all users or prove reading.
**Clear log** clears this activity from the app journal, without removing news,
channels or contacts or ending live connections. New activity is recorded again
after clearing.

Use the same release APK on all test phones. New channel controls, editor posts,
writer nicknames and media require version 0.7.0. Older applications cannot apply
removal or revocation notices.

The combined feed identifies each source. Inside a channel, its name and avatar
appear once in the page header; cards show selectable text, time and a distinct
writer nickname when provided. Tap **News details** for local send/receive
times, delivery route and signature information. Tap a time for its full date and
UTC offset. The channel list shows local unread counts beside the preview; 99+
is a display cap, not a network total. Choose **Unread** beside **Following** and
**Discover** at the top of Channels to show channels with unread news. Following and trust remain
private choices; a valid signature does not establish factual accuracy.

Following a channel removes it from **Discover** and keeps it in **Following**.
Unfollowing makes it available in Discover again; blocked channels remain hidden.
Web addresses beginning with `https://`, `http://` or `www.` can be tapped to open
an external browser or the device's associated app. No link is opened or fetched
for a preview automatically. The original text remains selectable for copying.
Malformed or unsafe addresses stay plain text; up to 64 addresses per post are
made interactive, with a maximum address length of 2,048 characters. The external
website still needs a working network route.

## Publish and recover

Create a channel from **Channels → Create a channel**. New protected channels
require saving a password-encrypted recovery kit before they are published.
It contains a separate recovery key, not the ordinary publishing key. Use the
key icon on Channels for **Recovery & collaboration**. Recovering with this kit
creates a new owner generation and requires saving an updated kit; peers stop
accepting the old owner and editors after receiving the update. Old-generation
news leaves their active cache. This does not erase copies or notify offline
phones immediately. All protected-channel participants need 0.8.9 or later. Choose several random,
unrelated words (at least 16 characters); save the file outside the phone and
keep the password separately. Both are required. The password is not deliberately
persisted or logged by FarvaharTrends. Passwords necessarily exist temporarily in
memory while processing, and Dart strings cannot be reliably erased from memory.
Do not share the owner backup/password to invite a writer.

Existing legacy channel IDs remain accessible. They do not acquire independent
recovery automatically. Channel management offers creation of a new protected
channel with a new identity that readers must choose to follow. An older channel gets a channel-scoped manager key when its owner
first uses recovery or management. Its old shared publisher key is never exported
in a single-channel recovery file. Historical root authority remains valid.

Use **Channels → Recovery & collaboration → Restore a channel** to import a
backup or protected-channel kit. Wrong passwords or modified files fail without
replacing ownership. Ordinary publishing-access backups are separate from the
offline recovery kit and cannot replace it after key compromise.
Back up again after changing editors or removing news. A stale backup does not
include later control updates; let the device synchronize before publishing.
Use editor invitations for concurrent writers instead of copying owner backups.

## Invite writers

1. On the writer's phone, open **Recovery & collaboration → Request editor access**.
   Enter a display name and save the request file.
2. Send this public request file to the owner using a communication method you trust.
3. The owner opens the channel menu → **Manage & recover channel → Invite an editor**,
   selects the request, checks the fingerprint with the writer, and saves an invitation.
4. The writer imports the invitation on the same phone that created the request.

Each writer has their own key and permission for one channel. The owner can revoke
it from channel management. Devices enforce revocation when they receive its
signed update, and hide cached posts using that revoked invitation. Offline peers
cannot know a revocation they have not received. Eight active writers are allowed.
Set an optional nickname under **Settings → Publishing → Writer nickname**.
It stays on this device and is reused across channels, shown in review and signed
with each new post. The composer has no editable nickname field. Changing or
clearing it affects future posts; existing signed posts stay unchanged. It is a
display name, not verified human identity. An editor's invitation label can still
appear when no nickname is set.

## Remove news or a channel

The owner can remove a post through **News details → Remove news** in the channel view. Channel
management also offers **Remove channel**, with confirmation. Updated devices hide
removed news, discard its unreferenced image cache, and stop forwarding it once
they learn the signed policy. A known channel-removal notice cannot be undone by
replaying an older policy, even one carrying a larger revision without removal.
The interface does not offer undo for channel removal.

Removal is not remote erasure: screenshots, exported copies, disconnected devices,
older software and hostile peers can retain information. Public caches are bounded;
a fresh device or a device that lost a channel's entire cached policy cannot know
an unseen removal until a peer supplies it. The latest policy retains 24 individual
removals. Older removals roll into signed sequence floors, which can retire an
older portion of that author's uncached history; up to 64 signed retained IDs preserve older cached posts the owner did not remove. Owner keys remain protected locally after
channel removal; removing a channel does not perform forensic erasure of a phone.

## Reading and optional alerts

Follow a source to put its news in your reader. Unread counters stay on this device;
opening a channel marks its cached news read. There are no ordinary-news read
receipts sent to publishers. Existing cached news starts read during migration.
Open the header's gear icon for **Settings**, with separate notifications, images,
background receiving and peer discovery sections. These preferences are no longer
embedded in Connection. Turn news notifications off there, or mute one channel
from its menu. Android must also permit app notifications. The required background
receiving status notification is separate. News notifications contain generic
update text and no article body. Notification settings are local.

## Optional compressed photos

Attach one image in the composer. Android re-encodes it to JPEG, removes original
EXIF/location metadata, scales it to at most 1280 pixels, and caps it at 96 KiB.
The source picker accepts up to 10 MiB / 64 megapixels. Text is signed and delivered
independently. Photos use separate, bounded 4 KiB chunks over verified connections;
the receiver checks the signed hash, size and JPEG dimensions before caching.
Bluetooth carries text and controls, never photo bytes.

Image downloads default to **Wi-Fi only**. Readers may choose **Wi-Fi and mobile
data** or **Text only**. Wi-Fi does not prove high bandwidth; use text only on weak
or costly connections. The image cache is limited to 8 MiB / 96 files. Media requests
follow public cache availability, not private channel-following choices.

From version 0.8.3, attaching and publishing a photo permits uploading that own
photo over mobile data regardless of the publisher's download preference.
Received photos follow that preference when downloading or relaying. Availability
is announced after publication and after a photo is cached, so a connected reader
can request it immediately. Transfers resume with a fresh request after reconnect.

For connection troubleshooting, open **Temporary log → Copy connection report**.
It copies bounded connection counts, network type and discovery status. It excludes
IP addresses, news, subscriptions and keys. Share it manually if needed; the app
does not send it automatically. A discovered peer still needs a working connection.

## Automatic discovery and Iran testing

All networks mode uses reachable Internet/domestic peers, with nearby fallbacks.
Users do not enter IP addresses. While isolated, discovery refreshes with bounded
15–120 second intervals plus jitter; existing connections avoid extra refreshes.
Initial discovery, NAT traversal and censorship can still prevent or delay links.

Canadian Wi-Fi/mobile-data tests establish a route here, not Iranian reachability.
During an international shutdown, an external connection must first get news into
Iran, and readers need an available domestic or nearby path from a bridge. Public
DHT services may be blocked. Cached domestic routing helps only when suitable
Iranian peers remain reachable. No anonymous-routing or five-minute nationwide
delivery guarantee is made. Test normal connectivity, locked receiving, restart,
Wi-Fi/mobile transitions and restricted connectivity separately before wider use.
