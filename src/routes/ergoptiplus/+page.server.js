// src/routes/ergoptiplus/+page.server.js
//
// Build-time loader that parses the Hammerspoon LLM catalog
// (static/ergopti_plus/_shared/llm/models.json) and exposes a compact
// per-provider summary to the page. Running this server-side keeps the
// 200 KB raw JSON out of the client bundle — only the trimmed summary is
// serialized into the prerendered HTML.

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

export const prerender = true;

// Resolve the JSON path from the repo root (process.cwd() at build time) so
// the path survives SvelteKit server-side compilation regardless of __dirname.
const MODELS_PATH = resolve(process.cwd(), 'static/ergopti_plus/_shared/llm/models.json');

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

export function load() {
	const raw = readFileSync(MODELS_PATH, 'utf-8');
	/** @type {Array<{label: string, families: Array<{label: string, models: Array<{parameters?: {total?: string}}>}>}>} */
	const catalog = JSON.parse(raw);

	const aiProviders = catalog
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

	const aiTotalProviders = aiProviders.length;
	const aiTotalModels = aiProviders.reduce((s, p) => s + p.modelCount, 0);
	const aiTotalFamilies = aiProviders.reduce((s, p) => s + p.familyCount, 0);

	return { aiProviders, aiTotalProviders, aiTotalModels, aiTotalFamilies };
}
