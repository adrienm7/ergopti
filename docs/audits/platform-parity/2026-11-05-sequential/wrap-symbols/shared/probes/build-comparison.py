import json
import pathlib
import tomllib

R = pathlib.Path("/workspace/worktrees/parity-sequential-2026-11-05/shared")
ARTIFACT_ROOT = pathlib.Path("/workspace/scratch/parity-sequential-2026-11-05/wrap-symbols/shared")
P = "static/ergopti_plus/"
S = P + "_shared/"
cat = json.loads((R / (S + "modules/wrap_symbols/wrap_symbols.json")).read_text())
vec = json.loads((R / (S + "tests/corpus/action_parameters/wrap_pair_vectors.json")).read_text())
m = tomllib.loads((R / (S + "modules/menu/menu.toml")).read_text())["menu"]
f = tomllib.loads((R / (S + "modules/features/manifest.toml")).read_text())
a = tomllib.loads((R / (S + "modules/actions/actions.toml")).read_text())
pairs = [
    dict(p, group=g["i18n"], group_index=gi + 1, pair_index=pi + 1)
    for gi, g in enumerate(cat["groups"])
    for pi, p in enumerate(g["pairs"])
]


def lua(v):
    if v is None:
        return "nil"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "{" + ",".join(lua(i) for i in v) + "}"
    if isinstance(v, dict):
        return "{" + ",".join("[" + lua(k) + "]=" + lua(x) for k, x in v.items()) + "}"
    return str(v)


(ARTIFACT_ROOT / "probes/catalogue-fixture.lua").write_text(
    "return " + lua({"pairs": pairs, "vectors": vec["vectors"]}) + "\n"
)
lookup = {}
for p in pairs:
    for end in ["left", "right"]:
        lookup[p[end]] = p
for p in pairs:
    p["default_enabled"] = {
        "windows": True,
        "macos": True,
        "linux": "all catalogue pairs; no per-pair choices",
    }
    p["parameter_resolution"] = {}
    for end in ["left", "right"]:
        wanted = p[end].strip()
        q = next((q for q in pairs if q["left"].strip() == wanted), None) or next(
            q for q in pairs if q["right"].strip() == wanted
        )
        p["parameter_resolution"][end] = {"left": q["left"], "right": q["right"]}
    p["native_trigger_mapping_source_only"] = {
        end: {"left": lookup[p[end]]["left"], "right": lookup[p[end]]["right"]}
        for end in ["left", "right"]
    }
    p["single_character_trigger_possible"] = {end: len(p[end]) == 1 for end in ["left", "right"]}
    p["classification"] = (
        "unknown_intent"
        if any(
            p["parameter_resolution"][e] != p["native_trigger_mapping_source_only"][e]
            for e in ["left", "right"]
        )
        else "parity"
    )
    if any(not v for v in p["single_character_trigger_possible"].values()):
        p["classification"] = "os_owner_finding_reference"
paths = {
    "shared": [
        S + "modules/wrap_symbols/wrap_symbols.json",
        S + "modules/wrap_symbols/README.md",
        S + "lua/wrap_pair/init.lua",
        S + "lua/menu/wrap_preferences.lua",
        S + "lua/menu/wrap_mutation.lua",
        S + "core/config_schema/config.schema.json",
        S + "modules/features/manifest.toml",
        S + "modules/menu/menu.toml",
        S + "modules/actions/actions.toml",
        S + "tests/corpus/action_parameters/wrap_pair_vectors.json",
        S + "tests/corpus/menus/wrap_symbol_controls.json",
    ],
    "windows": [
        P + "windows/infra/wrap_symbols_config.ahk",
        P + "windows/infra/wrap_pair.ahk",
        P + "windows/ui/menu/menu_shortcuts.ahk",
        P + "windows/infra/hotstrings/hotstring_inputhook.ahk",
        P + "windows/modules/gestures/actions.ahk",
    ],
    "macos": [
        P + "macos/modules/shortcuts/actions/text.lua",
        P + "macos/modules/shortcuts/actions/system.lua",
        P + "macos/ui/menu/menu_shortcuts.lua",
        P + "macos/modules/shortcuts/bindings.lua",
        P + "macos/modules/gestures/actions.lua",
    ],
    "linux": [
        P + "linux/modules/shortcuts/manager.lua",
        P + "linux/modules/shortcuts/wrap_on_type.lua",
        P + "linux/ui/menu/menu_shortcuts.lua",
    ],
}
rows = []


def row(id, contract, w, h, linux_value, cl="parity", basis="source traced; native GUI unrun"):
    rows.append(
        {
            "id": id,
            "contract": contract,
            "windows": w,
            "macos": h,
            "linux": linux_value,
            "classification": cl,
            "basis": basis,
        }
    )


