# Cross-platform PoC report

Reconciled on 2026-08-30 (Europe/Helsinki). This report deliberately keeps
desktop reproducibility, Android hardware validation, and Steam Deck hardware
validation separate. It does not close issue #23 or issue #7.

## Revision and reproducible builds

Desktop behavior is pinned to
`f713cf733874d706f08fbc480c958f4f2a2d9b23` (`fix: harden off-track placement
validation`), with its evidence-only capture record at
`f5b34f0d18d0749d185345c9938b393bb18c5271`. Android and Steam Deck artifact
hashes below remain historical export inspection only, not current
physical-platform acceptance evidence.

The following Godot `4.7.1.stable.official.a13da4feb` exports and hashes are
historical local-inspection records only; they are not packages to install for
the final physical validation:

| Target | Artifact | SHA-256 | Local inspection |
| --- | --- | --- | --- |
| Historical Android Debug | `slicksnslide-fest-debug.apk` (28,527,062 bytes) | `0e98e78fe17ea4ff7bee4cacfcdc8a14c169bdb127d57ad8ee6b32a56a804819` | arm64-v8a; min SDK 24; target/compile SDK 36; v2/v3 signature verified |
| Historical Linux x86_64 | `slicksnslide-fest.x86_64` (73,470,264 bytes) | `2cb27aee3f7fdf763d0ae16972f6975606959a071f4cd33f6ef1429eb8385049` | ELF x86-64, dynamically linked for GNU/Linux 5.15.0 |
| Historical Linux data | `slicksnslide-fest.pck` (1,508,680 bytes) | `a33c0ff2294d9c4fd77506e3019854f2795bb152fa3e5f2ef93e69fa1a842f55` | paired with the Linux executable |

These ignored local build outputs are reproducibility checks, not installation,
launch, or platform acceptance evidence.

## Architecture and catalog version

Catalog version 1 uses deterministic per-cell placement after road acceptance.
Grass and debris occupy the 0-12 m decorative band; trees and rocks are solid
hazards only from 20-140 m, preserving the 20 m recovery corridor. Runtime
uses decorative batches and chunked static bodies, while each seed exposes a
separate SHA-256 road and object fingerprint. See [Off-track objects](offtrack-objects.md).

## Seeds 0-19 and fingerprints

The ledger was regenerated from the fixed runtime tree at `f713cf7`. Every road
and object fingerprint below is a 64-character SHA-256 value. The road hashes
match the pre-remediation baseline for every seed; object hashes are current to
the footprint-boundary fix. Deterministic placement tests also verify that each
object fingerprint repeats for the same seed.

