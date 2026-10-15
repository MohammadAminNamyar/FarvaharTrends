# Channel-owner compromise recovery design

Status: implemented experimentally for 0.8.9, with protocol, persistence,
multi-peer and workflow tests. Android checks confirmed creation/recovery save
cancellation, saved-kit replacement and removal of old-generation news on a
Samsung receiving over mobile data. This feature is not in the 0.8.8 APK and has not received an
independent security review. Legacy encrypted backups restore the same owner
authority and cannot invalidate a stolen legacy owner key.

## Authority and attacker model

A protected channel precommits an independent recovery public key in immutable
version-2 channel metadata. The ordinary owner key signs news and editor/policy
changes. The recovery key signs owner-generation grants. Possession of an
ordinary owner/editor key does not grant access to the recovery key or allow a
new recovery public key. Compromise of the recovery key itself is outside this
single-authority design; users would need to establish a new channel identity
through another trusted route. Network observers and device compromise are
separate threats; this feature does not hide a publisher's address.

The recovery private key must exist only transiently during preparation and
recovery, and in an explicitly exported password-encrypted recovery file. Do
not store it in the ordinary channel vault, status responses, public journal,
logs, or the current owner backup. No password is persisted. Dart memory cannot
promise reliable secret erasure, and a compromised device can capture a file or
password during use. Recovery should be performed on a device the user trusts.

## Versioned metadata and grants

Channel v2 keeps immutable signed metadata and its content-derived ID, but adds
the recovery certificate and a distinct signing domain. V1 remains parseable
with its existing semantics. A v1 channel cannot gain a different immutable
root without a new identity. Migration therefore creates a new protected
channel and gives readers an explicit transition notice; it must not silently
follow a channel merely because it has the same name. A migration signed only
by an already stolen old key is not evidence of the legitimate owner.

A recovery-signed owner grant binds the exact channel ID, new owner's
certificate and a positive generation. Owner policies and editor invitations sign the exact owner-grant ID and carry
that grant. Substituting a grant from another generation or a conflicting grant
fails, even if the same online certificate was reused. Each policy
has a revision scoped to the generation. Authority ordering is generation
first, revision second. An old owner at revision 9,007,199,254,740,991 must lose
to a recovery-authorized new generation at revision 1. Only the recovery key
can increase a generation. Grants are domain-separated from news, editor
invitations, transport identity and generic backup material.

Editor invitations are bound to the owner's generation, not merely a display
nickname or revision. After rotation, all old-generation writers lose their
authority until explicitly invited by the new owner. A channel's deleted flag
cannot let a stolen old owner defeat a later recovery; a higher recovery
generation may reactivate the channel. Within one generation, existing deletion
and revocation rules remain monotonic.

Two different recovery grants at the same generation constitute a conflict.
Once both are known, fail closed for new publication from that generation and
retain bounded evidence of the conflict. Resolve it through a higher recovery
generation, rather than treating an arbitrary hash ordering as proof of the
legitimate owner. A fresh device that has received only one grant cannot know
that a second exists. The UI must not claim consensus or global freshness.

## Preparation and recovery workflow

1. The owner chooses a protected channel, enters its name and a strong recovery
   passphrase. Generate separate ordinary-owner and recovery keys.
2. Create the signed channel, initial generation grant and initial policy.
   Return only an encrypted recovery file and an opaque preparation token to
   the UI. Keep pending ordinary-owner material bounded and short-lived.
3. The system file picker saves the encrypted recovery file. Only successful
   save acknowledgement commits the channel to the normal vault and public
   journal. Cancellation must not publish it or imply a usable backup exists.
   Saving on the same phone does not make the backup physically offline; the
   interface tells the owner to keep a separate safe copy.
4. Recovery opens that file and decrypts it after fixed-parameter size/KDF
   checks. Use the highest locally known generation and the file's generation
   to propose the next generation. If the network has a newer grant, the user
   must reconcile it before relying on the replacement.
5. Generate a new ordinary-owner key, sign its grant using the recovery key,
   create an empty editor policy at revision 1, and persist its vault and public
   authority checkpoint before
   announcing success. The new signing key belongs only to the ordinary vault.
   The vault and journal are separate files, not one atomic transaction; an
   interrupted commit can be retried or recovered using the saved kit.