row(
    "catalogue-source",
    "43 pairs,7 ordered groups; source of truth JSON",
    "load at startup -> pairs/groups",
    "load at require -> WRAP_GROUPS/PAIRS",
    "load at require -> lookup+ordered list",
    basis="actual shared parser consumes generated complete catalogue fixture; native consumers source traced",
)
row(
    "load-failure",
    "Do not silently certify empty catalogue",
    "warn+six-pair emergency fallback",
    "warn+six-pair emergency fallback",
    "error+empty list/lookup",
    "explicit_intent",
)
row(
    "group-presentation",
    "Labels/group order from catalogue",
    "named groups preserve order",
    "named groups preserve order",
    "flat alphabetically sorted action rows",
    "explicit_intent",
    basis="management corpus explicitly says Linux has no management controls; do not infer missing all3 feature from stale README",
)
row(
    "pair-defaults",
    "Built-in pairs enabled unless false",
    "disabled Map empty",
    "state absent/true enables",
    "all catalogue pairs active",
)
row(
    "enable-defaults",
    "Neutral default false, recommended true",
    "shortcuts.wrap_text_if_selected",
    "shortcuts.keys.wrap_text_if_selected",
    "shortcuts.wrap_text_if_selected",
    "explicit_intent",
)
row(
    "store-namespace",
    "Driver storage intentionally differs",
    "wrap_symbols.toml",
    "config.toml shortcuts.wrap_symbols states/custom",
    "does not read this namespace",
    "explicit_intent",
    basis="feature section+reason text explicitly names stores",
)
row(
    "strict-source-projection",
    "Typed bool states and scalar custom array; unknown/invalid retained",
    "dedicated TOML disabled/custom parser",
    "actual shared WrapPreferences.project",
    "not applicable",
    "native_alternative",
    basis="actual shared project/prepare probes; Windows native writer source only",
)
row(
    "durable-publication",
    "Only literal ACK publishes settings",
    "durable stage/replace with path+epoch lease",
    "WrapMutation candidate +native preferences writer",
    "boolean switch persisted before applied",
    "parity",
    basis="actual pure mutation ACK/refusal/reentry/successor probes; no durable native write claimed",
)
row(
    "symbol-toggle",
    "Opening symbol canonical state key disables its native pair",
    "native disabled set",
    "map only strict false disables",
    "no per-symbol settings",
    "explicit_intent",
)
row(
    "global-and-group",
    "Enable/disable declared built-ins",
    "all/group built-in keys; custom unchanged",
    "all/group built-in keys; custom unchanged",
    "absent by declared platform restriction",
    "explicit_intent",
)
row(
    "restore-recommended",
    "Default choices and custom handling",
    "clear disabled and custom",
    "states/custom become empty",
    "no corresponding pair-store control",
    "explicit_intent",
)
row(
    "custom-management",
    "Ordered Unicode scalar pairs; blank right means mirror",
    "two native prompts; scalar validator",
    "two dialog prompts; exact_unicode_scalar",
    "not implemented; action parameter provides alternative",
    "explicit_intent",
)
row(
    "custom-collision",
    "Custom entries overlay built-ins",
    "last custom pair wins both endpoints",
    "last custom pair wins both endpoints",
    "no management custom table",
    "unknown_intent",
)
row(
    "custom-multichar",
    "Management scalar differs from binding parameter text",
    "management rejects multi; action parser allows left|right",
    "shared preferences scalar; shared parameter allows multi",
    "parameter allows multi",
    "explicit_intent",
    basis="actual preferences and parameter probes distinguish intended surfaces",
)
row(
    "parameter-parse",
    "Trim outer whitespace; opening precedence; closing aliases; exactly one pipe custom",
    "native WrapPairParse",
    "shared WrapPair.parse",
    "shared WrapPair.parse",
    "parity",
    basis="actual shared parser all43x2 endpoints+19 golden vectors; Windows execution owned by OS role",
)
row(
    "parameter-invalid",
    "Invalid pair refused before output",
    "binding warning",
    "binding warning",
    "binding warning",
    "parity",
)
row(
    "parameter-catalogue-independence",
    "Binding parameter uses built-in list even pair disabled in typed wrap",
    "full builtin list",
    "wrap_pair_list full groups",
    "full ordered builtin list",
    "explicit_intent",
)
row(
    "pair-reversal",
    "Closing symbol resolves original left/right; no direction reversal",
    "native parser closing alias",
    "shared parser",
    "shared parser",
    "parity",
    basis="actual shared parser exhaustive endpoint probe",
)
row(
    "quote-overlap",
    "“ opens one pair and closes later „ pair",
    "last assignment native map maps to „…“; parser opening-first",
    "same native last assignment",
    "same native last assignment",
    "unknown_intent",
    basis="explicit golden parser rule vs source-derived trigger mapping; no forced business finding",
)
row(
    "collision-filtering",
    "An enabled opener should remain when only overlapping pair disabled",
    "rebuild filters disabled pair before assignment, preserving earlier opener",
    "preflatten then filter: disable „ removes enabled “ opener",
    "no per-pair choices",
    "os_owner_finding_reference",
    basis="macOS actual Text+eventtap owner probe; source difference in native projection order; no duplicate WSS finding",
)
row(
    "spaced-guillemets",
    "Output delimiters include spaces but typed characters are single",
    "exact spaced trigger keys",
    "exact spaced trigger keys",
    "exact spaced trigger keys and single-character getter",
    "os_owner_finding_reference",
    basis="OS agents execute actual consumers; shared parser accepts bare symbol and emits spaced pair correctly; catalogue trigger/output conflation",
)
row(
    "typed-enable",
    "Wrap only when feature active and selection exists",
    "PrefixWatcher+UIA",
    "eventtap+AXSelectedText",
    "daemon consumption+PRIMARY controller",
    "native_alternative",
)
row(
    "typed-selection-api",
    "Selection detection differs by backend",
    "UIA selected text/cache",
    "AXSelectedText/cache; no Ctrl+C on each typed key",
    "PRIMARY baseline changed after selection context",
    "native_constraint",
)
row(
    "typed-no-selection",
    "Unconsumed raw character proceeds once",
    "prefix continuation",
    "eventtap returns false",
    "controller returns false",
    "parity",
)
row(
    "typed-refused-output",
    "Only acknowledged output suppresses original key",
    "_PrefixTryWrapSelection commit receipt",
    "wrap_selection returns literal true required",
    "type_text returns literal true required",
    "parity",
    basis="native owner seams OS role; source traced here",
)
row(
    "linux-stale-primary",
    "Safety over same-text reselect",
    "not applicable",
    "not applicable",
    "unchanged PRIMARY refuses/retypes symbol even if same text reselected",
    "explicit_intent",
    basis="controller module explicitly documents safe missed wrap",
)
row(
    "modifier-policy",
    "Typing layer vs command modifiers",
    "physical admitted characters from canonical input context",
    "Cmd/Ctrl passthrough; Alt allowed for AltGr layout",
    "Ctrl/Alt/Meta passthrough",
    "native_alternative",
    basis="modifier policy differs; no all3 hardware parity claim",
)
row(
    "action-selection-empty",
    "wrap_selection binding: empty selection does nothing",
    "capture empty skips transform/paste",
    "wrap_copied_selection clipboard transform",
    "transform_selection; no fallback",
    "explicit_intent",
    basis="actions.toml declaration; action owners source traced",
)
row(
    "linux-picker-empty",
    "Direct menu selection picker empty behavior differs from binding",
    "no direct menu action; checkboxes control typed wrap",
    "no direct menu action; checkboxes control typed wrap",
    "direct wrap_selection inserts empty left+right when reason=no_selection",
    "native_alternative",
    basis="binding path has no such fallback; do not report action contract violation",
)
row(
    "text-content",
    "Multiline/Unicode selected bytes wrapped verbatim",
    "Left.Text.Right",
    "left..sel..right",
    "left..selected..right",
    "parity",
    basis="pure parser+scalar fixture only; actual selected receiving not exercised in shared role",
)
row(
    "privacy-and-destination",
    "Retain synthetic input destination; preserve privacy guards",
    "UIA+input context fences; ClipboardAll for explicit action",
    "text owner scope/broker/pasteboard transaction; rich restore",
    "retained destination/PRIMARY typed path; text clipboard action",
    "native_constraint",
    basis="prior flows own clipboard restoration differences; no expanded privacy conclusion",
)
row(
    "lifecycle",
    "Paused/stale/config replacement cannot wrongly consume text",
    "suspend/epoch checks in prefix and writer",
    "eventtap lifecycle/admission+mutation read view",
    "is_active/context_epoch/reentrant generation in controller",
    "parity",
    basis="shared mutation stale controls actual; platform lifecycle source-only",
)
row(
    "live-update",
    "Preference ACK changes active pairs without reload",
    "atomic active map publish",
    "getter builds active map from acknowledged Mutation.view",
    "only boolean switch changes; catalogue at module require",
    "native_alternative",
)
row(
    "preview-label",
    "Catalogue sample is pair/ellipsis, binding prompt describes full list",
    "symbol pair row labels",
    "symbol pair row labels+Pair.describe",
    "flat pair/ellipsis row labels+Pair.describe",
    "parity",
    basis="pair labels are literal Unicode; group/control labels translated; no G5 visual proof",
)
row(
    "locale-coverage",
    "Every declared group/control/reason/action prompt key localized",
    "t(key)",
    "i18n.get(key)",
    "i18n.get for applicable controls",
    "parity",
    basis="all21 locale dictionaries enumerated; frontend rendering unrun",
)
row(
    "readme-drift",
    "README says both drivers, wrong open/close/label_key shape",
    "actual left/right native consumer exists",
    "actual left/right consumer exists",
    "actual third consumer exists",
    "documentation_only",
)
settings = []


