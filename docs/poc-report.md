# Cross-platform PoC report

Reconciled on 2026-08-30 (Europe/Helsinki). This report deliberately keeps
desktop reproducibility, Android hardware validation, and Steam Deck hardware
validation separate. It does not close issue #23 or issue #7.

## Revision and reproducible builds

Both platform lanes are pinned to
`0e0b90305dfe3510dd644e57f6be12eac452d915` (`docs: record non-vacuous
off-track validation`). The recorded pin had no tracked modifications. The
only change since the tested runtime revision
`412db6a1d3b285ba9cf7acb147bda7b5052058ab` is
`docs/evidence/offtrack-objects/desktop-validation.md`; the product/runtime
tree is therefore the same measured tree.

Godot `4.7.1.stable.official.a13da4feb` reproduced both exports locally:

| Target | Artifact | SHA-256 | Local inspection |
| --- | --- | --- | --- |
| Android Debug | `slicksnslide-fest-debug.apk` (28,527,062 bytes) | `0e98e78fe17ea4ff7bee4cacfcdc8a14c169bdb127d57ad8ee6b32a56a804819` | arm64-v8a; min SDK 24; target/compile SDK 36; v2/v3 signature verified |
| Linux x86_64 | `slicksnslide-fest.x86_64` (73,470,264 bytes) | `2cb27aee3f7fdf763d0ae16972f6975606959a071f4cd33f6ef1429eb8385049` | ELF x86-64, dynamically linked for GNU/Linux 5.15.0 |
| Linux data | `slicksnslide-fest.pck` (1,508,680 bytes) | `a33c0ff2294d9c4fd77506e3019854f2795bb152fa3e5f2ef93e69fa1a842f55` | paired with the Linux executable |

These ignored local build outputs are reproducibility checks, not installation,
launch, or platform acceptance evidence.

## Architecture and catalog version

Catalog version 1 uses deterministic per-cell placement after road acceptance.
Grass and debris occupy the 0-12 m decorative band; trees and rocks are solid
hazards only from 20-140 m, preserving the 20 m recovery corridor. Runtime
uses decorative batches and chunked static bodies, while each seed exposes a
separate SHA-256 road and object fingerprint. See [Off-track objects](offtrack-objects.md).

## Seeds 0-19 and fingerprints

The ledger was regenerated from the pinned runtime tree. Every road and object
fingerprint below is a 64-character SHA-256 value; deterministic placement
tests also verify that each object fingerprint repeats for the same seed.

| Seed | Road fingerprint | Object fingerprint |
| ---: | --- | --- |
| 0 | `c473c35414d6ee31c9abada0c4d5fe4856997f137ca8d7dd6223a45da29bf55f` | `04a02f965f1b5d84b6014caa57e377793a8133dfae7adc352dfde7be1dfd9bad` |
| 1 | `b4b5a88a8be258e58c43567bb2e1ffc9364f21c98bae38ee92e0a087de9fa90e` | `908a607c9c9f511ac9d06ca51339367f317541928699ea4d14dcd03db22a1874` |
| 2 | `d1e5d0df9651e041374342582d1cccf79193fe8ecb95796baac1eb19217bd7ea` | `c681efab831f057fa9fb08676b9c784463da6a86e650fbd35c6599922d70d5be` |
| 3 | `a1e4ab9b4425050a266ac40d2bb958b99d303303192c241c02b0822912ed078d` | `3c1877ec0ba5c5ea7377c5f371db1734a734c87c3812048ee089673a2803beae` |
| 4 | `4600dc93fe343e17e999276b333051a9538f51c50d02992863af9b4970779155` | `116e6e3ea7e45226c34deb079d39e2491ae527483c803999f0e7b9e39962fa80` |
| 5 | `8d530ec157495015293c77e77d2b3f9dfb458db272c3176b1f11bc9e495716b5` | `c97f4c62599e343be01e8805f46fee1d525882d654324cc663729ca1a0d6f17b` |
| 6 | `7fad0c2e88fccb083da767eba455a3b50ed248e8fea025fb43500d14e3ab04d9` | `f6bee7c9fdc3ca954bac765ff6136b69787c75d39dbd056699285dd1a9ecd200` |
| 7 | `ed6a92a5ee67e6e67f147fe6382bb266afe356d1de03cdc2322fdeb1d28c2af8` | `9a3965d30d5b18ddeb963f2af4b3acfdb2ecf2d598e21ecd159037a8d9987fd2` |
| 8 | `d0ff3f39294c44e16a182eabc0283b23842801ce6617c1f79a66001d93929aef` | `4eeeab9e0054dc4affd9a7345646f87f6ff797e52c08a97388b793eed20aa6f6` |
| 9 | `3fbe38ff1f6a222c0050cc004bddf93225b5da99176639d4b22f5934ece85670` | `1f14e7895cd92d4a92064fb738d2bdd27745ac01c3617d32245d1ebddb52d878` |
| 10 | `56c585fc00729f4416cd459c57e7b6821b101a83374f9bb2e7443f6633546c42` | `8ddad9c2bcdcf2d6ff84ee527b26f1a152fa72f45a307891b4960733f9c783a6` |
| 11 | `f0237efe220f89c01733e293d377a299f1c39b88843c992b5006bc0512ba51b0` | `48c71e92ee2f8217b13ac6699ec9a9d39f7e8dd908d9d38b1c7be16da7b26195` |
| 12 | `5331af0ca10b06d73cb47223caf72bebfa0c87c53df04951a395c24e2646976f` | `edbc6647b4e3540feb6ebf9f39885073118681bd2f26916d20a777a0e59b17ea` |
| 13 | `a3b44cf2ccee2206c308f0bdc1af8324e32767e59152061a174b887ad3db97a2` | `73df7e168391e177df4076970a094e361c0bf22fc859f0b8e3eeaab084378313` |
| 14 | `72af4a69dc7a4a8c5924348879c45258c9fd047fdcf325774a44ba025b781633` | `c83b678ccab714492feef65aeb509806c9ff9a91008b8d41954ba0394b0fe73a` |
| 15 | `3c2386bfa626521b3ba4996c2191cefb6902728d9c1ec80c9bd18b8a7c30fa34` | `0dc6c3f3d75708494a1ba46e511f49689b3c5095e76fdbc54f0dfb3d99a74677` |
| 16 | `97458ea8106f57c08f45cc2f6d35611be28bd03e40dcc57431022e129a2d1bb9` | `6b3e62db4057510204e904d1144829a0e6b8642f17f37f1972e881d516fd3a39` |
| 17 | `497f951e560567f3ed51b523ded8761dbad88e94fa347124e56ece7911b60cf4` | `4c74e42c6600b2dc9bc71446754000d27f762f7d949da59d04f8f83c15373fba` |
| 18 | `4018845b4baf9e1d3da8b49fc42d02b832771c952fb0616de956b13a150a4597` | `5c790565e6b18ec827e55dbd9e728046e3f855ef2b2e2cb284de2893d164f35a` |
| 19 | `1ccbbd249025dfc5f5d8a05f60fa43933f023bd34cfa38d66d42d66bc066bbda` | `8ba347b53c21a3cd7e714a2c71bfcb72964df2963086fc1fdec68d5448344626` |

