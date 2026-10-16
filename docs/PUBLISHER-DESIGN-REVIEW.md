# Independent design review: shutdown networking and publisher protection

Revision 2, 16 October 2026. Written against `docs/EXPERIMENTAL-PUBLISHER-PROTOCOL.md`,
`docs/PUBLISHER-LAB-RESULTS.md`, `tools/privacy_lab/` and the production code under
`lib/`. Revision 1 (same day) contained errors the project owner identified; section 0
lists them. Before publication this revision was given to three independent adversarial
reviewers (threat-model logic, protocol correctness, fact-checking against primary
sources and code); their findings are folded in and the ones that changed the design
are marked "(review)". No further pass was run after that rewrite. This document contains
no new measurements. **Established** means a primary source or code location is cited;
**model** means arithmetic from stated assumptions; the rest is engineering judgement.

## 0. Corrections to revision 1

1. **L1 was wrong.** A single relay that unseals the envelope sees the publisher's IP,
   connection certificate and the plaintext article: the full mapping. What remains is
   protection against every party other than that relay (section 2).
2. **L3 was redundancy, not privacy.** Two independent single relays double the parties
   that learn the mapping. Replaced by a persistent entry guard with an exit chosen from
   the guard's reachable set (section 3), with the honest statement that in sparse
   traffic the guard still links publisher to article by timing.
3. **The cover-latency figures were wrong.** A Poisson schedule with a 10 s mean has a
   6.93 s median and 29.96 s p95 wait with no maximum; a fixed 5 s period costs
   135 MiB/day at 8 KiB cells. Section 4 reports startup, median, p95, p99, maximum and
   failures separately and never substitutes p95 for the five-second maximum. (Review)
   Cover also requires batching at the entry and a hold at the exit, or the release time
   pins the sender's slot; the maximum added delay is then three periods, not one.
4. **The impossibility claim was overstated.** No result says every construction needs a
   stable group with a known honest fraction. Section 5 states what is established and
   names the one constraint that is construction-independent.
5. **Discovery was wrong in three places.** TCP hole punching across two NATs works under
   RFC 5128 §3.4 conditions; stock Android cannot bind a listener below port 1024; TLS on
   443 is not censorship resistance, and the production transport has a cleartext banner.
6. **Attacker views were vague.** Section 7 defines what each attacker observes and
   separates by-inspection results from statistical tests.
7. **The protocol was under-specified.** Section 8 specifies keys, encryption, replay,
   acknowledgements, retries, staging, coverage and crash behaviour. (Review) Several
   gaps were found in the first draft of that specification and are now addressed:
   the entry could not route to a publisher-chosen exit; channel creation, recovery and
   invitation acceptance write straight into the public store; the relay has no ingress
   path that bypasses link budgets; policy revisions collide while one is pending.

## 1. Summary

- **The construction-independent fact.** A publisher whose access link is observed and
  whose article is public seconds later is linked to it by timing. How quickly depends
  on how many other phones send similar bursts in the same window (section 5.2 gives the
  model and the assumption; the base rate is unmeasured). The anonymity trilemma gives
  the price of hiding the instant: every potential sender must transmit about one
  message per latency bound whether or not it has news. The byte cost follows from the
  message size, not from the theorem: at the 8 KiB cell used here and a 5 s bound it is
  135 MiB/day per sender; at a 1 KiB cell it would be 17 MiB/day, which is why the size
  of signed objects (dominated today by embedded RSA-2048 certificates) matters. The published theorems are for a global observer; section 5.2
  gives our derivation that the same lower bound holds for an observer of one target's
  link plus public outputs.
- **Two honest products exist within the budget.** (a) A fast mode that confines who
  learns the mapping to one long-lived relay the publisher chose, plus a per-article exit,
  and makes no claim against anyone who sees the publisher's uplink. (b) A slow mode with
  scheduled cover, window batching at the entry and a hold at the exit, whose protection
  against the carrier is anonymity among the entry's cover clients (at most seven today)
  times the entries feeding the same exit in a window, with a maximum added delay of
  three cover periods. **The slow mode's protection claims are unresolved (owner's
  review):** nothing in M3 prevents a malicious entry from isolating one client's cell in
  a window and watching for a release (section 3, E10). There is no mode that is fast,
  cheap and hides the publisher from the carrier.
- **What the second hop buys is less than revision 1 claimed (review).** The guard sees
  when the publisher sends; the article appears seconds later; in sparse traffic that is
  the mapping. The exit learning the content is irrelevant because the content is public
  moments later. The second hop denies the guard certainty and helps only in dense
  traffic. A single persistent guard relay gets most of the fast mode's value at half the
  cost; the choice is the owner's and both are specified.
