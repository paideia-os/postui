# postui — CHANGELOG

All notable changes are logged here per Keep a Changelog convention.
Semver strictly followed. Tag: postui-vX.Y.Z at each release.

## [1.0.0] — 2026-09-07

Initial release. Ratatui-parity TUI widget library over KIND_TUI_CANVAS.

### Added
- M1: Rect/Style/Color/Cell/Buffer primitives; Frame/Terminal driver;
  Block widget; WidgetKind dispatch (7 issues).
- M2: Layout engine (largest-remainder apportionment); Text/Span/Line
  + Width UTF-8 module; Paragraph/List/Table/Tabs/Scrollbar widgets;
  semantic-pipe registry (10 issues).
- M3: Fixed64 Q32.32 module; Gauge/Sparkline/BarChart/Chart/Canvas
  widgets (7 issues).
- M4: TextInput/Tree/Calendar/Clear widgets; Padding utility;
  Event enum + ESC-sequence parser (mouse + bracketed-paste);
  Terminal input dispatcher (KIND_TTY primary/sys_read fallback)
  (8 issues).
- M5: Schema-version-tolerance conformance; scraper example;
  release manifest + dual ML-DSA-65/Ed25519 signing;
  .pdxdoc source; full widget-catalog smoke matrix (6 issues).

### Requires
- paideia-as v0.34+ (module basename PascalCase, cmp reg/imm32 only,
  no test mnemonic, byte-load zero-then-mov_b, SysV push-pop parity).
- paideia-os R89 KIND_TUI_CANVAS substrate.

### Fingerprint
[base64 blake3 hash of the source tree at v1.0.0 tag, generated
post-tag via find-blake3]