## Desktop, Android, and Steam Deck matrix

| Platform | Revision / package | Verified | Unavailable or open | Issue state |
| --- | --- | --- | --- | --- |
| Desktop Linux | Runtime tree at pinned revision; desktop measurements recorded at `412db6a...` | headless suites, mutations, graphical captures, generation/construction budgets | physical controller is not a desktop substitute | desktop code-complete |
| Android SM-X710 | current APK hash above | export, manifest, ABI, and v2/v3 signing only | no connected device, controller, install, launch, current capture, collision, lifecycle, or 10-minute run | #23 OPEN |
| Steam Deck | current Linux binary and PCK hashes above | native package export and ELF inspection only | no Deck, Gaming Mode, built-in controls, non-Steam shortcut, capture, suspend/resume, or 10-minute run | #7 OPEN |

## Generation, construction, frame-time, memory, and object counts

Desktop evidence over seeds 0-19 reports placement p50/p95 of 53.816/67.803
ms against the 80 ms budget and runtime construction p50/p95 of 11.099/15.861
ms against the 100 ms budget. Placement count min/median/max is 507/628/722;
solid collider count is 192/224.5/286; decorative batch count is 236/308/340.
The desktop evidence records no sustained gameplay frame-time or memory trace.

Android and Steam Deck frame time, spikes, memory, thermal/TDP context, and
current object/collider observations are **not measured**. Historical Android
data in the issue #6 report predates this revision and is not used here.

## Driving observations

Desktop capture inspection confirms a dirt road, decorative shoulder, readable
recovery corridor, and a deeper tree or rock for seeds 0, 4, and 9. No current
Android or Steam Deck driving observation exists. In particular, controller-only
flow, full analog range/neutral return, a valid lap, pause/reset/restart,
tree-and-rock collision, recovery-corridor usability, focus/lifecycle, and
Android/Deck suspend-resume remain unverified on their required hardware.

## Captures

Desktop captures are [seed 0](evidence/offtrack-objects/seed-0.png),
[seed 4](evidence/offtrack-objects/seed-4.png), and
[seed 9](evidence/offtrack-objects/seed-9.png), each 1280x720 and reviewed in
a graphical session. No current-revision Android capture and no Steam Deck
Gaming Mode capture exists. The older Android images are retained in the
Android evidence report as historical evidence, not replacement proof.

## Known limitations and open defects

- Issue #23 is open: an SM-X710 with an external controller must install and
  drive the exact Android APK above across at least three seeds for ten minutes,
  then record performance/memory, current captures, lifecycle, collisions, and
  recovery-corridor observations.
- Issue #7 is open: the exact Linux package above must be added as a non-Steam
  game and exercised in Steam Deck Gaming Mode at 1280x800 with built-in
  controls, including focus/pause/back and suspend/resume evidence.
- Installing, launching, deploying to either device, and changing GitHub issue
  or epic state were outside this reconciliation's authority and were not done.

## Go, conditional go, or no-go recommendation

**Conditional go for desktop code completeness; no-go for cross-platform
acceptance.** The current revision is reproducibly exportable and desktop
budgets/captures are evidence-backed. Android #23 and Steam Deck #7 must stay
open until their own physical hardware evidence is collected at this identical
revision. Desktop proof must not be averaged into a platform acceptance claim.
