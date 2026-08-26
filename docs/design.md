# postui — design document

**Status:** Draft v1.0 (authoritative spec for postui M1–M5)
**Date:** 2026-08-25
**Authors:** osarch + softarch combined pass
**Repo:** `paideia-os/postui`
**License:** MIT

---

## §0. Setting

paideia-os is a clean-slate x86_64 microkernel written entirely in `.pdx`
(Paideia assembly, compiled by `paideia-as` to ELF). It has no POSIX layer
and no borrowed userland — every ring-3 tool (`ls`, `cat`, `ps`, `shell`,
`doc`, …) is a from-scratch `.pdx` program compiled against the same
capability substrate the kernel itself uses. Four pillars govern every
design decision made anywhere in the org:

1. **Multicore-first** — every subsystem is built around the per-CPU CB /
   `GS_BASE` pattern from day one, not retrofitted for SMP later.
2. **Post-quantum** — release artifacts are ML-DSA-65 signed; `pkg` verifies
   dual signatures (Ed25519 + ML-DSA-65) before install.
3. **FP-disciplined** — every function carries an explicit effect row
   (`!{mem, sysreg, io, fs, net, sched, time}`) and capability row (`@{cap}`)
   in its type. There is no ambient authority and no untracked side effect.
4. **Semantically-queryable terminal** — the shell (`paideia-os/shell`,
   v1.0.0) already emits `ShellCommandRecord`, `CommandCompletion[]`, and
   `PdxFsMountRecord@0.1` as **semantic-pipe** records: every human-visible
   byte stream has a structured twin a scraper or agent can subscribe to
   without screen-scraping ANSI. This is not a shell-only feature — it is a
   standing architectural commitment (`libpdx-semantic-pipe`, R49 wave) that
   any interactive surface in the OS is expected to extend.

**postui** is the TUI (terminal user interface) widget library that lets
ring-3 tools build rich, multi-pane interactive screens (task viewers, file
browsers, log tailers) instead of hand-rolled ANSI. It is modeled on
**Ratatui** (the Rust immediate-mode TUI ecosystem, itself the successor to
`tui-rs`) for three concrete reasons, not out of familiarity:

- **Immediate-mode redraw matches paideia-os's actual constraints.**
  Ratatui's model — hold no persistent widget-tree state across frames,
  recompute a `Buffer` of `Cell`s from application state every tick, diff
  against the previous frame, emit only the changed cells — needs no
  garbage collector, no retained scene graph, and no dynamic dispatch over
  a widget tree. That is exactly the shape a capability-discipline, no-GC,
  effect-tracked kernel language can express cleanly. A retained-mode GUI
  toolkit (the eventual G4+ Vello/compositor track, milestones `g1`–`g12`)
  is a different, much later problem; postui is deliberately terminal-only.
- **Ratatui's widget catalog is the de facto reference surface for "what a
  serious TUI library covers."** Reusing its widget taxonomy (Block,
  Paragraph, List, Table, Tabs, Gauge, Sparkline, Chart, Canvas, Tree,
  Calendar, Scrollbar, …) means postui does not have to invent a v1 scope
  from nothing, and every mismatch against `.pdx`'s actual language surface
  becomes a concrete, checkable question ("does Ratatui's `Chart` widget's
  approach port?") rather than an open-ended design exercise.
- **Ratatui's architecture (`Widget` trait + generic `StatefulWidget<S>` +
  a `Buffer` grid) is built on Rust generics and trait objects that
  `paideia-as` does not have.** This is the central finding of §1: postui
  is not a line-by-line port. It borrows Ratatui's *widget taxonomy and
  layout model*; it does **not** borrow Ratatui's *type-system
  architecture*. Every widget is redesigned around `.pdx`'s actual
  primitives: closed enums, `match`-style dispatch, structs, closures, and
  effect/capability rows.

The rendering substrate is new kernel work: `KIND_TUI_CANVAS`, a
capability-gated, memory-backed double-buffered cell grid with kernel-side
damage diffing, sitting on top of the existing `KIND_TTY` sink. Every
widget's `draw()` call does two things, not one: it writes cells into the
canvas's back buffer, **and** it emits a frozen-schema semantic-pipe record
describing the same screen region — extending pillar 4 to every postui
screen, not just the shell prompt.

---

## §1. Feasibility assessment

This section is a real audit against the `paideia-as` v0.22.0 compiler as
it exists today (`tools/paideia-as`, workspace version `0.22.0`,
`crates/paideia-as-elaborator`, `crates/paideia-as-encoder`), not against
the aspirational Phase-2/3 language surface described in
`design/terminal/semantic-shell.md` (Datalog, Hindley-Milner inference
across three sub-languages, Kitty graphics protocol — none of that is
built; that document describes a future shell language, not the `.pdx`
surface postui compiles against). Every claim below was checked by reading
`paideia-as`'s own source, not assumed.

### 1.1 What `.pdx` actually has today

Verified present in `paideia-as` 0.22.0:

| Feature | Evidence |
|---|---|
| Structs / packed records | `struct_registry.rs`; v0.22's own milestone title is "Slice<T> + packed struct + MMIO/PerCpu/Refcount lowering" |
| Closed enums + `EnumCons` | `derive_fn_sig.rs`, `EnumRegistry`, `emit_pass_state.rs` |
| Closures with capture analysis | `capture.rs`, `check_lambda.rs` — captures are classified `ByRef`/`ByConsume` and checked against the closure's linearity class (Linear/Affine/Unrestricted) |
| ML-style modules / functors | v0.20 "SELF-HOST" changelog: "m5 (ML modules + functors) — Signature / Structure / Functor AST + module-kind machinery + structure/sig matching + applicative-functor cache" |
| `Slice<T>` | v0.22 changelog title; a *built-in* parametric container, not user-definable generics |
| Effect rows + capability rows | Every function signature in this codebase (`!{mem, sysreg} @{cap}`) — this is not aspirational, it is load-bearing in every `.pdx` file read for this audit (`kind_tty.pdx`, `command_record.pdx`) |
| Recursion | Ordinary control flow; no restriction found |
| `unsafe` blocks with raw x86_64 encoding | `unsafe_walker.rs` + register/memory sub-modules; this is how every kernel-side cap handler in this codebase is written |
| SysV lambdas with >6 args | v0.22.0 changelog #1326 — stack-spill calling convention landed |

Verified **absent**:

| Feature | Evidence |
|---|---|
| User-definable generics (`List<T>` for arbitrary `T`, generic functions) | Zero hits for `generic` in `paideia-as-types/src/types.rs` or `paideia-as-ast/src/types.rs`. `Slice<T>` is a single built-in container, not a generics facility. |
| Trait objects / dynamic dispatch (`dyn Widget`) | No trait/interface construct at all in the type system — modules/functors are the closest analogue, and functor application is resolved statically at compile time (an "applicative-functor cache", not runtime vtables). |
| Scalar floating-point arithmetic codegen | `Type::Float(32\|64)` exists in `paideia-as-types::Type` **only as a type tag** — it is used exclusively for display strings (`"f32"`, `"f64"`) in two files (`check_fn_ptr_sig.rs`, `check_expr.rs`) for signature/error-message purposes. A repo-wide search for `movss`, `movsd`, `addss`, `addsd`, `mulss`, `mulsd`, `cvtsi2sd`, `cvttsd2si` across every crate under `tools/paideia-as/crates/*/src` returns **zero matches**. There is no scalar-float lowering path anywhere in the encoder. `f32`/`f64` is a dead type today: it type-checks in a signature but cannot be added, multiplied, or converted from an integer. |
| Grapheme-cluster / East-Asian-Width Unicode support | Nothing under `paideia-stdlib` or the elaborator implements UAX #29 (grapheme clustering) or UAX #11 (East Asian Width). The rich Unicode pipeline in `design/terminal/semantic-shell.md` §10 is Phase-2/3 shell design, not a shipped stdlib routine any `.pdx` program can call today. |
| A Cassowary-style (or any) general linear-constraint solver | Not present, and not a good target for `.pdx` even if it were — see §1.3. |

