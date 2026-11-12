# _shared/data/identifiers.py
# AUTO-GENERATED from _shared/data/identifiers.json.
# DO NOT EDIT BY HAND — run `npm run codegen:identifiers` to refresh.
"""Application names, bundle ids, service labels and external hosts.

Hosts are bare names: build a URL as f"https://{HOSTS['github']}/...".
"""

APP = {
    "name": "ErgoptiPlus",
    "ahk": "ErgoptiPlus.ahk",
    "exe": "ErgoptiPlus.exe",
    "bundle": "ErgoptiPlus.app",
}

BUNDLE_IDS = {
    "launcher": "com.ergoptiplus.app",
    "hammerspoon": "com.ergoptiplus.app.hammerspoon",
}

SIGNING_IDS = {
    "runtime_installer": "com.ergoptiplus.app.runtime-installer",
    "installed_physical_source": "com.ergoptiplus.app.installed-physical-source",
    "remap_core": "com.ergoptiplus.remap.core",
    "remap_console": "com.ergoptiplus.remap.console",
    "remap_cli": "com.ergoptiplus.remap.cli",
}

SERVICE_LABELS = {
    "macos_core": "com.ergoptiplus.runtime.core",
    "macos_remap_guardian": "com.ergoptiplus.remap-guardian",
    "macos_virtual_hid": "com.ergoptiplus.runtime.vhid",
}

HOSTS = {
    "github": "github.com",
    "github_api": "api.github.com",
    "huggingface": "huggingface.co",
    "ollama": "ollama.com",
    "ollama_registry": "registry.ollama.ai",
}

DEV_SOURCE = {
    "plist_key": "ErgoptiDevSourceRoot",
    "environment": "ERGOPTI_DEV_SOURCE_ROOT",
}

FIELD_REPORT = {
    "branch_prefix": "field/",
    "folder": "docs/field-reports",
    "base_config_key": "ergoptiFieldBase",
    "environment": "ERGOPTI_FIELD_RUN_ROOT",
}