6. Propagate authority before new news. Readers persist the highest known
   generation and enforce it on replay, restart, policy update and news import.
   A stale owner backup cannot overwrite a newer local owner generation.

The encrypted recovery format uses a separate version/kind and authenticated
domain, reusing the existing fixed-parameter Argon2id and AES-GCM implementation.
This integration still needs independent review. Keep file/body size bounds, canonical encodings and a strict
field allowlist. Never implement new cryptographic primitives for this feature.

## Distribution, retention and compatibility

Negotiate an explicit owner-recovery capability. A v1/v0.8.8 peer must continue
to exchange its supported news without being sent unsupported v2 metadata that
could trigger its malformed-object budget. Capability negotiation is not an
authorization proof and cannot downgrade a v2 channel's verification rules.

Highest-generation state outlives ordinary news eviction for followed and
managed channels. A separate public proof checkpoint is flushed before accepting
an authority change. Content journal rollback cannot undo that checkpoint.
Committed checkpoint corruption fails closed; it does not silently load an
older backup. A complete pending write can recover an interrupted rename.
This is not protection against rollback of every file by an attacker controlling
the device. Foreign channels use the bounded content journal until followed;
unsolicited traffic cannot fill the permanent checkpoint.

The checkpoint holds up to 128 protected channel identities and 3 MiB. Old
anchors remain after unfollowing, so a long-lived installation can reach this
limit; new protected entries then fail rather than silently dropping revocation
knowledge. There is currently no UI to forget these anchors. This conservative
limit and recovery from checkpoint corruption need usability review before
large deployment. Ordinary news/channel limits remain separate.

The new `owner-recovery-v1` capability gates v2 channel metadata, policies,
authority objects and news. Older applications can still exchange v1 channels;
they cannot display protected channels. All participants in a protected-channel
test should update to 0.8.9 or later. Initial online-owner identity remains in
immutable channel metadata; the stable recovery fingerprint is shown in the
identity sheet for protected channels.

Offline peers cannot enforce a grant they have not received. News signed by a
revoked key cannot be classified as legitimately pre-compromise using its
timestamp. Default to excluding old-generation news from active propagation
after recovery; any locally retained history must be identified accordingly.
Remote erasure, immediate worldwide revocation and fresh knowledge on first
installation are not promised.

## Required acceptance tests

- Stolen owner cannot forge a generation grant, change its channel binding or
  recovery key, or override recovery with a large revision/deleted policy.
- A fresh reader validates a replacement owner through the committed recovery
  key; malformed proofs, extra fields and unsupported downgrades fail closed.
- Old editor/manager grants fail after recovery; new scoped invitations work.
- Conflicting same-generation grants remain conflicted after restart and cache
  churn, and a higher recovery generation resolves them.
- Replay of old owner files, old policies and old news cannot roll back known
  authority, including after a partial write or failed compaction.
- File-save cancellation, process death during preparation, wrong password,
  oversized imports, low storage and duplicate completion leave no silently
  published orphan channel or replaced private key.
- Two-peer and three-peer tests exercise authority arriving before/after news,
  offline readers, relay loss, deletion/recovery, legacy compatibility and
  recovery UI in Farsi and English.
- Inspect saved public/private files and status/log/export paths for accidental
  recovery-key or passphrase retention; obtain an independent review before
  claiming compromise recovery is safe for high-risk publishing.

Implemented test coverage is in `owner_authority_test.dart`,
`owner_authority_storage_test.dart`, `owner_authority_network_test.dart`,
`owner_recovery_workflow_test.dart` and `owner_recovery_ui_test.dart`. It includes
maximum old-owner revisions, deletion/recovery, conflict serialization, stale
content-journal restoration, failed writes, private-key separation, saved-kit
recovery after interrupted preparation, a relay to a fresh reader, legacy
compatibility, and Farsi/English save cancellation. This is developer testing,
not an independent review or evidence from Iranian networks.

The offline/online authority separation and rollback concerns are informed by
the [TUF specification](https://theupdateframework.github.io/specification/latest/).
This channel protocol has different offline/news requirements and is not a TUF
implementation or independently reviewed design.