### 1.2 The central architectural mismatch: Ratatui is generics-and-traits, `.pdx` is enums-and-modules

Ratatui's core abstraction is:

```rust
pub trait Widget { fn render(self, area: Rect, buf: &mut Buffer); }
pub trait StatefulWidget { type State; fn render(self, area: Rect, buf: &mut Buffer, state: &mut Self::State); }
```

Every widget is a distinct Rust type implementing `Widget` (or
`StatefulWidget<State = ListState>`, etc.); `Frame::render_widget` takes
`impl Widget` generically and monomorphizes per call site. None of this —
generic trait bounds, associated types, monomorphization — exists in
`paideia-as`. **This is not a gap to file against `paideia-as`; it is the
wrong shape for this language, full stop**, in the same sense that the
existing kernel cap-dispatch tables (`cap_handler_tty`, `cap_handler_blkdev`,
…) are not ports of a C++ vtable-based driver framework — they are closed
`op` dispatch over a `match`-shaped `cmp`/`je` chain, because that is what
`.pdx` is good at.

**Resolution — closed-enum + dispatch-function architecture:**

```paideia-as
module Widget = structure {
  // A closed sum of every widget kind. Adding widget #31 means adding a
  // variant here and a case to widget_draw's dispatch — the same shape
  // KIND_TTY's cap_handler_tty already uses for its six ops.
  enum WidgetKind =
    | Block(BlockSpec)
    | Paragraph(ParagraphSpec)
    | ListW(ListSpec)
    | TableW(TableSpec)
    | TabsW(TabsSpec)
    | GaugeW(GaugeSpec)
    | SparklineW(SparklineSpec)
    | BarChartW(BarChartSpec)
    | ChartW(ChartSpec)
    | CanvasW(CanvasSpec)
    | TreeW(TreeSpec)
    | CalendarW(CalendarSpec)
    | ScrollbarW(ScrollbarSpec)
    | TextInputW(TextInputSpec)
    | ClearW

  // widget_draw is the one function every caller goes through — the
  // postui analogue of cap_handler_tty's op dispatch. It writes cells
  // into buf AND (per §2.3) emits the widget's semantic record.
  pub let widget_draw : (WidgetKind, Rect, Buffer) -> () !{mem} @{} =
    fn (kind: WidgetKind) (area: Rect) (buf: Buffer) -> ...
}
```

Every "widget" is a plain struct (`BlockSpec`, `ParagraphSpec`, …) carrying
its own configuration and, where Ratatui would use a separate
`StatefulWidget`, an explicit `*State` struct passed alongside it
(`ListSpec` + `ListState`, `TableSpec` + `TableState` — mirroring Ratatui's
own state/spec split, which already exists independently of the
trait-object question). No dynamic dispatch, no vtables, no vendored
"downcast" pattern. This costs postui the ability for third-party code to
add a widget kind *without recompiling postui itself* (true trait objects
give you that; a closed enum does not) — an acceptable, explicit trade,
consistent with how every kernel cap kind in this codebase is a fixed,
closed `KIND_*` ordinal set rather than a plugin registry.

### 1.3 Layout: integer distribution, not Cassowary