# Find the two canonical declarations without projecting one driver over another.
def walk(v, path):
    if isinstance(v, dict):
        if v.get("id") == "wrap_text_if_selected":
            settings.append({"path": path + ".wrap_text_if_selected", **v})
        for k, x in v.items():
            walk(x, path + "." + k if path else k)
    elif isinstance(v, list):
        for x in v:
            walk(x, path)


walk(f["features"], "")
# Recursive path is the canonical manifest section.
control_names = [k for k in m if k.startswith("wrap_symbols_")]
controls = {k: m[k] for k in control_names}
locale_keys = set(g["i18n"] for g in cat["groups"])
for arr in controls.values():
    for x in arr:
        if "i18n" in x:
            locale_keys.add(x["i18n"])
locale_keys.update(
    [
        "menu.shortcuts.wrap_symbols",
        "menu.shortcuts.wrap_symbols_title",
        "menu.shortcuts.wrap_symbols_custom_label",
        "dialog.shortcuts.wrap_symbol_title",
        "dialog.shortcuts.wrap_symbol_prompt",
        "dialog.shortcuts.wrap_symbol_invalid",
        "dialog.shortcuts.wrap_symbol_close_title",
        "dialog.shortcuts.wrap_symbol_close_prompt",
        "shortcuts.label_wrap_text",
        "menu.shortcuts.selection_symbol",
        "platform_reason.wrap_symbols_store_is_macos",
        "platform_reason.wrap_selection_is_a_shortcut_key_on_macos",
        "platform_reason.shortcut_settings_are_stored_per_driver",
        "sg_actions.wrap_selection",
        "dialog.gestures.param_wrap_pair",
        "dialog.gestures.param_err_wrap_pair",
    ]
)
locales = {
    p.stem: {k: json.loads(p.read_text()).get(k) for k in sorted(locale_keys)}
    for p in (R / (S + "data/locales")).glob("*.json")
}
missing = {
    lang: [k for k, v in vals.items() if v is None]
    for lang, vals in locales.items()
    if any(v is None for v in vals.values())
}
result = {
    "schema_version": 1,
    "scope": "wrap-symbols-shared-contract",
    "audited_sha": "7aecd9a25b35efdcff68898919506dc2f6fd02d0",
    "catalogue": {
        "groups": cat["groups"],
        "rows": pairs,
        "pair_count": len(pairs),
        "group_count": len(cat["groups"]),
        "lookup_unique_keys": len(lookup),
        "linux_picker_row_count_source_only": sum(
            1 for key, pair in lookup.items() if key == pair["left"]
        ),
        "mapping_provenance": "native_trigger_mapping_source_only is Python derivation of inspected assignment loops, never native execution",
    },
    "settings": settings,
    "macos_wrap_store_section": f["sections"]["shortcuts"]["wrap_symbols"],
    "custom_pair_schema": json.loads(
        (R / (S + "core/config_schema/config.schema.json")).read_text()
    )["$defs"]["shortcuts"]["properties"]["wrap_symbols"],
    "controls": controls,
    "parent_frame": m["shortcut_wrap_frame"],
    "linux_live_control": m["shortcut_wrap_live_control"],
    "action": a["sg_actions"]["wrap_selection"],
    "capabilities": rows,
    "locales": locales,
    "missing_locale_keys": missing,
    "source_paths": paths,
    "native_gui_executed": False,
    "classification_legend": {
        "parity": "source aligned; execution basis stated",
        "explicit_intent": "declaration or corpus distinguishes policy",
        "native_alternative": "different OS workflow; no inferred missing parity",
        "native_constraint": "native selection/storage mechanics differ, native receiving unrun",
        "unknown_intent": "ambiguous source policy, outside canonical findings",
        "os_owner_finding_reference": "actual platform probes owned by OS role, no duplicate shared ID",
        "documentation_only": "stale prose cannot establish missing implementation",
    },
}
(ARTIFACT_ROOT / "comparison.json").write_text(
    json.dumps(result, ensure_ascii=False, indent=2) + "\n"
)
assert len(pairs) == 43 and len(cat["groups"]) == 7 and len(rows) == 36
assert len(settings) == 2, (len(settings), settings)
print(
    "inventory:43 catalogue rows,7 groups,36 capabilities,2 enable settings,7 management commands,21 locales; missing locale keys="
    + str(missing)
)
