import json
import pathlib
import tomllib

ROOT = pathlib.Path("/workspace/worktrees/parity-sequential-2026-11-05/shared")
OUT = pathlib.Path("/workspace/scratch/parity-sequential-2026-11-05/wpm/shared")
P = "static/ergopti_plus/"
S = P + "_shared/"
model = S + "lua/wpm_widget/model.lua"
const = S + "modules/wpm_widget/constants.toml"
manifest = S + "modules/features/manifest.toml"
menu = S + "modules/menu/menu.toml"
features = tomllib.loads((ROOT / manifest).read_text())["features"]["metrics"]
menus = tomllib.loads((ROOT / menu).read_text())["menu"]["metrics_menu"]
canon = tomllib.loads((ROOT / const).read_text())
locales = {p.stem: json.loads(p.read_text()) for p in (ROOT / (S + "data/locales")).glob("*.json")}
paths = {
    "windows": {
        "widget": P + "windows/ui/wpm/wpm_display.ahk",
        "drawing": P + "windows/ui/wpm/wpm_widget.ahk",
        "config": P + "windows/ui/wpm/wpm_config.ahk",
        "menu": P + "windows/ui/menu/menu_metrics.ahk",
        "commands": P + "windows/ui/menu/menu_metrics_actions.ahk",
        "keystats": P + "windows/modules/keystats/keystats_hotstring_log.ahk",
        "ai": P + "windows/modules/keymap/llm_bridge.ahk",
    },
    "macos": {
        "widget": P + "macos/ui/wpm/wpm_widget.lua",
        "readout": P + "macos/ui/wpm/wpm_menubar.lua",
        "helper": P + "macos/ui/wpm/shared.lua",
        "menu": P + "macos/ui/menu/menu_metrics.lua",
        "keystats": P + "macos/modules/keystats/init.lua",
    },
    "linux": {
        "widget": P + "linux/ui/wpm/widget.lua",
        "readout": P + "linux/ui/wpm/tray_readout.lua",
        "surface": P + "linux/adapters/wpm_surface.lua",
        "menu": P + "linux/ui/menu/menu_metrics.lua",
        "keystats": P + "linux/modules/keystats/keystats.lua",
    },
}
rows = []


def row(
    id,
    contract,
    w,
    m,
    linux_value,
    classification="parity",
    basis="source traced; model cases executed where noted",
    evidence=None,
):
    rows.append(
        dict(
            id=id,
            contract=contract,
            windows=w,
            macos=m,
            linux=linux_value,
            classification=classification,
            basis=basis,
            evidence=evidence or [model, const],
        )
    )


