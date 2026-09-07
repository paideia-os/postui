# postui — release manifest

**Wave:** postui v1  **Milestone:** M5-003  **Issue:** #37
**Upstream design:**
[`shell/design/release-manifest.md`](https://github.com/paideia-os/shell/blob/main/design/release-manifest.md)
(sibling satellite; shell.M5-001 is the reference implementation of the
dual-signer release pattern) and
[`paideia-os/design/tooling/plan.md`](https://github.com/paideia-os/paideia-os/blob/main/design/tooling/plan.md)
D4 (dual-signed install model) + §6.3 (repository model).
**Authoritative wire spec:**
[`pkg/design/manifest-format.md`](https://github.com/paideia-os/pkg/blob/main/design/manifest-format.md)
§4 — the KV codec is shared across every satellite in the tooling
wave; this document is postui's satellite-library-flavoured instance.

## 0. Reading order

- §1 — what a postui v1.0.0 release ships and where each artefact
  lands in the tarball.
- §2 — the release KV inventory postui emits into `manifest.pdxsig`.
- §3 — sigblock policy: ML-DSA-65 (primary, post-quantum) plus
  Ed25519 (secondary, classical) and why postui carries both.
- §4 — verification chain a `pkg install postui` performs and the
  key-fingerprint hand-off at `pkgs.paideia-os`.
- §5 — version discipline (semver + `postui-v1.0.0` tag) and how the
  version fields in `manifest.pdxproj` move.
- §6 — `CHANGELOG.md` / `STATUS.md` conventions this repo follows at
  every release.
- §7 — deferred substrate: what M5-003 stubs and what a later paideia-
  as round completes.

## 1. What a postui v1.0.0 release ships

postui is a satellite **library**, not an executable, so the tarball
layout differs from shell's in one respect: there is no `bin/postui`.
The `manifest_kind: satellite-library` field in `manifest.pdxproj`
(the M5-003 landing) tells the pkg-side decoder to expect the
following layout instead:

```
postui-v1.0.0.tar.gz
├── manifest.pdxsig             # this document's subject
├── lib/postui.a                # elaborated ar-archive of loose ELF64
│                               # objects (build-out/*.o, one per src)
├── include/postui.pdxdecl      # public symbol + widget-kind decl
├── caps.decl                   # library-visible cap grants (empty)
├── deps.list                   # transitive deps (libpdx-semantic-pipe)
└── doc/postui.pdxdoc           # M5-004 doc source
```

`pkg install postui` reads the manifest first, verifies both
signatures per §3, cross-checks the hashes for `caps.decl`,
`deps.list`, and every FILE_INVENTORY entry, and only then
extracts the tree into `/pkgs/postui-1.0.0/`. Downstream consumers
(`postui-top`, `postui-hex`, `postui-dmesg`, and any future TUI
app) then link against `/pkgs/postui-1.0.0/lib/postui.a` at their
own release time — the M5-003 hand-off is the point after which
the satellite apps stop rebuilding postui from source.

## 2. Release KV inventory

postui's `manifest.pdxsig` body ships the fourteen KV records
`shell/design/release-manifest.md` §2 defines, adjusted for the
library layout:

| # | Tag                     | Value for postui v1.0.0                           |
|---|-------------------------|---------------------------------------------------|
| 1 | `PKG_NAME`         (0x0001) | `"postui"` (6 bytes)                          |
| 2 | `PKG_VERSION`      (0x0002) | `"1.0.0"` (5 bytes; semver per §5)            |
| 3 | `PKG_REPO_URL`     (0x0003) | `"github.com/paideia-os/postui"` (29 bytes)   |
| 4 | `PAIDEIA_AS_VER`   (0x0004) | `"0.34"` (4 bytes; toolchain floor per M1)    |
| 5 | `AUTHOR_PUBKEY`    (0x0010) | 1952-byte ML-DSA-65 pubkey of `signer_author` |
| 6 | `AUTHOR_FPR`       (0x0011) | 32-byte sha3-256 fingerprint of AUTHOR_PUBKEY |
| 7 | `AUTHOR_EXPIRY`    (0x0012) | `0` (u64; 0 = never)                          |
| 8 | `ROOT_PUBKEY`      (0x0020) | 1952-byte ML-DSA-65 pubkey of `signer_root`   |
| 9 | `ROOT_FPR`         (0x0021) | 32-byte sha3-256 fingerprint of ROOT_PUBKEY   |
|10 | `ROOT_EXPIRY`      (0x0022) | `0` (u64; 0 = never)                          |
|11 | `CAPS_DECL_HASH`   (0x0030) | 32-byte sha3-256 of packaged `caps.decl`     |
|12 | `DEPS_LIST_HASH`   (0x0031) | 32-byte sha3-256 of packaged `deps.list`     |
|13 | `FILE_INVENTORY`   (0x0040) | one per file — see below                     |
|14 | `BUILD_REPRODUCER` (0x00F0) | UTF-8 attribution string                     |

The signer identities themselves live in `manifest.pdxproj`:

- `signer_author: snunez+postui-author@paideia-os.dev` — the
  postui maintainer key. Signs the manifest first; proves the
  tarball came from the postui repo owner.
- `signer_root: paideia-os-release-root@paideia-os.dev` — the
  org-wide R32 release root. Countersigns the manifest; proves the
  tarball reached the mainline `pkgs.paideia-os` distribution.

`FILE_INVENTORY` records (repeated tag 0x0040) enumerate:

- `lib/postui.a` (mode 0o644, sha3-256 of the ar-archive bytes)
- `include/postui.pdxdecl` (mode 0o644, sha3-256 of the decl file)
- `caps.decl` (mode 0o644, sha3-256 of the on-disk file)
- `deps.list` (mode 0o644, sha3-256 of the on-disk file)
- `doc/postui.pdxdoc` (mode 0o644, sha3-256 of the doc source)

The `caps.decl` / `deps.list` FILE_INVENTORY records duplicate the
hash in the standalone `CAPS_DECL_HASH` / `DEPS_LIST_HASH` tags —
the duplication is documented in `pkg/design/manifest-format.md`
§4.3 last paragraph and is intentional (fast-lookup optimisation
that saves a second inventory walk at install time).

## 3. Sigblock — dual signing

The sigblock covers the concatenation `header || body`. postui emits
**two** signatures per signer (author and root), one under each
algorithm, for a total of four signature records:

### 3.1 Primary signer — ML-DSA-65 (post-quantum)

- Algorithm: ML-DSA-65 at NIST security level 2 (3293-byte
  signatures; `RM_SIG_LEN_MLDSA65_L2` in shell's
  `src/release_manifest.pdx` — postui reuses that constant when its
  own encoder half lands).
- Rationale: post-quantum forward secrecy is the org-wide default
  per `paideia-os/design/security/pe-secure-boot-signing.md` §PBS-D1.
  Anything the paideia-os toolchain signs after
  v0.33-crypto-kdf gets an ML-DSA-65 signature; postui v1 is inside
  that horizon and inherits it.
- Signing key: private-key file held out-of-tree; the public key
  ships in the body as `AUTHOR_PUBKEY` / `ROOT_PUBKEY`.
- Signature envelope: pkg §4.4 layout (u32 length prefix + bytes).

### 3.2 Secondary signer — Ed25519 (classical)

- Algorithm: Ed25519 (RFC 8032), 64-byte signatures, 32-byte pubkey.
- Rationale: Ed25519 rides as a secondary signer so consumers that
  pre-date the paideia-as v0.33-crypto-kdf toolchain — or that
  fetch the tarball via a partner mirror whose verifier lacks the
  ML-DSA-65 code path — still have a classical-crypto path. This is
  the transitional-crypto pattern paideia-os follows across every
  signed artefact until the ecosystem is fully post-quantum. The
  Ed25519 signer's identity is the same email as the ML-DSA-65
  signer (author + root); the classical private key is derived from
  the same key-material pool but held in a separate file per
  `paideia-os/design/security/key-storage.md`.
- Signature envelope: pkg §4.4 layout (u32 length prefix + bytes),
  same shape as ML-DSA-65 but with `SIG_ALG = 0x0002` (Ed25519)
  instead of `0x0001` (ML-DSA-65).

### 3.3 Verification policy

`pkg install postui` verifies **all four** signatures (author-mldsa,
author-ed25519, root-mldsa, root-ed25519). Any single failure
refuses the install. `pkg install --from-source postui` skips the
author signatures (the user is building from verified source) but
still verifies the source-tree root against the author key per
`paideia-os/design/tooling/plan.md` D4 last paragraph.

A partner mirror configured with `--classical-only` (a compile-time
build flag on a non-Paideia distribution) verifies just the two
Ed25519 signatures. paideia-os's own `pkgs.paideia-os` mirror never
runs in this mode.

### 3.4 M5-003 placeholder

The M5-003 landing populates only the `manifest.pdxproj` fields
above and this design document. The actual encoder half (postui's
own `src/release_manifest.pdx`, mirroring shell's) lands as a
follow-up under a distinct issue once the shell reference
implementation stabilises. Until then, the sigblock stays
zero-filled behind correct length prefixes (3293 bytes per
ML-DSA-65 signature, 64 bytes per Ed25519 signature) so envelope
offsets remain measurable at release-lint time.

## 4. Verification chain

At install time `pkg install postui` walks the following chain:

1. **Fetch tarball** from `pkgs.paideia-os/postui/postui-v1.0.0.tar.gz`
   (the `mirror_target` field in `manifest.pdxproj`).
2. **Parse manifest** header + body per `pkg/design/manifest-format.md`
   §4. A parse error refuses fast, before any signature check.
3. **Fetch author fingerprint** — resolve `AUTHOR_FPR` (KV #6)
   against `pkgs.paideia-os/keys/snunez+postui-author@paideia-os.dev.fpr`.
   Fingerprint mismatch refuses.
4. **Fetch root fingerprint** — resolve `ROOT_FPR` (KV #9) against
   `pkgs.paideia-os/keys/paideia-os-release-root@paideia-os.dev.fpr`.
   Fingerprint mismatch refuses.
5. **Verify author signatures** — ML-DSA-65 and Ed25519 both against
   `AUTHOR_PUBKEY` (KV #5). Either failing refuses.
6. **Verify root signatures** — ML-DSA-65 and Ed25519 both against
   `ROOT_PUBKEY` (KV #8). Either failing refuses.
7. **Verify FILE_INVENTORY hashes** — sha3-256 every extracted file
   and compare against KV #13 records. Any mismatch refuses.
8. **Extract** into `/pkgs/postui-1.0.0/` and register with the
   local pkg database.

The fingerprint files at `pkgs.paideia-os/keys/*.fpr` are the trust
root. A first-use install pins them into
`/pkgs/.state/known-fingerprints.db`; subsequent installs compare
against the pinned value and refuse a silent fingerprint rotation.
Rotation requires the operator to `pkg fpr-rotate <signer>` with
the new fingerprint present in the manifest of a fresh tarball
signed by the previous fingerprint.

## 5. Version discipline

postui follows semver strictly:

- `PKG_VERSION` in `manifest.pdxsig` = `version` in
  `manifest.pdxproj` = git tag = tarball name. All four move
  together in a single commit at each release close.
- Pre-release versions use `-pre` / `-rcN` suffixes and DO NOT ship
  a signed tarball to `pkgs.paideia-os`. The M1 landing's
  `version = 0.1.0-pre` is an in-development marker; the first
  signed tarball is `postui-v1.0.0.tar.gz` at M5-006.
- The git tag has the format `postui-v<version>` (leading `postui-`
  disambiguates in monorepo tag listings and mirrors the
  paideia-as tag shape). M5-006 tags `postui-v1.0.0`.
- **Breaking** widget-record schema changes bump the major version
  and rotate the affected schema-hash constant in
  `src/semantic_registry.pdx` — the schema hash is the ABI-visible
  half of the version and the M5-001 conformance matrix
  (`docs/design.md` §5.1) verifies the tolerance rules.
- **Additive** widget-kind or field additions bump the minor
  version and leave existing schema hashes untouched.
- **Fix-only** releases bump the patch version.

## 6. CHANGELOG.md / STATUS.md conventions

### 6.1 STATUS.md

`STATUS.md` (already present at repo root) tracks the milestone
lattice and the version marker. At every release close (M5-006),
the version marker updates from `unreleased (pre-0.1.0)` to
`v1.0.0` and the milestone table's status column moves M5 to
`done`. `STATUS.md` never lists individual issue landings — that
is the CHANGELOG's job.

### 6.2 CHANGELOG.md

`CHANGELOG.md` lands at repo root under M5-006 and follows the
compact commit-message convention (per user memory
`feedback_compact_commit_messages.md`):

- Header per version: `## v1.0.0 — 2026-MM-DD`.
- Body: one bullet per milestone (M1..M5), each with a nested
  bullet per issue landing. No narrative bodies; story-like
  exposition lives in issue comments.
- Signature record: the final line of each version block lists the
  ML-DSA-65 + Ed25519 fingerprints that signed the tarball, in
  base64. This is the human-readable trust record for anyone who
  wants to cross-check the pinned fingerprints in
  `/pkgs/.state/known-fingerprints.db`.
- Cross-repo pointers: when a postui release requires a specific
  paideia-as toolchain floor (per `PAIDEIA_AS_VER` in the
  manifest) or a specific paideia-os kernel round (per the
  `KIND_TUI_CANVAS` substrate), the version block lists those
  pointers in a `Requires:` line at the top.

Example M5-006 skeleton:

```
## v1.0.0 — 2026-MM-DD

Requires: paideia-as v0.34+, paideia-os R89+.

- M1: skeleton + cell buffer + minimal Block widget (#1-#9)
- M2: layout + Paragraph/List/Table/Tabs (#10-#19)
- M3: charts + canvas (Fixed64 fixed-point) (#20-#26)
- M4: tree/calendar/textinput/input pipeline (#27-#34)
- M5: semantic-pipe hookup + release (#35-#40)

Signed by:
  author (ML-DSA-65): <base64 fingerprint>
  author (Ed25519):   <base64 fingerprint>
  root   (ML-DSA-65): <base64 fingerprint>
  root   (Ed25519):   <base64 fingerprint>
```

## 7. Deferred substrate

M5-003 lands the manifest fields and this design document. The
following substrate is deferred to distinct follow-up issues:

- **Encoder half.** postui's own `src/release_manifest.pdx` (mirror
  of `shell/src/release_manifest.pdx`) lands under a follow-up
  once shell's reference encoder stabilises. Until then, the
  release lint runs against a hand-crafted goldens fixture.
- **Test matrix.** `tests/test_release_manifest.pdx` (mirror of
  shell's `trm_run_all`) lands with the encoder half and gates the
  release-lint sequence per shell §4.
- **Mirror-push protocol.** The `pkgs.paideia-os` mirror itself is
  documented in `shell/design/mirror-push.md`; postui reuses that
  protocol verbatim, so no separate mirror-push doc lives in this
  repo.
- **Ed25519 signer bolt-on.** The paideia-as toolchain reaches
  Ed25519 signing at a separate crypto milestone from the
  ML-DSA-65 one. Until both are present, both signature slots
  ship zero-filled behind correct length prefixes.
