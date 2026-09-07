# postui — architecture

**Wave:** postui v1 (Ratatui-parity TUI widget library)
**Repo:** github.com/paideia-os/postui
**Upstream design:** `docs/design.md` §§1–5 (authoritative external spec).

This document describes the internal shape of the postui library at
commit tip. It does not repeat the wave-level rationale from
`docs/design.md` (feasibility analysis, Ratatui divergence, cross-repo
plan); read that first for the *why*. This document is the *what and
how*: which module owns which invariant, where the error bands live,
what the M1 landing pattern is, and which pieces are scaffold-only
awaiting later M1 issues.

postui is a **userspace library**, not a binary. It has no `_start`,
no `main`, and no ELF entry. Every ring-3 consumer (postui-top,
postui-hex, postui-dmesg, plus any future TUI app) links postui's
loose ELF64 objects into its own binary; the "public surface" is
therefore the module-and-function surface `manifest.pdxproj`
declares — not a CLI or a REPL loop. This inverts the shape shell's
own `architecture.md` starts from and is called out at every §2.x
sub-header so a reader from that document does not silently import
its assumptions.

## 1. Public surface

The M1 module set (10 files under `src/`, all enumerated in
`manifest.pdxproj:sources:`) breaks into three tiers by landing
status at commit tip:

**Tier A — full body landed (M1-001..M1-004):**

- `Lib` (`src/lib.pdx`) — library identity + error-band anchor
  (`POSTUI_VERSION_*`, `POSTUI_ERR_BAND_BASE`, `POSTUI_OK`). M1-001.
- `Rect` (`src/rect.pdx`) — packed-u64 (x,y,w,h) terminal geometry
  primitive. `rect_new`, `rect_x/y/w/h`, `rect_contains`,
  `rect_intersect`, `rect_area`. M1-002.
- `Style` (`src/style.pdx`) — packed-u64 (fg,bg,mods,pad) style
  aggregate. `style_new`, `style_with_fg`, `style_with_bg`,
  `style_add_modifier`. M1-002.
- `Color` (`src/color.pdx`) — packed-u64 24-bit truecolor triplet.
  `color_from_rgb`, `color_to_index` (xterm 6x6x6 cube), `color_lerp`
  (0..256 blend). M1-002.
- `Cell` (`src/cell.pdx`) — 16-byte cell wire-format helpers.
  `cell_write`, `cell_symbol/fg/bg/mods/style`, `cell_set_symbol`,
  `cell_set_style`, `cell_copy`, `cell_equal`. M1-003.
- `Buffer` (`src/buffer.pdx`) — back/front region layout over a
  `KIND_TUI_CANVAS` `memory_slot`. `buffer_region_bytes`,
  `buffer_bytes`, `buffer_at`, `buffer_at_front`, `buffer_set`,
  `buffer_clear`. M1-003.
- `TuiCanvasClient` (`src/tui_canvas_client.pdx`) — M1-001 seeded
  constants (`TCC_KIND_TUI_CANVAS = 0x1A6`, `TCC_OP_*`, `TCC_R_TUI_*`,
  kernel-side error-band mirror at `0xFFFFEB1x`). M1-004 added the
  eight `sys_cap_invoke` wrapper bodies: `tcc_present`,
  `tcc_query_rows`, `tcc_query_cols`, `tcc_query_id`,
  `tcc_query_tty_id`, `tcc_resize`, `tcc_clear`, `tcc_debug_print`.
  Mint remains caller-owned (see §2.7).

**Tier B — scaffold-only (M1-001 seeded constants; bodies land at
their own M1 issue):**

- `Frame` (`src/frame.pdx`) — terminal-state ordinals
  (`FRAME_STATE_*`, `FRAME_INPUT_*`) only. `Terminal::init`,
  `Terminal::next_event`, `Frame::render` land at M1-005.
- `Block` (`src/block.pdx`) — `BLOCK_BORDER_*` ordinals plus
  `BLOCK_PADDING_MAX`. `BlockSpec` struct + `block_draw` body +
  `BlockView@0.1` schema land at M1-006.
- `WidgetKind` (`src/widget_kind.pdx`) — `WK_*` widget ordinals and
  `WK_COUNT = 15`. Closed `WidgetKind` enum + `widget_draw` dispatch
  land at M1-007.

**Tier C — future waves (not present as files at commit tip):** every
M2..M5 module (Layout, Text/Span/Line, Width, Paragraph, List, Table,
Tabs, Scrollbar, Fixed64, Gauge, Sparkline, BarChart, Chart, Canvas,
Tree, Calendar, TextInput, Event/parser, semantic-pipe registry
wiring) lands in its own PR against its own milestone per
`docs/design.md` §5.1.

## 2. Module details

### 2.1 `Lib` module (src/lib.pdx) — M1-001

**Purpose.** The library-identity anchor and the single point of
authority for the postui-side error-band base. Ships two classes of
symbols and nothing else: the version triple every consumer can
compare against at compile time, and the wave-scoped
`POSTUI_ERR_BAND_BASE` every postui error return uses as a
high-nibble discriminator.

**Constants.**

- `POSTUI_VERSION_MAJOR/MINOR/PATCH : u64` — three u64 slots
  (`0.1.0`-shaped pre-release) rather than a packed triple so a
  consumer's runtime version check stays a plain integer compare.
  The human-facing authority is `manifest.pdxproj`'s `version` field
  (currently `0.1.0-pre`); these constants get bumped in lockstep at
  every release (M5 is the first tagged release).
- `POSTUI_ERR_BAND_BASE : u64 = 0xFFFFEB80` — the high-nibble anchor
  for every postui-side (library, not kernel) error return. Disjoint
  from the kernel's KIND_TUI_CANVAS band (`0xFFFFEB10..0xFFFFEB1F`)
  and from `KIND_SIG_KEY`'s `0xFFFFEB00..0F`. A consumer switching
  on `>> 8` can attribute a refusal to the right layer (postui
  library / kernel `cap_handler_tui_canvas` / kernel `cap_handler_tty`)
  without a full-value table lookup.
- `POSTUI_OK : u64 = 0` — the universal success sentinel every
  callable in the library returns on the happy path.