Ratatui's `Layout` (since ~v0.19) resolves `Constraint::{Length, Min, Max,
Percentage, Ratio, Fill}` via the `cassowary-rs` linear-constraint solver —
general LP, floating-point internally, capable of resolving
over-constrained systems by a global least-violation rule. Porting a
general Simplex-family solver to a language with **no float arithmetic
lowering** (§1.1) is out of scope for v1 and arguably the wrong target even
if float codegen existed — a terminal layout problem never needs general
LP; it needs "split N pixels among a handful of ordered constraints
deterministically."

**Resolution:** an all-integer, single-pass proportional distribution
(§2.4) — closer to Ratatui's own *pre*-v0.19 layout algorithm than to
Cassowary. `Length` constraints are subtracted first; the remainder is
distributed across `Percentage`/`Ratio`/`Fill` constraints using integer
division with largest-remainder apportionment (Hamilton's method — the
same rounding rule used for legislative seat apportionment, chosen because
it guarantees percentages sum to exactly the remaining space with no
1-cell drift); `Min`/`Max` clamp in a second pass, redistributing any
freed space to `Fill` segments. This is a well-defined, deterministic,
totally-ordered algorithm — GREEN, not a compromise so much as a
correctly-scoped simplification for a terminal-sized problem (a handful of
splits, never hundreds).

### 1.4 Fixed-point in place of floating point

Ratatui's `Chart`/`Canvas`/axis-scaling code is `f64` throughout: dataset
values, axis bounds, coordinate-to-cell projection. Given §1.1's confirmed
absence of scalar-float codegen, postui M3 introduces a **Q32.32
fixed-point module** (`Fixed64`: a `u64`-backed signed fixed-point type,
32 integer bits + 32 fractional bits, plain integer `add`/`sub`/`mul`
(128-bit intermediate via `mul`+shift)/`div`(shift+`idiv`)/`to_i64`
truncation) that every chart/canvas widget uses for axis bounds, sample
interpolation, and coordinate projection. This is not a hack bolted on
around a missing feature — Q32.32 fixed point is the standard technique
plenty of production embedded/no-FPU systems use for exactly this problem,
and `.pdx`'s 64-bit integer ops (`mul`, `idiv`, shifts) are more than
sufficient to implement it directly, with no compiler changes at all.
Braille dot-grid and line-drawing in `Canvas` use integer Bresenham, which
was never float-dependent in the first place (Ratatui's own
implementation already special-cases integer inputs for exactly this
reason).

**The one real, verified `paideia-as` gap this analysis surfaces** — real
scalar `f32`/`f64` arithmetic codegen — is **not filed as a blocker**. It
does not block v1 (Q32.32 covers every widget's needs); it is filed in
§5.5 as a tracked, non-gating future-enhancement issue so a hypothetical
v2 "arbitrary-precision Chart" upgrade has a named target instead of
silently assuming float arithmetic works because the type name parses.

### 1.5 Grapheme width: a stdlib routine, not a compiler gap

Ratatui depends on the `unicode-width` crate for column-width computation
(so a CJK character correctly occupies two terminal cells, and a
combining mark occupies zero). `paideia-as` has no such facility built in
(§1.1). This is **not** filed as a `paideia-as` issue: computing UTF-8
continuation-byte spans and looking up a codepoint range against a
East-Asian-Width table is ordinary byte-scanning logic + a static lookup
table — entirely expressible in plain `.pdx` today, no new compiler
feature required. postui M2 ships a `Width` module doing exactly this
(§2.6, widget catalog). v1's width table covers the common East-Asian-Wide
+ combining-mark ranges; full UAX #29 extended-grapheme-cluster boundary
detection (ZWJ sequences, variation selectors) is out of v1 scope and
documented as a known limitation — multi-codepoint emoji sequences may
render as multiple cells rather than one. This mirrors exactly how the
Phase-1 `design/terminal/semantic-shell.md` §13.2 itself scoped: "ASCII-only
input acceptable for early bring-up," Unicode maturity is explicitly a
later-phase concern for the *shell*, and postui inherits the same posture
for the same honest reason.

### 1.6 Feasibility score per widget class

| Widget class | Score | Why |
|---|---|---|
| Block (borders, title, padding) | GREEN | Pure struct + integer geometry; no mismatch |
| Paragraph (wrap, styled spans, scroll) | GREEN | Byte/width-table wrap (§1.5); no float |
| List + ListState | GREEN | Enum dispatch + plain struct state |
| Table + TableState | GREEN | Built on Layout (§1.3, GREEN) for column widths |
| Tabs | GREEN | Trivial: index + label array |
| Gauge / LineGauge | GREEN | Integer percentage math only |
| Sparkline | GREEN | Integer min/max normalize |
| BarChart | GREEN | Integer bar-height math |
| Scrollbar | GREEN | Integer position/track-length math |
| Clear | GREEN | Trivial cell blanking |
| Tree (recursive node list) | GREEN | Plain recursion; no generics needed (closed `TreeNode` struct with a fixed-depth child-slice, not an arbitrary generic tree) |
| Calendar | GREEN | Integer date math (Zeller/civil-from-days algorithms are pure integer) |
| TextInput / TextArea | GREEN | Cursor math is integer; depends on input pipeline (§2.7), not on a language gap |
| Layout (Length/Percentage/Min/Max/Ratio/Fill) | GREEN | §1.3's integer distribution, not Cassowary |
| Chart / LineChart (axis + dataset scaling) | YELLOW | Needs the Q32.32 rewrite (§1.4); real design work, no compiler gap, some precision/behavior divergence from Ratatui's `f64` path documented as a known limitation |
| Canvas (arbitrary coordinate space, shapes) | YELLOW | Same Q32.32 rewrite; Bresenham primitives are naturally integer already |
| Full Unicode grapheme clustering (cross-cutting, not one widget) | YELLOW | v1 ships a width-table approximation (§1.5), not full UAX #29; documented limitation, not a blocker |
| Ratatui's generic `Widget`/`StatefulWidget` trait-object architecture | RED (as literally specified) → resolved | No `.pdx` analogue exists (§1.2); **not ported** — replaced by the closed `WidgetKind` enum + dispatch function architecture, which is fully GREEN to build |
| Scalar float arithmetic (as a language feature, not a widget) | RED (does not exist) → worked around | Q32.32 fixed point avoids needing it for v1 (§1.4); real gap filed non-blocking in §5.5 |

No widget class in Ratatui's catalog is irreducibly RED for postui v1 —
every RED finding is at the *architecture* or *language-feature* level,
and each has an already-adopted, GREEN-buildable resolution. This is the
honest version of "full parity is feasible": not because `.pdx` has
everything Rust has, but because every place it doesn't has a concrete,
already-scoped workaround that costs real design effort (fixed-point math,
a width table, an enum-dispatch rewrite of the widget model) rather than a
new compiler feature.

---

## §2. Architecture

### 2.1 Cap model — `KIND_TUI_CANVAS`

**Ordinal:** `0x1A6` (next free slot after `KIND_TCP_SOCKET` = `0x1A5`;
checked against every `KIND_*` constant under
`src/kernel/core/cap/*.pdx` — no collision).

**Derivation:** over `KIND_MEMORY` (= `KIND_PAGE`, 4), following the exact
precedent `kind_gpu_bo.pdx` (`0x174`) and `kind_display_plane.pdx`
(`0x173`) already established for buffer-backed caps: "the kernel never
trusts a ring-3 [canvas] blob directly; it trusts the `KIND_MEMORY` holder
that had authority over those bytes." A `KIND_TUI_CANVAS` additionally
names — and validates at mint — a `tty_slot` referencing a live
`KIND_TTY` row (`tty_tail_valid`), so a canvas is always provably wired to
a real TTY sink and a memory revocation or TTY revocation both cascade
into the canvas becoming unusable.

This differs from `KIND_TTY` itself (which derives over `KIND_IPC_ENDPOINT`)
because a TTY sink is a *conversation with a server*, while a canvas is a
*buffer with a rendering target* — the same distinction `kind_gpu_bo`
(memory-derived) draws against `kind_display_output`/`kind_display_mode`
(server-conversation-shaped) elsewhere in the same tree.

**Row layout (mirrors the 48-byte `kind_tty` row's "six-word" discipline,
here eight words = 64 bytes, one cache line):**

```
[+0]  header: in_use[63:56] | reserved[55:0]
[+8]  canvas_id       (u64)  server-assigned; refused == 0 at mint
[+16] memory_slot     (u64)  the KIND_MEMORY(4) slot backing the cell grid
[+24] tty_slot        (u64)  the KIND_TTY row this canvas emits ANSI into
[+32] rows | cols      rows[63:32] | cols[31:0]   (both <= TUI_DIM_MAX = 4096,
                        same ceiling TTY_ROWS_MAX/TTY_COLS_MAX already use)
[+40] cell_bytes      (u64)  = 16 (CELL_BYTES); recorded so a future cell
                        format revision can version-check existing rows
[+48] presents        (u64)  running PRESENT-op count (kernel-side stat)
[+56] reserved        (u64)  flags (mode bits reserved for future use)
```

**Backing buffer layout** (inside the `memory_slot`'s byte range, sized
`2 * rows * cols * CELL_BYTES` and mapped writable into the client's
address space at mint):

```
[0, N)     back buffer  — client-writable scratch; every widget's draw()
                          writes here every frame
[N, 2N)    front buffer — kernel-owned "last emitted" snapshot; the client
                          never writes here directly
```

where `N = rows * cols * 16`. A 240x67 terminal (a generous real-world
size) gives `N = 257,280` bytes — two such regions is ~500 KiB per canvas,
trivially page-mappable and nowhere near the `KIND_MEMORY` allocator's
practical ceiling.

**Cell wire format (16 bytes, `CELL_BYTES`):**

```
[+0]  symbol   [4]u8   up to 4 UTF-8 bytes (one grapheme under the v1
                       width-table model, §1.5); zero-padded if shorter
[+4]  fg       [3]u8   24-bit truecolor (r, g, b)
[+7]  bg       [3]u8   24-bit truecolor (r, g, b)
[+10] mods     u8      bitflags: BOLD|ITALIC|UNDERLINE|DIM|CROSSED_OUT|
                       SLOW_BLINK|RAPID_BLINK|REVERSED (8 bits, 8 flags —
                       HIDDEN dropped from Ratatui's 9-flag set as
                       out-of-v1-scope, can be added in the reserved
                       byte below without breaking the format)
[+11] reserved [5]u8   zero; future use (e.g. a 9th modifier, hyperlink id)
```

No 16-color or 256-palette tier is stored or emitted — 24-bit truecolor
only, per the frozen design constraint.

**Rights** (mirrors `R_TTY_*`'s bit-assignment style):

```
R_TUI_PRESENT  0x002   diff + emit a frame (the "write" analogue)
R_TUI_INVOKE   0x008   query ops (rows, cols, id, tty_id)
R_TUI_RESIZE   0x010   TUI_OP_RESIZE / TUI_OP_CLEAR
R_TUI_REVOKE   0x020   teardown the row
R_TUI_MINT     0x200   derive a narrower child (reserved; no v1 caller)
R_TUI_OBSERVE  0x400   debug printer
R_TUI_ALL      0x63A
```

**Ops** (`cap_handler_tui_canvas(rights, target_ptr, op_arg) -> u64`,
same three-`u64` dispatch shape as `cap_handler_tty`):

| Ordinal | Op | Rights | Behavior |
|---|---|---|---|
| 0 | `TUI_OP_PRESENT` | `R_TUI_PRESENT` | Scan back vs. front buffer; per dirty row, compute `(min_col, max_col)`; for each dirty run, emit a cursor-position escape (`CSI row;col H`) + one SGR sequence per fg/bg/mods change + the run's UTF-8 symbol bytes, via the existing `TTY_OP_WRITE` wire on the row's `tty_slot`; copy back→front for the rows just emitted; bump `presents` |
| 1 | `TUI_OP_QUERY_ROWS` | `R_TUI_INVOKE` | Returns `rows` |
| 2 | `TUI_OP_QUERY_COLS` | `R_TUI_INVOKE` | Returns `cols` |
| 3 | `TUI_OP_QUERY_ID` | `R_TUI_INVOKE` | Returns `canvas_id` |
| 4 | `TUI_OP_QUERY_TTY_ID` | `R_TUI_INVOKE` | Returns the underlying `tty_id` (via `tty_row_id(tty_slot)`) |
| 5 | `TUI_OP_RESIZE` | `R_TUI_RESIZE` | Re-derive `rows`/`cols` on a terminal resize event; re-maps the backing region (a fresh mint under the hood, old row revoked) |
| 6 | `TUI_OP_CLEAR` | `R_TUI_RESIZE` | Mark every cell in front buffer as a blank sentinel, forcing the next `PRESENT` to be a full repaint (used after `RESIZE` and on first frame) |
| 7 | `TUI_OP_DEBUG_PRINT` | `R_TUI_OBSERVE` | Debug hook, no side effect beyond the existing `TTY_OP_DEBUG_PRINT` pattern |

**Failure taxonomy:** a new disjoint 16-wide band,
`0xFFFFEC40..0xFFFFEC4F` (the next free band after `KIND_TTY`'s
`0xFFFFEC30..0xFFFFEC3F`), with the same named-constant discipline
(`TUI_MINT_BAD_MEMORY`, `TUI_MINT_BAD_TTY`, `TUI_MINT_BAD_DIMS`,
`TUI_TAIL_ENOSPC`, `TUI_BAD_SLOT`, `TUI_REVOKE_ALREADY`, …).

**Why `cap_invoke` is control-plane-only, not per-cell:** the `(rights,
target_ptr, op_arg)` triple `cap_handler_tty`/`cap_handler_tui_canvas`
share cannot carry a cell write's payload (16 bytes of cell data + a
row/col address) in one call, and even if it could, a full-screen redraw
is thousands of cells — thousands of syscalls per frame is not a
tolerable per-frame cost. Following the `kind_gpu_bo`/`kind_display_plane`
precedent exactly: the pixel (here, cell) payload lives in a **directly
memory-mapped** region named by the `KIND_MEMORY` parent; `cap_invoke` is
reserved for the handful of *control* transitions (present, resize, query,
revoke) that must be capability-checked. This is both the
security-correct shape (matches every other buffer-backed cap in this
tree) and the only one fast enough for 60 Hz-class redraw rates.

### 2.2 Rendering pipeline

```
Application state
      │
      ▼
Widget tree (a Vec<WidgetKind> the app builds fresh each tick — no
              retained state across frames, per Ratatui's immediate-mode
              model)
      │
      ▼
Frame::render(widget, area)     — user-side, calls widget_draw per widget
      │
      ▼
Buffer (back-buffer region of the mapped KIND_MEMORY range)
      │  writes are plain stores through the mapped pointer; no cap_invoke
      │  per cell (§2.1)
      ▼
cap_invoke(canvas_cap, TUI_OP_PRESENT, 0)
      │
      ▼
Kernel: back vs. front diff → per-row dirty (min_col,max_col) → ANSI
        cursor/SGR/glyph sequence → TTY_OP_WRITE on tty_slot → back→front
        commit for emitted rows
      │
      ▼
Underlying KIND_TTY sink → physical UART / framebuffer console
```

A postui "app loop" is therefore: build widget list from state → call
`Frame::render` for each → one `PRESENT` call → block on the next input
event (§2.7) → repeat. There is no separate "diff" step on the userspace
side at all — the *kernel* owns the only diff, which is the frozen design
constraint (#2) working as intended: user-space always writes the full
back buffer for whatever regions it touched; the kernel decides what
actually changed.

### 2.3 Semantic-pipe integration

Every widget's `draw()` call does two things, mirroring exactly how the
shell's `command_record.pdx`/`completion.pdx` pair a human-visible action
with a durable structured record:

1. Write cells into the `Buffer` (§2.2).
2. Call `semantic_pipe::send_record(app_pipe_fd, SCHEMA_HASH, record_bytes)`
   — the `libpdx-semantic-pipe` `Send` module's existing entry point,
   unmodified. `app_pipe_fd` is a `KIND_IPC_ENDPOINT` the app binds once at
   startup (mirroring the shell's own semantic-pipe binding at session
   start); `SCHEMA_HASH` is the 32-byte BLAKE3 hash of the frozen schema
   name+version string (e.g. `"ListView@0.1"`), computed once and stored
   as a compile-time constant per widget module — the same "32-byte
   BLAKE3 schema-hash prefix" contract `libpdx-semantic-pipe`'s `README`
   already documents, reused verbatim rather than reinvented.

**Wire format per record** follows `command_record.pdx`'s established
shape exactly: a fixed header (magic `u32` + `record_len u32` + fields) +
variable payload + zero-pad to an 8-byte boundary. Every widget's schema
is frozen at `@0.1` for postui's v1 release; `libpdx-semantic-pipe`'s
existing 4-rule version-tolerance matrix (already shipped, v1.0.0) governs
what a later `@0.2` may change without breaking an old subscriber — postui
does not need to invent its own versioning rule, only conform to the one
that already exists.

**Schema registry pattern:** each widget module exports a
`{WIDGET}_SCHEMA_NAME : [u8; N]` constant and a
`{widget}_schema_hash() -> [u8; 32]` accessor (BLAKE3 over the name
string, computed once at first call and cached — mirrors `svc.schema-
registry`'s `bind_by_name` convenience already in `libpdx-semantic-pipe`).
A scraper subscribes by calling the registry's `bind_by_name("ListView@0.1")`
to obtain the matching hash, then filters incoming frames on that hash —
exactly the `Binding` module's existing per-fd schema-hash binding table,
reused, not extended.

**Example — `ListView@0.1`:**

```
[+0]  u32 magic       = LSTV_MAGIC
[+4]  u32 record_len
[+8]  u32 item_count
[+12] u32 selected_index   (0xFFFFFFFF if none selected)
[+16] u32 viewport_offset
[+20] u32 reserved
[+24] u8[...]  item_count null-separated UTF-8 label strings
[+..] zero_pad to 8-byte boundary
```

Every widget's schema in §2.6's catalog follows this same discipline:
fixed header of plain scalars describing the widget's *state*, followed
by the minimum variable payload needed to reconstruct what's on screen
(labels, cell values) without needing the raw cell buffer at all — the
whole point being that a scraper never needs to parse ANSI or read
`KIND_TUI_CANVAS`'s cell grid to know "what list is showing, and what's
selected."

### 2.4 Layout engine

Constraint kinds (a closed enum, matching Ratatui's public surface):
`Length(u16)`, `Percentage(u8)`, `Ratio(u16, u16)`, `Min(u16)`, `Max(u16)`,
`Fill(u16)` (a relative-weight remainder-filler, Ratatui's newest
constraint kind, trivial to add to an integer model since it's just
another remainder-weight bucket).

**Algorithm** (single pass, all-integer):

1. Sum every `Length(n)` constraint's `n`; subtract from the total area
   dimension (rows or cols, per split direction). Remaining space =
   `R`.
2. Convert every `Percentage(p)`/`Ratio(num,den)`/`Fill(w)` constraint to
   a weight (percentage: `p`; ratio: `num*100/den`; fill: `w*100`, an
   arbitrary but consistent common weight-scale so all three kinds share
   one apportionment pass). Sum weights = `W`.
3. Apportion `R` across the weighted constraints via **largest-remainder
   (Hamilton) apportionment**: give each constraint `floor(R * weight_i /
   W)`, then distribute the `R - sum(floor(...))` leftover cells one each
   to the constraints with the largest fractional remainder, highest
   first. This guarantees the weighted constraints' allocations sum to
   exactly `R` — no drift, no off-by-one from naive integer division.
4. Clamp every constraint's final allocation into `[Min, Max]` where
   declared; any cells freed by clamping are re-apportioned to the
   remaining unclamped `Fill`/`Percentage`/`Ratio` constraints by
   repeating step 3 on the freed remainder (bounded iteration — at most
   `n` constraints, so at most `n` clamp-and-redistribute rounds, which
   terminates because each round strictly reduces the unclamped set).

This is a total, terminating, deterministic function
`layout_split(direction, area, constraints[]) -> Rect[]` — no solver
state, no infeasibility case (unlike Cassowary, which can report a system
unsatisfiable; this algorithm always produces *some* allocation, clamping
takes priority over exact proportionality when they conflict, which is a
documented, acceptable divergence from Ratatui's Cassowary-resolved
semantics for pathological constraint sets).

### 2.5 Input handling

**Primary path:** `KIND_TTY` read, once `TTY_OP_READ` + raw/cooked mode
toggle lands (paideia-os issue `#1986` / `R66v2.POS-001`, already filed,
not yet landed as of this writing). postui's `Terminal::init()` probes for
this by attempting `TTY_OP_SET_RAW`; if the TTY cap's rights don't confer
`R_TTY_READ`-equivalent or the op is refused (`TTY_TAIL_BAD_ARG` on an old
kernel), it falls back.

**Fallback path:** `sys_read(0, buf, len)` against the VFS fd, exactly the
pattern `src/user/shell.pdx`'s `shell_read_line` already uses — bytes
arrive already line-buffered/cooked by whatever discipline the underlying
tty layer applies, so raw single-keystroke ESC-sequence recognition is
degraded (a full escape sequence may arrive split across two `read`s if
the user's terminal driver is slow; postui's parser (below) already
buffers partial sequences across calls, so this is a latency cost, not a
correctness one).

**Removal:** the fallback path is explicitly temporary — postui M4 files
its removal as a tracked follow-up (§5.1, `postui.M4-007`) gated on
`#1986` landing and stabilizing, not shipped as permanent debt.

**Event enum:**

```paideia-as
enum Event =
  | Key(u32)                              // a decoded keycode/char
  | Resize(u16, u16)                       // (rows, cols)
  | Mouse { x: u16, y: u16, button: u8, modifiers: u8 }
  | Paste([u8; N])                         // bracketed-paste payload
```

**ESC-sequence parser:** a small state machine over three prefixes —
`CSI` (`ESC [`), `SS3` (`ESC O`), `OSC` (`ESC ]`, used for e.g. focus/paste
markers) — accumulating parameter bytes until a final byte in the
appropriate range terminates the sequence, then mapping the recognized
sequence to an `Event`. This is ordinary byte-oriented state-machine logic
(a `match` over `(state, byte)` pairs), no language feature required
beyond what's already in `.pdx`.

### 2.6 Widget catalog

| Widget | Purpose | Semantic record | Effort |
|---|---|---|---|
| Block | Border + title + padding container | `BlockView@0.1` (title text, border kind) | XS |
| Paragraph | Wrapped/styled text block | `ParagraphView@0.1` (wrapped line count, scroll offset) | M |
| List + ListState | Selectable scrolling list | `ListView@0.1` (§2.3 example) | M |
| Table + TableState | Column-aligned selectable rows | `TableView@0.1` (row count, column headers, selected row) | L |
| Tabs | Horizontal tab bar | `TabsView@0.1` (labels, selected index) | S |
| Gauge / LineGauge | Percentage-fill bar | `GaugeView@0.1` (ratio numerator/denominator) | S |
| Sparkline | Inline mini bar-history | `SparklineView@0.1` (sample window, min/max) | S |
| BarChart | Labeled vertical bars | `BarChartView@0.1` (labels, values) | M |
| Chart / LineChart | Axis + dataset line/scatter plot | `ChartView@0.1` (axis bounds as `Fixed64`, dataset point count) | L |
| Canvas | Arbitrary shape drawing (line/rect/circle/braille) | `CanvasView@0.1` (bounding box, shape count) | L |
| Tree | Expand/collapse hierarchical list | `TreeView@0.1` (visible node count, expanded-path set) | M |
| Calendar | Month grid with day markers | `CalendarView@0.1` (year, month, marked days) | M |
| Scrollbar | Track + thumb position indicator | `ScrollbarView@0.1` (position, content length) | S |
| TextInput / TextArea | Editable text field with cursor | `TextInputView@0.1` (buffer text, cursor offset) | M |
| Clear | Blank a region (modal-overlay prep) | none (no visible state to report) | XS |
| Layout | Constraint-based `Rect` splitter (not a drawn widget) | none | M |

### 2.7 Input dispatch (runtime loop)

```
Terminal::init()  → probe KIND_TTY raw-mode; else sys_read(0) fallback (§2.5)
       │
       ▼
loop:
  event = next_event()          // blocks on KIND_TTY read or sys_read(0)
  app.handle(event)              // app-defined state transition
  frame = build_widget_tree(app.state)
  for (widget, area) in frame: widget_draw(widget, area, canvas.back_buffer)
  cap_invoke(canvas_cap, TUI_OP_PRESENT, 0)
```

---

## §3. Reference apps

Three satellite repos, each proving library generality across a distinct
widget-mix profile, each its own `.pdxproj` app depending on `postui` +
`libpdx-semantic-pipe` (+ `libpdx-cap` for cap marshalling, per the
existing satellite convention).

### 3.1 `postui-top` — task viewer

**Widget mix:** `Table` (process rows: pid, name, state, cpu%, mem) +
`Gauge`×2 (aggregate CPU, aggregate memory) + `Sparkline` (CPU history,
rolling window) + `Tabs` (All / User / Kernel task views).

**Data source:** `sys_taskinfo` (syscall 83, landed per `R57.M4-003`,
`paideia-os` HEAD context) polled on a fixed tick.

**Semantic records emitted:** app-local `TaskRow@0.1` (pid, name, state,
cpu_permille, mem_bytes) per visible row, reusing postui's `TableView@0.1`
and `GaugeView@0.1` for the widget-state half.

**Target LOC:** ~600–900 across scaffold + poll loop + render + record
emission.

**Milestones:** `postui-top.M1` (scaffold + `sys_taskinfo` poll loop),
`postui-top.M2` (Table + Gauge render), `postui-top.M3` (Sparkline
history + Tabs view switch), `postui-top.M4` (semantic-pipe wiring +
release).

### 3.2 `postui-hex` — file/hex browser

**Widget mix:** `List` (directory sidebar) + `Paragraph`-derived hex-dump
pane (offset | hex bytes | ASCII gutter — implemented as a specialized
`Paragraph` styling pass, not a new widget) + `Scrollbar` (byte-offset
position within the open file).

**Data source:** `sys_open`/`sys_read`/`sys_stat` over PdxFS, plus
`ls`-style directory enumeration for the sidebar.

**Semantic records emitted:** app-local `HexViewRecord@0.1` (file path,
byte offset, row byte count, ASCII text) per visible hex row, reusing
`ListView@0.1` for the sidebar and `ScrollbarView@0.1` for position.

**Target LOC:** ~500–800.

**Milestones:** `postui-hex.M1` (scaffold + file open/read), `postui-hex.M2`
(hex-dump Paragraph render + Scrollbar), `postui-hex.M3` (sidebar List +
navigation + file switch), `postui-hex.M4` (semantic-pipe + release).

### 3.3 `postui-dmesg` — klog tail with filter

**Widget mix:** `List` (log line buffer, auto-scroll-to-bottom) +
`TextInput` (live filter string) + `Tabs` (severity split: All / Warn+ /
Error).

**Data source:** `KIND_DMESG` cap (`src/kernel/core/cap/kind_dmesg.pdx`,
already landed), polled/subscribed for new lines.

**Semantic records emitted:** app-local `DmesgLineView@0.1` (sequence
number, severity, timestamp, text), reusing `ListView@0.1` for the visible
window and `TextInputView@0.1` for the filter box's own state.

**Target LOC:** ~500–800.

**Milestones:** `postui-dmesg.M1` (scaffold + `KIND_DMESG` poll),
`postui-dmesg.M2` (List render + `TextInput` filter), `postui-dmesg.M3`
(Tabs severity split + live tail), `postui-dmesg.M4` (semantic-pipe +
release).

---

## §4. Cross-repo dependency chain

```
paideia-as (verified, non-blocking for v1)
  R89-XREPO.PAS-001  f32/f64 scalar codegen — tracked, NOT on the v1
                      critical path (Q32.32 fixed point covers v1, §1.4)

paideia-os
  R89.M1-001  kind_tui_canvas.pdx (ordinal + row + rights + mint gate)
      │
      ▼
  R89.M1-002  cap_handler_tui_canvas dispatch (PRESENT/QUERY_*/RESIZE/CLEAR)
      │
      ▼
  R89.M1-003  cell diff + ANSI emit path (depends on TTY_OP_WRITE's real
              wire, R49.M1 — already landed per this doc's setting)
      │
      ▼
  R89.M1-005  boot witness: mint canvas over a TTY sink, draw+present
      │
      ▼
postui.M1-004  KIND_TUI_CANVAS client bindings (mint/present/resize/query)
      │            ── first point postui code can compile against a real
      │               kernel cap rather than a stub
      ▼
postui.M1-005  Frame/Terminal driver loop (init, KIND_TTY probe / sys_read
               fallback §2.5, draw callback, present)
      │
      ▼
postui.M1-006  Block widget  ──►  postui.M1-008 boot smoke (first pixel
                                   on screen)
      │
      ▼
postui.M2  (Layout, Paragraph, List, Table, Tabs, Width/grapheme module)
      │
      ▼
postui.M3  (Fixed64, Gauge, Sparkline, BarChart, Chart, Canvas)
      │
      ▼
postui.M4  (Tree, Calendar, TextInput, input-event pipeline, Mouse/Paste)
      │            ── depends on paideia-os #1986 (R66v2.POS-001,
      │               TTY_OP_READ) landing for the primary input path
      │               (§2.5); sys_read(0) fallback unblocks M4 in the
      │               meantime, so this is a soft, not hard, dependency
      ▼
