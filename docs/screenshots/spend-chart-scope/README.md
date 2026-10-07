---
summary: "Synthetic screenshots and validation for spend chart date inspection and active source legends."
read_when:
  - Reviewing spend chart date selection and source visibility
---

# Spend chart scope proof

These screenshots render the production `SpendDashboardTrendPanel` with deterministic fixtures from
`SpendTrendScopeTests` and `SpendTrendChartRenderTests`. Dates, account labels and amounts are synthetic.

- `overview-narrow.png`: the fixture contains six source rows, but only the three sources with positive
  spend in the displayed October 1–7 range appear in the legend. The amount inspector wraps items as
  needed, and its date belongs to an actual bucket. Dates without daily buckets are excluded from inspection.
- `hourly.png`: only the two sources with positive hourly spend on October 7 appear in the legend.
  The zero-cost Claude record remains in the model, preserving recorded-zero versus missing-hour
  behavior, while its legend and amount row do not occupy space.

The overview legend follows the whole selected range or drilled interval. The hourly legend follows
the selected day. The amount inspector follows its selected bucket. Source colors and identities use
the complete source list, keeping multiple accounts distinct when unused sources are hidden.

## Validation

The production and test sources were validated at `70b194db18374bae6a90196b786771c684023a97`, based on
upstream `03a51bdcf`. The later evidence commit only adds these screenshots and this document.

- `make check` passed, with zero SwiftLint violations.
- Full regression via `./Scripts/test.sh --direct-workers 4` passed all 1,586 test selections
  in 144/144 groups on the first attempt, with zero retries or timeouts.
- Focused regression passed 30 Swift Testing tests in five suites plus one XCTest native render test.
  The render test produced 14 screenshots, including Chinese light/dark and wide/narrow layouts.
- Tests cover out-of-range and empty daily dates in UTC, Asia/Shanghai and America/Los_Angeles,
  partial weekly buckets, missing hourly data, used versus idle sources, account colors, drilled
  intervals and stale focused dates.

The initial serial `make test` run was stopped while switching to the complete direct run above and
is not counted as a pass. Screenshots verify native component layout with isolated fixtures; a
packaged-app pointer interaction was not captured. The installed application was not replaced.

Reproduce from the repository root:

```sh
make check
CODEXBAR_SPEND_TREND_PROOF_DIR="$PWD/.build/spend-chart-proof" ./Scripts/test.sh --direct-workers 4
CODEXBAR_SPEND_TREND_PROOF_DIR="$PWD/.build/spend-chart-proof" \
  ./Scripts/test_fast.sh --skip-build \
  --filter 'SpendTrendScopeTests|SpendTrendChartTests|SpendTrendPresentationRegressionTests|SpendTrendCalendarTests|SpendTrendOverflowTests|SpendTrendChartRenderTests'
```

The published images correspond to `13-used-sources-narrow.png` and `14-hourly-used-sources.png` in
the render output. Only optional EXIF metadata was removed for publication; image pixels and color
profiles are unchanged. No user-supplied screenshots, personal account history or raw local logs
are included.