**Design-time deviation from `docs/design.md`.** §2.1 of the external
spec assigned `0xFFFFEC40..0xFFFFEC4F` to the KIND_TUI_CANVAS failure
band; that page was subsequently reclaimed by
`KIND_NVME_CONTROLLER`, and the actual kernel landing moved to
`0xFFFFEB10..0xFFFFEB1F` (see the deviation note at the top of
`src/kernel/core/cap/kind_tui_canvas.pdx` in the paideia-os monorepo).
`POSTUI_ERR_BAND_BASE` follows: `0xFFFFEB80` is the next free slot
in the same page that keeps clear of both KIND_SIG_KEY and the
KIND_TUI_CANVAS kernel mirror without straying into an unrelated
page. `docs/design.md` §2.1 has not yet been amended; this document
records the discrepancy explicitly so a later docs-edit pass can
close the loop.

### 2.2 `Rect` module (src/rect.pdx) — M1-002

**Purpose.** Integer terminal-cell geometry. Every layout, every
widget region, every clip rectangle in the library flows through a
`Rect`.

**Packed wire (RECT_BYTES = 8).** One u64 packs four u16 fields:

```
bits [ 0..16)  x   column of top-left cell    (0..RECT_DIM_MAX)
bits [16..32)  y   row of top-left cell       (0..RECT_DIM_MAX)
bits [32..48)  w   width in cells             (0..RECT_DIM_MAX)
bits [48..64)  h   height in cells            (0..RECT_DIM_MAX)
```

`RECT_DIM_MAX = 4096` mirrors `TUI_DIM_MAX` in the kernel-side cap
row (docs/design.md §2.1); the packed shape means a `Rect` passes
and returns in a single GPR with no memory traffic.

**Callable surface.**

```
rect_new(x, y, w, h) -> u64            // pack; every field masked to 16b
rect_x(r) -> u64                       // unpack x
rect_y(r) -> u64                       // unpack y
rect_w(r) -> u64                       // unpack w
rect_h(r) -> u64                       // unpack h
rect_contains(r, px, py) -> u64        // half-open [x,x+w) x [y,y+h) test
rect_intersect(a, b) -> u64            // AABB intersection; empty -> 0
rect_area(r) -> u64                    // w * h
```

Every field is masked before shift so an out-of-bound argument
truncates deterministically rather than corrupting a neighbour. A
zero-area rect (w==0 or h==0) contains no point and intersects to
zero. `rect_intersect` returns the zero-Rect (0) on non-overlap; a
caller distinguishing "did they overlap?" tests `rect_w`/`rect_h` of
the return, not the packed word (a legitimate (0,0,0,0) input is
indistinguishable from a non-overlap by the packed word alone —
documented, not a bug).

**Effect row.** `!{} @{}` throughout — every callable is a pure
register-only leaf, no memory access, no push/pop except
`rect_intersect` (5 callee-save pushes = 40 bytes; entry rsp%16==8,
+40==48, 16-byte-aligned before any nested call — the 5-push shape
matches the `madt.pdx` precedent and hardens against a future edit
that adds a nested call, even though the body has none today).

### 2.3 `Style` module (src/style.pdx) — M1-002

**Purpose.** Visual-attribute aggregate that mirrors, in one register,
the fg + bg + mods span a `Cell` writes into its bytes 4..11.

**Packed wire (STYLE_BYTES = 8).**

```
bits [ 0..24)  fg    24-bit truecolor Color-packed
bits [24..48)  bg    24-bit truecolor Color-packed
bits [48..56)  mods  STYLE_MOD_* bitflags (8 bits)
bits [56..64)  pad   reserved zero (future 9th modifier / hyperlink id)
```

Byte-for-byte identical to Cell's bytes 4..12 in little-endian
memory — the load-bearing property `cell_set_style` exploits to
write fg+bg+mods+one-reserved-zero as a single 8-byte store instead
of seven per-byte writes.

**Modifier bitflags.** Eight single-bit values in the mods byte —
`STYLE_MOD_BOLD` (0x01), `STYLE_MOD_ITALIC` (0x02),
`STYLE_MOD_UNDERLINE` (0x04), `STYLE_MOD_DIM` (0x08),
`STYLE_MOD_CROSSED_OUT` (0x10), `STYLE_MOD_SLOW_BLINK` (0x20),
`STYLE_MOD_RAPID_BLINK` (0x40), `STYLE_MOD_REVERSED` (0x80). Composed
with `|`. HIDDEN is dropped from Ratatui's 9-flag set at v1 scope
(docs/design.md §2.1); the reserved pad byte holds space for it and
one future flag (hyperlink id) without breaking wire width.

**Callable surface.**

```
style_new(fg, bg, mods) -> u64         // pack; every field pre-masked
style_with_fg(style, color) -> u64     // replace fg slot; bg/mods preserved
style_with_bg(style, color) -> u64     // replace bg slot; fg/mods preserved
style_add_modifier(style, mod) -> u64  // OR-in mods bits; pad protected
```

Every setter is a pure register-only leaf. `style_with_fg` uses
`shr 24; shl 24` to zero the fg slot rather than an `and reg, imm64`
mask; `style_with_bg` composes the two preserved slabs (low 24 fg,
top 16 mods+pad) separately and ORs — both avoid the imm32 ceiling
on `and`.

### 2.4 `Color` module (src/color.pdx) — M1-002

**Purpose.** 24-bit truecolor triplet and helpers. postui is
truecolor-only at v1 (docs/design.md §2.1 wire-format freeze); no
16-color / 256-palette tier is stored anywhere. `color_to_index`
projects to xterm-256 for callers rendering to a legacy SGR sink but
that index is never stored in a Cell.

**Packed wire (COLOR_BYTES = 3).**

```
bits [ 0.. 8)  r   0..255
bits [ 8..16)  g   0..255
bits [16..24)  b   0..255
bits [24..64)  0   reserved zero — Cell reads exactly 3 bytes
```

Same channel order Cell's fg/bg slots use; a `color_from_rgb` output
OR-slotted at bit 0 (fg) or bit 24 (bg) of a Style produces the
correct wire layout with one shift + one OR.

**Callable surface.**

```
color_from_rgb(r, g, b) -> u64          // r | g<<8 | b<<16; masks per byte
color_to_index(r, g, b) -> u64          // xterm 6x6x6 cube approx
color_lerp(a, b, t) -> u64              // (256-t)*a + t*b >> 8 per channel
```