postui.M5  (semantic-pipe version matrix, release, doc)
      │
      ├──► postui-top.M1..M4   (independent after postui.M2 lands —
      │                          needs Table/Gauge/Sparkline/Tabs)
      ├──► postui-hex.M1..M4   (independent after postui.M2 lands —
      │                          needs List/Paragraph/Scrollbar)
      └──► postui-dmesg.M1..M4 (independent after postui.M2 AND M4 land —
                                 needs List + TextInput)
```

**Reading this graph:** the only hard serial chain is
`paideia-os R89.M1-001..003/005 → postui.M1-004/005 → postui.M1-006..008`
— everything after a working `Block` renders on a real canvas
parallelizes across the postui M2–M5 widget batches and, once M2 lands,
across all three app repos simultaneously. `R89-XREPO.PAS-001` (the one
real `paideia-as` gap) sits off this critical path entirely — it is a
tracked improvement, not a blocker, exactly as `R64v2.PAS-001` blocked
only the device-target half of R64/R65 in the precedent audit
(`design/roadmap/rows-4-5-6-scoping.md` §2.7).

---

## §5. Milestone + issue plan

Milestones are created first per repo, then issues assigned. Every issue
body follows: **Scope**, **Files touched**, **Fingerprint** (where
applicable), **Effort** (XS ≤100 LOC, S ≤300, M ≤800, L ≤2000, XL >2000),
**Deps**.

### 5.1 postui (this repo)

**M1 — skeleton + cell buffer + minimal Block widget**

| Issue | Scope | Effort | Deps |
|---|---|---|---|
| `postui.M1-001` | Repo scaffold: `manifest.pdxproj`, `caps.decl`, module layout | S | none |
| `postui.M1-002` | `Rect`/`Style`/`Color`(24-bit tuple)/`Modifier` primitives | S | M1-001 |
| `postui.M1-003` | `Cell`/`Buffer`: back/front region layout, 16-byte cell wire format (§2.1) | S | M1-002 |
| `postui.M1-004` | `KIND_TUI_CANVAS` client bindings (mint/present/resize/query wrappers) | M | `paideia-os` R89.M1-002 |
| `postui.M1-005` | `Frame`/`Terminal` driver loop: init, KIND_TTY-vs-`sys_read(0)` probe, draw callback, present | M | M1-004 |
| `postui.M1-006` | `Block` widget (borders: plain/rounded/double/thick, title, padding) + `BlockView@0.1` | S | M1-003 |
| `postui.M1-007` | `WidgetKind` closed enum + `widget_draw` dispatch (§1.2, §2.6 scaffolding for all 15 kinds; only `Block` implemented, rest stubbed `unimplemented`) | M | M1-006 |
| `postui.M1-008` | Boot smoke: render one `Block` to a canvas, verify cell bytes match expected fixture | S | M1-005, M1-007 |
| `postui.M1-009` | `design/architecture.md` internal spec (mirrors `shell`'s own) | S | M1-001 |

**M2 — layout + Paragraph/List/Table/Tabs**

| Issue | Scope | Effort | Deps |
|---|---|---|---|
| `postui.M2-001` | Layout engine: integer constraint distribution (§2.4) | M | M1-002 |
| `postui.M2-002` | `Text`/`Span`/`Line` primitives (styled runs, wrap) | M | M1-002 |
| `postui.M2-003` | `Width` module: UTF-8 continuation-byte scan + East-Asian-Width lookup table (§1.5) | M | M1-002 |
| `postui.M2-004` | `Paragraph` widget (wrap, scroll, alignment) + `ParagraphView@0.1` | M | M2-002, M2-003 |
| `postui.M2-005` | `List` + `ListState` + `ListView@0.1` | M | M2-003 |
| `postui.M2-006` | `Table` + `TableState` + `TableView@0.1` | L | M2-001, M2-003 |
| `postui.M2-007` | `Tabs` + `TabsView@0.1` | S | M2-003 |
| `postui.M2-008` | `Scrollbar` + `ScrollbarView@0.1` | S | M1-002 |
| `postui.M2-009` | Semantic-pipe registry hookup: schema-hash constant per widget, `libpdx-semantic-pipe` `Send`/`Binding` wiring (§2.3) | M | M1-006, M2-004 |
| `postui.M2-010` | Boot smoke: List + Table render + semantic-record round-trip via a test subscriber | S | M2-005, M2-006, M2-009 |

**M3 — charts + canvas**

| Issue | Scope | Effort | Deps |
|---|---|---|---|
| `postui.M3-001` | `Fixed64` Q32.32 module: add/sub/mul/div/scale (§1.4) | M | M1-001 |
| `postui.M3-002` | `Gauge`/`LineGauge` + `GaugeView@0.1` | S | M1-002 |
| `postui.M3-003` | `Sparkline` + `SparklineView@0.1` | S | M1-002 |
| `postui.M3-004` | `BarChart` + `BarChartView@0.1` | M | M2-001 |
| `postui.M3-005` | `Chart`/axis/dataset (Fixed64 scaling, line/scatter markers) + `ChartView@0.1` | L | M3-001, M2-001 |
| `postui.M3-006` | `Canvas` (Fixed64 coordinate space, Bresenham line/rect/circle, braille grid) + `CanvasView@0.1` | L | M3-001 |
| `postui.M3-007` | Boot smoke: Chart + Canvas render determinism (same input → byte-identical cells) | S | M3-005, M3-006 |

**M4 — tree/calendar/textinput/input pipeline**

| Issue | Scope | Effort | Deps |
|---|---|---|---|
| `postui.M4-001` | `TextInput`/`TextArea` (cursor math, insert/delete) + `TextInputView@0.1` | M | M2-003 |
| `postui.M4-002` | `Tree` (recursive node model, expand/collapse state) + `TreeView@0.1` | M | M2-005 |
| `postui.M4-003` | `Calendar` (integer date math, month grid) + `CalendarView@0.1` | M | M1-002 |
| `postui.M4-004` | `Clear` widget + `Padding` utility | XS | M1-002 |
| `postui.M4-005` | `Event` enum + ESC-sequence (CSI/SS3/OSC) parser (§2.5, §2.7) | L | M1-005 |
| `postui.M4-006` | Mouse + bracketed-paste event support | M | M4-005 |
| `postui.M4-007` | Primary-path switch to `KIND_TTY` raw-mode read + tracked fallback-removal note, gated on paideia-os `#1986` | S | `paideia-os` `#1986` |
| `postui.M4-008` | Boot smoke: full widget-catalog render regression corpus (all 15 widget kinds) | M | M3-007, M4-001..004 |

