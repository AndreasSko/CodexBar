# Langdock synthetic presentation proof

These captures use production menu cards and settings rows, synthetic responses/profiles, a fixed
clock, and no account data. The menu fixtures pass through the bundled plugin and the selected-profile
host. They demonstrate presentation, not live browser import or packaged-app acceptance.

- `langdock-settings-before.png`: the original draft's directory field, reconstructed with the production field row.
- `langdock-settings-after.png`: the shared Browser profile picker with an explicitly selected synthetic Edge profile.
- `langdock-active.png`: session 23% and weekly 54% used.
- `langdock-weekly-only.png`: disabled session limits leave the weekly value visible.
- `langdock-stale.png`: a transient failure retains the values and their original 15-minute age.

Regenerate without browser-cookie or Keychain access:

```bash
unset CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS
source Scripts/test_environment.sh
CODEXBAR_LANGDOCK_PROOF_DIR=/tmp/langdock-proof \
  swift test --build-system native --jobs 4 -Xswiftc -gnone --no-parallel \
  --filter 'LangdockScreenshotRenderTests|LangdockProfileScreenshotTests'
```

Rendering is opt-in through the output-directory variable. Parser, session, settings, history, and
widget/export assertions run independently. [acceptance.md](acceptance.md) preserves the contributor's
historical native-build record; the current plugin verification is reported in the PR body.
