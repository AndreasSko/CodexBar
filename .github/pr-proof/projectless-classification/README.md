# Independent Codex chats: synthetic native UI proof

These screenshots contain synthetic fixture data only. Names, paths, account sources, token counts, and amounts do not represent personal usage. The window is explicitly labeled “Synthetic Usage & Spend”.

The opt-in `SpendDashboardNativeProofTests` fixture uses the production dashboard and Codex metadata-classification path in an isolated test host. The fixture has one project row and three independently marked chat rows, including an attachment-heading title that falls back to “Independent chat”.

- `chats.png`: three rows under Independent chats, with saved titles or a neutral fallback.
- `privacy.png`: the same rows after toggling privacy, with numbered labels and unchanged synthetic amounts.

Interaction covered switching Projects/Independent chats, toggling privacy on and off, checking path/tooltips are hidden, and restoring titles. These captures preceded a read-only membership equality compatibility correction; the UI implementation did not change. Final-code fixture loading also passed, but a further interactive repeat was blocked by the locked Mac. This is synthetic runtime evidence, not validation against a user's installed application or live accounts.

Set `CODEXBAR_SPEND_NATIVE_PROOF_DIR` to an isolated output directory and enable `CODEXBAR_SPEND_PROJECTLESS_NATIVE_PROOF=1` with the native proof fixture. See its existing environment/output controls in `Tests/CodexBarTests/SpendDashboardNativeProofTests.swift`.
