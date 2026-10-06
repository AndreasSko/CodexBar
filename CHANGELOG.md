# Changelog

## 0.72.1 — Unreleased

### Added

- CLI: persist provider data sources with `config set-source`, validate supported sources, and use `auto` to clear the override without changing provider enablement or credentials (#4142, #4197). Thanks @Yuxin-Qiao!
- Usage & Spend: choose the statistics time zone or pin the Mac's current time zone without editing hidden preferences; existing selections stay pinned until changed (#4185). Thanks @DGPisces!
- Langdock: add personal session and weekly usage through a bundled plugin bound to one selected Edge profile, with live session checks and no persistent quota history or widgets (#4171). Thanks @dYn36!
- Codex: list managed accounts and explicitly promote one from the macOS CLI, preserving displaced credentials with shared app/CLI locking, private atomic writes, and rejection of changed auth or managed-home destinations (#3191, #4234). Thanks @Yuxin-Qiao!

- Dashboard: expose managed Codex accounts with saved usage, stable IDs, independent errors, and shared identity redaction in one-shot JSON and HTTP schema-v1 snapshots (#4184). Thanks @niteshmanav!

### Changed

- Costs: reduce retained memory when loading and updating large Claude and Vertex transcript histories.
- Costs: use substantially less memory with large Claude and Vertex histories; cached cost history no longer keeps a second encoded copy in memory, cache files load from mapped reads and save as streams, and repeated session IDs and model names share storage.
- Costs: reduce temporary memory while rebuilding Claude cost reports, reloading the report cache, and merging Pi usage that adds no exact-time entries.
- Menu bar: make Cursor Grok Bot and other declared extra allowances selectable in provider metric settings, with labeled percentages and a dash for unknown readings (#4207). Thanks @marklights54-byte!

### Fixed

- Codex costs: a request with unknown historical pricing no longer hides the estimate for the other requests of its model and day. The day shows the priced subtotal as a partial estimate with its unpriced request count, and a day with an unpriced model is no longer reported as fully priced (#4273, #4278, #4279). Thanks @gabrielrojasc and @luochen211!
