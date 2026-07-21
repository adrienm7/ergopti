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

// ==========================================
// ==========================================
// ======= 4/ Driver UI — Webviews ==========
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
// ======= 5/ Page Load ==========
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
	const localesCount = readdirSync(LOCALES_ROOT).filter((f) => f.endsWith('.json')).length;

	return {
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
		localesCount
	};
}
