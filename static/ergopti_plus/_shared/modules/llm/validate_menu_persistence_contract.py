#!/usr/bin/env python3
"""Validate menu_persistence_contract.json (CI-friendly, no AHK/Lua required)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

CONTRACT = Path(__file__).with_name("menu_persistence_contract.json")

REQUIRED_ENTRY = {"id", "ahk"}
AHK_REQUIRED = {"tray_key", "section", "key", "sample"}
HS_OPTIONAL_NULL = True


def _check_hs(hs: dict | None, entry_id: str, errors: list[str]) -> None:
    if hs is None:
        return
    if not isinstance(hs, dict):
        errors.append(f"{entry_id}: hs must be object or null")
        return
    if "flat_key" not in hs:
        errors.append(f"{entry_id}: hs.flat_key required when hs is set")
    if hs.get("persist") == "nested":
        if not hs.get("nested_key"):
            errors.append(f"{entry_id}: hs.nested_key required for persist=nested")
    elif not hs.get("section") or not hs.get("key"):
        if not (hs.get("section") and hs.get("path") and hs.get("key")):
            errors.append(f"{entry_id}: hs needs section+key or section+path+key")
    if hs.get("toml_array") and "sample" not in hs:
        errors.append(f"{entry_id}: hs.sample required for toml_array")


def _check_ahk(ahk: dict, entry_id: str, errors: list[str]) -> None:
    if not isinstance(ahk, dict):
        errors.append(f"{entry_id}: ahk must be object")
        return
    persist = ahk.get("persist")
    if persist == "extra":
        for k in ("tray_key", "section", "key", "sample"):
            if k not in ahk:
                errors.append(f"{entry_id}: ahk.{k} required for persist=extra")
        return
    missing = AHK_REQUIRED - set(ahk)
    if missing:
        errors.append(f"{entry_id}: ahk missing {sorted(missing)}")
    if "features" not in ahk and persist != "extra":
        errors.append(f"{entry_id}: ahk.features required unless persist=extra")


def _check_ahk_persist_source(entries: list[dict], errors: list[str]) -> None:
    persist = CONTRACT.parent.parent / "windows" / "ui" / "tray_llm" / "persist.ahk"
    if not persist.is_file():
        return
    body = persist.read_text(encoding="utf-8")
    sync = body[
        body.find("_LLM_Tray_SyncToFeatures()") : body.find("_LLM_Tray_AppendPersistedUpdates")
    ]
    append = body[
        body.find("_LLM_Tray_AppendPersistedUpdates") : body.find("LLM_Tray_BuildSavedOpts")
    ]
    build = body[body.find("LLM_Tray_BuildSavedOpts") :]
    for entry in entries:
        ahk = entry.get("ahk")
        if not isinstance(ahk, dict):
            continue
        tk = ahk["tray_key"]
        needles = (f'"{tk}"', f"['{tk}']")
        if not any(n in sync or n in append for n in needles):
            errors.append(f"{entry['id']}: tray_key {tk} missing from persist sync/append")
        if ahk.get("persist") != "extra" and f'opts["{tk}"]' not in build:
            if entry["id"] not in ("nav_modifiers", "disabled_apps", "trigger_shortcut"):
                errors.append(f"{entry['id']}: BuildSavedOpts missing opts[\"{tk}\"]")


def _check_hs_preferences(entries: list[dict], errors: list[str]) -> None:
    prefs = CONTRACT.parent.parent / "macos" / "ui" / "menu" / "preferences.lua"
    if not prefs.is_file():
        return
    body = prefs.read_text(encoding="utf-8")
    for entry in entries:
        hs = entry.get("hs")
        if not isinstance(hs, dict) or not hs.get("flat_key"):
            continue
        fk = hs["flat_key"]
        if fk not in body:
            errors.append(f"{entry['id']}: preferences.lua missing flat_key {fk}")


def main() -> int:
    raw = CONTRACT.read_text(encoding="utf-8")
    data = json.loads(raw)
    errors: list[str] = []
    if not isinstance(data.get("entries"), list):
        print("contract must have entries[]", file=sys.stderr)
        return 1
    ids: list[str] = []
    for entry in data["entries"]:
        if not isinstance(entry, dict):
            errors.append("entry must be object")
            continue
        missing = REQUIRED_ENTRY - set(entry)
        if missing:
            errors.append(f"entry missing {sorted(missing)}: {entry!r}")
            continue
        eid = entry["id"]
        if eid in ids:
            errors.append(f"duplicate id: {eid}")
        ids.append(eid)
        _check_ahk(entry.get("ahk"), eid, errors)
        _check_hs(entry.get("hs"), eid, errors)
    _check_ahk_persist_source(data["entries"], errors)
    _check_hs_preferences(data["entries"], errors)
    if errors:
        for e in errors:
            print(e, file=sys.stderr)
        return 1
    print(f"ok: {len(ids)} contract entries validated")
    return 0


if __name__ == "__main__":
    sys.exit(main())