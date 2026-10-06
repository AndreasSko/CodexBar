# Packaged application proof

The native screenshots use synthetic data in a freshly packaged debug application. A local
debug overlay supplies isolated settings and snapshots before ordinary provider startup.
It opens the production `SettingsWindowController` on General; the Usage & Spend pane is then
selected through the application's real settings sidebar. The production preferences window,
dashboard, icon loader and packaged resource lookup are unchanged.

This is application-window evidence with synthetic inputs. It does not claim authenticated
provider transport, real billing totals, or a release build. The six other images in the parent
directory remain component-rendering evidence.

## Reproduce

Use a fresh output directory:

```sh
python3 Scripts/build_spend_brand_native_proof.py /tmp/codexbar-brand-proof
mkdir -p /tmp/codexbar-brand-proof/home
XCTestSessionIdentifier=brand-native-proof \
CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 \
CODEXBAR_TEST_CODEX_FILE_ISOLATION=1 \
CODEXBAR_TEST_SESSION_FILE_ISOLATION=1 \
CFFIXED_USER_HOME=/tmp/codexbar-brand-proof/home \
CODEXBAR_SPEND_BRAND_NATIVE_DIR=/tmp/codexbar-brand-proof \
/tmp/codexbar-brand-proof/CodexBar.app/Contents/MacOS/CodexBar \
  --spend-brand-proof -AppleLanguages '(en)' -AppleLocale en_US
```

The builder refuses to overwrite source changes, temporarily inserts the opt-in debug entrypoint,
packages with the repository script, and restores the tracked entrypoint in `finally`. Its proof
application has a separate bundle identifier. The overlay is not part of normal application builds
or provider behavior. The source is in `Scripts/fixtures/spend_brand_native_proof.swift`.

Select **Usage & Spend** in the settings sidebar. Capture the window in both appearances.
The proof application's **Toggle proof appearance** menu item (Command-D) changes only that
proof application's appearance. Quit with Command-Q.

The launcher requires test credential/session isolation and suppressed Keychain access. Automatic
refresh is disabled, the controller returns only its synthetic inputs, and an attempted provider
transport or login fails the proof. No real account, session, usage or monetary data is used.

## Evidence

- `application-light.png` and `application-dark.png`: native window screenshots after sidebar entry.
- `runtime-light.json` and `runtime-dark.json`: selected pane, appearance, application-bundle lookup
  and template/original icon flags. Local process/window identifiers are omitted from public copies.
- `build-receipt.json`: production revision and the exact debug overlay checksum.
- `regression-receipt.json`: complete local regression result using the repository's optional
  direct execution mode, with all discovered selections included.

Codex and Claude provider images report original rendering; their child images report template
rendering. Cursor keeps its existing template fallback. The screenshots also retain monochrome
provider icons in the settings sidebar.
