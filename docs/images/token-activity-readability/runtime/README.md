---
summary: "Isolated full-app token activity proof using only synthetic history."
read_when:
  - Reproducing token activity in the complete Usage & Spend pane
---

# Full-app proof launcher

Run `bash docs/images/token-activity-readability/runtime/launch.sh` from a checkout of the PR on macOS. The script creates and retains a separate worktree, builds an ad-hoc signed debug app, and launches the complete production `SpendDashboardPane` with its real controller and data model. It does not replace an installed app.

The opt-in launcher uses a fixed date (2026-10-06 UTC) and 365 generated daily entries. Every displayed account, model, token count, and amount is a **synthetic fixture**, not personal history. Preferences and token stores are in memory, normal startup is bypassed, Keychain access is disabled, and the provider transport override fails if invoked. The production activity, coverage, aggregation, and date-selection paths remain active.

The footer provides narrow/wide and Light/Dark controls plus a Snapshot action. The app writes its own content-view PNGs and local state receipts, including selected dates and nested scroll offsets. Raw build/runtime logs and receipts may contain machine paths or timestamps: retain them privately and publish only inspected screenshots and a sanitized receipt.

For interactive evidence, show the activity section at narrow width, page to both ends, inspect/select a date, check keyboard date reveal, switch appearance, and widen the window until the year fits. The receipt should show annual content width 689, narrow viewport width 355, initial offset 334, and a selected date after a real grid click.

This launcher is a reproducible setup artifact. Complete-app interactive evidence is still pending; the host was locked before that capture could finish. The existing component screenshots and enabled native tests are documented separately in the parent README.