`color_to_index` quantizes each channel as `c / 51` yielding
{0..5} — the nearest fixed-step approximation to the xterm palette's
non-uniform steps {0, 95, 135, 175, 215, 255}. The 232..255 greyscale
ramp is not used; a future higher-fidelity mapping can replace the
quantizer without changing the API surface.

`color_lerp` uses a 0..256 blend factor (not 0..255) so `256 - t`
fits an imm32 subtract without a `-1` correction and the divide is
a pure `shr 8`. `t > 256` clamps to 256 (saturate at b rather than
wrap).

### 2.5 `Cell` module (src/cell.pdx) — M1-003

**Purpose.** Serialize and inspect one 16-byte cell in the back or
front buffer. The postui-side counterpart to the kernel-side diff
step at `TUI_OP_PRESENT`: user-space writes cells here, kernel reads
them there.

**Wire format (CELL_BYTES = 16, docs/design.md §2.1).**

```
[+0..+4)   symbol    u32   Unicode codepoint (little-endian)
[+4..+7)   fg        [3]u8 Color-packed truecolor triple
[+7..+10)  bg        [3]u8 Color-packed truecolor triple
[+10..+11) mods      u8    STYLE_MOD_* bitflags
[+11..+16) reserved  [5]u8 zero on the wire
```

Named offset/length constants (`CELL_OFF_SYMBOL`, `CELL_LEN_FG`, …)
expose the layout to downstream readers so displacements never live
as raw numerals in a body. Field widths sum to 16 by construction.

**Two-word memory layout.** Cell is intrinsically pointer-shaped
(16 bytes exceeds one GPR); the two 8-byte words in little-endian
memory break as:

```
word0 (dst+0):  symbol[32] | fg.r[8] | fg.g[8] | fg.b[8] | bg.r[8]
word1 (dst+8):  bg.g[8]    | bg.b[8] | mods[8] | reserved[40] (zero)
```

The bg triple straddles the 8-byte boundary — `cell_write` handles
this with one word-split and two stores rather than 10+ byte-writes.

**Callable surface.**

```
cell_write(dst, sym, fg, bg, mods)     // build & store both words
cell_symbol(src) -> u64                 // u32 codepoint, zero-extended
cell_fg(src) -> u64                     // Color-packed fg
cell_bg(src) -> u64                     // Color-packed bg
cell_mods(src) -> u64                   // mods byte, zero-extended
cell_style(src) -> u64                  // Style-packed fg|bg|mods|0
cell_set_symbol(dst, sym)               // 4-byte store; other fields safe
cell_set_style(dst, style)              // one 8-byte store (see Style §2.3)
cell_copy(dst, src)                     // 16-byte copy = 2 qword pairs
cell_equal(a, b) -> u64                 // 1 if 16 bytes match, else 0
```

Every byte-load uses the `xor rax, rax; mov_b rax, [ptr]` idiom (or
its `mov_d` counterpart) even where x86_64 auto-zero-extension would
suffice — defense in depth against a paideia-as encoder revision
that ever elects a sign-extending form (matches the
`pdxfs_lite/write.pdx` convention from R25-M2-005). Reserved bytes
participate in `cell_equal` verbatim; a caller that broke the
reserved-zero invariant on one side will (correctly) see inequality.

**Effect row.** `!{mem} @{}` on every callable — Cell is
intrinsically memory-touching.

### 2.6 `Buffer` module (src/buffer.pdx) — M1-003

**Purpose.** Address arithmetic and bulk moves over the back/front
region layout that sits inside a `KIND_TUI_CANVAS`'s parent
`memory_slot`.

**Region layout (docs/design.md §2.1).** For a canvas of `rows` x
`cols`, one region is `N = rows * cols * 16` bytes; two regions live
back-to-back in the same mapped range:

```
[0, N)     back buffer   — client-writable; every widget draws here
[N, 2N)    front buffer  — kernel-owned "last emitted"; client may
                            read for local diff heuristics but MUST
                            NOT write (only TUI_OP_PRESENT copies
                            back->front once a frame lands on TTY)
```

Cells within each region are row-major: `(x, y)` lives at byte
offset `(y * cols + x) * 16`.

**Named ordinals.**

- `BUFFER_REGION_BACK = 0`, `BUFFER_REGION_FRONT = 1` —
  region ordinals; downstream code names regions symbolically rather
  than by magic 0/1.
- `BUFFER_REGION_COUNT = 2` — locked; a hypothetical triple-buffer
  variant would revise the KIND_TUI_CANVAS wire and bump postui
  major, not add a third region under the same cap.
- `BUFFER_CELL_BYTES = 16` — re-exported so a caller does not have
  to `import Cell`. Byte-for-byte matches `Cell::CELL_BYTES`; both
  read the same literal from docs/design.md §2.1 rather than one
  importing the other's constant.

**Callable surface.**

```
buffer_region_bytes(rows, cols) -> u64  // rows * cols * 16
buffer_bytes(rows, cols) -> u64         // 2 * rows * cols * 16
buffer_at(buf, rows, cols, x, y) -> u64        // back-region cell addr
buffer_at_front(buf, rows, cols, x, y) -> u64  // front-region cell addr
buffer_set(buf, rows, cols, x, y, src)         // copy 16B src -> back(x,y)
buffer_clear(buf, rows, cols, src)             // fill back with 16B src
```

`buffer_at` takes `rows` as a signature parameter even though the
back region starts at `buf + 0` (arithmetic uses only `cols`, `x`,
`y`). The unused parameter buys API symmetry with `buffer_at_front`
(which needs `rows` to skip past the back region) — worth the
one-register move at each call site.

**Bounds discipline.** No bounds check inside Buffer. Every producer
of an `(x, y)` pair (Frame::draw, widget_draw dispatch) clamps
against the canvas's stamped `rows`/`cols` at its own layer; adding
a gate here would double-charge every cell write.

**Deliberate omission.** No `buffer_diff_present` in this module.
Per docs/design.md §2.1 the back-vs-front diff and the resulting
SGR/cursor emit path is kernel-side (TUI_OP_PRESENT, op 0 of
`cap_handler_tui_canvas`); user-space PRESENT is a single
`cap_invoke(canvas_cap, TUI_OP_PRESENT, 0)` trampoline landing at
M1-004 in `TuiCanvasClient`.

**Effect row.** `!{} @{}` on pure address arithmetic (`buffer_at`,
`buffer_at_front`, size helpers). `!{mem} @{}` on `buffer_set` and
`buffer_clear` which write through the returned pointer.

