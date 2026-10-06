#!/usr/bin/env python3
"""Validate private real-import receipts and emit an allowlisted public derivative.

The input directory and all receipts/logs must stay outside the checkout. No
private values are copied into the output, including hashes of private inputs.
"""

import argparse
import json
import math
from pathlib import Path
import re


def require(condition, message):
    if not condition:
        raise ValueError(message)


def without_exclusions(value):
    if isinstance(value, dict):
        return {key: without_exclusions(item) for key, item in value.items()
                if key != "incompleteRequestCount"}
    if isinstance(value, list):
        return [without_exclusions(item) for item in value]
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("private_directory", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--base-revision", required=True)
    parser.add_argument("--after-revision", required=True)
    args = parser.parse_args()
    for revision in (args.base_revision, args.after_revision):
        require(re.fullmatch(r"[0-9a-f]{40}", revision), "Expected a public Git commit ID.")

    variants = {}
    sections = []
    for variant in ("base", "after"):
        root = args.private_directory / "import-proof" / variant
        receipts = []
        for phase in ("cold", "warm"):
            prefix = args.private_directory / f"import-proof-{variant}-{phase}"
            require(json.loads(prefix.with_name(prefix.name + "-exit.json").read_text()) == 0,
                    "A proof process did not exit successfully.")
            transcript = prefix.with_suffix(".log").read_text()
            require("test_copiedLogTraversesProductionImportAndCache]' passed" in transcript
                    and "Executed 1 test, with 0 failures" in transcript and "skipped" not in transcript,
                    "Expected an executed, passing observer test.")
            expected = [
                f"IMPORT_PROOF phase={phase} productionSource=available sourceKind=openCodex",
                "IMPORT_PROOF storeCachePresent=true reader="
                + ("full-log" if phase == "cold" else "cached-zero-log-bytes"),
                "IMPORT_PROOF namedModels=" + ("hidden exclusions=absent" if variant == "base"
                                               else "retained exclusions=propagated"),
                "IMPORT_PROOF knownSubtotals=preserved-on-dashboard",
            ]
            if phase == "warm":
                expected.append("IMPORT_PROOF freshProcessReload=identical-daily-and-dashboard-accounting")
            actual = [line for line in transcript.splitlines() if line.startswith("IMPORT_PROOF ")]
            require(actual == expected, "Observer diagnostics do not match the allowlist.")
            sections.append(f"[{variant} / {phase} / separate process / XCTest PASS]")
            sections.extend(expected)
            receipts.append(json.loads((root / "private-receipts" / f"{phase}.json").read_text()))
        require(receipts[0] == receipts[1], "Cold and warm receipts differ.")
        variants[variant] = receipts[0]

    old, new = variants["base"], variants["after"]
    require(old["knownTokens"] is not None and old["knownCost"] is not None
            and math.isfinite(old["knownCost"]), "Expected known finite accounting subtotals.")
    require(old["knownTokens"] == new["knownTokens"] and old["knownCost"] == new["knownCost"],
            "Known accounting subtotals differ between revisions.")
    require(old["expectedModelNames"] == new["expectedModelNames"]
            and old["modelNames"] == [] and new["modelNames"] == new["expectedModelNames"],
            "Expected model retention changed differently from the reported repair.")
    require(old["incompleteRequests"] == 0 and new["incompleteRequests"] > 0,
            "Expected missing-usage markers were not propagated.")
    require(without_exclusions(old["daily"]) == without_exclusions(new["daily"]),
            "Daily accounting differs beyond the exclusion markers.")
    for name in ("inputs/opencodex/usage.jsonl", "inputs/models-dev-v1.json"):
        require((args.private_directory / "import-proof/base" / name).read_bytes()
                == (args.private_directory / "import-proof/after" / name).read_bytes(),
                "Private inputs differ between revisions.")

    output = (
        "Anonymized derivative of real production import runs.\n"
        "Private model names, paths, sessions/accounts, timestamps, request/token quantities and monetary values are withheld.\n"
        "Original input, raw logs, SQLite caches and JSON receipts are preserved locally; this is not an untouched raw transcript.\n\n"
        f"Base production revision: {args.base_revision}\n"
        f"After production revision: {args.after_revision}\n"
        "Observer: Tests/CodexBarTests/SpendDashboardRealImportProofTests.swift (identical in both checkouts)\n"
        "Path: SpendDashboardSource.mergingOpenCodexInputsWithObservation -> default store.loadEntries -> fan-out/aggregator -> SpendDashboardModel.build\n"
        "Input-byte equality between variants: PASS\n"
        "Frozen pricing-catalog byte equality between variants: PASS\n"
        "Known non-null token subtotal equality between variants: PASS\n"
        "Known non-null finite cost subtotal equality between variants: PASS\n"
        "Daily known accounting equality with exclusion markers removed: PASS\n"
        "Named models hidden on base and retained after fix: PASS\n"
        "Incomplete-request markers absent on base and propagated after fix: PASS\n"
        "Fresh-process cold/warm daily and dashboard accounting equality: PASS\n\n"
        + "\n".join(sections) + "\n"
    )
    args.output.write_text(output)
    print("Anonymized production-import evidence generated; every validation passed.")


if __name__ == "__main__":
    main()
