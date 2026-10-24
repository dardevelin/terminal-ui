#!/usr/bin/env python3
"""An app's own package can run swtui.

The tutorial has the reader drive their running app with
``swift run swtui ctl …`` from their own package. SwiftPM lets a package run
only the executables its dependencies declare as products, and swtui was a
bare target: from anywhere but this checkout the command failed with "no
executable product named 'swtui'". Its being a product is what the manifest
says, so the manifest is what this reads.

Run::

    python3 tools/scripts/test_swtui_is_a_product.py
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from terminalui.cases import run_cases  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]


def declared_products() -> dict[str, list[str]]:
    manifest = subprocess.run(["swift", "package", "dump-package"], cwd=REPO_ROOT,
                              capture_output=True, text=True, check=True).stdout
    return {product["name"]: list(product["type"]) for product in json.loads(manifest)["products"]}


def swtui_is_an_executable_product() -> None:
    products = declared_products()
    assert products.get("swtui") == ["executable"], f"declared products: {products}"


if __name__ == "__main__":
    sys.exit(run_cases([("swtui is an executable product", swtui_is_an_executable_product)]))