### 2.7 `TuiCanvasClient` module (src/tui_canvas_client.pdx) — M1-001 constants + M1-004 wrappers

**Purpose.** The user-space cap-invoke wrappers for `KIND_TUI_CANVAS`
ops. Higher-level modules (`Frame` at M1-005) go through this so the
raw `(sysno, slot, op)` triple is encoded in exactly one place — the
same discipline `shell`'s `Syscall` module applies to the SC+ IDs it
mirrors.

**Constants (landed at M1-001).**

- `TCC_KIND_TUI_CANVAS : u64 = 0x1A6` — mirror of the authoritative
  kernel ordinal (paideia-os R89.M1-001; docs/design.md §2.1). The
  `TCC_` prefix flags the mirror invariant, same shape shell's
  `SH_KIND_*` uses.
- `TCC_OP_PRESENT/QUERY_ROWS/QUERY_COLS/QUERY_ID/QUERY_TTY_ID/
  RESIZE/CLEAR/DEBUG_PRINT : u64 = 0..7` — the eight-op dispatch
  ordinal set from docs/design.md §2.1.
- `TCC_R_TUI_PRESENT` (0x002), `TCC_R_TUI_INVOKE` (0x008),
  `TCC_R_TUI_RESIZE` (0x010), `TCC_R_TUI_REVOKE` (0x020),
  `TCC_R_TUI_MINT` (0x200), `TCC_R_TUI_OBSERVE` (0x400),
  `TCC_R_TUI_ALL` (0x63A) — rights bits (mirrors kernel-side
  `R_TUI_*`).
- `TCC_ERR_BAND_BASE = 0xFFFFEB10`, `TCC_ERR_BAND_TOP = 0xFFFFEB1F`
  plus eight named sentinels (`TCC_ERR_TAIL_ENOSPC`,
  `TCC_ERR_MINT_BAD_MEMORY`, `TCC_ERR_MINT_BAD_TTY`,
  `TCC_ERR_MINT_BAD_DIMS`, `TCC_ERR_MINT_BAD_SIZE`,
  `TCC_ERR_BAD_SLOT`, `TCC_ERR_BAD_RIGHTS`,
  `TCC_ERR_REVOKE_ALREADY`) — byte-for-byte mirror of
  `kind_tui_canvas.pdx`. See §2.1 deviation for the band's real
  address.
- `TCC_SYS_CAP_INVOKE : u64 = 4` — SC+ sysno mirror for
  `sys_cap_invoke` (design/user/syscall-table.md row 4, paideia-os).
  Held in exactly one named constant so the eight wrappers all name
  the SYSCALL entrance uniformly.

**Wrapper surface (landed at M1-004).**

```
tcc_present(canvas_cap)                              -> u64   ! op 0
tcc_query_rows(canvas_cap)                           -> u64   ! op 1
tcc_query_cols(canvas_cap)                           -> u64   ! op 2
tcc_query_id(canvas_cap)                             -> u64   ! op 3
tcc_query_tty_id(canvas_cap)                         -> u64   ! op 4
tcc_resize(canvas_cap, rows, cols)                   -> u64   ! op 5
tcc_clear(canvas_cap, cell_hi, cell_lo)              -> u64   ! op 6
tcc_debug_print(canvas_cap, msg_ptr, msg_len)        -> u64   ! op 7
```

Each wrapper is a leaf function (no push/pop, no local frame, no
nested call), 3-7 instructions. Effect row `!{sysreg} @{cap}` matches
`syscall_shim.pdx`'s `sys_cap_invoke` exactly — the kernel-side
transitive widening (e.g. `{mem,sysreg,PortIo} @{cap,paideia.port_io}`
for the PRESENT path) belongs to `cap_handler_tui_canvas.pdx`, not
this userspace wrapper.

The wrappers return the kernel's `u64` verbatim — 0 for success on
mutators, a u64 payload for QUERY ops, one of the `TCC_ERR_*` codes
from the `0xFFFFEB1x` band on refusal (or
`INVOKE_RESULT_INVALID_HANDLE = 0xFFFFFFFFFFFFFFFE` if `canvas_cap`
does not name a live row). No errno translation is performed;
postui's higher layers (Frame at M1-005) read `TCC_ERR_*` directly,
matching the same "raw kernel u64 through" convention shell's
`Syscall` applies to SC+ IDs.

**Calling convention.** Arity-2 wrappers (`tcc_present` through
`tcc_query_tty_id`) take SysV `rdi=canvas_cap`, load `rsi` with the
op ordinal, `rax` with the SC+ ID (4), and issue `syscall`. Arity-4
wrappers (`tcc_resize`, `tcc_clear`, `tcc_debug_print`) apply the
standard Linux `rcx -> r10` shuffle in-order — `mov r10, rdx;
mov rdx, rsi; mov rsi, <op>; mov rax, 4; syscall; ret` — moving
SysV arg3 into the SYSCALL arg3 slot before overwriting rsi/rax.
Same pattern shell's `syscall.pdx sys_wait4` uses.

**Kernel-side landing note.** At the M1-004 landing tip,
`cap_handler_tui_canvas.pdx` implements PRESENT / QUERY_ROWS /
QUERY_COLS / QUERY_ID / QUERY_TTY_ID as real bodies (paideia-os
R89.M1-002/003); RESIZE / CLEAR / DEBUG_PRINT dispatch through
rights-checked stubs returning 0. The wire-compatible wrappers pass
`rdx`/`r10` in their SYSCALL slots so the eventual R89.M1-004
`canvas_damage.pdx` real bodies consume them without a client
change.

