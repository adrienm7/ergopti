// tools/test/test-webview-geometry-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Webview Geometry Single-Source Guard
 * DESCRIPTION:
 * Every webview window's geometry (width/height) is defined exactly ONCE, in
 * _shared/ui/apps.manifest.json. All three drivers must open each window at that
 * canonical size (SSoT), so the same editor is never a different size on macOS
 * vs Windows.
 *
 * ROOT CAUSE ENCODED:
 * The manifest existed but was read by no live path, so each size was in reality
 * hardcoded per driver — and 9 of them had already drifted (e.g. the hotstring
 * editor was 960x640 on Windows but 760x640 on macOS). This guard makes drift
 * impossible again by pinning both drivers to the manifest:
 *
 *   macOS  — every UI module resolves geometry through
 *            ui_builder.get_app_geometry("<id>") at open time. The module must
 *            NOT hardcode a numeric size (no `get_centered_frame(<number>` and no
 *            `math.min(<number>, math.floor(...)` clamp). Adding a literal back
 *            fails this test.
 *   Windows — the geometry literals (WebView2 hosts still hardcode them) must
 *            equal the manifest value for that app. The expected strings are
 *            BUILT from the manifest at test time, so if the manifest changes the
 *            Windows literal must follow or this test fails.
 *
 * Windows migration to the manifest-reading WebViewHost factory
 * (lib/webview_utils.ahk) is the intended end state; until then this value gate
 * keeps the hardcoded Windows sizes honest.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = 'static/ergopti_plus';
const MANIFEST = path.join(ROOT, SP, '_shared/ui/apps.manifest.json');

function readManifest() {
	const json = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
	if (!json || typeof json.apps !== 'object') {
		throw new Error('apps.manifest.json has no "apps" object');
	}
	return json.apps;
}

// ── macOS: each module must DEFER to the manifest, never hardcode a size ──────
// id → module file (relative to static/ergopti_plus/macos).
const MACOS_MODULES = {
	action_picker: 'ui/action_picker/init.lua',
	hotstrings_config_window: 'ui/hotstrings_config_window/init.lua',
	prompt_editor: 'ui/prompt_editor/init.lua',
	changelog: 'ui/changelog/init.lua',
	model_browser: 'ui/model_browser/init.lua',
	hotstring_editor: 'ui/hotstring_editor/init.lua',
	personal_info_editor: 'ui/personal_info_editor/init.lua',
	onboarding: 'ui/onboarding/init.lua',
	paths_editor: 'ui/menu/menu_paths.lua',
	token_prompt: 'ui/menu/menu_llm/models_selector.lua'
};

// ── Windows: geometry literals that must equal the manifest value ────────────
// Each app lists RegExp builders; `m` is the manifest entry. Two host forms:
// literal `w<W> h<H>` (Show/placeholder) and `NAME_WIDTH := <W>` globals. The
// value is always interpolated from the manifest so this cannot pass on drift.
const WINDOWS_APPS = {
	hotstring_editor: {
		file: 'ui/personal_toml_editor_webview.ahk',
		checks: (m) => [new RegExp(`\\bw${m.width}\\s+h${m.height}\\b`)]
	},
	healthcheck: {
		file: 'ui/healthcheck/core.ahk',
		// Width is a global; height is content-driven (Show uses AutoSize) with the
		// canonical value held in ContentH.
		checks: (m) => [new RegExp(`_HC_WIN_W\\s*:=\\s*${m.width}\\b`), new RegExp(`ContentH\\s*:=\\s*${m.height}\\b`)]
	},
	changelog: {
		file: 'ui/changelog/init.ahk',
		checks: (m) => [new RegExp(`\\bw${m.width}\\s+h${m.height}\\b`)]
	},
	model_browser: {
		file: 'ui/model_browser/init.ahk',
		checks: (m) => [new RegExp(`\\bw${m.width}\\s+h${m.height}\\b`)]
	},
	hotstrings_config_window: {
		file: 'ui/hotstrings_config_window/webview.ahk',
		checks: (m) => [new RegExp(`HCWWEB_WIDTH\\s*:=\\s*${m.width}\\b`), new RegExp(`HCWWEB_HEIGHT\\s*:=\\s*${m.height}\\b`)]
	},
	prompt_editor: {
		file: 'ui/prompt_editor/init.ahk',
		checks: (m) => [new RegExp(`PROMPTED_WIDTH\\s*:=\\s*${m.width}\\b`), new RegExp(`PROMPTED_HEIGHT\\s*:=\\s*${m.height}\\b`)]
	},
	onboarding: {
		file: 'ui/onboarding/webview.ahk',
		checks: (m) => [new RegExp(`\\bw${m.width}\\s+h${m.height}\\b`)]
	},
	paths_editor: {
		file: 'ui/paths_editor/init.ahk',
		checks: (m) => [new RegExp(`\\bw${m.width}\\s+h${m.height}\\b`)]
	},
	personal_info_editor: {
		file: 'ui/personal_info_editor/init.ahk',
		checks: (m) => [new RegExp(`\\bw${m.width}\\s+h${m.height}\\b`)]
	},
	action_picker: {
		file: 'ui/action_picker_webview.ahk',
		checks: (m) => [new RegExp(`ACTPICK_WIDTH\\s*:=\\s*${m.width}\\b`), new RegExp(`ACTPICK_HEIGHT\\s*:=\\s*${m.height}\\b`)]
	}
};

const errors = [];
const apps = readManifest();

// ---- macOS defer checks --------------------------------------------------
for (const [id, rel] of Object.entries(MACOS_MODULES)) {
	if (!apps[id]) {
		errors.push(`manifest is missing app id "${id}" (referenced by macOS ${rel})`);
		continue;
	}
	const abs = path.join(ROOT, SP, 'macos', rel);
	const src = fs.readFileSync(abs, 'utf8');
	if (!src.includes(`get_app_geometry("${id}")`)) {
		errors.push(`macos/${rel}: must resolve geometry via ui_builder.get_app_geometry("${id}")`);
	}
	if (/get_centered_frame\(\s*\d/.test(src)) {
		errors.push(`macos/${rel}: hardcoded numeric size passed to get_centered_frame — must use geo.width/geo.height`);
	}
	if (/math\.min\(\s*\d+\s*,\s*math\.floor/.test(src)) {
		errors.push(`macos/${rel}: hardcoded clamp max in math.min(<number>, math.floor(...)) — must use geo.width/geo.height`);
	}
}

// ---- Windows value checks ------------------------------------------------
for (const [id, spec] of Object.entries(WINDOWS_APPS)) {
	const m = apps[id];
	if (!m) {
		errors.push(`manifest is missing app id "${id}" (referenced by Windows ${spec.file})`);
		continue;
	}
	const abs = path.join(ROOT, SP, 'windows', spec.file);
	const src = fs.readFileSync(abs, 'utf8');
	for (const re of spec.checks(m)) {
		if (!re.test(src)) {
			errors.push(`windows/${spec.file}: geometry for "${id}" does not match manifest (${m.width}x${m.height}); expected /${re.source}/`);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Webview geometry is not single-sourced from apps.manifest.json:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

const total = Object.keys(MACOS_MODULES).length + Object.keys(WINDOWS_APPS).length;
console.log(
	`\x1b[32m[OK] Webview geometry single-sourced — ${Object.keys(MACOS_MODULES).length} macOS modules defer to get_app_geometry, ` +
		`${Object.keys(WINDOWS_APPS).length} Windows hosts match apps.manifest.json (${total} checks).\x1b[0m`
);