**M5 — semantic-pipe hookup + release**

| Issue | Scope | Effort | Deps |
|---|---|---|---|
| `postui.M5-001` | Schema-version-tolerance conformance across all widget records (reuses `libpdx-semantic-pipe`'s existing 4-rule matrix; no new rule) | M | M4-008 |
| `postui.M5-002` | Scraper example: read-only subscriber client for a running app's semantic pipe | S | M5-001 |
| `postui.M5-003` | Release manifest + dual ML-DSA-65/Ed25519 signing (mirrors `shell.M5-001`) | S | M5-001 |
| `postui.M5-004` | `doc/postui.pdxdoc` doc-source + `doc postui` integration | S | M5-001 |
| `postui.M5-005` | Full widget-catalog smoke matrix (all ~30 widget/state combinations) | L | M4-008 |
| `postui.M5-006` | v1.0.0 release: `CHANGELOG.md`, `STATUS.md` rollup, git tag | XS | M5-003, M5-005 |

### 5.2 postui-top

| Issue | Scope | Effort | Deps |
|---|---|---|---|
| `postui-top.M1-001` | Scaffold + `sys_taskinfo` poll loop | S | `postui` M1 |
| `postui-top.M2-001` | `Table` render (process rows) | M | `postui` M2 |
| `postui-top.M2-002` | `Gauge`×2 (CPU/mem aggregate) | S | `postui` M3 |
| `postui-top.M3-001` | `Sparkline` CPU history | S | `postui` M3 |
| `postui-top.M3-002` | `Tabs` (All/User/Kernel view switch) | S | `postui` M2 |
| `postui-top.M4-001` | `TaskRow@0.1` semantic record emission | M | `postui` M5 |
| `postui-top.M4-002` | Release + smoke | S | M4-001 |

### 5.3 postui-hex

| Issue | Scope | Effort | Deps |
|---|---|---|---|
| `postui-hex.M1-001` | Scaffold + file open/read/stat | S | `postui` M1 |
| `postui-hex.M2-001` | Hex-dump `Paragraph` render (offset/hex/ASCII gutter) | M | `postui` M2 |
| `postui-hex.M2-002` | `Scrollbar` byte-offset position | S | `postui` M2 |
| `postui-hex.M3-001` | Sidebar `List` + directory navigation + file switch | M | `postui` M2 |
| `postui-hex.M4-001` | `HexViewRecord@0.1` semantic record emission | M | `postui` M5 |
| `postui-hex.M4-002` | Release + smoke | S | M4-001 |

### 5.4 postui-dmesg

| Issue | Scope | Effort | Deps |
|---|---|---|---|
| `postui-dmesg.M1-001` | Scaffold + `KIND_DMESG` poll | S | `postui` M1 |
| `postui-dmesg.M2-001` | `List` render (log line buffer, auto-scroll) | M | `postui` M2 |
| `postui-dmesg.M2-002` | `TextInput` live filter | M | `postui` M4 |
| `postui-dmesg.M3-001` | `Tabs` severity split + live tail | S | `postui` M2 |
| `postui-dmesg.M4-001` | `DmesgLineView@0.1` semantic record emission | M | `postui` M5 |
| `postui-dmesg.M4-002` | Release + smoke | S | M4-001 |

### 5.5 paideia-os — `R89 — KIND_TUI_CANVAS substrate`

| Issue | Scope | Files touched | Effort | Deps |
|---|---|---|---|---|
| `R89.M1-001` | `kind_tui_canvas.pdx`: ordinal `0x1A6`, row layout, rights, mint gate (memory_slot + tty_slot validation, §2.1) | `src/kernel/core/cap/kind_tui_canvas.pdx` | L | none |
| `R89.M1-002` | `cap_handler_tui_canvas` dispatch: PRESENT/QUERY_ROWS/QUERY_COLS/QUERY_ID/QUERY_TTY_ID/RESIZE/CLEAR/DEBUG_PRINT | `src/kernel/core/cap/kind_tui_canvas.pdx` | M | R89.M1-001 |
| `R89.M1-003` | Cell diff + ANSI emit path: back/front scan, per-row dirty `(min_col,max_col)`, SGR+cursor-position sequence builder, `TTY_OP_WRITE` wire-out | `src/kernel/core/tty/` (new emit helper), `src/kernel/core/cap/kind_tui_canvas.pdx` | L | R89.M1-002 |
| `R89.M1-004` | Damage/stat bookkeeping (`_tui_stats` counter table, mirrors `_tty_stats`) | `src/kernel/core/cap/kind_tui_canvas.pdx` | S | R89.M1-002 |
| `R89.M1-005` | Boot witness: mint canvas over a TTY sink, draw a `Block` via raw cell writes, `PRESENT`, verify emitted bytes | `src/kernel/boot/witness/` (new), `tests/` | M | R89.M1-003, R89.M1-004 |
| `R89.M1-006` | Design doc: `design/kernel/kind-tui-canvas.md` | `design/kernel/kind-tui-canvas.md` | S | R89.M1-001 |
| `R89.M1-007` | Round closure retro | `design/round-retrospectives/r89-closure.md` | S | R89.M1-005, R89.M1-006 |

### 5.6 paideia-as — `R89-XREPO — postui-required encoder gaps`

Exactly two issues. This is the entire set §1's feasibility analysis
surfaced as **real, verified, non-manufactured** gaps — every other
mismatch found in §1 (trait objects, Cassowary, grapheme clustering) has a
`.pdx`-native resolution that needs no compiler change at all.

| Issue | Scope | Files touched | Effort | Deps |
|---|---|---|---|---|
| `R89-XREPO.PAS-001` | Scalar `f32`/`f64` arithmetic codegen: `movss`/`movsd`/`addsd`/`subsd`/`mulsd`/`divsd`/`cvtsi2sd`/`cvttsd2si` lowering + SysV/MS x64 `xmm0`/`xmm1` return-value ABI wiring. **Justification:** `Type::Float(32\|64)` exists in `paideia-as-types::Type` today **only** as a display-string token used in `check_fn_ptr_sig.rs`/`check_expr.rs` signature diagnostics — a repo-wide search for scalar-float instruction mnemonics across every crate under `tools/paideia-as/crates/*/src` returns zero matches; the type is a dead surface with no lowering path. **Not currently blocking postui v1** — `postui.M3-001`'s Q32.32 `Fixed64` module (§1.4) covers every v1 chart/canvas need on pure integer ops. Filed so a future precision upgrade has a real target instead of an assumption. | `crates/paideia-as-elaborator/src/lower_type.rs`, a new `crates/paideia-as-encoder/src/float_arith.rs`, SysV/MS x64 ABI call-site marshalling | L | none |
| `R89-XREPO.PAS-002` | Version/CHANGELOG discipline for the above: workspace version bump + tag + `CHANGELOG.md` entry, per this project's standing `paideia-as` version-discipline rule | `CHANGELOG.md`, git tag | XS | R89-XREPO.PAS-001 |

### 5.7 Mechanical `gh` filing pattern

Representative invocations (full set executed programmatically per this
table; every remaining issue in §5.1–§5.6 follows the identical shape —
`gh issue create --repo <repo> --milestone "<title>" --title "<id> <scope
one-liner>" --body "See docs/design.md §<n>."`):

```bash
# --- postui milestones ---
gh api repos/paideia-os/postui/milestones -f title="postui.M1 — skeleton + cell buffer + minimal Block widget"
gh api repos/paideia-os/postui/milestones -f title="postui.M2 — layout + Paragraph/List/Table/Tabs"
gh api repos/paideia-os/postui/milestones -f title="postui.M3 — charts + canvas"
gh api repos/paideia-os/postui/milestones -f title="postui.M4 — tree/calendar/textinput/input pipeline"
gh api repos/paideia-os/postui/milestones -f title="postui.M5 — semantic-pipe hookup + release"

gh issue create --repo paideia-os/postui --milestone "postui.M1 — skeleton + cell buffer + minimal Block widget" \
  --title "postui.M1-001 Repo scaffold: manifest.pdxproj, caps.decl, module layout" \
  --body "See docs/design.md §5.1. Effort: S. Deps: none."
# ... one gh issue create per row in §5.1's tables, same shape.

# --- postui-top / postui-hex / postui-dmesg: one milestone each, same pattern ---
gh api repos/paideia-os/postui-top/milestones -f title="postui-top.M1 — scaffold + data poll loop"
# ... M2/M3/M4 milestones + issues per §5.2.

# --- paideia-os ---
gh api repos/paideia-os/paideia-os/milestones -f title="R89 — KIND_TUI_CANVAS substrate"
gh issue create --repo paideia-os/paideia-os --milestone "R89 — KIND_TUI_CANVAS substrate" \
  --title "R89.M1-001 kind_tui_canvas.pdx: ordinal 0x1A6, row layout, rights, mint gate" \
  --body "See docs/design.md §2.1, §5.5 in postui (paideia-os/postui). Effort: L. Deps: none."
# ... R89.M1-002..007 per §5.5.

# --- paideia-as ---
gh api repos/paideia-os/paideia-as/milestones -f title="R89-XREPO — postui-required encoder gaps"
gh issue create --repo paideia-os/paideia-as --milestone "R89-XREPO — postui-required encoder gaps" \
  --title "R89-XREPO.PAS-001 Scalar f32/f64 arithmetic codegen (non-blocking for postui v1)" \
  --body "See docs/design.md §1.4, §5.6 in paideia-os/postui. Effort: L. Deps: none."
gh issue create --repo paideia-os/paideia-as --milestone "R89-XREPO — postui-required encoder gaps" \
  --title "R89-XREPO.PAS-002 Version/CHANGELOG discipline for f32/f64 codegen" \
  --body "See docs/design.md §5.6 in paideia-os/postui. Effort: XS. Deps: R89-XREPO.PAS-001."
```

---

*End of document.*
