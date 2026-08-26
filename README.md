# postui

paideia-os TUI (terminal user interface) widget library — Ratatui-inspired,
cap-based, semantically-queryable. Full Ratatui-parity widget catalog
(~30 widgets), 24-bit truecolor only, rendering through a new
`KIND_TUI_CANVAS` kernel capability with kernel-side double-buffered damage
diffing.

## Status

**Design phase — M1 not yet landed.** See `docs/design.md` for the
authoritative spec (feasibility assessment, cap architecture, semantic-pipe
integration, layout engine, widget catalog, reference apps, and the full
milestone/issue plan) and `STATUS.md` for the milestone rollup.

## Why postui

Every ring-3 tool in paideia-os is a from-scratch `.pdx` program; there is
no borrowed userland and no existing TUI facility. `postui` gives tools
like `postui-top` (task viewer), `postui-hex` (file/hex browser), and
`postui-dmesg` (klog tail) a shared widget substrate instead of hand-rolled
ANSI, while extending pillar 4 (semantically-queryable terminal): every
widget's `draw()` call emits both terminal cells and a frozen-schema
semantic-pipe record, so a scraper or agent can read screen state directly
without parsing ANSI.

## Local layout

- `docs/design.md` — the authoritative design document.
- `src/` — one module per widget/subsystem (populated starting M1).
- `tests/` — boot/unit smokes (populated starting M1).
- `tools/` — build/dev helper scripts (populated as needed).

## License

MIT — see LICENSE.