**Mint deferred (caller-owned).** `KIND_TUI_CANVAS_MINT` is a
`KIND_CAP_TABLE`-level op invoked via libpdx-cap's `cap_mint_write`
against a `KIND_MEMORY` parent + `KIND_TTY` `tty_slot`. That path
belongs to the tool caller (shell, or an app's own init sequence),
mediated by the caller's own libpdx-cap linkage. postui only
invokes ops on an already-minted canvas cap handed to Frame at
M1-005. Same posture shell's `Session` takes for KIND_IPC_ENDPOINT:
the shell mints, higher layers only invoke.

### 2.8 `Frame` module (src/frame.pdx) — M1-001 scaffold; bodies M1-005

**Purpose.** The runtime driver loop — `Terminal::init` (with the
KIND_TTY raw-mode probe / `sys_read(0)` fallback from
docs/design.md §2.5), `Terminal::next_event`, and the
`Frame::render(widget, area)` per-widget dispatch entry the app-loop
in docs/design.md §2.7 goes through.

**Landed at commit tip (constants only).**

- Terminal-state ordinals — `FRAME_STATE_UNINITIALIZED = 0`,
  `FRAME_STATE_INITIALIZED = 1`, `FRAME_STATE_FAULTED = 2`. Named
  rather than positional so a downstream trace / stat counter stays
  readable. `Terminal::init` transitions UNINITIALIZED -> INITIALIZED
  on success or -> FAULTED on any unrecoverable error, and every
  subsequent op checks the FAULTED state before touching the
  canvas.
- Input-path discriminator — `FRAME_INPUT_KIND_TTY = 1`,
  `FRAME_INPUT_SYS_READ_FALLBACK = 2`. `Terminal::init` sets this
  once and every `Terminal::next_event` reads it to pick the right
  transport. M4-007 tracks removal of the fallback once paideia-os
  #1986 (R66v2.POS-001, `TTY_OP_READ`) lands.

**Deferred to M1-005 (driver bodies).** `Terminal::init(rows, cols,
memory_cap, tty_cap, canvas_cap_dst)` — probes the TTY, mints the
canvas over the memory slot via `TuiCanvasClient::tcc_mint`, clears
the front-buffer to force a first-frame full repaint. `Frame::render`
walks a widget list, dispatches each through `widget_draw`, and issues
one `TCC_OP_PRESENT`. `Terminal::next_event` blocks on the chosen
input transport and returns the decoded `Event`.

### 2.9 `Block` module (src/block.pdx) — M1-001 scaffold; body M1-006

**Purpose.** The smallest widget in the catalog — border + title +
padding container. docs/design.md §2.6 lists Block as XS-effort and
notes that every heavier widget composes a Block inside its own
render body, so landing Block first minimizes the number of
unimplemented dependencies at M1-008 boot smoke.

**Landed at commit tip (constants only).**

- Border-kind ordinals — `BLOCK_BORDER_NONE = 0`,
  `BLOCK_BORDER_PLAIN = 1`, `BLOCK_BORDER_ROUNDED = 2`,
  `BLOCK_BORDER_DOUBLE = 3`, `BLOCK_BORDER_THICK = 4` — the exact
  set docs/design.md §5.1 M1-006 scope lists ("borders: plain /
  rounded / double / thick"). Fixed closed set at v1; a future
  custom-glyph tuple surface would add a variant and a paired
  constant tuple in M1-006 without touching downstream dispatch.
- `BLOCK_PADDING_MAX : u64 = 128` — hard integer ceiling on padding
  per side. The M1-006 struct body rejects a padding request that
  would leave zero interior cells, a runtime check stricter than
  this constant.

**Deferred to M1-006 (body).** The `BlockSpec` struct (borders +
title bytes + padding tuple), `block_draw(area, buf, spec)` writing
borders / title / inset padding into the back-region cells, and the
`BlockView@0.1` semantic-pipe record (title text, border kind) the
draw call emits alongside the cell writes.

### 2.10 `WidgetKind` module (src/widget_kind.pdx) — M1-001 scaffold; body M1-007

**Purpose.** The closed-enum + one-dispatch-function architecture
docs/design.md §1.2 substitutes for Ratatui's trait-object
`Widget`/`StatefulWidget` model. Adding widget #31 is one new variant
here and one new case in `widget_draw` — the same shape KIND_TTY's
`cap_handler_tty` already uses for its six ops.

**Landed at commit tip (constants only).**

Widget-kind ordinals, matching docs/design.md §2.6 catalog order:

```
WK_BLOCK      = 0    WK_GAUGE       = 5    WK_TREE       = 10
WK_PARAGRAPH  = 1    WK_SPARKLINE   = 6    WK_CALENDAR   = 11
WK_LIST       = 2    WK_BARCHART    = 7    WK_SCROLLBAR  = 12
WK_TABLE      = 3    WK_CHART       = 8    WK_TEXTINPUT  = 13
WK_TABS       = 4    WK_CANVAS      = 9    WK_CLEAR      = 14
```

`WK_COUNT : u64 = 15` locks the cardinality; a dispatch table's
static-array reservation keys on this constant so a future `WK_*`
addition is caught by a compile-time size check rather than silently
over-indexing an out-of-date table. An existing ordinal never
changes semantic identity — postui MINOR bumps at every widget
addition, and adding widget #16 reserves ordinal 15 fresh past the
current top.

**Deferred to M1-007 (enum + dispatch).** The closed `WidgetKind`
enum (15 variants, each carrying its widget-specific spec struct;
docs/design.md §1.2 example), and the `widget_draw(kind, area, buf)`
dispatch function that pattern-matches on the variant. At M1-007 only
the `WK_BLOCK` arm invokes a real draw body (`Block::block_draw` from
M1-006); the other 14 arms stub `unimplemented` until their M2..M4
widget-body PRs land — the same phased pattern shell's `Dispatch`
uses (four handlers landed at ENH-004, table slot reserved for 12
more).

## 3. Draw lifecycle

postui adopts Ratatui's immediate-mode model in full (docs/design.md
§2.2): no retained scene graph, no persistent widget-tree state
across frames, recompute a `Buffer` of `Cell`s from application state
every tick. The kernel owns the only diff.

**App tick shape (target; every step past the widget-list build is
deferred to its own M1 landing):**

```
1. app.handle(event)                  ; app-defined state transition
2. widgets = build_widget_tree(state) ; a plain list of (WidgetKind, Rect)
3. for (widget, area) in widgets:
     widget_draw(widget, area, canvas.back_buffer)   ; M1-007 dispatch
                                                     ; each variant writes
                                                     ; cells via cell_write
                                                     ; / cell_set_* through
                                                     ; buffer_at
4. tcc_present(canvas_cap, 0)         ; one cap_invoke per frame
5. block on next_event()              ; KIND_TTY read or sys_read(0)
```

**Kernel-owned diff.** Step 4 hands control to
`cap_handler_tui_canvas` (paideia-os R89.M1-002/003 in the monorepo).
The kernel scans back vs. front, computes per-row dirty
`(min_col, max_col)`, builds a cursor-position + SGR-transition +
UTF-8-symbol byte sequence per dirty run, and issues it through
`TTY_OP_WRITE` on the row's `tty_slot`. Rows just emitted get
copied back->front. User-space never sees this — the whole
tick is one `PRESENT` from its side.

**Why the diff is kernel-side.** docs/design.md §2.1 lays it out
in full: the `(rights, target_ptr, op_arg)` triple that
`cap_handler_tui_canvas` shares with every other cap dispatch cannot
carry a per-cell payload, and even if it could, a full-screen redraw
is thousands of cells — thousands of syscalls per frame is
intolerable. Following the `kind_gpu_bo` / `kind_display_plane`
precedent exactly: the cell payload lives in a directly memory-mapped
region named by the parent `KIND_MEMORY`; `cap_invoke` is reserved
for the handful of *control* transitions (present, resize, query,
revoke) that must be capability-checked. This is the security-correct
shape (matches every other buffer-backed cap in the tree) and the
only shape fast enough for 60Hz-class redraw.

**Semantic-pipe co-emission (deferred to M2-009).** Every widget's
draw call is designed to do two things per docs/design.md §2.3: (1)
write cells into the `Buffer` (§2.2 above), and (2) call
`semantic_pipe::send_record(app_pipe_fd, SCHEMA_HASH, record_bytes)`
using the `libpdx-semantic-pipe` `Send` module's existing entry point.
`SCHEMA_HASH` is the 32-byte BLAKE3 hash of the widget's frozen
schema name+version string (e.g. `"BlockView@0.1"`), computed once at
first call and cached — mirrors `svc.schema-registry`'s
`bind_by_name` convenience. Every schema is frozen at `@0.1` for
postui v1; the 4-rule version-tolerance matrix already shipped in
`libpdx-semantic-pipe` v1.0.0 governs what a subsequent `@0.2` may
change without breaking an old subscriber. postui does not extend
that matrix; it conforms to it. The registry wiring itself lands at
M2-009 alongside `Send`/`Binding` integration.

## 4. Cross-repo contract

### 4.1 `KIND_TUI_CANVAS` — the kernel side

postui.M1-004 (the `TuiCanvasClient` bodies) is the first postui
symbol that compiles against a real kernel cap rather than a stub.
The dependency is on paideia-os R89:

- **R89.M1-001** — `src/kernel/core/cap/kind_tui_canvas.pdx`:
  ordinal `0x1A6`, 64-byte row layout, rights, mint gate
  (memory_slot + tty_slot validation).
- **R89.M1-002** — `cap_handler_tui_canvas` dispatch:
  PRESENT / QUERY_ROWS / QUERY_COLS / QUERY_ID / QUERY_TTY_ID /
  RESIZE / CLEAR / DEBUG_PRINT.
- **R89.M1-003** — cell diff + ANSI emit path: back/front scan,
  per-row dirty run, SGR + cursor-position sequence builder,
  `TTY_OP_WRITE` wire-out.
- **R89.M1-004** — damage/stat bookkeeping (`_tui_stats` counter
  table, mirrors `_tty_stats`).
- **R89.M1-005** — boot witness: mint canvas over a TTY sink, draw a
  Block via raw cell writes, PRESENT, verify emitted bytes.
- **R89.M1-006** — `design/kernel/kind-tui-canvas.md` (kernel-side
  companion to this document).

**Wire commitments postui makes.**

- `KIND_TUI_CANVAS` ordinal = `0x1A6`, pinned in
  `TuiCanvasClient::TCC_KIND_TUI_CANVAS`.
- 16-byte Cell wire format per docs/design.md §2.1 — pinned by
  `Cell::CELL_BYTES = 16` and the named offset/length constants.
- Back region at `[0, N)`, front region at `[N, 2N)`,
  `N = rows * cols * 16` — encoded in `Buffer::buffer_bytes` and the
  `buffer_at` / `buffer_at_front` address formulas.
- Truecolor-only (no 16-color / 256-palette tier) — enforced by
  Cell's 3-byte fg/bg slots and Color's 24-bit width.
- 8 modifier bits with a reserved 9th slot in the pad byte — encoded
  in Style's mods/pad layout and Cell's `[+10]`/`[+11]` slots.

A drift on any one of these values silently breaks every rendered
frame; the boot smoke at postui.M1-008 (render one Block, verify
cell bytes byte-for-byte against a fixture) is the load-bearing
regression check for the whole set.

### 4.2 `KIND_TTY` — the input + physical-sink substrate

Two independent uses, both declared in `caps.decl`:

- **write** — a canvas is provably wired to a live `KIND_TTY` at
  mint time (the row's `tty_slot` is validated via
  `tty_tail_valid` at `cap_handler_tui_canvas` mint).
  `TUI_OP_PRESENT` emits its ANSI byte stream through that slot, so
  the write right is transitively required even though postui code
  never issues `TTY_OP_WRITE` itself — the caller's exec-time
  InitCap seeding must carry it or the mint gate refuses.
- **read** — the primary input path (docs/design.md §2.5). Once
  paideia-os #1986 lands (`TTY_OP_READ` + raw-mode toggle), M1-005's
  `Terminal::init` probes it via `TTY_OP_SET_RAW`; if the cap lacks
  `R_TTY_READ` or the op is refused, `Terminal::next_event` falls
  back to `sys_read(0)` against the VFS fd. The fallback is
  explicitly temporary (M4-007 tracks removal); `caps.decl` declares
  read up front so downstream tooling sees the eventual runtime
  dependency at M1 landing time.

### 4.3 `KIND_MEMORY` — the canvas backing store

`KIND_TUI_CANVAS` derives over `KIND_MEMORY` (= `KIND_PAGE`, 4),
following the `kind_gpu_bo` / `kind_display_plane` precedent. The
caller mints a `KIND_MEMORY` region sized
`Buffer::buffer_bytes(rows, cols) = 2 * rows * cols * 16` and hands
it to the canvas derive at `Terminal::init`. postui does not hold
memory authority beyond the derive; the derived canvas cap is what
postui subsequently invokes for every PRESENT.

### 4.4 Semantic-pipe schemas postui declares (M2-009+)

The 14 `{Widget}View@0.1` schemas listed in
`caps.decl:declares_output_schemas:` — one per widget kind that has
visible state a scraper needs (`Clear` and `Layout` have no state,
so they emit no record). Each schema's fixed header carries plain
scalars describing the widget's state; a variable payload carries
labels or cell values. Consumers subscribe by name via
`libpdx-semantic-pipe`'s `Binding::bind_by_name("ListView@0.1")`
without needing to parse ANSI or read the raw cell grid.

## 5. Return codes

### 5.1 Aggregate table (per-module bands)

Every callable in postui returns a `u64`; `0` is universal success
(`Lib::POSTUI_OK`). Non-zero returns partition into bands so a
consumer's switch is a `>> 8` on the high nibble:

| Band                    | Owner                             | Landing |
|-------------------------|-----------------------------------|---------|
| `0xFFFFEB10..0xFFFFEB1F` | KIND_TUI_CANVAS kernel (mirror in `TuiCanvasClient::TCC_ERR_*`) | R89.M1-001..003 |
| (none allocated)        | M1-004 wrappers pass kernel returns through verbatim; no library-side band needed | M1-004 |
| `0xFFFFEB90..0xFFFFEB9F` | postui library, reserved for M1-005 Frame/Terminal | M1-005 |
| `0xFFFFEBA0..0xFFFFEBAF` | postui library, reserved for M1-006 Block widget | M1-006 |
| `0xFFFFEBB0..0xFFFFEBBF` | postui library, reserved for M1-007 WidgetKind dispatch | M1-007 |
| `0xFFFFEBC0..0xFFFFEBCF` | postui library, reserved for M2 (Layout, Paragraph, List, Table, Tabs, Scrollbar, Width) | M2 batch |
| `0xFFFFEBD0..0xFFFFEBDF` | postui library, reserved for M3 (Fixed64, Gauge, Sparkline, BarChart, Chart, Canvas) | M3 batch |
| `0xFFFFEBE0..0xFFFFEBEF` | postui library, reserved for M4 (Tree, Calendar, TextInput, Event pipeline) | M4 batch |

The band anchor is `Lib::POSTUI_ERR_BAND_BASE = 0xFFFFEB80`; every
in-tree M1-005+ landing sub-allocates a 16-wide slice above that
base. Bands are assigned at the milestone level so a downstream
consumer can attribute a return without a full-value table lookup.

**M1-001..M1-004 allocate no library-side error codes.** Lib ships
only version + anchor constants; the Rect/Style/Color/Cell/Buffer
primitives are all `!{}` or `!{mem}` pure helpers that truncate
deterministically on out-of-bound input rather than returning an
error; and the M1-004 `TuiCanvasClient` wrappers return kernel
values verbatim (0 for success on mutators, u64 payload for QUERY
ops, one of the eight `TCC_ERR_*` codes in the `0xFFFFEB1x` kernel
band on refusal, or `INVOKE_RESULT_INVALID_HANDLE` for an unknown
slot). The first postui library error return lands at M1-005 when
`Terminal::init`'s TTY probe and canvas mint composition gain
refusal paths of their own.

### 5.2 Kernel-mirror constants (`TCC_ERR_*`)

The eight kernel-side sentinels the `TuiCanvasClient` module mirrors
byte-for-byte from `kind_tui_canvas.pdx`:

| Value        | `TCC_ERR_*` name         | Semantic |
|--------------|--------------------------|----------|
| `0xFFFFEB1F` | `TCC_ERR_TAIL_ENOSPC`    | tail region cannot hold another row |
| `0xFFFFEB1E` | `TCC_ERR_MINT_BAD_MEMORY`| memory_slot invalid at mint |
| `0xFFFFEB1D` | `TCC_ERR_MINT_BAD_TTY`   | tty_slot invalid at mint |
| `0xFFFFEB1C` | `TCC_ERR_MINT_BAD_DIMS`  | rows/cols out of range at mint |
| `0xFFFFEB1B` | `TCC_ERR_MINT_BAD_SIZE`  | memory_slot too small for rows*cols*32 |
| `0xFFFFEB1A` | `TCC_ERR_BAD_SLOT`       | canvas slot invalid on any op |
| `0xFFFFEB19` | `TCC_ERR_BAD_RIGHTS`     | op refused for lack of required rights |
| `0xFFFFEB18` | `TCC_ERR_REVOKE_ALREADY` | revoke on an already-revoked row |

These are the values `TuiCanvasClient` will return directly (M1-004)
when a cap_invoke returns a kernel-side refusal — no translation, no
re-wrap. The mirror invariant means a shift-and-switch works
uniformly regardless of which layer the refusal came from.

## 6. Discipline invariants

### 6.1 paideia-as encoder pitfalls (project-standing)

Every module in postui observes the six-item compliance list
`manifest.pdxproj:compliance:` declares — each pitfall has burned
sub-agents repeatedly across the org (feedback file
`feedback_pdx_encoder_pitfalls`) and postui's M1 landing was
verified clean on all six:

- **`module-basename-pascal`** — every module name is PascalCase
  basename of its file (`Lib`, `Rect`, `Style`, `Color`, `Cell`,
  `Buffer`, `TuiCanvasClient`, `Frame`, `Block`, `WidgetKind`), no
  directory prefix. Enforced by paideia-as at parse time.
- **`no-test-mnemonic`** — every zero-check goes through
  `cmp reg, 0`. `test reg, reg` is a paideia-as encoder pitfall
  (feedback file cites it as a recurring softarch trip). No `test`
  mnemonic appears anywhere in postui's `.pdx` sources at commit
  tip.
- **`cmp-imm32-only`** — every `cmp reg, imm` / `and reg, imm` uses
  `imm <= 0x7FFFFFFF`. The widest immediate in postui is `0xFFFFFF`
  (16_777_215, Color 24-bit mask) which fits imm32; larger masks
  (`~0xFFFFFF`, `0xFFFFFFFF00000000`) are synthesized via
  `shl`/`shr` pairs (see `style_with_fg` for the pattern).
- **`r11-scratch`** — r11 is not preserved across calls; the SysV
  ABI marks it caller-save and paideia-as does not save it either.
  postui reserves r11 as LEA scratch (unused in leaf modules at
  commit tip).
- **`byte-load-zero-then-mov_b`** — `xor rax, rax; mov_b rax, [ptr]`
  before every byte load. mov_b does not zero-extend on x86_64; the
  xor is not optional. Cell::cell_mods and cell_style consume this
  discipline directly; the mov_d loads in cell_symbol/fg/bg use the
  same defense-in-depth xor for consistency.
- **`sysv-push-pop-parity`** — rsp%16==0 at every nested `call`.
  `rect_intersect`, `color_to_index`, and `color_lerp` all push 5
  callee-save regs (40 bytes; entry rsp%16==8, +40==48, aligned)
  rather than 4 (which would leave rsp%16==8 mis-aligned) — the
  5-push shape mirrors the `madt.pdx` precedent and hardens against
  a future edit that adds a nested call. None of the three bodies
  makes a nested call today; the discipline is preserved anyway.

Additionally, from the feedback file's pitfall list:

- **No 2-op `imul reg, imm`** — every multiplication uses either
  1-op `imul reg` (with rax/rdx implicit) or 2-op `imul reg, reg`.
  postui uses only 2-op `imul reg, reg` (buffer_region_bytes /
  buffer_bytes / buffer_at / buffer_at_front / buffer_set /
  buffer_clear / color_to_index / color_lerp).
- **No `test rN, rN`** — see `no-test-mnemonic` above.
- **No `and reg, imm64`** — see `cmp-imm32-only`; masks that would
  need imm64 are synthesized via `shl`/`shr`.
- **No multiline `pub let ="..."`** — every string constant in
  postui (currently none — bodies land at M1-004+) will use the
  single-line form.
- **Module basename matches file** — enforced (see above).

### 6.2 postui-specific invariants

- **16-byte cell alignment.** Every cell in a Buffer region lives
  at an offset that is a multiple of 16 by construction
  (`(y*cols+x)*16`). No callable accepts a raw cell pointer that
  isn't so aligned; every producer (`buffer_at`, `buffer_at_front`,
  the M1-004 mint sizing) enforces the invariant at its layer.