- **FPP-1 (owner's correction).** An idealized DC-net in which every member sends an
  equal cell every round hides the publication instant from the carrier among the honest
  members. Our implementation has not been shown to have that property: its timing
  leakage is unmeasured, bulk rounds occur only when someone reserves, and colluding
  members shrink the set to one. The 337 MiB/day figure is the cost of the idealized
  every-round-bulk model, not of what was measured (section 5.3). Retire it on
  availability, admission and cost; keep the harness and the reproduced attacks.
- **Production exposures found, independent of all this and cheap to fix:** a cleartext
  `PTRELAY/1` banner with the full connection certificate sent before TLS on every helper
  dial including reconnects; a certificate shape no other software produces; a fixed
  listener port; an image hash advertised before its article exists; beacon cards cached
  on peers' disks for seven days (section 6.4).
- **Smallest decisive experiment** for the fast mode: an ordinary neighbour cannot tell
  the publisher from a reader. Today's engine fails this by inspection in several places
  (section 7.2). Section 9.2 specifies the test so that it can fail.

## 2. Adversaries and the protection table

### 2.1 Adversaries, by what they observe

| Id | Adversary | Observes | Does not observe |
| --- | --- | --- | --- |
| A1 | Entry guard E (malicious node) | Publisher's connection certificate and IP; every cell with size and time; cell count per submission; which exit each cell names; acknowledgement traffic; public releases | Cell plaintext |
| A2 | Exit R (malicious node) | Which entry delivered each cell and when; plaintext or padding marker | Who sent the cell to E |
| A3 | E and R colluding | Union | Nothing relevant |
| A4 | Non-relay immediate peer | All ordinary protocol traffic with the publisher: inventories, requests, pushes, responses, sizes, timing, who offers what first | Envelope links |
| A5 | Any downstream peer | Which peer first offered each object, network-wide, over time | Link traffic |
| A6 | Observer of the publisher's access link (ISP, local Wi-Fi) reading public releases | Sizes and times of everything the phone sends and receives | Contents; other phones' links |
| A7 | Observer of E's links | E's inbound and outbound, sizes and times; public releases | Contents |
| A8 | The state as carrier | A6 and A7 for every phone, plus any relays it runs | Contents |

### 2.2 Modes

| Mode | Description |
| --- | --- |
| M0 | Production: full objects pushed to all peers; publisher serves image bytes first |
| M1g | One persistent guard relay unseals and releases |
| M2g | Persistent guard E; inner layer sealed to an exit R chosen from E's announced reachable set, fresh per article; no batching, no holds |
| M3 | M2g plus cover: one cell per period T from the publisher; E batches a window and forwards at window end; exit for a window derived from a hash of E's id and the window index over E's list; R holds each real object uniformly in [0, T); acknowledgements identical for padding and real cells. **Protection claims unresolved**, see section 3 |
| M4 | M3 with additional batching hops |

### 2.3 What each adversary learns about the publisher-to-article mapping

FULL = mapping known. TIMING = knows this phone sent a real cell at t; under the
sparse-burst assumption in 5.2 the candidate set is expected to shrink to one within a
few articles (model, base rate unmeasured). CONTENT = knows the
article. k(…) = source hidden among the stated set. PART = learns only that the phone runs
protected mode. NONE = nothing, conditional on section 8 invariants and the section 9
experiment.

| Adversary | M0 | M1g | M2g | M3 | M4 |
| --- | --- | --- | --- | --- | --- |
| A1 guard | FULL | FULL | TIMING, plus object class from cell count; FULL in sparse traffic | UNRESOLVED: an active E can isolate one client (n−1 attack, section 3); the passive-E bound is k(E's clients, ≤ 7) and requires batching, per-window exit and uniform acks; E's control of its exit list makes E+R collusion cost f, not f² | UNRESOLVED, same attack at the entry |
| A2 exit | FULL | FULL (= guard) | CONTENT, plus "source is a client of E" | CONTENT, same | CONTENT |
| A3 E+R | FULL | FULL | FULL | FULL | k(E's clients) while any intermediate hop is honest; FULL if the whole path colludes |
| A4 neighbour | FULL today | NONE, conditional | NONE, conditional, including the first-offer statistic | NONE, conditional | same |
| A5 downstream | FULL | Guard is first source every time: identifies the guard; publisher is one of its clients | Exit per article; the exit set over time is the guard's reachable set, which identifies the guard; then one of its clients | same | same, weaker with more hops |
| A6 uplink only | FULL | TIMING | TIMING | PART: cannot tell which period carried news | PART |
| A7 E's links | FULL | FULL | FULL: matches in to out by size and time, then release | k(E's clients) with batching at E; FULL without | k(fan-in^hops) |
| A8 state | FULL | FULL | FULL | At best k(7 × entries feeding that exit in the window), ≤ 49 with fan-in 7, realistically 7; unresolved against an active entry | At best k(7^batching nodes); unresolved |

Every M3 and M4 cell is an upper bound on protection pending E10, not a claim.

Three results from review drive the rest of the document. First, **M1g and M2g give no
protection against A6, A7 or A8**, and the guard alone (A1) gets the mapping by timing in
realistic traffic; the second hop only removes certainty. Second, **M3 without batching
at E and a hold at R is M2g**: the exit's prompt release marks the sender's slot, and
the exit name on each cell tells E which client fed the releasing exit. Third, the
anonymity set of any cover design is bounded by traffic through one exit per window,
which with phones as exits is the entry's client count; enlarging it means fewer exits,
which is infrastructure, or more hops, which is M4.

### 2.4 Exposure to malicious nodes over time (model)

Fraction f of reachable relays malicious, m articles, independent uniform choices.
Probability the mapping is ever learned by a node:

| f | m | Fresh relay or fresh entry per article, by decryption or timing | Persistent guard, by timing | Persistent guard with a colluding exit, by decryption |
| --- | --- | --- | --- | --- |
| 0.05 | 10 | 0.401 | 0.05 | 0.020 |
| 0.05 | 100 | 0.994 | 0.05 | 0.050 |
| 0.10 | 10 | 0.651 | 0.10 | 0.065 |
| 0.10 | 100 | 1.000 | 0.10 | 0.100 |
| 0.25 | 100 | 1.000 | 0.25 | 0.250 |

Formulas `1-(1-f)^m`, `f`, `f·(1-(1-f)^m)`. The guard rationale is Wright et al. 2003 and
Øverlier and Syverson 2006 (**established**); the closed forms are ours. Revision 1's
"fresh pair, f²" column counted only decryption and hid that a fresh malicious entry
links by timing just as a fresh single relay does. f is the malicious fraction among peers
with a good 24 h history under automatic admission, which an adversary can inflate;
section 5.4 lists Sybil admission as unresolved.

## 3. Sequential relays, corrected

- **Routing (review).** Envelope keys are learned from link peers, every node holds at
  most eight links (`lib/core/peer_engine.dart:182`), and a publisher's peer set rarely
  intersects its guard's. The guard therefore announces the exit key ids it can reach
  (its link peers with valid keys plus beacons it can dial); the publisher chooses from
  that list. The guard learns the exit choice by design; the exit learns only that the
  source is one of the guard's clients.
- **Collusion.** A malicious guard that curates its list toward colluding exits turns
  f² into f. This is a residual, stated in the table.
- **Timing.** In fast mode no holds at E or R: against A1, A6 and A7 they buy nothing in
  sparse traffic, and in the fast mode they only add delay. In cover mode E batches per
  window and R holds uniformly in [0, T); without both, cover is worthless (2.3).
- **Retries.** Fresh ephemeral keys per attempt. Fast mode: through the same guard to a
  fresh exit; the guard already knows the publisher sent. Cover mode: a retry occupies
  the next scheduled slot and adds no cell; because every cell, padding included, carries
  the same acknowledgement expectation, failure counting and guard-rotation rule
  (8.4), a guard that drops a client's cells cannot tell whether that client publishes
  from its reaction.
- **Early release by R.** Harmless in fast mode. In cover mode it defeats the hold and is
  equivalent to R being malicious toward timing; a reviewer-level residual.
- **Withholding by R.** No echo; resubmit to a fresh exit; R learns nothing new.
- **Withholding by E.** No acknowledgement or no relayed exit acknowledgement; counted
  identically for all cells; bounded rotation with a visible warning (the guard-denial
  attack of Elahi et al. 2012 remains).
- **Isolation by E, the n−1 attack (owner's review; unresolved).** In cover mode E can
  withhold every other client's cells for a window, forward the target's cell to the
  window's exit together with padding E sealed itself (anyone holding the exit's public
  key can), and watch whether an article is released within the hold period. Uniform
  acknowledgements do not prevent this: E can relay forged exit acknowledgements if they
  are unsigned, or forward the withheld cells to a different exit so that genuine
  acknowledgements arrive; signed acknowledgements naming the expected exit only let the
  other clients detect the deviation afterwards and rotate away, which costs E those
  clients but not the result. The remaining anonymity set in the isolated window is the
  clients of other entries feeding the same exit, which with phones as exits is usually
  nobody. This is the active attack class of Serjantov, Dingledine and Syverson 2002,
  also described in the Katzenpost threat model, and it is the same shape as the
  reproduced FPP-0 isolation attack. Known defences are loop cover with detection
  (Loopix), verifiable processing with accountability (Dissent, Verdict) or trusting the
  entry; none is specified here. E10 in section 7 tests it; until it is addressed, every
  M3 claim against the entry and the state is unresolved.
- **Replay (review).** HPKE base mode does not bind the outer layer to the inner one
  (RFC 9180 §9.1.1), so E can resubmit inner cells; the exit's replay set is bounded and
  evictable by anyone holding the exit's public key. Replay is harmless after the store's
  content-addressed deduplication; the set is resource hygiene, not a security property.
- **Duplicate submission** is dropped.

## 4. Latency and bandwidth, reported separately

### 4.1 Reporting contract

For each mode: **startup** (app start to first possible protected submission: a live
guard with a valid key and exit list, pending store open); **steady-state added delay**
for successes (median, p95, p99, maximum, conservative paired bounds, 300 pairs per
profile); **failures** (no echo within the deadline; counts and recovery times, never
folded into success quantiles); **idle cost** per day. The five-second target is a
maximum on steady-state added delay for successes on a healthy route.

### 4.2 Fast mode (M2g) design budget, not a result

Added delay = seal and pending journal commit at the publisher + one 11 KiB frame to E
(8 KiB cell as base64 JSON on today's framing; about 8.2 KiB with a binary frame) + E's
commit + one frame to R + R's commit and verification + R's ordinary gossip, minus the
publisher's own gossip in M0. No scheduled waiting. With two domestic RTTs of 50 to
150 ms, transfers at 1 Mbps or better, three flash commits of 10 to 50 ms and the
measured 140 to 270 ms baseline gossip-to-store time, the maximum is under two seconds
and the median under one on the shaped profile used so far. Multi-cell objects add one
transfer per cell per hop: a 13-cell image roughly 1 s more. Failure recovery is a 30 s
echo deadline plus one attempt, reported as a failure of the target. M1g is the same
minus one hop.

### 4.3 Cover mode (M3) arithmetic (model)

Fixed period T, one 8 KiB cell per period, sender wait U[0,T), entry window U[0,T),
exit hold U[0,T); the sum has median 1.5 T, p95 2.33 T, p99 2.61 T, maximum 3 T, plus the
fast-mode hop cost H. Sender cost 675 / T MiB/day at 8 KiB binary cells, about 910 / T on
today's JSON framing. A relay node with seven cover clients carries eight times the
sender cost. Multi-cell objects are not handled by this schedule: a 13-cell image would
span 13 windows and 13 different exits (section 8.2); a first cover mode would be limited
to one-cell objects.

| T | Sender, MiB/day | Relay node, MiB/day | Median | p95 | Maximum |
| --- | ---: | ---: | ---: | ---: | ---: |
| 5 s | 135 | 1,080 | 7.5 s | 11.7 s | 15 s |
| 30 s | 22.5 | 180 | 45 s | 70 s | 90 s |
| 60 s | 11.25 | 90 | 90 s | 140 s | 180 s |
| 300 s | 2.25 | 18 | 450 s | 699 s | 900 s |

A Poisson schedule with mean μ costs the same and has no maximum; dropped. Today's
per-link egress cap of 512 KiB/min (`peer_engine.dart:77,3704`) is exceeded by seven
clients' batch to one exit at T = 5 s (904 KiB/min) and fits at T ≥ 30 s. Cellular NAT
idle timeouts under ten minutes on 11 of 73 carriers (Wang et al. 2011) and UDP timeouts
near one minute (Richter et al. 2016) mean a 300 s cover cell can replace the keepalive on
that link, the only configuration in which cover is nearly free.

**Reconciliation with five seconds.** A 5 s maximum including H needs T ≤ about 1.2 s
with batching, over 560 MiB/day at 8 KiB cells (proportionally less at smaller cells). Without batching the maximum is T + H but the
protection is gone (2.3). Section 5.2 shows the rate requirement is not an artefact of
this schedule. The fast mode therefore has no cover and no claim against A6, and the
cover mode has a stated maximum of 3 T + H and a stated cost. No setting satisfies both.

### 4.4 Mesh mix (M4) arithmetic (model)

n_b batching nodes (entry, intermediates, exit), each one window T; sender waits its own
slot. Maximum (n_b + 1) T + H; median (n_b + 1) T / 2; mean uplink n_b × 675 / T per
user; a node with fan-in 7 carries 8 × 675 / T; anonymity set at most 7^n_b and only if
all those phones are online and sending.

| T | n_b | Mean uplink | Relay node | Maximum delay | Set bound |
| --- | --- | ---: | ---: | ---: | ---: |
| 60 s | 2 (M3) | 22.5 | 90 | 180 s + H | 49 |
| 60 s | 3 | 33.75 | 90 | 240 s + H | 343 |
| 300 s | 2 (M3) | 4.5 | 18 | 900 s + H | 49 |
| 300 s | 3 | 6.75 | 18 | 1,200 s + H | 343 |

With few cover senders the set is the population, not the bound. M4 is a mixnet whose
mixes are phones; listed so the owner can see what state-level protection costs.

## 5. What is established, what our prototype assumed, what is impossible

### 5.1 Established results and their scope

- **Chaum 1988.** A DC-net participant's anonymity set is the connected component of the
  key-sharing graph after removing colluders' edges; all-but-one colluding leaves a
  singleton. Our "seven clients plus two coordinators" is this with a set of one.
- **Dissent in Numbers (OSDI 2012), Verdict (USENIX Security 2013).** Anytrust: at least
  one of a small fixed server set is honest; clients may be arbitrarily malicious.
  Servers XOR in pads only for clients whose ciphertexts arrived; a round completes if
  participation is at least a policy fraction α of the previous round, otherwise waits
  and on a hard timeout fails. Static roster per session; protocol halts if a server is
  offline; rounds closed by server window policy, not client clocks; no intersection
  defence across rounds, stated by the authors. Anonymity among honest online clients;
  set size unknowable in practice.
- **Riposte (2015), Express (2021), Spectrum (2022).** Fixed server sets with at least one
  honest (Riposte's scalable variant needs no two of three colluding); clients churn in
  Riposte and Express, must stay online in Spectrum; Riposte and Spectrum batch over
  epochs of hours, Express needs no rounds and answers in 0.2 to 15 s with anonymity
  among senders in a chosen interval. All need the fixed servers the owner excludes.
- **Tor and entry guards.** Unlinkability when the adversary does not see both ends; not
  claimed against a global observer. Persistent guards cap lifetime compromise near the
  malicious-guard fraction instead of tending to one.
- **Anonymity trilemma.** Das, Meiser, Mohammadi, Kate (S&P 2018), for a global passive
  adversary and protocols without user coordination: strong sender anonymity is
  impossible when `2ℓβ < 1 − ε` for synchronized senders (under ℓ < N and βN ≥ 1), or
  `2ℓp < 1 − ε` for unsynchronized senders where p is the per-round probability of
  sending anything; with c ≥ ℓ compromised parties constant latency is impossible
  outright. The PoPETs 2020 follow-up covers user-coordinated protocols including
  DC-nets: unified necessary condition `ℓ̂(p′ + β) ≥ 1 − ε`; DC-nets escape only with
  every user sending a share per message (B = N); when all but a constant number of K
  parties are compromised, strong anonymity needs `ℓ̂² > c`, latency on the order of √K.
  (The 2018 PDF was not retrievable in this session; statements are from the first
  author's 2021 dissertation, the 2020 appendix and the 2018 poster abstract, which agree.)
- **Disclosure attacks.** Kesdogan, Agrawal and Penz 2002; Danezis 2003: an observer who
  knows when the target sends and sees each round's recipient set recovers the target's
  partner set; Danezis gives `t > [m·l·(√((m−1)/m²) + √((N−1)(b−1)/N²))]²`, about 114 to
  258 observations at Kesdogan's baseline. With one channel (m = 1) the first term
  vanishes (by the formula).
- **Sybil.** Douceur 2002: without a trusted authority or scarce resource, distinct
  identities cannot be bounded (not re-verified in this review).

### 5.2 The local-observer corollary (our derivation; necessary condition only)

The first part of the invariant in both trilemma proofs is that the other challenge user
transmitted something in the ℓ rounds before the challenge message arrived. Checking it
needs only the target's link and the public arrival time. An observer of one phone's
uplink who reads releases plays "the target published iff it transmitted in the last ℓ
rounds", which gives the synchronized-sender bound `δ ≥ 1 − f(ℓ)` directly; for
unsynchronized senders the same argument gives a bound at least as strong as the
authors', and whether their weaker constant is slack or reflects something the local
argument misses is not settled here. For user-coordinated protocols the window is
ℓ + 1. The observer must know or bound ℓ and see releases at round granularity. What
does not transfer is every term involving compromised parties. So: hiding the
publication instant from an observer of the publisher's own link requires sending about
one message per ℓ for any construction; and, per section 2.3, meeting that rate is
necessary but not sufficient, because release timing and routing can still leak.

Two qualifications (owner's review). First, the bound is in messages per round, not
bytes: the daily cost is the message size times 86,400 / ℓ, so the figures in 4.3 are for
the 8 KiB cell chosen here and a design with smaller signed objects pays proportionally
less. Second, how fast an observer converges without cover is a model, not a
measurement: if a fraction q of the phones the observer watches emit an envelope-sized
uplink burst in any window of width H, the expected candidate set after m articles is
about N·q^m plus the publisher. With q small the set is one within two or three articles;
with q near one (many phones sending similar bursts constantly, which is what cover
manufactures) it never shrinks. The base rate q of such bursts in ordinary traffic on the
target networks is unmeasured and should be captured before any claim about how many
articles an observer needs.

### 5.3 Our prototype versus the literature (review-corrected)

| Requirement | FPP-1 | Dissent anytrust | Fast mode M2g |
| --- | --- | --- | --- |
| All clients present each round | Yes, fail closed | No; absent clients' pads excluded | No |
| All coordinators / servers present | Yes | Yes | No |
| Static roster | Yes | Yes per session | No |
| Clock agreement | 100 ms assumed | No; servers close windows | No |
| Honest fraction of clients known | Not needed for correctness, set size unknowable | Same | Not applicable |
| Trust assumption | One honest coordinator | One honest server | Guard and exit do not collude |
| Resists A6 / A8 | Idealized property only: a DC-net in which every member sends an equal cell every round hides the instant among honest members. Not established for our implementation (see below) | Same idealized property, same conditions | No |

The all-clients rule was ours. The carrier-resistance row must be read carefully
(owner's correction). What an idealized DC-net gives is anonymity among the honest
members that sent in the round, provided their transmissions are indistinguishable in
size and time. Our implementation has not demonstrated that: its own documentation
lists response-work correlation, queue-dependent timing and scheduler-controlled cutoffs
as open; colluding members reduce the set, down to one in the reproduced seven-plus-two
case; and as measured, bulk rounds with 8 KiB cells occur only when some member has
reserved a slot, so the carrier sees that a publication happened in this cohort at that
round, leaving at most the honest cohort as the set. The measured approximately
95 MiB/day idle figure is that regime: 96-byte reservation cells every 2 s plus framing
and control traffic, with no bulk cells. Hiding the instant itself would require every
member to send a full 8 KiB bulk cell every round; 8192 bytes × 43,200 rounds per day is
the 337 MiB/day model, which was never run. Disqualifiers remain availability, automatic
admission and cost in either regime.

### 5.4 Classification

**Established:** 5.1; the lab figures in `PUBLISHER-LAB-RESULTS.md`; the exposures in 6.4.
**Plausible engineering:** M1g and M2g as confinement of exposure to chosen relays; the
staging design in section 8; beacon reachability on fixed broadband.
**Unresolved:** any protection against A8 within the latency and bandwidth budget;
automatic Sybil-resistant admission; intersection resistance across many publications.

## 6. Discovery and reachability, qualified

### 6.1 What the shutdowns looked like (measured where stated; otherwise reported)

- **November 2019.** International routes withdrawn per ISP (measured); the three mobile
  carriers lost international reachability from 16 November (measured) and reportedly
  all data service at first; reports put Irancell's domestic-only restoration at
  24 November and global mobile access at about 27 November; fixed lines reportedly
  restored first. NIN reachability is inferred from service availability, not measured.
- **September to October 2022.** Nightly curfews cut the three mobile networks completely
  from about 16:00 to midnight local (measured); fixed broadband kept domestic and
  international connectivity (measured), with regional total blackouts. NIN access for
  mobile users during curfews is field-reported only.
- **June 2025.** Forwarding-plane discard at the gateway; NIN unaffected (IODA; preprint
  measurement by Sadeghi Jahromi and Jaskolka 2026 for the mechanism).
- **January 2026.** IPv6 routes withdrawn first, IPv4 kept so whitelists could be applied,
  then the NIN, white SIMs, mobile voice and landlines; a whitelisted-services phase
  followed. **February to May 2026:** an 86-day shutdown (preprint measurement).
- **Inter-provider reachability of end-user IPs inside Iran has never been measured.**
  Architecturally every domestic path crosses TIC-controlled infrastructure.

Three regimes to design for: mobile data absent while fixed Wi-Fi works; domestic-only;
nothing but nearby radios. "Two CGNAT phones" arises only in the first regime's
complement, and in the worst regimes mobile data is simply off.

### 6.2 NAT traversal, corrected

RFC 5128 §3.4: TCP hole punching needs endpoint-independent mapping on both NATs and
correct simultaneous-open handling; Ford, Srisuresh and Kegel 2005: 64 % of tested NATs
TCP-compatible, 82 % UDP; Guha and Francis 2005: up to 88 % with refinements. Cellular:
Wang et al. 2011 found 26 % of 72 NAT-deploying carriers using random per-connection
mapping and 18 of 20 tested allowing SYN-out-then-SYN-in; Richter et al. 2016 found 40 %
of cellular CGNs symmetric. Two carriers drawn from a 40 %-symmetric population are both
endpoint-independent about 36 % of the time (**model**). Hole punching needs a rendezvous
(any existing TLS link) and `SO_REUSEADDR` on listener and connecting sockets, which
dart:io does not appear to expose (unverified); if so, native code. Irancell's documented
12:1 IPv4 CGNAT means unsolicited inbound to a mobile client never works; IPv6 gives
global addresses but was withdrawn first in January 2026 and timed out on Irancell during
the 2022 curfews. Conclusion: do not design around mobile-to-mobile. Fixed broadband
survived at least domestically in 2019, 2022 and June 2025, failed in January 2026, and
is unmeasured for February to May 2026; home NATs are far more traversable and the app's
NAT-PMP lease already applies there. Classify NAT type per flow before writing code.

### 6.3 Beacon phones: port, exposure, censorship

- **Port.** Stock Android cannot bind below 1024 (`ip_unprivileged_port_start` default
  1024, apps hold no `CAP_NET_BIND_SERVICE`; **established** from AOSP source). The fixed
  port 45871 on every device is a scan fingerprint; use a per-device random high port
  carried in the signed contact card.
- **Exposure.** A beacon's card (public IP, port, stable certificate) is gossiped to every
  peer and cached on their disks for seven days (`lib/core/peer_contact.dart:16`). A
  seized phone or malicious peer yields beacon addresses that a carrier maps to
  subscribers. Intrinsic to being reachable; opt-in with a plain warning, shorter and
  encrypted cache, and a publisher's phone never a beacon for its own channel.
- **Censorship.** Measured: a protocol allow-lister that in 2020 required the first two
  client packets on TCP 53, 80 and 443 to look like DNS, HTTP or TLS and dropped the flow
  for a resetting 60 s otherwise, with other ports unfiltered at that time; SNI-based
  TLS resets, by 2025 on all TCP ports (that is the block-list filter, not the
  allow-lister); QUIC blocked since September 2022 and broad UDP dropping measured in
  2024 to 2025; blanket IPv6 withdrawal in shutdowns; no documented active probing, but
  anecdotal volume-triggered IP:443 blocks of foreign proxies. Under a full allow-list
  (January 2026) no residential peer-to-peer path is expected to pass (inferred; domestic
  paths unmeasured). Achievable posture: first bytes are a TLS 1.3 ClientHello, with TLS 1.3 required rather
  than preferred, because only TLS 1.3 encrypts the Certificate messages (RFC 8446 §1.2)
  and a TLS 1.2 handshake would expose the self-signed certificate to any passive
  observer; no fixed port; silence toward non-TLS first bytes, closed after a bounded timeout, because a
  listener with four handshake slots cannot afford open connections (the revision-1
  suggestion of no finite timeout, from Frolov et al. 2020, is withdrawn; it trades a
  fingerprint for a trivial resource-exhaustion attack, and any finite value is a
  fingerprint); an unremarkable certificate shape. Not achievable with dart:io: TLS-PSK gating (no API;
  Android's `PskKeyManager` removed in API 26) or hiding the self-signed certificate from
  a scanner that completes the handshake. The Dart ClientHello fingerprint is unknown.

### 6.4 Production exposures found (established, code cited)

1. `lib/core/tcp_enrollment.dart:9,19`, `lib/core/peer_engine.dart:2195-2208`: cleartext
   `PTRELAY/1 <base64url beacon>` with the dialer's full connection certificate before
   TLS on every dial to a helper contact or flagged card, including reconnects to pinned
   peers. A passive observer links one phone across all its IPs. The measured 2020
   allow-lister would drop it on 53/80/443; on 45871 no measured filter acts on a
   non-TLS first packet, but the linkability stands. Fix: TLS 1.3 first. The version matters (owner's
   review): TLS 1.2 sends certificates in the clear, TLS 1.3 encrypts them (RFC 8446
   §1.2), so the existing `minimumTlsProtocolVersion = tls1_3` in `_context()`
   (`peer_engine.dart:1883-1892`) must remain on both client and server with no legacy
   fallback, and the fix must be verified by packet capture showing the negotiated
   version and no certificate bytes on the wire. Preserve what the preface provides
   today: the server accepts the client's self-signed certificate at the
   handshake without trusting it, the client's first encrypted message is the signed
   beacon, the server verifies that the beacon's signing key is the key in the presented
   client certificate and that the beacon binds this connection (the server's certificate
   fingerprint and a server nonce, or a TLS exporter value) so a beacon cannot be relayed
   between connections, and only then enrolls the certificate; pinning for already-known
   peers is unchanged. Handshake work stays bounded by the existing four concurrent
   handshakes, the per-/24 and global admission limits and a finite deadline for the
   beacon to arrive; RSA verification of beacons is charged to the same per-window
   budget. The change needs tests for malformed, truncated and deliberately slow
   connections alongside the privacy checks.
2. `lib/core/identity.dart:29-70`: self-signed RSA-2048, CN = hex SHA-256, O =
   `FarvaharTrends`, validity 2000-01-01 to 9999-12-31. Unique, stable per device.
3. `lib/core/peer_engine.dart:66,1708`, `LocalWifiTransport.java:334`: fixed port 45871;
   `tcp_enrollment.dart:88`: silent clients closed after exactly 3 s.
4. `lib/core/peer_engine.dart:3351-3356` versus `3396`: between the media-store write and
   the publication record the image hash is already advertisable; any inventory sent on
   an image-allowed link in that window announces the hash before the article exists.
   A race, not an on-demand observation, but whenever it fires it identifies the
   publisher of the next article.
5. `lib/app_controller.dart:439`: `acceptTcpEnrollment` true for every install despite the
   opt-in comment.

### 6.5 Field measurements

Inbound self-test pass rate per network class, hourly for a week; NAT classification per
flow; time to first live link from a card cache aged 1 h, 6 h, 24 h, host-observed;
survival of a TLS-first handshake to a random high port on a residential IP per carrier
in normal times.

## 7. Security experiments with attacker views defined

| Experiment | Attacker | Observes | Does not observe | Type | Reject if |
| --- | --- | --- | --- | --- | --- |
| E1 Single relay | A1 = A2 (M1g) | IP, certificate, plaintext | Nothing | Inspection | Always; residual |
| E2 Guard alone, fast mode | A1 under M2g | Cell times and counts; public releases | Contents | Inspection | Always in sparse traffic; residual |
| E3 Uplink observer, fast mode | A6 under M2g | Publisher's packet sizes and times; releases | Contents | Inspection | Always; residual |
| E4 Neighbour indistinguishability | A4 under M2g | Every frame with publisher and control reader; first offers; probe responses; response latency | Envelope links | Deterministic invariants plus classifier | Any invariant violated or classifier above chance |
| E5 Pre-release exposure and forwarding behaviour | A4, A5 under M2g | Any object or hash from the publisher before the exit's release; after release, first-offer rate and release-to-offer latency for its own articles versus matched readers | Link traffic | Deterministic before release; comparative after | Anything pending appears before release; or the publisher's post-release forwarding of its own articles differs from matched readers beyond the stated sensitivity |
| E6 Response timing | A4 under M2g | Latency of the publisher's responses before, during, after a submission, under the shaped profile | Envelope links | Statistical | Shift detectable |
| E7 Guard under cover | A1 under M3 as specified | Cells, counts, exit per window, acks, failure counts over days | Contents | Statistical | Real cells or publishing clients identifiable above chance |
| E8 Uplink under cover | A6 under M3 | Wi-Fi uplink capture; release times | Contents | Statistical | Publication instants recoverable above chance |
| E9 Exit under cover | A2 under M3 | Arrivals via E, padding versus real | Who fed E | Statistical | Source narrowed beyond E's client set |
| E10 Malicious-entry isolation | A1 under M3, active | Everything A1 sees, plus the power to withhold, delay, reorder and inject cells and acknowledgements | Contents | Deterministic on the harness | E identifies the publishing client from the presence of a release after an isolated window; expected to succeed as M3 stands |

A pass on any statistical experiment means no tested leak was detected at the stated
sensitivity, not that exposure is confined to the listed residuals.

### 7.2 Known failures of E4 and E5 in today's engine (established)

- A node holding an object never sends `want` after an inventory (`peer_engine.dart:
  2581-2607`): advertise the id and watch for the request.
- A newly admitting node re-gossips and sends `mediaWant` (`3089-3101`); the publisher's
  duplicate path returns before either (`2908-2918`). Deterministic.
- The duplicate path skips RSA verification and the journal write; per-link serial
  processing (`2450`) makes the next response faster. Statistical; this is E6.
- A node that has the image bytes skips the fetch (`media_transfer.dart:107-111`); the
  publisher has them unless its cache evicted the file.
- The image-hash race in 6.4 item 4; and, by the same mechanism, every channel id and
  policy id the owner writes to the store is advertised by `_sendInventory` before any
  peer has it (`3505-3517, 3528-3531`) (review).
- The owner's channels are exempt from store eviction (`pilot_store.dart:105`), so under
  cache pressure a reader's inventory drops channels the publisher's never does (review;
  long-horizon, statistical).

## 8. Protocol specification

### 8.1 Keys

- X25519 envelope key per device, separate from the RSA-2048 connection identity and all
  signing keys; rotated every 24 h, previous accepted 24 h more; key id = first 8 bytes
  of SHA-256 of the public key; stored in a new secure-storage record `{current,
  previous, validFromMs}` under the existing identity lease (`Identity` and
  `ChannelKeyStore` cannot hold it: `identity.dart:95-110,192-198`,
  `channel_key_store.dart:78-88`).
- Distribution: feature-gated frame `envelopeKey {publicKey, keyId, validFromMs,
  validUntilMs, relayCapacity, servesImages, exitKeyIds[], signature}` signed by the
  connection identity, sent on link establishment and on change. `exitKeyIds` is the
  sender's announced reachable exit set (review). An unknown frame type today causes an
  `invalid_frame` disconnect (`peer_engine.dart:2893,2473-2487`); add to dispatch and gate
  like `ownerAuthority`.
- No forward secrecy against recipient key compromise (RFC 9180 §9.7.4); rotation cadence
  is a protection parameter; retired private keys erased.
- No mature Dart HPKE library; `package:cryptography` supplies X25519, HKDF-SHA256 and
  ChaCha20-Poly1305 in pure Dart; implement the RFC 9180 schedule on top and check
  against the RFC test vectors, or do it natively. Constant-time behaviour unverified.

### 8.2 Cell format

Outer cell exactly 8192 bytes before framing:

```
inner_pt = version(1) | type(1) | object_id(32) | frag_index(2) | frag_count(2)
         | hold_s(2) | nonce(16) | payload_len(2) | payload | zero padding
inner_ct = HPKE.Seal(pk_R, info="ft/env/inner/v1"|keyid_R, aad=keyid_R, inner_pt)
outer_pt = keyid_R(8) | inner_ct
outer_ct = HPKE.Seal(pk_E, info="ft/env/outer/v1"|keyid_E, aad=keyid_E, outer_pt)
```

DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305, base mode; 48 bytes per
layer; payload capacity 8030 bytes. Types: bulletin, channel, channel policy, owner
authority, image chunk, padding. A signed bulletin or channel is one cell, a policy or
authority up to four (`ChannelControl.maxBytes` 24 KiB), a 96 KiB image 13. `hold_s` is
used only in cover mode: the exit holds the complete object for that many seconds after
its last fragment; it is drawn by the publisher uniformly in [0, T). Cell count per
submission is visible to E and A7 and reveals object class in fast mode. **Multi-cell
objects in cover mode are unresolved (owner's review).** With one cell per slot and the
exit changing every window, a 13-cell image spans 13 windows and 13 exits, so its
fragments do not meet. The options each leak or cost: routing all fragments to the exit
of the first fragment makes E forward some cells against the window rule, which tells E
that this client has a multi-cell object in flight; sending all fragments in one slot
makes the slot size content-dependent for E, A6 and A7; sending a constant maximal
number of cells every slot for every client multiplies cover cost by the maximum cell
count; adding a hop with per-client-epoch exits moves the continuity leak to the new
hop. A first cover mode would therefore carry only objects that fit one cell, which
covers short text bulletins and excludes images and the channel creation bundle unless
the latter is packed into one cell (a v2 channel, authority and initial policy are close
to the 8030-byte limit; this must be checked, because a creation bundle sent outside
cover links the channel to the publisher once and permanently). Whatever option is
chosen, the exit's incomplete-object lifetime must exceed (cells − 1) × T plus the hold,
which at T = 60 s is over 12 minutes for 13 cells and exceeds the fast-mode 10-minute
lifetime; set it to 2 × cells × T in cover mode, bound pending fragments per entry to a
small number of objects of at most 13 cells each, and expire oldest first. Padding cells
are indistinguishable from real cells to E and on the wire. Replace today's base64-in-JSON framing with a binary
frame type to recover the 25 % overhead.

### 8.3 Publisher state machine

Pending store: a journaled collection separate from `_store.bulletins`,
`_store.channels`, `_store.channelPolicies`, `_store.ownerAuthorities` and `MediaStore`;
pending image bytes in a directory the media store never indexes. States:

1. `composed`: object signed; bulletin sequence reserved through `nextChannelSequence`
   as today (already journaled, gap-not-reuse; `pilot_store.dart:206-223`); policy
   revisions and authority generations reserved from the union of store and pending, with
   at most one pending policy and one pending authority per channel (review).
2. `sealed`: cells built for (guard, exit from the guard's list); attempt counter
   incremented; journaled before any send.
3. `acked`: the guard's acknowledgement of the outer-cell hash received and journaled
   (unsigned; the link is already mutually authenticated; the ack means "durably
   journaled at E").
4. `echoed`: the object arrived through the ordinary receive path from any peer and was
   admitted like foreign news; pending copy deleted. Reachable from any state (review).
5. `failed`: attempts exhausted; shown to the user; a user-triggered resend sends the
   same object, never a new one (review); no direct publication ever.

Timers: `sealed` without `acked` in 10 s or on link loss, resend with fresh ephemeral keys
through the same guard to a fresh exit; `acked` without `echoed` in 30 s, same; three
attempts then `failed`. In cover mode every send waits for the next slot and replaces
that slot's padding. Dependencies (review): a protected channel's creation bundle
(channel, owner authority, first policy) is staged and submitted as one object set to one
exit; nothing can be composed for the channel until that bundle has echoed; a bulletin is
submitted only after its channel, authority and current policy are public; a new policy
only after the previous one echoed. `restoreChannelRecovery`, `commitProtectedChannel`
and `acceptEditorInvitation` currently write to the store and gossip directly
(`owner_channel_management.dart:134-150`, `channel_management.dart:236-249,418-427`);
for protected channels they stage instead. Nothing in the pending store is read by
`_sendInventory`, the `want` handler, `_imageInventory`, `_serveImage` or `_pruneImages`.
Because the public store does not contain the pending object, the duplicate check at
`peer_engine.dart:2911` does not fire on echo (confirmed by review against
`verifyForChannel`, which has no self-origin check), and the engine requests the object,
re-gossips it and downloads its own image bytes exactly as a reader would.

### 8.4 Relay state machines

Entry E: on `envelope` from a client link, charge the client's ingress allowance, decode
the outer layer, check `keyid_R` is on its announced exit list, journal `{outer_hash,
keyid_R, inner_ct, received_at}`, acknowledge. Fast mode: forward immediately over the
link to R (or dial R's card for beacon exits). Cover mode: hold all cells received in the
current window and forward them at window end in random order; relay R's per-cell
acknowledgement back to the client; the exit for a window is
`list[H(E_id || window) mod |list|]` over the sorted announced list, which clients
recompute. Retry a failed forward for 60 s then drop. Acknowledgements, failure counts
and client-side rotation triggers are identical for padding and real cells (review).
`relayCapacity` ≤ 7 (eight links minus the exit link); per-link egress to one exit bounds
T to 30 s or more on today's budget.

Exit R: on an inner cell from E, charge E's ingress allowance, decrypt, drop nonces seen
for this key id (bounded set, hygiene only), journal the fragment, acknowledge to E
identically for padding and real cells. When all fragments are present and, in cover
mode, `hold_s` has elapsed since the last fragment, admit the object through a dedicated
relay-ingress path (review): a link variant with no socket, modern and owner-recovery
features set, its own allowance outside the eight connection slots, gossip to all links,
and an invalid-object counter that does not gate releases, because anyone holding the
exit's public key can seal garbage to it. Images: bytes written to the media store and the
bulletin admitted in the same serial section so `_pruneImages` cannot remove them
(`media_transfer.dart:12-21,183-186`); served regardless of the exit's own `imageMode`,
which today gates non-local images on Wi-Fi only (`peer_engine.dart:62`), hence the
`servesImages` flag and the publisher choosing image-capable exits for image posts (which
tells E the post has an image; it already knew from the cell count in fast mode). A
relayed bulletin whose channel is not yet public would be parked for 45 s and its `want`
sent to no real link (`peer_engine.dart:78,2984-3027`); the dependency rule in 8.3 avoids
this, and the ingress path sends `want` on real links when parking. Incomplete objects
expire after 10 minutes in fast mode and 2 × cells × T in cover mode, with a bounded
number of pending objects per entry (section 8.2).

### 8.5 Relay selection

Guard: an authenticated peer with a long local history, from a new persisted
per-identity record (first seen, sessions, successes; nothing today persists this,
`peer_contact_store.dart:6`; its existence on a device marks the device as a publisher at
rest unless every node keeps it); kept until unreachable for 7 days or three failed
submissions in a day; at most two rotations per day, each shown to the user. Exits: from
the guard's announced list, excluding the guard itself; fresh per attempt in fast mode;
derived per window in cover mode. The follower-exclusion rule from the first draft is
dropped: follow state is never on the wire and not computable (review). With fewer than
one guard plus one exit the publisher waits and says so; never direct publication.

### 8.6 Budgets

Envelope frames spend the sender's ordinary reserved-slot ingress allowance at the
receiver (`connection_budget.dart:70-93`); sealing buys no extra ingress. At T = 5 s one
client's cover is about 132 KiB/min, inside a slot's 256 KiB reserve; seven clients' batch
to one exit exceeds the 512 KiB/min per-link egress cap, so cover mode needs T ≥ 30 s or
a raised relay cap.

### 8.7 Coverage of publisher actions

Through the envelope: `channel`, `bulletin`, `channelPolicy` (writer grants, revocations,
deletion, removals; `channel_management.dart:179-186,322-370,431-455,477-533`),
`ownerAuthority`, image chunks. Editor grants travel out of band and first reach the
network inside the editor's first bulletin, which is enveloped; the editor device must
also stage, not store, the invitation's policy (review). Nicknames are a bulletin field.
Legacy diagnostic bulletins (`_broadcast`, `peer_engine.dart:3421-3423`) are disabled for
protected channels. Diagnostic receipts and helper or discovery contact cards are not
publisher objects but must never be emitted by a publisher for its own objects.

### 8.8 Crash and partial delivery

Publisher: before `sealed` journaled, nothing sent; after, resend on restart; after
`acked`, wait for echo up to the deadline from restart, then resend; deadlines are
process-relative; no anchor restored. Entry and exit: journaled cells forwarded or
released on restart; lost ones covered by the publisher's deadline. Partial image at R:
fragments held 10 minutes then deleted; the whole object is resent to a fresh exit;
fragments never span exits. The single invariant E4 and E5 test: no code path writes a
pending object into the public store or the serving media index except the ordinary
receive path on echo.

## 9. Smallest decisive experiments

### 9.1 Rejected on paper

Only two things are rejected without a run (owner's review narrowed this). A proposal
that claims to hide the publication instant from an observer of the publisher's link
while the publisher transmits less than about one message per latency bound; that
follows from 5.2 for any construction. And a cover proposal without batching at the
entry and a hold at the exit, by the argument in 2.3. The byte figures in 4.3 are not a
universal cutoff: they follow from the 8 KiB cell and the schedule assumed there, and a
design with smaller messages or a different schedule must be costed on its own terms
before it is accepted or rejected.

### 9.2 Decisive for the fast mode: neighbour indistinguishability (review-corrected)

Claim under test: in M2g, the publisher's neighbours and downstream peers cannot
distinguish it from a reader through the ordinary protocol. **A pass means no tested
leak was detected at the experiment's stated sensitivity (owner's review).** It does not
show that remaining exposure is confined to the listed residuals; it does not cover the
timing behaviour of the real cryptography and storage, which must be retested as E6 on
the actual implementation; and it says nothing about M3.

Apparatus on the loopback TLS harness under the shaped 5 Mbps / 80 ms profile: two
engines A and B that are assigned the publisher and control-reader roles at random per
session, with fresh identities, keys and store directories for every session so that no
identity or address can serve as a classifier label; guard E announcing an exit list of
three exits R1 to R3; logging neighbour P; downstream D. A and B have identical link sets
and receive identical ordinary public traffic from an unrelated publisher Z at the same
rate, so both show normal reader behaviour and comparable load. Fifty protected
publications per session at random times, half with images, over several sessions; runs
with R1 withholding and with E withholding one attempt to exercise retries. The envelope
stub must emit real-size cells through the real `_send` path to real links and perform
CPU work and journal commits of the same order; it tests staging invariants, and the real
implementation must later undergo E6 on its own.

P and D record every frame type, size and time, inventories, who first offers each
object and image hash, and the response latency to their own periodic requests. Two kinds
of probe are kept apart. Black-box: P learns an object id only when the exit's gossip
makes it public, then advertises it to both A and B in the same inventory and compares
their `want`, re-gossip and image-fetch behaviour; this is what a real neighbour can do.
White-box: the harness inspects the publisher engine's inventory responses, `want`
handler and media index directly for any pending id before release; this is an invariant
check, not an attacker capability, and is reported as such. The revision-1 probe that
advertised an unpublished id to the publisher assumed knowledge no neighbour has and is
replaced.

Rejection rules (owner's review corrected the first-source rule: after an article is
public, any reader may legitimately be the first to forward it to a given neighbour, so
being first source alone does not identify the author):

- Before release, deterministic: any object, fragment, id or image hash originating from
  the publisher's protected submission is observed at P or D, or (white-box) is visible in
  the publisher engine's inventory responses, `want` handling or media index, before the
  exit releases it.
- After release, comparative: for the publisher's own articles, its first-offer rate at P
  and D, its release-to-offer latency and its request, re-gossip and image-fetch
  behaviour are compared with the same measures for matched readers (the control role
  with the same links and the same public traffic) on the same articles. A difference
  beyond the stated sensitivity rejects.
- Statistical: a classifier trained on some sessions distinguishes the publisher's link
  from the control's on held-out sessions above chance, using features that exclude
  identities and addresses.

Controls and uncertainty: a **known-leaking positive control** runs the identical
detection method against the current engine publishing directly (M0), which must detect
the distinguishers in 7.2; if it does not, the experiment is not sensitive enough and no
pass is claimed. The unit of independence is the session (fresh identities, stores and
role assignment), not the message; accuracy, rates and latencies are computed per
session and summarised with confidence intervals across sessions, and the number of
sessions and the detectable effect size are stated with the result.

Outputs: which of the 7.2 leaks disappeared and which remain; added delay (startup,
median, p95, p99, maximum, failures) on the shaped profile; CPU, storage and traffic cost
of the staging store and the stub relays. Pass means no tested neighbour or downstream
leak at that sensitivity. Fail names the leaking engine path. Measurements with real
encryption and storage must follow before the five-second requirement is judged. Cost:
one staging store, one envelope stub with real-size frames, one logging peer, one
positive-control run. The fast mode, pass or fail, does not hide publication from a
carrier observing the publisher's connection; that remains the unmet original goal, as
does shutdown reachability.

### 9.2.1 Historical x1 stub (16 October 2026)

This describes the original experiment. It also reused signing and connection
keys in its harness; excluding identities from classifier inputs did not test the
observable equality of those keys. Its detector results therefore do not establish
absence of tested publisher linkability. See the corrected x2 implementation below.

The experiment is `test/protected_staging_experiment_test.dart`, with the pending
store, cell codec and relay roles in `lib/core/protected_publication.dart` behind an
`EnvelopeExperiment` constructor argument that production never sets. Deviations from
the specification above, all deliberate simplifications of a stub: the guard's exit list
is configured by the harness rather than announced; the exit admits a relayed object by
handing it to the ordinary receive path with the entry's link as the apparent sender,
so budgets and strikes land on the entry (the dedicated relay ingress is not built); cells
are masked with a SHA-256 keystream that anyone can remove, so no cryptographic cost is
measured; the exit announces an image it received through a cell exactly as a node does
after completing a download; the pending-store bookkeeping on echo runs after the
ordinary path has queued its gossip (an earlier placement added about 80 ms to the
publisher's forwarding and was caught by the offer-latency comparison in a smoke run);
and the timing probe in the staging arm usually compares two duplicate-path responses,
because the exit delivers to both engines before the observer can push, so it is weaker
than the same probe in the positive control. Results are the two runs recorded in
`PUBLISHER-LAB-RESULTS.md` (16 October 2026): run 1 overloaded the shared test isolate and
only its deterministic detectors count; run 2 is the measured result. In run 2 the positive
control detected every 7.2 distinguisher in all three sessions; in the staging arm no
pending data appeared before release in 168 publications including channel creation,
images, retries and restarts, the first source was a relay every time, the request probe
agreed, the publisher fetched its own image like a reader, and no forwarding-order or
forwarding-latency difference was detected at the stated sensitivity. Stub publish-to-release delay
had a 536 ms median for text (not a paired added-delay measurement), with a tail to 12 s inside the publisher's call path that is
unexplained and must be profiled on the real implementation.

### 9.2.2 Current encrypted x2 laboratory implementation

`protected_publication.dart` holds laboratory configuration and pending-record
types; `protected_runtime.dart` holds the flag-gated lifecycle, fragmentation,
relay admission and echo handling. `hpke.dart` implements the RFC 9180
X25519/HKDF-SHA256/ChaCha20-Poly1305 base-mode suite, checked against Appendix
A.2.1; `envelope_crypto_worker.dart` runs it in separate persistent isolates.
This is a local implementation using established primitives, not an audited
third-party HPKE implementation. The insecure stub is a distinct wire feature.

The internal relay ingress retains real verification/admission budgets but does
not duplicate transport byte charges or create new connection-budget slots.
Invalid opaque data is not attributed as misconduct to an entry that cannot
decrypt it. Journals and incomplete fragment groups have explicit count, byte
and expiry limits, durable acknowledgements, bounded compaction, restart tests
and completed-object replay handling. Publisher echoes follow the ordinary
reader path. The image-reference index removes repeated per-inventory bulletin
parsing without changing normal image-download policy.

The corrected 9.2 harness separates signing/transport identities, inspects
unreleased public state, timestamps local exit admission, compares the same
reader endpoint with matched payload lengths, alternates phase order and uses
equal observation windows. Unrelated public-id probes overlap sealing; the
post-release duplicate probe remains separately labelled. Engine logic shares
one isolate, so these probes are not independent-device timing evidence.
The long harness requires explicit opt-in and does not run alongside the suite.
Results and exact commands are recorded in `PUBLISHER-LAB-RESULTS.md`.

The normal app does not enable this path. Recipient keys and exit lists remain
lab-pinned. Recoverable channel creation and management actions are not staged
by these entry points. No cover mode, malicious-entry isolation defence,
carrier-anonymity claim, production discovery integration, recipient-key rotation
or handset battery claim follows from this implementation.

### 9.3 Afterwards

Field reachability (6.5); the 300-pair latency run of M2g with startup, failures and idle
cost reported separately; E7 to E9 only if the owner chooses a cover mode, labelled with
the 4.3 maxima and the 2.3 anonymity sets.

## 10. Recommendations

1. Fix the five production exposures in 6.4 now, keeping pinning, key binding and the
   handshake bounds as specified there, with malformed and slow-connection tests.
2. Build the staging store and run 9.2 before any envelope cryptography.
3. Decide between M1g and M2g with 2.3 and 2.4 in view; both confine exposure to chosen
   relays and neither protects against the carrier. Label the mode that way in the UI.
4. Do not offer a cover mode until E10 (malicious-entry isolation) and the multi-cell
   question in 8.2 are resolved; its protection claims are marked unresolved throughout.
   If they are resolved, present it only with the 4.3 table: maximum delay 3 T + H, cost
   675 / T MiB/day plus relay load, protection at best anonymity among the guard's cover
   clients. The 300 s period doubling as the NAT keepalive is the one nearly free setting.
5. Retire FPP-1 on availability, admission and cost; keep the harness and attacks.
   Migrate new channel signing to Ed25519 as a separate versioned change; it also shrinks
   signed objects, which sets the cost of any future cover cell.
6. Treat M4 as research with 4.4's costs written down.