| Seed | Road fingerprint | Object fingerprint |
| ---: | --- | --- |
| 0 | `c473c35414d6ee31c9abada0c4d5fe4856997f137ca8d7dd6223a45da29bf55f` | `5f587a1b70ce3300729a390f555f277329c0d3e2e385891396868da5470bac88` |
| 1 | `b4b5a88a8be258e58c43567bb2e1ffc9364f21c98bae38ee92e0a087de9fa90e` | `a6e2ba9fb9a8ac7f43b29874878529b37cb3f368bcd382e2a7346760e895a9f7` |
| 2 | `d1e5d0df9651e041374342582d1cccf79193fe8ecb95796baac1eb19217bd7ea` | `308f0795be1df084a297b4e74971d17be10297420df51c6297fbe28606594d28` |
| 3 | `a1e4ab9b4425050a266ac40d2bb958b99d303303192c241c02b0822912ed078d` | `8222001966fe85a9b0df8c1abdc5e4172586c18b702ea3891fce5309e8c2a0d9` |
| 4 | `4600dc93fe343e17e999276b333051a9538f51c50d02992863af9b4970779155` | `e48a8ef915e3eb316784300ad5f26189d7f157ab2c0f4bdfad733d0e676c2348` |
| 5 | `8d530ec157495015293c77e77d2b3f9dfb458db272c3176b1f11bc9e495716b5` | `23565fec72cb77b09ef01fae6966bf754460768b30697939a5273e380df4523a` |
| 6 | `7fad0c2e88fccb083da767eba455a3b50ed248e8fea025fb43500d14e3ab04d9` | `1c92f61706ca488261612277291ffbb8cfe076fec6df9d36471026adf6b2c59e` |
| 7 | `ed6a92a5ee67e6e67f147fe6382bb266afe356d1de03cdc2322fdeb1d28c2af8` | `9a3965d30d5b18ddeb963f2af4b3acfdb2ecf2d598e21ecd159037a8d9987fd2` |
| 8 | `d0ff3f39294c44e16a182eabc0283b23842801ce6617c1f79a66001d93929aef` | `7ab67ac9cd411656a5799f04904d19de9bf6142212e79d063fd230274ec52a47` |
| 9 | `3fbe38ff1f6a222c0050cc004bddf93225b5da99176639d4b22f5934ece85670` | `7f5a46301fead1d1514cabb3d0b82f207e210d88a1ef1b46d246695f782aaa6b` |
| 10 | `56c585fc00729f4416cd459c57e7b6821b101a83374f9bb2e7443f6633546c42` | `4fa89cd904ad87ea423b28f3ad382d563525354a5ff317f1bf9449e72e7dd2d5` |
| 11 | `f0237efe220f89c01733e293d377a299f1c39b88843c992b5006bc0512ba51b0` | `ce168f228e687a01bfdfc0dc5cb043a5b7555ea3f0a9877a13574de16f2b5e61` |
| 12 | `5331af0ca10b06d73cb47223caf72bebfa0c87c53df04951a395c24e2646976f` | `8c9512f41ea4fcb539b6c2b5dbc1475b06cd274cbf243a8ce6272ac79df2f2e2` |
| 13 | `a3b44cf2ccee2206c308f0bdc1af8324e32767e59152061a174b887ad3db97a2` | `765febb166d37358cf41515ecebe5ac3aa314ff0f5136b83cf31455dd1458852` |
| 14 | `72af4a69dc7a4a8c5924348879c45258c9fd047fdcf325774a44ba025b781633` | `24b85a0a988cc5c7f76b9d74615e8c35d68f0d74bb323d89764b62b6a1233132` |
| 15 | `3c2386bfa626521b3ba4996c2191cefb6902728d9c1ec80c9bd18b8a7c30fa34` | `6060ea3ec4be6e5684247648357331687cf19d318fb493c802608099d89fd622` |
| 16 | `97458ea8106f57c08f45cc2f6d35611be28bd03e40dcc57431022e129a2d1bb9` | `2c7dbb2314d629d893c06757e9c960c155be26fb7dfcc6e95dcb3ac6751a2288` |
| 17 | `497f951e560567f3ed51b523ded8761dbad88e94fa347124e56ece7911b60cf4` | `97198fba598f07593c8b9af43619979916abc23956b60e591203c57a5664e85f` |
| 18 | `4018845b4baf9e1d3da8b49fc42d02b832771c952fb0616de956b13a150a4597` | `d3a77402e5dd1b77ac221b57f466b0ac1825934d022ea7318d42177b0cf3ffff` |
| 19 | `1ccbbd249025dfc5f5d8a05f60fa43933f023bd34cfa38d66d42d66bc066bbda` | `ee5073557e8b04df7f95c075a37edc7cbd1d00b731b2760c62a84c892afc3016` |

## Desktop, Android, and Steam Deck matrix

| Platform | Revision / package | Verified | Unavailable or open | Issue state |
| --- | --- | --- | --- | --- |
| Desktop Linux | Runtime tree at `f713cf7`; capture evidence at `f5b34f0` | headless suites, graphical captures, warmed frame-time/memory/count traces, generated-solid production-car impact, generation/construction budgets | physical controller is not a desktop substitute | desktop code-complete |
| Android SM-X710 | no fixed-revision APK; listed hash is historical only | historical export, manifest, ABI, and v2/v3 signing inspection | checkout `f713cf733874d706f08fbc480c958f4f2a2d9b23`, export a new APK, record its SHA-256, then install and validate hardware | #23 OPEN |
| Steam Deck | no fixed-revision Linux package; listed hashes are historical only | historical native package and ELF inspection | checkout `f713cf733874d706f08fbc480c958f4f2a2d9b23`, export new executable/PCK, record both SHA-256 values, then validate Gaming Mode hardware | #7 OPEN |