- **Reserved bytes on the Cell wire stay zero.** Bytes `[+11..+16)`
  of every Cell are reserved; `cell_write` explicitly zeros them
  via the word1 composition, and every setter (`cell_set_symbol`,
  `cell_set_style`) writes a strict subset of bytes so the reserved
  slot is never disturbed. `cell_equal` compares reserved bytes
  verbatim — a caller that broke the invariant on one side sees
  inequality, and this is the intended behavior.
- **Style's pad byte stays zero.** `style_new` masks the pad slot
  to zero at construction; `cell_set_style` defends against a
  hand-crafted Style with junk in bits [56..64) via a `shl 8; shr 8`
  pair before the 8-byte store, so a caller cannot silently corrupt
  a Cell's reserved byte 11 by passing an ill-formed Style.
- **Truecolor-only wire.** No 16-color or 256-palette tier is ever
  stored in a Cell or a Style. `color_to_index` computes a
  256-color approximation but its output is never fed back into
  Cell/Style; it exists for legacy SGR sinks only.
- **Front-buffer write posture.** The front region belongs to the
  kernel. Only `TUI_OP_PRESENT` (kernel-side) copies back->front.
  postui exposes `buffer_at_front` for read access (local diff
  heuristics) but has no callable that writes to the front region.
- **Cap revocation cascade.** A `KIND_TUI_CANVAS` cap is
  transitively revoked when either its `memory_slot` or its
  `tty_slot` is revoked (kernel-side property; documented in
  `docs/design.md` §2.1). postui's Frame layer (M1-005) treats every
  `TCC_ERR_BAD_SLOT` as a terminal transition to
  `FRAME_STATE_FAULTED`; a re-init requires a fresh mint against a
  fresh memory + tty pair.

