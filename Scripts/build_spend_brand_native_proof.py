#!/usr/bin/env python3
"""Build a local debug proof overlay; restore application sources after packaging."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
destination = output / "CodexBar.app"
if destination.exists():
    raise SystemExit("Use a fresh proof output directory.")
entry = root / "Sources/CodexBar/CodexbarApp.swift"
overlay = root / "Sources/CodexBar/SpendBrandNativeProof.swift"
fixture = root / "Scripts/fixtures/spend_brand_native_proof.swift"
original = entry.read_bytes()
tracked = subprocess.check_output(["git", "show", "HEAD:Sources/CodexBar/CodexbarApp.swift"], cwd=root)
if original != tracked or overlay.exists():
    raise SystemExit("Refuse to overwrite existing source changes.")
marker = b"        if MenuBarLayoutNativeProof.runIfRequested() {"
patched = original.replace(marker, b"        if SpendBrandNativeProof.runIfRequested() { return }\n" + marker, 1)
if patched == original:
    raise SystemExit("Proof entrypoint anchor is missing.")
try:
    entry.write_bytes(patched)
    shutil.copyfile(fixture, overlay)
    with (output / "package.log").open("w") as log:
        subprocess.run(["./Scripts/package_app.sh", "debug"], cwd=root, stdout=log,
                       stderr=subprocess.STDOUT, check=True,
                       env={**os.environ, "CODEXBAR_SIGNING": "adhoc"})
    shutil.copytree(root / "CodexBar.app", destination, symlinks=True)
    info = destination / "Contents/Info.plist"
    metadata = plistlib.loads(info.read_bytes())
    metadata["CFBundleIdentifier"] = "com.steipete.codexbar.brand-proof"
    metadata["CFBundleDisplayName"] = "CodexBar Brand Proof"
    info.write_bytes(plistlib.dumps(metadata))
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(destination)], check=True)
    (output / "build-receipt.json").write_text(json.dumps({
        "productionHead": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "debugProofOverlay": True,
        "overlaySHA256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
        "productionViewsModified": False,
        "application": "CodexBar.app"
    }, indent=2) + "\n")
finally:
    if entry.read_bytes() == patched:
        entry.write_bytes(original)
    else:
        raise SystemExit("Source changed during packaging; preserve it for manual recovery.")
    overlay.unlink(missing_ok=True)
