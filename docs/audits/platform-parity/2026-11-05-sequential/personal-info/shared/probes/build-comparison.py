import pathlib
import json
import tomllib

R = pathlib.Path("/workspace/worktrees/parity-sequential-2026-11-05/shared")
ARTIFACT_ROOT = pathlib.Path("/workspace/scratch/parity-sequential-2026-11-05/personal-info/shared")
P = "static/ergopti_plus/"
S = P + "_shared/"
fields = tomllib.loads((R / (S + "modules/personal_info/fields.toml")).read_text())
example = tomllib.loads(
    (R / (S + "core/config_schema/examples/personal_info.example.toml")).read_text()
)
previews = tomllib.loads((R / (S + "modules/personal_info/preview_vectors.toml")).read_text())
corpus = json.loads((R / (S + "tests/corpus/personal_info/mask_vectors.json")).read_text())
features = tomllib.loads((R / (S + "modules/features/manifest.toml")).read_text())
menus = tomllib.loads((R / (S + "modules/menu/menu.toml")).read_text())["menu"]
actions = tomllib.loads((R / (S + "modules/actions/actions.toml")).read_text())


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
        return "{" + ",".join(lua(x) for x in v) + "}"
    if isinstance(v, dict):
        return "{" + ",".join("[" + lua(k) + "]=" + lua(x) for k, x in v.items()) + "}"
    return str(v)


(ARTIFACT_ROOT / "probes/fixture.lua").write_text("return " + lua({"mask": corpus}) + "\n")
label_names = {
    "first_name": "firstname",
    "last_name": "lastname",
    "date_of_birth": "birthdate",
    "email_address": "email",
    "work_email_address": "work_email",
    "phone_number": "phone_digits",
    "phone_number_clean": "phone_formatted",
    "street_address": "street",
    "postal_code": "postal_code",
    "city": "city",
    "country": "country",
    "credit_card": "credit_card",
    "social_security_number": "ssn",
}
field_rows = []
for name, classification in fields["fields"].items():
    field_rows.append(
        {
            "field": name,
            "masked": classification["masked"],
            "example_declared": name in example["info"],
            "default_aliases": [k for k, v in example["letters"].items() if v == name],
            "contract": "preview "
            + (
                "partially masked/full hidden under12 content characters"
                if classification["masked"]
                else "full value intentionally visible"
            )
            + "; full text injected; all personal content private for logging",
            "windows": "PersonalInfoMaskForPreview -> native AHK twin; loaded known info keys; editor raw key label",
            "macos": "shared Mask.mask_field via binding; fixed15 form and field schema",
            "linux": "shared Mask.mask_field via binding; arbitrary loaded info keys; raw key labels",
            "classification": "explicit_intent",
            "basis": "canonical fields policy plus actual shared mask executed; native integration source traced",
            "macos_label_key": ("personal_info.field_" + label_names[name])
            if name in label_names
            else None,
        }
    )
