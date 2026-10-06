---
summary: "Synthetic native screenshots and validation for token activity readability."
read_when:
  - Reviewing the token activity palette, minimum cell size, or horizontal navigation
---

# Token activity readability

These are native SwiftUI component renders using fixed synthetic activity and a fixed date. The displayed total is a test fixture; no personal usage, account history, or original user screenshot is included. The images cover the component, not an installed full-app session.

At 339 points of content width, the previous layout squeezed the entire year into tiny cells and let the English title wrap into a narrow column. The updated layout keeps days at least 10 points wide, defaults to the recent end, and provides labeled navigation with overlapping weeks. At 760 points, the year fits and the navigation row disappears.

## Before: narrow Dark mode

Rendered with the same synthetic input against the unmodified base implementation.

![Previous narrow Dark mode](before-dark-narrow.png)

## After: narrow Dark mode, recent end

![Narrow Dark mode](dark-narrow.png)

## After: narrow Dark mode, earliest end

![Earliest activity](dark-earliest.png)

## After: narrow Light mode

![Narrow Light mode](light-narrow.png)

## After: wide Dark mode

![Wide Dark mode](dark-wide.png)

## Native proof

To enable the optional native rendering, mouse-click, and date-reveal tests from the repository root on macOS:

```bash
source Scripts/test_environment.sh
CODEXBAR_ACTIVITY_READABILITY_PROOF_DIR="$PWD/.build/activity-proof" \
  swift test --filter 'SpendActivityAppearanceTests|SpendActivityHeatmapTests|SpendActivityReadabilityRenderTests|LocalizationLanguageCatalogTests|LocalizationBundleTests|UserFacingLocalizationCoverageTests'
```

The final focused run passed 85 Swift Testing tests and all 3 enabled native XCTest cases. The screenshot matrix produced 80 images across Chinese/English, Light/Dark mode, 339/520/760-point widths, all three activity modes, partial coverage, and zero activity. Native mouse events changed the 339-point viewport offsets through `350, 26, 0, 0, 325, 350, 350`: both ends are reachable, and clicking the disabled end controls does not move the viewport.

`make check` passed. A complete `make test` run on source commit `47479f3a0eaf82ffb0081a4fa41dbdc36dc1abe4` exited successfully: all 143 groups completed. The first pass completed 142 groups; group 134 timed out and the repository script recovered it by running all 12 selections individually. The [sanitized receipt](full-test-receipt.json) records that retry instead of claiming a clean first pass.

The unchanged cached-title performance test passed its original 50 ms budget in that complete run. The clean upstream base also passed its full 83-test renderer suite on the same host. Another isolated PR renderer run failed the budget at 85.7 ms, so timing variability remains observed and its exact cause is undetermined; the renderer source and test are byte-identical to the base. No test or threshold was relaxed.

The [full-app synthetic proof launcher](runtime/README.md) builds a separate packaged app with the complete production Usage & Spend pane. It is a reproducible setup artifact; the complete-app interactive capture is pending because the host locked before paging and date-inspection recording finished. Installed-app trackpad and VoiceOver operation remain unverified. No original user screenshot or real account history is included in this evidence.
