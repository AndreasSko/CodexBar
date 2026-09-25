---
summary: "Langdock personal included-usage limits from a selected Microsoft Edge profile."
read_when:
  - Setting up Langdock in CodexBar
  - Debugging Langdock profile or cookie access
---

# Langdock

CodexBar reads the personal included-usage limits shown on Langdock's account Usage page. This
provider is disabled by default and supports macOS Edge profiles only.

1. Sign in to Langdock in the Edge profile you want to monitor.
2. In CodexBar's Langdock provider settings, enter that profile's directory path as **Edge profile ID**.
   The path must identify the exact Edge profile that owns the Langdock session.
3. Enable Langdock, then refresh. The CLI equivalent is
   `codexbar usage --provider langdock --source web`.

CodexBar selects that one profile and reads its applicable `langdock.com` and `app.langdock.com`
cookies in memory. It does not switch to another Edge account if the selected profile is missing
or its session expires. macOS must allow the running CodexBar bundle to read the Edge profile and
the Edge Safe Storage Keychain item. Browser access errors are shown in CodexBar; no administrator
rights or access to the Langdock macOS app are required.

If usage disappears after a restart, verify the saved **Edge profile ID** against the profile
path shown by `edge://version` in the same Edge window as Langdock. A message that Edge cookie
access is blocked calls for a manual Langdock refresh and a check of CodexBar's Keychain access
setting. If CodexBar reports that it cannot read the profile, check **Privacy & Security → Files &
Folders → CodexBar → Microsoft Edge** for the exact app bundle being run. Local ad hoc signed
builds may need a renewed macOS grant after rebuilding. A missing cookie store remains a separate
profile or browser-data problem; CodexBar does not try another profile.

Langdock reports a five-hour session percentage and a seven-day weekly percentage. A disabled
session limit hides the session bar. Missing reset dates remain unknown. If Langdock returns a
valid response without included plan usage, CodexBar shows “No included usage limits available.”
Extra Usage, workspace-wide billing, and widgets are outside this integration.