paths = {
    "shared": [
        S + "modules/personal_info/fields.toml",
        S + "modules/personal_info/README.md",
        S + "modules/personal_info/preview_vectors.toml",
        S + "tests/corpus/personal_info/mask_vectors.json",
        S + "lua/personal_info/mask.lua",
        S + "lua/dynamic_hotstrings/init.lua",
        S + "lua/menu/frames/personal_info_source.lua",
        S + "core/config_schema/examples/personal_info.example.toml",
        S + "core/config_schema/config.schema.json",
        S + "modules/features/manifest.toml",
        S + "modules/menu/menu.toml",
        S + "modules/actions/actions.toml",
        S + "ui/personal_info_editor/script.js",
        S + "ui/personal_info_editor/index.html",
        S + "modules/diagnostics/redaction.json",
    ],
    "windows": [
        P + "windows/infra/personal_info_mask.ahk",
        P + "windows/infra/personal_info_preview.ahk",
        P + "windows/infra/hotstrings/personal_toml_io.ahk",
        P + "windows/ui/personal_info_editor/init.ahk",
        P + "windows/modules/hotstrings/hotstrings_text_expansion.ahk",
        P + "windows/modules/dynamic_hotstrings/dynamic_hotstrings.ahk",
        P + "windows/modules/gestures/actions.ahk",
    ],
    "macos": [
        P + "macos/infra/personal_info_fields.lua",
        P + "macos/modules/dynamic_hotstrings/personal_info.lua",
        P + "macos/modules/dynamic_hotstrings/rules_engine.lua",
        P + "macos/ui/personal_info_editor/init.lua",
        P + "macos/modules/gestures/actions.lua",
    ],
    "linux": [
        P + "linux/infra/personal_info_fields.lua",
        P + "linux/modules/dynamic_hotstrings/manager.lua",
        P + "linux/modules/dynamic_hotstrings/prefix_rules.lua",
        P + "linux/ui/personal_info_editor/bridge.lua",
        P + "linux/modules/gestures/manager.lua",
        P + "linux/ui/menu/menu_hotstrings.lua",
    ],
}
rows = []


def row(
    id,
    contract,
    w,
    m,
    linux_value,
    cl="source_aligned",
    basis="actual OS integration source traced; native receiving unrun",
):
    rows.append(
        dict(
            id=id,
            contract=contract,
            windows=w,
            macos=m,
            linux=linux_value,
            classification=cl,
            basis=basis,
        )
    )


