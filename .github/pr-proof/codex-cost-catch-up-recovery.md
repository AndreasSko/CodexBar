# Codex cost catch-up recovery and cache compatibility

The [captured terminal output](codex-cost-catch-up-recovery.log) covers production revision
`e3c5efb99e7b31755d26fc84ee1a71a55f0f5c1b`. The later evidence commit changes only documentation.
All inputs are synthetic; private paths and unrelated test output are omitted. The complete original is retained locally.

## Results

- The real menu worker receives an empty time-budget yield from the actual fetcher, scanner, executor,
  and SQLite cache. It records the existing cooldown, requests a fresh two-second budget, and completes
  the pending scan with confirmed coverage. The forwarding wrapper returns the real measured duration
  and scan status. Only the empty pass uses a controlled clock; recovery scans use normal wall-clock budgets.
- The real dashboard worker pauses on an unreadable fixture file. After restoring permissions, another
  actual scan completes the same cache. Dashboard synchronization clears the pause through the real
  coverage read, with no additional dashboard scan pass.
- The released `ed735dc27ffa70d9` fingerprint is included in the predecessor adoption regression.
  All 41 predecessor cases pass, including reopening after the source file is removed. The complete
  stored snapshot, retained-report payload, and unfinished JSONL resume state survive with zero rebuilds;
  the saved checkpoint subsequently resumes the unfinished line correctly.

The clock and AC/nominal resource state are controlled, and cooldown waiting is skipped after recording
the scheduled delay. This proves the production component flow under fixture conditions, rather than
an app-bundle interaction or the exact cause of a historical user report.

## Reproduce on macOS

The opt-in [fixture](../../Scripts/fixtures/codex_cost_catch_up_proof.swift) uses the existing test helpers.
It creates temporary session inputs and one unique account cache, and cleans up only its allocated data.
Run from the repository root in Bash:

```bash
set -euo pipefail
proof_test=Tests/CodexBarTests/CodexCostCatchUpProductionProofTests.swift
test ! -e "$proof_test"
trap 'rm -f "$proof_test"' EXIT
cp Scripts/fixtures/codex_cost_catch_up_proof.swift "$proof_test"
source Scripts/test_environment.sh
swift test --filter 'CodexCostCatchUpProductionProofTests|CostUsageStoreTests'
```

The captured run passed all 77 tests across these two suites. The fixture checks its assertions before
printing each `PROOF` line. It does not alter an installed app or access a real account.
