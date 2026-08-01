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
 *   Linux  — ui/webview_manager.lua reads the manifest generically for
 *            every app id, so the check is that it keeps doing so and hardcodes
 *            no per-app size of its own.
 *
 * Windows migration to the manifest-reading WebViewHost factory
 * (infra/webview_utils.ahk) is the intended end state; until then this value gate
 * keeps the hardcoded Windows sizes honest.
 *
 * COVERAGE IS DERIVED FROM THE MANIFEST, NOT FROM A HAND-WRITTEN LIST:
 * The per-driver maps below used to BE the coverage, so an app absent from them
 * was silently unguarded — and four were. That is how the macOS healthcheck came
 * to open at 700x600 while Windows opened the same diagnostic at the manifest's
 * 740x560: exactly the drift this file exists to prevent, in a window nobody had
 * listed. Every app id in the manifest must now be either checked on a driver or
 * named in that driver's EXCLUSIONS with a written reason, and an exclusion for
 * an app that no longer exists fails too, so the list cannot rot.
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
	token_prompt: 'ui/menu/menu_llm/models_selector.lua',
	healthcheck: 'ui/healthcheck/core.lua',
	download_window: 'ui/download_window/init.lua'
};

// Apps deliberately not value-checked on macOS, each with the reason. A stale
// entry (app gone from the manifest) fails, so this cannot quietly rot.
const MACOS_EXCLUSIONS = {
	metrics_apps: 'sizes itself to the screen (sf.w - 100), by design — the manifest value is honoured only by Linux',
	metrics_typing: 'sizes itself to the screen (sf.w - 100), by design — the manifest value is honoured only by Linux'
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
	},
	download_window: {
		file: 'modules/llm/ollama_webview.ahk',
		checks: (m) => [new RegExp(`_OllamaWV_W\\s*:=\\s*${m.width}\\b`), new RegExp(`_OllamaWV_H\\s*:=\\s*${m.height}\\b`)]
	}
};

// Same contract as MACOS_EXCLUSIONS: a reason, or a check.
const WINDOWS_EXCLUSIONS = {
	metrics_apps: 'KLWV_Open sizes the dashboard to 70 % of the work area, capped 1300x800 — deliberately adaptive, ignores the manifest',
	metrics_typing: 'KLWV_Open sizes the dashboard to 70 % of the work area, capped 1300x800 — deliberately adaptive, ignores the manifest',
	token_prompt: 'no Windows host — the token dialog is a native InputBox, which has no manifest geometry'
};

// ── Linux: the manager must resolve geometry generically, for every app ───────
// Linux is the one driver that already reads the manifest for all 14 ids, so the
// check is that it keeps doing so rather than growing per-app literals.
const LINUX_MANAGER = 'ui/webview_manager.lua';

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

// ---- Linux: generic manifest resolution, no per-app literals ---------------
const linuxAbs = path.join(ROOT, SP, 'linux', LINUX_MANAGER);
const linuxSrc = fs.readFileSync(linuxAbs, 'utf8');
if (!/apps\.manifest\.json/.test(linuxSrc)) {
	errors.push(`linux/${LINUX_MANAGER}: must resolve window geometry from _shared/ui/apps.manifest.json`);
}
if (!/manifest\.apps\[\s*app_name\s*\]/.test(linuxSrc)) {
	errors.push(
		`linux/${LINUX_MANAGER}: geometry lookup must be keyed by the app id (manifest.apps[app_name]), not per-app branches`
	);
}
// A per-app size literal here would be a second source of truth. The generic
// fallback defaults are the one allowed set of numbers, so they are exempted —
// and separately required NOT to coincide with any real app's geometry, since a
// silent fallback that happens to match would be indistinguishable from a hit.
const LINUX_FALLBACK = { width: 800, height: 600, min_width: 400, min_height: 300 };
for (const [id, m] of Object.entries(apps)) {
	for (const dim of ['width', 'height']) {
		if (m[dim] === LINUX_FALLBACK[dim]) continue;
		// (?<![\w_]) so `min_height = 300` is not read as a `height` literal — the
		// fallback's min_height happens to equal paths_editor's height.
		const re = new RegExp(`(?<![\\w_])${dim}\\s*=\\s*${m[dim]}\\b`);
		if (re.test(linuxSrc)) {
			errors.push(`linux/${LINUX_MANAGER}: hardcodes ${dim} ${m[dim]} — that is "${id}"'s manifest value, read it from the manifest`);
		}
	}
}
for (const [id, m] of Object.entries(apps)) {
	if (m.width === LINUX_FALLBACK.width && m.height === LINUX_FALLBACK.height) {
		errors.push(
			`apps.manifest.json: "${id}" is ${m.width}x${m.height}, identical to the Linux manager's fallback size — ` +
				'a manifest miss would then be invisible. Change the app size or the fallback.'
		);
	}
}

// ---- Coverage completeness: every manifest app, on every driver ------------
// Derived from the manifest so a new app is guarded the day it is added.
const DRIVERS = [
	{ name: 'macOS', covered: MACOS_MODULES, excluded: MACOS_EXCLUSIONS },
	{ name: 'Windows', covered: WINDOWS_APPS, excluded: WINDOWS_EXCLUSIONS },
	{ name: 'Linux', covered: apps, excluded: {} } // generic reader covers every id
];
for (const d of DRIVERS) {
	for (const id of Object.keys(apps)) {
		if (d.covered[id] || d.excluded[id]) continue;
		errors.push(
			`${d.name}: app "${id}" is in apps.manifest.json but neither geometry-checked nor excluded — ` +
				'add a check, or an EXCLUSIONS entry saying why it cannot have one.'
		);
	}
	for (const id of Object.keys(d.excluded)) {
		if (!apps[id]) {
			errors.push(`${d.name}: EXCLUSIONS names "${id}", which is not in apps.manifest.json — stale entry, delete it.`);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Webview geometry is not single-sourced from apps.manifest.json:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

const excluded = Object.keys(MACOS_EXCLUSIONS).length + Object.keys(WINDOWS_EXCLUSIONS).length;
const total = Object.keys(MACOS_MODULES).length + Object.keys(WINDOWS_APPS).length;
console.log(
	`\x1b[32m[OK] Webview geometry single-sourced — ${Object.keys(apps).length} manifest apps, all accounted for on three drivers: ` +
		`${Object.keys(MACOS_MODULES).length} macOS modules defer to get_app_geometry, ` +
		`${Object.keys(WINDOWS_APPS).length} Windows hosts match the manifest, ` +
		`Linux resolves every id generically (${total} value checks, ${excluded} documented exclusions).\x1b[0m`
);
