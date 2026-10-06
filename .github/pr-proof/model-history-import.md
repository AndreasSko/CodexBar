# Real model-history import proof

[The anonymized transcript](model-history-import.log) records four successful runs against a copied real usage log: base/cold, base/warm, after/cold, and after/warm. Both variants use byte-identical input and a frozen pricing catalog. Every warm run starts a separate process and reads zero log bytes, exercising the persisted SQLite cache.

The observer invokes `SpendDashboardSource.mergingOpenCodexInputsWithObservation` with its default loader. This traverses `OpenCodexUsageStore.loadEntries`, parsing/cache storage, provider fan-out, aggregation, and `SpendDashboardModel.build`. No loader stub or duplicate baseline aggregator is used. The independently built base checkout has unchanged production code; the same opt-in observer was temporarily copied into it after its clean-tree regression run and then removed.

The baseline drops the named dashboard model rows. The repaired revision retains all named rows present in the requested daily report and propagates missing-usage exclusions. Known non-null token and finite cost subtotals match exactly across revisions. The complete daily reports also match after removing only `incompleteRequestCount`; each variant's cold/warm receipts match without removing any fields. Share statistics continue to omit incomplete model rankings.

The transcript is an anonymized derivative, not a raw transcript or installed-app capture. Original copied input, raw logs, cache databases, and JSON receipts remain private. Model names, personal paths, sessions/accounts, timestamps, request/token quantities, money, credentials, and endpoints are withheld. The derivative includes neither hashes of private input nor individual model counts. The existing component screenshots use synthetic fixtures and remain separate evidence.

## Reproduce with private inputs

Build each revision independently, without copying build products. Add the identical [`SpendDashboardRealImportProofTests`](../../Tests/CodexBarTests/SpendDashboardRealImportProofTests.swift) observer to the unchanged base. It skips unless all proof controls are provided.

Outside the checkout, prepare `import-proof/base` and `import-proof/after`, each containing:

- `inputs/opencodex/usage.jsonl`: identical private copied logs that reproduce missing-usage model retention.
- `inputs/models-dev-v1.json`: identical frozen pricing catalog.
- `home/`: a fresh isolated Foundation home for that variant.

Use a fixed private reference time appropriate to the copied input. In each checkout, invoke the repository's native test entrypoint once with `cold` and once with `warm`, in separate processes:

```sh
env CFFIXED_USER_HOME="$PROOF_ROOT/home" \
  CODEXBAR_MODEL_IMPORT_PROOF_ROOT="$PROOF_ROOT" \
  CODEXBAR_MODEL_IMPORT_PROOF_NOW="$FIXED_NOW" \
  CODEXBAR_MODEL_IMPORT_PROOF_BASELINE="$IS_BASELINE" \
  CODEXBAR_MODEL_IMPORT_PROOF_PHASE="$PHASE" \
  ./Scripts/test_fast.sh --skip-build --filter SpendDashboardRealImportProofTests
```

`PROOF_ROOT` is that variant's private root; `IS_BASELINE` is `1` for base and `0` for after. Keep each full output at `import-proof-{base,after}-{cold,warm}.log` and its actual process exit code as a JSON integer in the matching `-exit.json` file in the private parent directory. A passing run must execute the observer, with no skipped test. The observer guards cache isolation before reading production inputs and writes receipts under `private-receipts/` with owner-only file permissions.

Only after all four processes succeed, run the [allowlist validator](verify_model_history_import.py):

```sh
python3 .github/pr-proof/verify_model_history_import.py \
  "$PRIVATE_DIRECTORY" "$PUBLIC_DERIVATIVE" \
  --base-revision "$BASE_COMMIT" --after-revision "$AFTER_COMMIT"
```

It checks actual process success, exact observer diagnostics, input equality, raw receipt equality, model retention, exclusion propagation, and unchanged known accounting before writing public output. It emits fixed diagnostic strings and public commit IDs only. Do not publish the private directory, raw receipts, or raw logs.
