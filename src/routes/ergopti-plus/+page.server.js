// src/routes/ergopti-plus/+page.server.js

/**
 * ==============================================================================
 * MODULE: Ergopti+ Marketing Page — Build-Time Data Loader
 * DESCRIPTION:
 * Parses the REAL driver data files under static/ergopti_plus/_shared/ at build
 * time and exposes compact summaries to the page. Nothing on the page is
 * hand-maintained: add a model, a provider, a profile or a hotstring to the
 * driver and the page refreshes itself on the next deploy.
 *
 * FEATURES & RATIONALE:
 * 1. Single Source of Truth: the drivers read these same JSON/TOML files at
 *    boot, so the page can never drift from what users actually install.
 * 2. Build-Time Only: the raw catalogs weigh hundreds of KB; parsing them here
 *    keeps the client bundle small — only trimmed summaries are serialized.
 * ==============================================================================
 */

import { readFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { parse as parseToml } from 'smol-toml';

export const prerender = true;

// Repo-rooted paths (process.cwd() is the repo root at build time).
const SHARED_ROOT = resolve(process.cwd(), 'static/ergopti_plus/_shared');
const LLM_ROOT = resolve(SHARED_ROOT, 'modules/llm');
const HOTSTRINGS_ROOT = resolve(SHARED_ROOT, 'modules/hotstrings');
const UI_ROOT = resolve(SHARED_ROOT, 'ui');
const LOCALES_ROOT = resolve(SHARED_ROOT, 'data/locales');
// Canonical language display order — single source shared with the drivers.
const LOCALE_ORDER_PATH = resolve(SHARED_ROOT, 'data/locale_order.json');

/**
 * Read and parse a JSON file, failing the build loudly on malformed input.
 * @param {string} path - Absolute path of the JSON file.
 * @returns {any} The parsed document.
 */
function readJson(path) {
	return JSON.parse(readFileSync(path, 'utf-8'));
}

// =========================================
// =========================================
// ======= 1/ LLM — Model Catalog ==========
// =========================================
// =========================================

/**
 * Parse a parameter count string like "30.53B", "350M" or "1.2B" into a
 * numeric value expressed in billions. Returns 0 for malformed inputs.
 * @param {unknown} raw
 * @returns {number}
 */
function parseParams(raw) {
	if (typeof raw !== 'string' || raw === '') return 0;
	const m = raw.match(/([\d.]+)\s*([BMK]?)/i);
	if (!m) return 0;
	const value = parseFloat(m[1]);
	const unit = (m[2] || 'B').toUpperCase();
	if (unit === 'B') return value;
	if (unit === 'M') return value / 1000;
	if (unit === 'K') return value / 1_000_000;
	return value;
}

/**
 * Format a B-value back to a human-readable label.
 * @param {number} b
 * @returns {string}
 */
function fmtParams(b) {
	if (b < 1) return `${Math.round(b * 1000)} M`;
	if (b >= 10) return `${Math.round(b)} B`;
	return `${b.toFixed(1).replace('.0', '')} B`;
}

/**
 * Summarize the local-model catalog (models.json) per provider.
 * @returns {{providers: Array<object>, totals: {providers: number, models: number, families: number}, range: {min: string, max: string}}}
 */
function loadModelCatalog() {
	const catalog = readJson(resolve(LLM_ROOT, 'models.json'));
	let globalMin = Infinity;
	let globalMax = 0;

	const providers = catalog
		.map((provider) => {
			let modelCount = 0;
			let min = Infinity;
			let max = 0;
			const familyLabels = [];
			for (const family of provider.families ?? []) {
				familyLabels.push(family.label);
				for (const model of family.models ?? []) {
					modelCount++;
					const v = parseParams(model.parameters?.total);
					if (v > 0) {
						if (v < min) min = v;
						if (v > max) max = v;
						if (v < globalMin) globalMin = v;
						if (v > globalMax) globalMax = v;
					}
				}
			}
			return {
				name: provider.label,
				modelCount,
				familyCount: familyLabels.length,
				families: familyLabels.join(', '),
				range: min === Infinity ? null : `${fmtParams(min)} → ${fmtParams(max)}`
			};
		})
		.sort((a, b) => b.modelCount - a.modelCount);

	return {
		providers,
		totals: {
			providers: providers.length,
			models: providers.reduce((s, p) => s + p.modelCount, 0),
			families: providers.reduce((s, p) => s + p.familyCount, 0)
		},
		range: { min: fmtParams(globalMin), max: fmtParams(globalMax) }
	};
}

// ==================================================
// ==================================================
// ======= 2/ LLM — Providers and Profiles ==========
// ==================================================
// ==================================================

/**
 * Load the remote API provider list, in the driver's canonical order.
 * The drivers load this same file at boot, so the page can never lag.
 * @returns {Array<{id: string, label: string, defaultModel: string}>}
 */
function loadApiProviders() {
	const doc = readJson(resolve(LLM_ROOT, 'api_providers.json'));
	return (doc.provider_order ?? [])
		.map((id) => {
			const p = doc.providers?.[id];
			if (!p) return null;
			return { id, label: p.label, defaultModel: p.default_model || '' };
		})
		.filter(Boolean);
}

/**
 * Load the prompt profiles joined with their French display labels, exactly
 * as the drivers do (profiles.json + locales key "llm.profile.<id>.label").
 * @returns {Array<{id: string, label: string, batch: boolean}>}
 */
function loadProfiles() {
	const profiles = readJson(resolve(LLM_ROOT, 'profiles.json'));
	const fr = readJson(resolve(LOCALES_ROOT, 'fr.json'));
	return profiles.map((p) => ({
		id: p.id,
		label: fr[`llm.profile.${p.id}.label`] ?? p.id,
		batch: Boolean(p.batch)
	}));
}

/**
 * Load the cross-driver LLM defaults that the page quotes (debounce, number
 * of predictions, context length, local server ports).
 * @returns {object}
 */
function loadLlmDefaults() {
	const defaults = readJson(resolve(LLM_ROOT, 'defaults.json'));
	const mlx = readJson(resolve(LLM_ROOT, 'mlx_server.json'));
	return {
		debounceMs: defaults.llm_debounce_ms,
		numPredictions: defaults.llm_num_predictions,
		contextLength: defaults.llm_context_length,
		ollamaPort: defaults.llm_ollama_port,
		mlxPort: mlx.port
	};
}

// ================================================
// ================================================
// ======= 3/ Hotstrings — Measured Counts ========
// ================================================
// ================================================

/**
 * Count the shipped hotstring entries per category by parsing the same TOML
 * files both drivers load at boot. An entry is any trigger mapped to a table
 * containing an "output" key inside a [[section]] array.
 * @returns {{categories: Array<{id: string, label: string, count: number, color: string, delaySec: number}>, total: number}}
 */
function loadHotstringCategories() {
	const index = parseToml(readFileSync(resolve(HOTSTRINGS_ROOT, '_index.toml'), 'utf-8'));
	const defaults = parseToml(readFileSync(resolve(HOTSTRINGS_ROOT, 'defaults.toml'), 'utf-8'));
	const fallbackColor = defaults.colors?.global_default ?? '#1e88e5';
	const order = index.menu?.categories_order ?? [];

	const categories = order.map((id) => {
		const doc = parseToml(readFileSync(resolve(HOTSTRINGS_ROOT, `${id}.toml`), 'utf-8'));
		let count = 0;
		for (const [key, value] of Object.entries(doc)) {
			if (key === '_meta' || !Array.isArray(value)) continue;
			for (const table of value) {
				for (const entry of Object.values(table)) {
					if (entry && typeof entry === 'object' && 'output' in entry) count++;
				}
			}
		}
		const meta = doc._meta ?? {};
		return {
			id,
			label: meta.description?.fr ?? id,
			count,
			color: meta.color ?? fallbackColor,
			delaySec: meta.delay ?? defaults.delays?.default_sec ?? 0.75
		};
	});

	return { categories, total: categories.reduce((s, c) => s + c.count, 0) };
}

// ==============================================
// ==============================================
// ======= 4/ Locales — Native Names ============
// ==============================================
// ==============================================

const I18N_LUA_PATH = resolve(process.cwd(), 'static/ergopti_plus/macos/lib/i18n.lua');

/**
 * List the UI locales shipped with the drivers — flags and native names come
 * from the driver's own canonical table (macos/lib/i18n.lua), cross-checked
 * against the locale JSON files actually present. Sorted the way the driver
 * menus present them: Latin-script names alphabetically first, non-Latin
 * scripts at the bottom. Fully automated: a locale added to the driver
 * appears here on the next deploy.
 * @returns {Array<{code: string, name: string, flag: string}>}
 */
function loadLocales() {
	const available = new Set(
		readdirSync(LOCALES_ROOT)
			.filter((f) => f.endsWith('.json'))
			.map((f) => f.replace(/\.json$/, ''))
	);

	// Parse the driver's canonical table: { code = "fr", flag = "🇫🇷", name = "…" }
	const lua = readFileSync(I18N_LUA_PATH, 'utf-8');
	const entryRe =
		/\{\s*code\s*=\s*"([a-z]+)",\s*flag\s*=\s*"([^"]*)",\s*name\s*=\s*"([^"]*)"\s*\}/g;
	const known = new Map();
	for (const m of lua.matchAll(entryRe)) {
		known.set(m[1], { flag: m[2], name: m[3].trim() });
	}

	const locales = [...available].map((code) => {
		const entry = known.get(code);
		let name = entry?.name ?? code.toUpperCase();
		if (!entry) {
			try {
				const display = new Intl.DisplayNames([code], { type: 'language' });
				name = display.of(code) ?? name;
				name = name.charAt(0).toUpperCase() + name.slice(1);
			} catch (_) {
				/* Unknown code — the uppercase code is a readable fallback. */
			}
		}
		return { code, name, flag: entry?.flag ?? '' };
	});

	// Single source of truth for row order: _shared/data/locale_order.json,
	// read the same way by the Linux driver and pinned by the macOS/Windows
	// tables. Codes absent from it (shouldn't happen — a parity test enforces
	// coverage) fall to the end alphabetically, so a new locale still appears.
	const order = readJson(LOCALE_ORDER_PATH).order;
	const rank = (code) => {
		const i = order.indexOf(code);
		return i === -1 ? order.length : i;
	};
	return locales.sort((a, b) => rank(a.code) - rank(b.code) || a.code.localeCompare(b.code));
}

// ==================================================
// ==================================================
// ======= 5/ Gestures — Shared Action Catalog ======
// ==================================================
// ==================================================

const GESTURES_ROOT = resolve(SHARED_ROOT, 'modules/gestures');

/**
 * Load the shared action catalog (single source of truth consumed by all
 * three drivers at boot), grouped exactly like the driver's action picker:
 * sg_order.items uses "#key" for group headers, "##key" for sub-headers and
 * "--" for separators. Headers resolve through the same locale keys the
 * picker uses. Axis actions form a final dedicated group.
 * @returns {Array<{title: string, sections: Array<{title: string, actions: Array<{id: string, label: string, platform: string, axis: boolean}>}>}>}
 */
function loadActionGroups() {
	// The file carries a (doubled) UTF-8 BOM that smol-toml rejects.
	const raw = readFileSync(resolve(GESTURES_ROOT, 'actions.toml'), 'utf-8').replace(/^﻿+/, '');
	const doc = parseToml(raw);
	const fr = readJson(resolve(LOCALES_ROOT, 'fr.json'));
	// Locale values keep the picker's leading "#" formatting marker — strip it.
	const headerLabel = (key) =>
		(fr[`sg_actions.sg_order.header.${key}`] ?? key).replace(/^#+\s*/, '');
	const action = (id, def, group, axis) => ({
		id,
		label: fr[`${group}.${id}`] ?? id,
		platform: def?.platform ?? 'all',
		axis
	});

	const groups = [];
	let currentGroup = null;
	let currentSection = null;
	for (const item of doc.sg_order?.items ?? []) {
		if (item === '--' || item === 'none') continue;
		if (item.startsWith('##')) {
			currentSection = { title: headerLabel(item.slice(2)), actions: [] };
			currentGroup?.sections.push(currentSection);
		} else if (item.startsWith('#')) {
			currentGroup = { title: headerLabel(item.slice(1)), sections: [] };
			currentSection = null;
			groups.push(currentGroup);
		} else if (doc.sg_actions?.[item]) {
			if (!currentSection) {
				currentSection = { title: '', actions: [] };
				currentGroup?.sections.push(currentSection);
			}
			currentSection.actions.push(action(item, doc.sg_actions[item], 'sg_actions', false));
		}
	}

	const axisActions = Object.entries(doc.ax_actions ?? {}).map(([id, def]) =>
		action(id, def, 'ax_actions', true)
	);
	if (axisActions.length > 0) {
		groups.push({
			title: 'Axes continus',
			sections: [{ title: '', actions: axisActions }]
		});
	}
	return groups;
}

// ====================================================
// ====================================================
// ======= 6/ macOS Bundled Apps — Descriptions =======
// ====================================================
// ====================================================

const MACOS_APPS_ROOT = resolve(process.cwd(), 'static/ergopti_plus/macos/apps');

/**
 * Extract the value of a top-level plist string key.
 * @param {string} xml
 * @param {string} key
 * @returns {string}
 */
function plistString(xml, key) {
	const m = xml.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`));
	return m ? m[1] : '';
}

/**
 * List the extra .app bundles shipped with the macOS driver, with the pitch
 * each bundle carries in its own Info.plist (ErgoptiDescription dict) and its
 * icon inlined as SVG (the bundles ship a web-friendly AppIcon.svg).
 * Fully automated: drop a described .app into macos/apps/ and it appears on
 * the page at the next deploy.
 * @returns {Array<{id: string, name: string, description: string, icon: string|null}>}
 */
function loadMacosApps() {
	return readdirSync(MACOS_APPS_ROOT, { withFileTypes: true })
		.filter((e) => e.isDirectory() && e.name.endsWith('.app'))
		.map((e) => {
			const xml = readFileSync(resolve(MACOS_APPS_ROOT, e.name, 'Contents/Info.plist'), 'utf-8');
			const descBlock = xml.match(/<key>ErgoptiDescription<\/key>\s*<dict>([\s\S]*?)<\/dict>/)?.[1];
			// Inline the bundle's own icon; small hand-authored SVGs, so this
			// stays cheap and needs no extra asset request or URL-encoding of
			// the space-containing .app path.
			let icon = null;
			try {
				icon = readFileSync(
					resolve(MACOS_APPS_ROOT, e.name, 'Contents/Resources/AppIcon.svg'),
					'utf-8'
				).replace(/<\?xml[^>]*\?>\s*/, '');
			} catch (_) {
				/* No SVG icon shipped — the card falls back to a monogram. */
			}
			return {
				id: e.name.replace(/\.app$/, ''),
				name: plistString(xml, 'CFBundleDisplayName') || plistString(xml, 'CFBundleName') || e.name,
				description: descBlock ? plistString(descBlock, 'fr') : '',
				icon
			};
		})
		.sort((a, b) => a.name.localeCompare(b.name, 'fr'));
}

// ==========================================
// ==========================================
// ======= 7/ Driver UI — Webviews ==========
// ==========================================
// ==========================================

/**
 * List the shared webview apps shipped with the drivers, with the window
 * geometry the drivers themselves use (apps.manifest.json — read by the
 * macOS, Windows and Linux hosts). These are the same HTML/JS bundles the
 * drivers open in native windows — and since they live under static/, the
 * site serves them as-is at /ergopti_plus/_shared/ui/<id>/.
 * @returns {Array<{id: string, width: number, height: number}>}
 */
function loadWebviews() {
	const manifest = readJson(resolve(UI_ROOT, 'apps.manifest.json'));
	const dirs = readdirSync(UI_ROOT, { withFileTypes: true })
		.filter((e) => e.isDirectory())
		.map((e) => e.name)
		.sort();
	return dirs.map((id) => {
		const geo = manifest.apps?.[id] ?? {};
		return { id, width: geo.width ?? 800, height: geo.height ?? 600 };
	});
}

// ===============================
// ===============================
// ======= 8/ Page Load ==========
// ===============================
// ===============================

/**
 * SvelteKit build-time load — every number the page displays is measured
 * here from the driver's own data files.
 * @returns {object}
 */
export function load() {
	const catalog = loadModelCatalog();
	const hotstrings = loadHotstringCategories();
	const locales = loadLocales();

	return {
		locales,
		localesCount: locales.length,
		aiProviders: catalog.providers,
		aiTotalProviders: catalog.totals.providers,
		aiTotalModels: catalog.totals.models,
		aiTotalFamilies: catalog.totals.families,
		aiParamRange: catalog.range,
		apiProviders: loadApiProviders(),
		aiProfiles: loadProfiles(),
		llmDefaults: loadLlmDefaults(),
		hotstringCategories: hotstrings.categories,
		hotstringTotal: hotstrings.total,
		webviews: loadWebviews(),
		actionGroups: loadActionGroups(),
		macosApps: loadMacosApps()
	};
}