row(
    "classification",
    "15 declared fields:4 financial/identity preview secrets,11 public-preview personal fields",
    "AHK declaration loader+mask twin",
    "shared mask through mac binding",
    "shared mask through Linux binding",
    basis="actual shared mask field matrix,16 TOML vectors,15JSON vectors and6 invalid policies",
)
row(
    "preview-policy",
    "head2/tail4,minimum12 content chars,bulletU2022; spaces/hyphen/NBSP preserved",
    "native twin recombines UTF16 surrogate pairs",
    "shared codepoint-aware mask",
    "shared codepoint-aware mask",
    basis="actual shared vectors+supplementary emoji/boundary controls; Windows twin source-only",
)
row(
    "preview-unknown",
    "No field provenance/unknown field does not imply public",
    "field missing defaults masked",
    "shared mask unknown masked",
    "shared mask unknown masked",
    "explicit_intent",
    basis="actual shared unknown/missing declaration controls",
)
row(
    "invalid-policy",
    "Fail closed on malformed policy",
    "loader refuses bad policy and mask all",
    "binding fallback or shared all-bullet fallback",
    "shape-validating binding fallback or all-bullet fallback",
    "explicit_intent",
    basis="actual shared invalid-policy controls; native loader failures source-only",
)
row(
    "invalid-field-record",
    "Malformed shipped classification should not reveal secret",
    "native parser produces checked map flags",
    "binding lacks Linux fullshape validation; shared direct entry indexing can throw",
    "binding validates fields and sourcebound array kind",
    "unknown_intent",
    basis="immutable shipped-file corruption only; no ordinary UI path proved; outside findings",
)
row(
    "full-injection",
    "Preview masking never replaces committed output",
    "frozen values/spec feed injection; mask only preview",
    "combo path literal; ordinary prefix registry may interpret {Tab} in personal payload (PIM002 OS candidate)",
    "combo values/full mapping replacement -> injector",
    "os_owner_reference",
    basis="mask is display-only; actual macOS prefix.lua owner probe accepts 0123{Tab}45 from editor then tokenizes prefix output; native receiving unrun in shared role",
)
row(
    "log-redaction",
    "Every personal value including unmasked phone/name is private",
    "PersonalInfoRedactForLog and IsPrivate flags",
    "private opts/metrics payload guard",
    "private prefix/combo flags and keystats redact",
    "explicit_intent",
    basis="actual shared redact returns one bullet per Unicode scalar including separators; whole persisted pipeline delegated",
)
row(
    "default-fields",
    "15 canonical info values in example",
    "known-key reader/default seed",
    "fixed15 DEFAULT_CONFIG",
    "source file arbitrary info keys; absent source empty",
    "native_alternative",
)
row(
    "default-aliases",
    "13 example aliases,12 distinct target fields; e/m both email",
    "known-file aliases or seeded aliases",
    "fixed13 DEFAULT_CONFIG alias keys",
    "parsed letters rows validated onecodepoint",
    "source_aligned",
)
row(
    "alias-customization",
    "Example says one-letter field mapping; no universal Unicode alphabet promise",
    "writer ASCII A-Z/a-z/0-9/_ aliases; reader known info keys",
    "parser retains only default alias keys",
    "one Unicode scalar alias accepted; raw mapping stored",
    "unknown_intent",
)
row(
    "alias-case",
    "Tag case and stored alias case are separate contracts",
    "resolver lowercases tag, stored keys exact; uppercase mismatch candidate",
    "tracker lowercases while resolver loops bytes/defaultlowerkeys",
    "resolver lowercases input, stored aliases exact",
    "unknown_intent",
    basis="source-only; unsupported/custom alphabet not inferred from arbitrary TOML",
)
row(
    "source-override",
    "Configured source directory and file owner should stay aligned",
    "PersonalInfoTomlPath/config writer path retained",
    "explicit init info_toml_path or base_dir fallback",
    "init default uses default_config_dir, bypassing configured Paths unless explicit argument",
    "os_owner_reference",
    basis="Linux role retains actual configured-directory proof; no duplicate PIS root",
)
row(
    "missing-source",
    "First-use behavior differs",
    "bootstrap/read control and native fallback",
    "writes DEFAULT_CONFIG via owned path",
    "empty info/letters; editor epoch ready may refuse missing source",
    "os_owner_reference",
    basis="Linux role investigating actual absentfile ready ownership; no firstboot feature equivalence claimed",
)
row(
    "custom-info-preservation",
    "Unknown source values/aliases should have declared ownership",
    "reader ignores unknown info keys; writer snapshot known keys",
    "fixed-schema parser+serializer discard unknown info/extra aliases",
    "arbitrary [info]/letters loaded; writer patches owned info",
    "os_owner_reference",
    basis="macOS role actual parser/editor preservation proof; prior config/editor roots deduplicated",
)
row(
    "empty-values",
    "An unresolved/blank part rejects whole combo",
    "HSE transient resolver refuses unresolved part",
    "resolve_combo explicitly all-or-nothing",
    "resolve_combo explicitly all-or-nothing",
    "explicit_intent",
)
row(
    "combo-order",
    "Field values follow typed alias order without trailingTab",
    "transient resolver pervalue escaping+Tabbetween",
    "inject each part and Tabonlybetween",
    "injected joinedvalues/tab route",
    "source_aligned",
)
row(
    "combo-generated",
    "Windows preregistered family distinct from transient resolver",
    "Generate all combinations up to maxLen; long tags resolved at firetime",
    "no exponential preregistration; collect/resolve at use time",
    "no multi registration; resolve at use time",
    "native_alternative",
)
row(
    "pattern-max",
    "Schema integer1..16; default/recommended1; not necessarily max tag length",
    "controls pregenerated length; >=2 native literalTab candidate",
    "feature metadata supported namespace, tracker not pregeneration",
    "configured row retained; combos resolved at use time",
    "os_owner_reference",
    basis="Windows role owns actual source retained probe of Generate; no fabricated universal dead-knob conclusion",
)
row(
    "single-field-tags",
    "Aliases and literal synonym tags are different sets",
    "8literal tags bic/cb/cc/iban/rib/ss/tel/tél plus letteraliases",
    "letteralias collector; no Windows synonym table",
    "letteralias rules/combo; no Windows synonym table",
    "native_alternative",
)
row(
    "static-collision",
    "Registered/static winner must be reconciled with transient preview",
    "registered specs can win before transient fallback; literal tags use sharednative tag map",
    "personal tracker and registered static registry boundary",
    "match/static owner then combo decision path",
    "unknown_intent",
    basis="source-only shared role; OS agents own actual collision controls",
)
row(
    "prefix-families",
    "Phone,SSN,IBAN prefix switches separate from @ aliases",
    "native prefix registrations",
    "rules_engine registry mappings",
    "pure Prefix.build mappings consumed by loader",
    "source_aligned",
)
row(
    "prefix-thresholds",
    "Phone2/4/6/formatted5;SSN5;IBAN6 rawchars",
    "native loops and +33 formatting",
    "sharedhelper+native mappings",
    "purePrefix.build",
    "source_aligned",
)
row(
    "prefix-counts",
    "Count must equal emitted mappings for source data",
    "native mapping registration avoids identical spacedtrigger; counts source different",
    "shared compute_prefix_counts advertises2 for unspaced SSN/IBAN despite1mapping",
    "same helper count2 vs actual purebuild1",
    "defect",
    basis="PIS-001 actual shared count +actual pureLinux producer; Linux actual manager active_count4 vs prefix_mappings2 evidence retained separately",
)
row(
    "prefix-format",
    "Unspaced/spaced triggers return matching output form",
    "raw removes ASCIIspaces",
    "raw removes%s",
    "raw removes%s",
    "unknown_intent",
    basis="space/whitespace differences source-only; Unicode format policy not inferred",
)
row(
    "phone-international",
    "French+33 prefix behavior is native producer policy",
    "drops leading0 in replacement",
    "native construction prepends+33 to full storedphone",
    "pure prefix replacement prepends+33 to full storedphone",
    "known_duplicate",
    basis="TODO.md first item and docs/audits/platform-parity/2026-11-04/hotstrings.md already track national0 normalization; no new PIS/PIL root",
)
row(
    "short-phone-trigger",
    "Shortest phone prefix should distinguish typing from explicit magic completion",
    "first2digits+magic key",
    "first2digits+magic key",
    "first2digits alone",
    "known_duplicate",
    basis="TODO.md first item and prior hotstrings audit; existing gap, not new finding",
)
row(
    "metadata-locale",
    "Feature description metadata differs from actual menu caption",
    "feature description_key absent in all21locale dictionaries; actual shared family caption translated",
    "same metadata vs actual caption distinction",
    "same metadata vs actual caption distinction",
    "unknown_intent",
    basis="actual family i18n is dynamichotstrings.textexpansionpersonalinformation; absent menu.hotstrings.dynamic.text_expansion_personal_information not claimed user-visible",
)
row(
    "feature-defaults",
    "Family off by default and recommended off; pattern1",
    "manifest/Features",
    "manifest/menu preference authority",
    "manifest/runtime preferences",
    "explicit_intent",
)
row(
    "editor-command",
    "Localized GUI editor row distinct from open-file action",
    "separate boot-order callback outside shared leaf",
    "personal_info_editor_frame native callback",
    "same shared frame plus bridge",
    "explicit_intent",
)
row(
    "open-file-action",
    "open_personal_info means native userfile opener",
    "GestureOpenIfExists(path)",
    "open_user_file PersonalInfoTomlPath",
    "open configured Paths.config file",
    "explicit_intent",
)
row(
    "editor-fields",
    "Shared page renders host-supplied rows",
    "dynamic native map values,rawkeylabels",
    "fixed15 localized labels except IBAN/BIC",
    "sorted dynamic map rows,rawkeylabels",
    "native_alternative",
)
row(
    "editor-alias-editing",
    "GUI edits values,not alias mappings",
    "source snapshot keeps aliases where owned",
    "same GUI noalias controls",
    "GUI values only; retained letters owned byhost",
    "explicit_intent",
)
row(
    "editor-secret-visibility",
    "Editor shows full values intentionally; preview policy is separate",
    "plaintext textinputs/native form",
    "plaintext textinputs",
    "plaintext textinputs",
    "explicit_intent",
    basis="page uses input.value; no password/secret editor masking requirement found",
)
row(
    "editor-preservation",
    "Host save must preserve owned source and report refusal",
    "native candidate/path/source receipt and fallbackdialog",
    "owned CAS/reload but fixed schema drops custom aliases/unknown source keys (OS PIM preservation root)",
    "bridge + dynamic edit capability and retained page epoch",
    "os_owner_reference",
    basis="durable ACK is not source-preservation equivalence; macOS customalias drop independently OS-owned; prior editor/config transaction roots deduplicated",
)
row(
    "editor-frontend",
    "Host fields ->textContent/values; save/cancel/ready messages",
    "shared script +WebView2 or nativedialog fallback",
    "shared script +WKWebView",
    "shared script +WebKit",
    "source_aligned",
    basis="shared page source inspected; native GUI unrun",
)
row(
    "editor-save-ack",
    "Save failure/close behavior native-owned",
    "handler+native dialog state",
    "host callback +notify_error",
    "bridge +notify_error",
    "unknown_intent",
    basis="no generic claim from shared page save message; prior native UI refusal/close roots excluded",
)
row(
    "menu-source-admission",
    "Only retained exact declared editor row may open",
    "Windows uses distinct boot-order injection",
    "shared Source.read +nativefacade",
    "shared Source.read +nativefacade",
    "explicit_intent",
    basis="actual pure admission healthy/refused/mutated/replaced/metatable probes",
)
row(
    "localization",
    "All canonical field labels and relevant actions/prompts translated",
    "raw canonical field keys shown in WebView",
    "13localized fields+IBAN/BIC literals",
    "raw canonical field keys shown",
    "native_alternative",
    basis="all21 dictionaries checked; actual displayed labels derive native payload not mere presence of translations",
)
row(
    "storage-confidentiality",
    "Do not conflate preview mask with data-at-rest encryption",
    "personal_info.toml plaintext private configuration",
    "same plaintext source",
    "same plaintext source",
    "explicit_intent",
    basis="README separates display from persistence privacy; logs/keystats crypto audits separate",
)
row(
    "pause-reload-stale",
    "Published data/preview/output respect lifecycle owner",
    "paused paths +writer/source lease",
    "trackertokens+config snapshot+registry transaction",
    "info_generation/editcapability+destination ownership",
    "source_aligned",
    basis="platform lifecycle proofs owned by OS roles; no shared semantic certification",
)
row(
    "diagnostic-exclusion",
    "Personal source excluded from diagnostics collection",
    "shared redaction list",
    "shared redaction list",
    "shared redaction list",
    "source_aligned",
    basis="source declaration only; diagnostic export execution unrun",
)
row(
    "documentation-drift",
    "README says Windows notwired and failfast raises",
    "actual native preview/mask wired and failclosed",
    "actual binding failclosed not mandatoryraise",
    "actual binding failclosed not mandatoryraise",
    "documentation_only",
)
for entry in rows:
    if entry["id"] == "pattern-max":
        entry["observed_limit"] = (
            "Windows eagerly enumerates alias_count^length combinations through configured max (schema1..16); Lua resolves dynamically and does not pregenerate. Complexity source-only, no high-value or hang experiment, no latency/memory measurement."
        )