## Generation, construction, frame-time, memory, and object counts

Desktop evidence over seeds 0-19 reports placement p50/p95 of 60.512/73.193
ms against the unchanged 80 ms budget and runtime construction p50/p95 of
16.590/19.460 ms against the unchanged 100 ms budget. The warmed graphical
production-session traces are 240 frames per seed after a 120-frame warm-up:
seed 0 is 1,117 nodes and 526/260/174/174/96 visuals/batches/solid
visuals/colliders/chunks, with 16.636/17.651 ms p50/p95 at 40.363–40.377 MiB;
seed 4 is 1,437 nodes and 666/333/231/231/115 with 16.646/17.324 ms at
41.886–41.901 MiB; seed 9 is 1,570 nodes and 686/328/264/264/121 with
16.685/17.578 ms at 42.316–42.331 MiB. An earlier contended timing run was
discarded; these are the clean committed-head measurements.
See the [desktop evidence](evidence/offtrack-objects/desktop-validation.md)
for the raw trace and complete count breakdown.

Android and Steam Deck frame time, spikes, memory, thermal/TDP context, and
current object/collider observations are **not measured**. Historical Android
data in the issue #6 report predates this revision and is not used here.

## Driving observations

Desktop capture inspection confirms a dirt road, decorative shoulder, readable
recovery corridor, and a deeper tree or rock for seeds 0, 4, and 9. The new
desktop still also proves the production CCD car contacted generated tree
`v1:0:-10:1` in seed 0. No current Android or Steam Deck driving observation
exists. In particular, controller-only flow, full analog range/neutral return,
a valid lap, pause/reset/restart, recovery-corridor usability, focus/lifecycle,
and Android/Deck suspend-resume remain unverified on their required hardware.

## Captures

Desktop captures are [seed 0](evidence/offtrack-objects/seed-0.png),
[seed 4](evidence/offtrack-objects/seed-4.png), and
[seed 9](evidence/offtrack-objects/seed-9.png), each 1280x720 and reviewed in
a graphical session. No current-revision Android capture and no Steam Deck
Gaming Mode capture exists. The older Android images are retained in the
Android evidence report as historical evidence, not replacement proof.
The [generated-solid impact](evidence/offtrack-objects/seed-0-generated-solid-impact.png)
is also 1280x720, graphically captured, and visually inspected.

## Known limitations and open defects

- **Epic #1: OPEN.** The parent epic cannot close while either independent
  physical-platform gate below remains incomplete.
- Issue #23 is open: first check out the fixed behavior revision
  `f713cf733874d706f08fbc480c958f4f2a2d9b23`, export a new Android APK, and
  record its SHA-256. Only then may an SM-X710 with an external controller
  install and drive that recorded artifact across at least three seeds for ten
  minutes, recording performance/memory, current captures, lifecycle,
  collisions, and recovery-corridor observations.
- Issue #7 is open: first check out the same final approved revision, export a
  new Linux executable and PCK, and record both SHA-256 values. Only then may
  that recorded package be added as a non-Steam game and exercised in Steam
  Deck Gaming Mode at 1280x800 with built-in controls, including
  focus/pause/back and suspend/resume evidence.
- Installing, launching, deploying to either device, and changing GitHub issue
  or epic state were outside this reconciliation's authority and were not done.

## Go, conditional go, or no-go recommendation

**Conditional go for desktop code completeness; no-go for cross-platform
acceptance.** Desktop budgets/captures are evidence-backed, but no
final-revision Android or Steam Deck package has been produced. Android #23
and Steam Deck #7 must stay open until fresh artifacts are exported from the
same recorded final revision and their own physical hardware evidence is
collected. Desktop proof must not be averaged into a platform acceptance claim.