row(
    "calculation",
    "Effective characters / 5 / elapsed minutes; at least 2 samples; round nearest; 15s rolling window,2s minimum",
    "WPMWidget_Calc counts ring samples; ring bounded to 2000",
    "get_live_stats uses effective ring and shared metrics",
    "live_wpm.stats uses stamps and shared metrics",
    evidence=[
        S + "lua/keystats/metrics.lua",
        S + "lua/keystats/live_wpm.lua",
        paths["windows"]["widget"],
        paths["macos"]["keystats"],
    ],
)
row(
    "manual-producer",
    "Accepted physical text contributes one sample per character; Backspace is not typed output",
    "keystats_hook -> Push, excludes non-text physical keys",
    "physical buffer -> recent_typing_eff; backspace removes prior sample",
    "ingest_keydown -> Live.record(1); backspace does not add",
    classification="unknown_intent",
    basis="source-only: correction treatment may differ; no cross-native desktop proof",
)
row(
    "hotstring-producer",
    "Successful replacements count produced characters and carry group",
    "KL_LogHotstring Loop StrLen(replacement) -> Push(category,section)",
    "notify_synthetic deferred builder -> effective stamps; source_variant group",
    "record_hotstring -> Live.record(char_count(replacement)); mark_source group",
    evidence=[paths["windows"]["keystats"], paths["macos"]["keystats"], paths["linux"]["keystats"]],
)
row(
    "ai-producer",
    "Accepted AI output contributes characters and llm source",
    "llm_bridge Loop StrLen(Transaction.Text) -> Push(ai)",
    "notify_synthetic(text,llm) -> effective stamps",
    "record_synthetic_output(text,llm) -> Live.record and mark_source",
    evidence=[paths["windows"]["ai"], paths["macos"]["keystats"], paths["linux"]["keystats"]],
)
row(
    "unicode-count",
    "Character semantics should be understood per native producer",
    "AHK StrLen UTF16 code units for synthetic output",
    "synthetic builder codepoint iteration",
    "char_count UTF8 codepoints",
    classification="unknown_intent",
    basis="source-only parity risk for non-BMP text; no native receiving executed",
)
row(
    "idle-number-reset",
    "Shared keystats timing says zero after >5000ms with no character",
    "Calc has no5s reset; hidden normally at3s, preview may expose retained WPM",
    "get_live_stats zeroes when session idle>5s",
    "live_wpm.stats zeroes when last_active idle>5s",
    classification="unknown_intent",
    basis="Lua tracker boundary executed; Windows source-only discrepancy delegated to OS role",
)
row(
    "source-time",
    "Producer time monotonic; active source hold1000ms",
    "A_TickCount ms and independent category ticks",
    "absoluteTime seconds returned to model",
    "timestamp ms stored and divided1000 for model",
)
row(
    "source-order",
    "Last producer supplies held colour",
    "AI > hotstring > autocorrection precedence among all held timestamps",
    "single last_source_type/variant",
    "single live tracker source/variant",
    classification="unknown_intent",
    basis="source-only discrepancy; Windows role has source-projection trace, not native AHK execution",
)
row(
    "source-hold-boundary",
    "Hold one second",
    "strict delta<1000ms",
    "model delta<=1s",
    "model delta<=1s",
    classification="unknown_intent",
    basis="Lua exact boundary executed, native tick-boundary difference unmeasured",
)
row(
    "source-neutral",
    "none/manual/hotstring/repeat_key/rolls use manual blue",
    "neutral category removes hotstring flag",
    "shared model neutral table",
    "shared model neutral table",
)
row(
    "source-colours",
    "manual#0055cc AI#7a30b0 invalid group#007aff; user group overrides live",
    "CategoryBgColor resolves shared TOML/overrides; section fallback",
    "resolve_group_hex -> hotstrings_config.resolve",
    "resolve_group_hex -> hotstrings catalogue resolver",
)
row(
    "colours-disabled",
    "Blue floating pill; unfilled macOS readout and neutral filled Linux icon",
    "ResolveBgColor returns manual",
    "compact model manual; menubar source-colour background omitted",
    "compact model manual; tray neutral_background fill",
    classification="explicit_intent",
)
row(
    "localized-unit",
    "Locale menu.metrics.wpm_unit applied to floating compact/graph and panel title",
    "t(unit) in drawing",
    "WPMShared.unit_label through i18n",
    "widget frame_options through i18n; tray title uses model label",
)
row(
    "compact-style",
    "80x68 logical pixels,20pt number,8pt unit,strip40% rounded,radius10,alpha220/255",
    "native Gui/GDI+ draws canon constants",
    "canvas receives shared compact frame",
    "GTK/Cairo receives shared compact frame",
)
row(
    "graph-style",
    "216x72,radius10,padding5,scale120,60 samples; last12s at200ms",
    "native GDI+ graph,history pushed per tick",
    "shared model graph_frame -> canvas",
    "shared model graph_frame -> GTK/Cairo",
)
row(
    "graph-colour-history",
    "Curve uses current source colour; samples preserve numeric speed",
    "numeric history; entire curve current accent",
    "history stores wpm/source, graph uses current colour",
    "same shared model",
    classification="explicit_intent",
)
row(
    "graph-idle-history",
    "Sampling continues per active tick while hidden",
    "tick before should_show",
    "push_history before show",
    "push_history before show",
)
row(
    "startup-hidden",
    "Readout should show only on activity/preview",
    "Show resets ring/history before hidden native surface; waits new typing",
    "existing keystats live buffer may immediately reveal after start",
    "existing live tracker may immediately reveal after start",
    classification="unknown_intent",
    basis="source-only enabling-with-existing-typing behavior differs",
)
row(
    "mouse-hide",
    "Module declarations say hide when mouse moves after last keystroke",
    "native fast MouseWatch hides and Tick mouse gate",
    "shared widget_visible allows WPM>0 to bypass mouse gate",
    "shared widget_visible allows WPM>0 to bypass mouse gate",
    classification="unknown_intent",
    basis="H-WPMS-001 actual shared-model producer->decision execution disagrees with model comments and Windows implementation; no user-facing spec located; native rendering not claimed",
)
row(
    "idle-hide",
    "Declared idle-hide3000ms",
    "last actual input time ->3s",
    "last_active refreshed by residual WPM, then3s tail",
    "same shared model",
    classification="unknown_intent",
    basis="H-WPMS-001 same rule: WPM observation treated as fresh input; no user-facing timing promise located",
)
row(
    "preview-visible",
    "Visible preview keeps readout available even WPM0",
    "TooltipIsVisible OR LLM_TooltipIsVisible",
    "widget/menubar ui.tooltip.is_visible; AI-specific status not checked here",
    "widget tooltip_visible checks hotstring and AI owners",
    classification="unknown_intent",
    basis="native macOS role investigates preview ownership; no unproved omission finding here",
)
row(
    "drag",
    "Both graph and compact must drag, save compact anchor",
    "WM_NCLBUTTONDOWN move loop +position persistence",
    "canvas mouse callback; native admission requires separate OS proof",
    "surface drag signals; forced visible during drag",
)
row(
    "mode-anchor",
    "Compact anchor fixed; graph shares bottom-right",
    "ShowPos derives graph position",
    "Model.frame_origin, anchor_from_origin",
    "same model",
    basis="model anchor round-trip executed",
)
row(
    "position-store",
    "Storage keys wpm_widget.pos_x/y, not config preferences",
    "Storage registry",
    "hs.settings Storage port",
    "storage file port",
    classification="explicit_intent",
)
row(
    "default-monitor-placement",
    "Bottom-right inset5, compact anchor",
    "MonitorGetWorkArea default primary monitor",
    "hs.screen.mainScreen fullFrame",
    "Gdk primary or monitor0 geometry",
    classification="native_constraint",
    basis="source-only work-area vs full-screen native coordinate domains; mainScreen choice differs; no native desktop geometry measured",
)
row(
    "saved-position-validation",
    "Do not invent cross-platform saved-coordinate parity",
    "finite numeric pair +center in any work area",
    "finite pair; reused anchor across active screen changes",
    "finite pair; reused anchor across active screen changes",
    classification="unknown_intent",
    basis="prior pair-finding duplicate excluded; OS roles own offscreen findings",
)
row(
    "reset-position",
    "Menu resets Storage anchor to default and applies next geometry",
    "WPMWidget_ResetPosition",
    "widget.reset_position",
    "widget.reset_position",
)
row(
    "menubar-availability",
    "Only macOS and Linux declared; Windows alternative known",
    "not implemented; grey reason names floating alternative",
    "native hs.menubar item",
    "separate StatusNotifier tray item",
    classification="explicit_intent",
    evidence=[manifest, menu, "TODO.md", S + "data/locales/en.json"],
)
row(
    "menubar-native-style",
    "13pt localized padded string,white text,source bg alpha0.5; icon adaptation permitted",
    "no panel readout",
    "styledtext AppleSystemUIFont13 with NBSP; optional bg",
    "44px PNG number only24px max autoshrinks; unit in title; neutral fill required",
    classification="native_constraint",
    basis="source inspected; Linux comments state panels ignore labels and cache icon paths; native OS outputs not executed",
)
row(
    "menubar-visibility",
    "WPM>0 or preview or held source; no floating3s tail",
    "not implemented",
    "equivalent condition in wpm_menubar.lua",
    "Model.menubar_visible",
    classification="explicit_intent",
)
row(
    "idle-style-constants",
    "bg_idle/text_idle/alpha_idle retained",
    "is_idle=false in tick, idle fill not shown",
    "model always active text/alpha",
    "same shared model",
    classification="unknown_intent",
    basis="shipped currently hide instead of dim; unused declaration not an actionable finding",
)
row(
    "canon-admission",
    "Missing required key refuses model canon",
    "native loader checks expected keys",
    "Model.validate through shared helper",
    "Model.validate through constants loader",
    classification="parity",
    basis="model malformed colour/missing scale key cases and producer probe; optional neutral entries omitted from REQUIRED",
)
row(
    "canon-invalid-neutral-entry",
    "Comment says every key checked; neutral rolls/repeat_key/hotstring not in REQUIRED",
    "NEUTRAL iterates shipped table",
    "validate accepts missing rolls and source then fallback_accent",
    "same model",
    classification="unknown_intent",
    basis="actual validate mutation characterized; bundled-file corruption only, no reachable ordinary UI edit so no confirmed finding",
)
row(
    "declaration-dependencies",
    "WPM feature metadata requires render/input dependencies",
    "webview2 despite native GDI+",
    "karabiner despite native canvas",
    "evdev for metrics source",
    classification="unknown_intent",
    basis="metadata only; no demonstrated readiness/UI refusal, not a confirmed defect",
)
row(
    "pause-lifecycle",
    "No readout activity while paused; enable/stop/reload persist and acknowledge",
    "Tick hides when A_IsSuspended; Push guards; lifecycle native-owned",
    "is_current fences; pause owner stops/restarts; config scope snapshots",
    "daemon controls ticks; preference debt admits/retries; config snapshots",
    basis="source only in shared role; refusal/stale seams assigned to OS roles",
)
row(
    "action-catalogue",
    "WPM controls are metrics-menu commands",
    "4 handlers",
    "6 handlers",
    "6 handlers",
    classification="explicit_intent",
    basis="no WPM-specific sg_action in actions.toml; open_metrics_typing/apps are dashboard actions, outside WPM readout scope",
    evidence=[
        S + "modules/actions/actions.toml",
        paths["windows"]["menu"],
        paths["macos"]["menu"],
        paths["linux"]["menu"],
    ],
)
settings = [x for x in features if x["id"].startswith("wpm_")]
actions = [
    x
    for x in menus
    if x.get("id")
    in {
        "wpm_menubar",
        "menubar_colors",
        "wpm_widget",
        "widget_colors",
        "include_realtime",
        "reset_wpm_position",
    }
]
reason = "platform_reason.wpm_readout_needs_a_menubar"
result = {
    "schema_version": 1,
    "audited_sha": "7aecd9a25b35efdcff68898919506dc2f6fd02d0",
    "bounded_scope": "WPM shared canon/model/live calculation +5 settings +6 menu commands +native adapter comparison",
    "classification_legend": {
        "parity": "same source-level contract; execution basis stated separately",
        "explicit_intent": "source/manifests state difference or deliberate policy",
        "native_constraint": "native adaptation evidenced by adapter mechanism; visual delivery unmeasured",
        "unknown_intent": "source difference or question without enough proof/intent to promote",
        "defect": "confirmed business-owner decision violation; source adapter trace separate",
    },
    "source_paths": paths,
    "capabilities": rows,
    "settings": settings,
    "menu_actions": actions,
    "locale_units": {k: v.get("menu.metrics.wpm_unit") for k, v in locales.items()},
    "reason_text": {k: v.get(reason) for k, v in locales.items()},
    "native_delivery_executed": False,
    "limits": [
        "All native UI/desktop delivery delegated; this role executes actual shared model and tracker only.",
        "Performance, memory growth, native pointer delivery, detached-monitor receiving, OS backend refusals unmeasured.",
        "G4 not asserted.",
        "Source-only differences remain outside canonical findings.",
    ],
}
(OUT / "comparison.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
assert len(settings) == 5 and len(actions) == 6
assert len(result["locale_units"]) == len(result["reason_text"])
assert all(result["locale_units"].values()) and all(result["reason_text"].values())
for pmap in paths.values():
    for p in pmap.values():
        assert (ROOT / p).is_file(), p
print(
    "comparison inventory:",
    len(rows),
    "capabilities,",
    len(settings),
    "settings,",
    len(actions),
    "menu actions,",
    len(locales),
    "locales with unit+reason",
)