### 6.3 Library posture (versus binary posture)

postui carries no `_start`, no argv walker, no session cap, no
stats table. Every stats counter and every session-bound piece of
state lives in the *consumer* binary (postui-top, postui-hex,
postui-dmesg, or any future app), not in the library. This is the
shape difference that lets one library body serve every app without
each app inheriting an unrelated `_start` frame — and it is why this
document has no §"REPL lifecycle" analogue to shell's own §3.

## 7. Fail-code family table

Every test module postui ships (`tests/test_*.pdx`, populated
starting M1-008 per `manifest.pdxproj:tests:`) allocates a
`0xFFFFEDxx` fail-code band per family so a smoke harness driver
can attribute a failure to a specific test without parsing driver
names:

| Test family                | Band                    | Landing |
|----------------------------|-------------------------|---------|
| `test_rect`                | `0xFFFFED10..0xFFFFED1F` | M1-002 follow-up (retroactive) |
| `test_style`               | `0xFFFFED20..0xFFFFED2F` | M1-002 follow-up (retroactive) |
| `test_color`               | `0xFFFFED30..0xFFFFED3F` | M1-002 follow-up (retroactive) |
| `test_cell`                | `0xFFFFED40..0xFFFFED4F` | M1-003 follow-up (retroactive) |
| `test_buffer`              | `0xFFFFED50..0xFFFFED5F` | M1-003 follow-up (retroactive) |
| `test_tui_canvas_client`   | `0xFFFFED60..0xFFFFED6F` | M1-004 follow-up (retroactive) |
| `test_frame`               | `0xFFFFED70..0xFFFFED7F` | M1-005 |
| `test_block`               | `0xFFFFED80..0xFFFFED8F` | M1-006 |
| `test_widget_kind`         | `0xFFFFED90..0xFFFFED9F` | M1-007 |
| `test_boot_smoke`          | `0xFFFFEDA0..0xFFFFEDAF` | M1-008 |
| `test_boot_list_table_smoke` | `0xFFFFEDB0..0xFFFFEDBF` | M2-010 |
| `test_boot_chart_canvas_smoke` | `0xFFFFEDC0..0xFFFFEDCF` | M3-007 |
| `test_boot_widget_catalog_smoke` | `0xFFFFEDD0..0xFFFFEDDF` | M4-008 |

Every family follows the shell precedent's shape: each test case
allocates a distinct sentinel in its band, an umbrella
`t{family}_run_all` matches the family shape so a boot-time smoke
harness invokes every driver uniformly, and a family's cases cover
both the happy path and every explicit refusal path the module's
callable surface exposes.

The M1-001..M1-003 test bodies are deliberately not landed at commit
tip — the M1 issue plan (docs/design.md §5.1) files them as
follow-up work rather than shipping test bodies with the primitive
landings. M1-008 boot smoke is the first test-tier landing and gates
the M2 wave from starting.

---

*This document is the internal architecture spec for postui at the
current commit. It is authoritative for the "what and how" of every
module already landed; the "why" for every architectural choice
lives in `docs/design.md` and is not repeated here.*
