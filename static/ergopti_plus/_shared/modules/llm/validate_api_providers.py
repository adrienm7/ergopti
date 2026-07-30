#!/usr/bin/env python3
# _shared/modules/llm/validate_api_providers.py
"""Validate _shared/modules/llm/api_providers.json (CI-friendly, no AHK/Lua required)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

CATALOG = Path(__file__).with_name("api_providers.json")
ALLOWED_FORMATS = {"openai", "anthropic", "gemini"}
REQUIRED_PROVIDER_KEYS = {"label", "base_url", "default_model", "format"}
REQUIRED_PRICE_KEYS = {"in", "out"}


def main() -> int:
    errors: list[str] = []
    if not CATALOG.is_file():
        print(f"FAIL: missing {CATALOG}", file=sys.stderr)
        return 1

    try:
        data = json.loads(CATALOG.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"FAIL: invalid JSON — {exc}", file=sys.stderr)
        return 1

    order = data.get("provider_order")
    providers = data.get("providers")
    prices = data.get("model_prices")

    if not isinstance(order, list) or not order:
        errors.append("provider_order must be a non-empty array")
    if not isinstance(providers, dict) or not providers:
        errors.append("providers must be a non-empty object")
    if not isinstance(prices, dict):
        errors.append("model_prices must be an object")

    if isinstance(order, list) and isinstance(providers, dict):
        seen: set[str] = set()
        for pid in order:
            if not isinstance(pid, str) or not pid:
                errors.append("provider_order entries must be non-empty strings")
                continue
            if pid in seen:
                errors.append(f"duplicate provider_order entry: {pid}")
            seen.add(pid)
            if pid not in providers:
                errors.append(f"provider_order references unknown provider: {pid}")

        for pid, desc in providers.items():
            if not isinstance(desc, dict):
                errors.append(f"providers.{pid} must be an object")
                continue
            missing = REQUIRED_PROVIDER_KEYS - set(desc)
            if missing:
                errors.append(f"providers.{pid} missing keys: {sorted(missing)}")
            fmt = desc.get("format")
            if fmt not in ALLOWED_FORMATS:
                errors.append(f"providers.{pid}.format must be one of {sorted(ALLOWED_FORMATS)}")

        orphans = set(providers) - set(order)
        if orphans:
            errors.append(f"providers not listed in provider_order: {sorted(orphans)}")

    if isinstance(prices, dict):
        for model, row in prices.items():
            if not isinstance(row, dict):
                errors.append(f"model_prices.{model} must be an object")
                continue
            missing = REQUIRED_PRICE_KEYS - set(row)
            if missing:
                errors.append(f"model_prices.{model} missing keys: {sorted(missing)}")
            for key in REQUIRED_PRICE_KEYS:
                val = row.get(key)
                if not isinstance(val, (int, float)) or val < 0:
                    errors.append(f"model_prices.{model}.{key} must be a non-negative number")

    root = CATALOG.parent.parent.parent  # static/ergopti_plus
    ahk = root / "windows" / "modules" / "llm" / "api_remote.ahk"
    lua = root / "macos" / "modules" / "llm" / "api_remote.lua"
    for path, label in ((ahk, "AHK"), (lua, "HS")):
        if not path.is_file():
            errors.append(f"{label} driver file missing: {path}")
            continue
        body = path.read_text(encoding="utf-8")
        if "api_providers.json" not in body:
            errors.append(f"{label} api_remote must load api_providers.json (found stale inline catalogue?)")

    if errors:
        print("FAIL: api_providers validation:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    n_prov = len(providers) if isinstance(providers, dict) else 0
    n_price = len(prices) if isinstance(prices, dict) else 0
    print(f"OK: api_providers.json — {n_prov} providers, {n_price} price rows")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())