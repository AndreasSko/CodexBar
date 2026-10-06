---
summary: "Official artwork used by spend chart legends and amount inspectors."
read_when:
  - Updating spend chart provider icons
---

# Spend chart provider artwork

Chart legends and amount inspectors request `ProviderBrandIcon.Style.brand`. Brand images retain
their original colors; a separate account color swatch matches the chart. Existing callers retain
the default adaptive monochrome style. OpenCodex sources retain their branch symbol.

All Usage & Spend provider icons share a fixed 20-point square slot, including chart legends,
amount inspectors, provider headings, account/source rows and subscription summaries. Callers cannot
override the size. Codex, Antigravity and Cursor's artwork use display scales of 1.22, 1.38 and 1.25 to
compensate for their transparent padding, giving each approximately 20-point visible artwork;
the monochrome Codex and Antigravity SVGs use scales of 1.24 and 1.14 for the same reason.
Source image bytes and aspect ratios remain unchanged. Both chart
locations use the same 8-point account swatch.

Brand and monochrome images have independent cache entries. Curated assets are keyed by product
identity, so OpenAI API and Azure OpenAI do not inherit Codex artwork from their shared legacy
monochrome resource. Providers without curated artwork fall back to the existing adaptive template,
including Cursor's cube mark. Cursor's official
[brand guidelines](https://cursor.com/brand) provide light and dark variants of its monochrome mark;
the orange chart swatch must not recolor the logo.

Verified 2026-10-06. Artwork identifies third-party products and remains owned by its creators.
Assets load from the application bundle without any network requests.

| Resource | Primary source and verification | Transformation |
| --- | --- | --- |
| `Brand-ProviderIcon-codex.png` | Installed OpenAI application `/Applications/ChatGPT.app`, bundle `com.openai.codex`, version `26.928.31416`, signing team `2DC432GLL2`; [Codex product page](https://openai.com/codex/) | Unmodified `Contents/Resources/icon-codex-light.png`. Preserves the blue/purple terminal artwork, rounded tile and transparent corners. The ICNS representation has an opaque square background, so it is unsuitable for inline original rendering. |
| `Brand-ProviderIcon-antigravity.png` | [Official homepage image](https://antigravity.google/assets/image/antigravity-logo.png), downloaded and hashed directly | Unmodified transparent PNG. Retains the official multicolor gradient, which native SVG decoding can flatten. |

| Bundled resource | SHA-256 |
| --- | --- |
| `Brand-ProviderIcon-codex.png` | `de7d43f3386105ab20952958c2c25beb0d903e2aeb6e1aef57c49a648c0d1c07` |
| `Brand-ProviderIcon-antigravity.png` | `193ba1805de11c23cd0c7a1df92aa0a886708e57350f6f7766100afe5befed73` |

Resource tests check separate caches in both load orders, original color pixels, transparent padding,
and adaptive fallback. Offline production view renders cover light/dark appearances and narrow widths.
