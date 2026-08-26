# postui — status

**Wave:** postui v1 (Ratatui-parity TUI library)
**Current milestone:** none landed — design phase complete, M1 not started
**Version:** unreleased (pre-`0.1.0`)

See `docs/design.md` for the full spec and `docs/design.md` §5 for the
milestone/issue breakdown across this repo and its three reference-app
satellites (`postui-top`, `postui-hex`, `postui-dmesg`).

## Milestones

| Milestone | Scope | Status |
|---|---|---|
| M1 | Skeleton + cell buffer + minimal Block widget | open, not started |
| M2 | Layout + Paragraph/List/Table/Tabs | open, not started |
| M3 | Charts + canvas (Fixed64 fixed-point) | open, not started |
| M4 | Tree/calendar/textinput/input pipeline | open, not started |
| M5 | Semantic-pipe hookup + release | open, not started |

## Cross-repo dependencies

- **paideia-os `R89 — KIND_TUI_CANVAS substrate`**: postui.M1-004/005
  cannot land against a real kernel cap until R89.M1-001..003/005 land.
  See `docs/design.md` §4.
- **paideia-os `#1986` (`R66v2.POS-001`, `KIND_TTY` raw-mode + `TTY_OP_READ`)**:
  postui's primary input path (§2.5); the `sys_read(0)` fallback unblocks
  M1–M3 in the meantime.
- **paideia-as `R89-XREPO.PAS-001`** (scalar f32/f64 codegen): tracked,
  non-blocking. postui v1 ships on the Q32.32 `Fixed64` module instead
  (`docs/design.md` §1.4).

## License

MIT — see LICENSE.