relevant_ids = {
    "text_expansion_personal_information",
    "iban_prefixes",
    "phone_prefixes",
    "ssn_prefixes",
}
settings = []


def walk(v, path):
    if isinstance(v, dict):
        if v.get("id") in relevant_ids:
            settings.append({"path": path + "." + v["id"], **v})
        for k, x in v.items():
            walk(x, path + "." + k if path else k)
    elif isinstance(v, list):
        for x in v:
            walk(x, path)


walk(features["features"], "")
keys = set("personal_info.field_" + x for x in label_names.values())
keys.update(
    [
        "menu.shortcuts.edit_personal_info",
        "editor.personal_info.window_title",
        "dialog.personal_info.save_failed",
        "common.save",
        "common.cancel",
        "sg_actions.open_personal_info",
        "menu.hotstrings.dynamic.text_expansion_personal_information",
        "dynamichotstrings.textexpansionpersonalinformation",
    ]
)
locales = {
    p.stem: {key: json.loads(p.read_text()).get(key) for key in sorted(keys)}
    for p in (R / (S + "data/locales")).glob("*.json")
}
missing = {
    lang: [k for k, v in data.items() if v is None]
    for lang, data in locales.items()
    if any(v is None for v in data.values())
}
schema = json.loads((R / (S + "core/config_schema/config.schema.json")).read_text())["$defs"][
    "hotstrings"
]["properties"]["dynamic"]["properties"]["text_expansion_personal_information"]
result = {
    "schema_version": 1,
    "scope": "personal-info-shared-contract",
    "audited_sha": "7aecd9a25b35efdcff68898919506dc2f6fd02d0",
    "policy": fields["policy"],
    "field_catalogue": field_rows,
    "example_aliases": example["letters"],
    "missing_metadata_locale_key_only": True,
    "preview_vector_counts": {
        "toml": len(previews["vectors"]),
        "json": len(corpus["vectors"]),
        "invalid_policy": len(corpus["invalid_policies"]),
    },
    "feature_settings": settings,
    "dynamic_personal_schema": schema,
    "menu_editor_frame": menus["personal_info_editor_frame"],
    "open_file_action": actions["sg_actions"]["open_personal_info"],
    "capabilities": rows,
    "locales": locales,
    "missing_locale_keys": missing,
    "source_paths": paths,
    "native_gui_executed": False,
    "classification_legend": {
        "source_aligned": "mechanisms appear aligned at source; native behavior not certified",
        "explicit_intent": "canon/schema/comments explicitly distinguish policy",
        "native_alternative": "different supported native workflow/display without inferred obligation",
        "unknown_intent": "unclear custom/edge policy,not a finding",
        "os_owner_reference": "platform evidence separately owned; no duplicate PIS root",
        "defect": "unique shared count owner actual output violates expected status",
        "documentation_only": "stale prose contradicted by actual consumers",
        "known_duplicate": "existing audited gap/TODO retained without new finding",
    },
}
(ARTIFACT_ROOT / "probes/editor-fixture.json").write_text(
    json.dumps(
        {
            "fields": [
                {
                    "key": r["field"],
                    "label": r["field"],
                    "value": ("" if i == 0 else "SYNTHETIC_" + str(i) + "_🙂\n<literal>"),
                    "hint": "(@x★)",
                }
                for i, r in enumerate(field_rows)
            ],
            "strings": {
                "common.save": "Save",
                "common.cancel": "Cancel",
                "editor.personal_info.window_title": "Synthetic Editor",
            },
        },
        ensure_ascii=False,
        indent=2,
    )
    + "\n"
)
(ARTIFACT_ROOT / "comparison.json").write_text(
    json.dumps(result, indent=2, ensure_ascii=False) + "\n"
)
assert set(fields["fields"]) == set(example["info"]) and len(fields["fields"]) == 15
assert len(example["letters"]) == 13 and len(settings) == 4 and len(locales) == 21
assert len(missing) == 21 and all(
    v == ["menu.hotstrings.dynamic.text_expansion_personal_information"] for v in missing.values()
)
assert fields["policy"] == corpus["policy"]
print(
    "inventory:15 fields,4masked,13 examplealiases,4 featurefamilies,"
    + str(len(rows))
    + " capabilities,21 locales;16TOML+15JSON vectors+6 invalidpolicy cases"
)
