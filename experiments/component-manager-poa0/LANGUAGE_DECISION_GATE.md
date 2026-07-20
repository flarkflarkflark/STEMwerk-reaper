# Language decision gate

`FINAL_LANGUAGE_DECISION=pending_native_ci` and `LOCAL_PREFERENCE=none`.

Hard gates are all common native cases, state rebuild, crash recovery,
generation activation, run pinning, stale-lease policy, zero mixed visibility,
correct native architecture, and no hidden Python/shell dependency in the
product design.

Practical evidence covers platform workarounds, build/test friction,
dependency quality, diagnostics, maintainability, agent reviewability,
complexity, CI stability, signability/notarization suitability, and Windows and
macOS toolchain/API friction.

- `RUST_WINS`: Rust clears every hard gate and Go fails one, or Rust has
  demonstrably better correctness/maintenance without disproportionate
  platform friction.
- `GO_WINS`: Go clears every hard gate and Rust fails one, or Go is materially
  easier to build/test/maintain without correctness loss.
- `NO_LANGUAGE_WINNER`: both clear hard gates and practical differences are
  inconclusive; product owner/maintainer decides using team preference,
  maintenance cost, future integration, and library risk.
- `ARCHITECTURE_REVIEW`: both fail the same architectural boundary.

No fixed percentage threshold is sufficient by itself.
