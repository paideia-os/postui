# postui — STATUS

## v1.0.0 shipped 2026-09-07 (postui-v1.0.0)

### Milestone rollup
- M1 skeleton + Block: DONE (9/9 + 4 fixups)
- M2 layout + primitives + widgets: DONE (10/10 + 6 fixups)
- M3 Fixed64 + charts: DONE (7/7 + 3 fixups)
- M4 TextInput/Tree/Calendar/Event: DONE (8/8)
- M5 conformance + release: DONE (6/6)

### Deferred (tracked as follow-ups)
- postui#41: tcc_resize/clear/debug_print frozen 2-arg ABI (M2/M5)
- postui#42: sys_semantic_send stub -> live wire (blocked by paideia-os)
- postui#43: Fixed64 32x32-split multiply for wider semantic range
- postui#44: TERMINAL_KIND_TTY_LIVE flip (blocked by paideia-os#1986)

### Consumer tools (waiting downstream)
- postui-top (top-like process viewer)
- postui-hex (hex viewer)
- postui-dmesg (kernel log viewer)

### Design docs
- docs/design.md (authoritative spec)
- design/architecture.md (internal spec)
- design/release-manifest.md (release policy)
- doc/postui.pdxdoc (viewer source)
