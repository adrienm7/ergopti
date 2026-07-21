// tools/test/test-i18n-fallback-path.cjs

/**
 * ==============================================================================
 * MODULE: Webview i18n Browser-Fallback Path Guard
 * DESCRIPTION:
 * Verifies that the bridge-less locale fallback in _shared/ui/i18n.js resolves
 * to a directory that actually exists. The two fallback branches (script-src
 * relative and location.href relative) are replayed here against the real
 * repository layout, so the resolved URL is proven to hit
 * _shared/data/locales/<code>.json.
 *
 * ROOT CAUSE ENCODED:
 * The original fallback pointed at "../../../locales/" — a static/locales/
 * directory that never existed in any layout (repo, site, or packaged app).
 * Nobody noticed because the drivers always inject window.__i18n_base, so the
 * fallback only runs bridge-less (Edge --app mode, website embeds), where every
 * data-i18n label silently stayed blank. This gate replays the actual string
 * manipulation from i18n.js and fails if the resolved path stops existing —
 * whether because the fallback regressed or because the locales moved.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const p = require('path');

const ROOT = p.resolve(__dirname, '..', '..');
const I18N_REL = 'static/ergopti_plus/_shared/ui/i18n.js';
const I18N_ABS = p.join(ROOT, I18N_REL);

const errors = [];

if (!fs.existsSync(I18N_ABS)) {
	errors.push(`${I18N_REL}: missing — every webview loads this script`);
} else {
	const src = fs.readFileSync(I18N_ABS, 'utf8');

	// ── 1. The dead path must never come back ───────────────────────────────
	if (src.includes("'../../../locales/'")) {
		errors.push(
			`${I18N_REL}: still references '../../../locales/' — that static/locales/ directory has never existed`
		);
	}

	// ── 2. Replay the script-src fallback against the real tree ─────────────
	// i18n.js: _script_src.replace(/[^/]+$/, '../data/locales/') + code + '.json'
	const srcBranch = src.match(/replace\(\/\[\^\/\]\+\$\/,\s*'([^']+)'\)/);
	if (!srcBranch) {
		errors.push(
			`${I18N_REL}: script-src fallback replace() not found — did the resolver change shape?`
		);
	} else {
		const scriptUrl = 'https://example.org/ergopti_plus/_shared/ui/i18n.js';
		const resolved = new URL(scriptUrl.replace(/[^/]+$/, srcBranch[1]) + 'fr.json');
		const repoPath = p.join(ROOT, 'static', ...resolved.pathname.split('/').filter(Boolean));
		if (!fs.existsSync(repoPath)) {
			errors.push(
				`${I18N_REL}: script-src fallback resolves to ${resolved.pathname} — not found at ${repoPath}`
			);
		}
	}

	// ── 3. Replay the location.href fallback against the real tree ──────────
	// i18n.js: parts.slice(0, parts.length - N).join('/') + '<suffix>' + code + '.json'
	const hrefBranch = src.match(/slice\(0,\s*parts\.length\s*-\s*(\d+)\)/);
	const hrefSuffix = src.match(/base_parts\.join\('\/'\)\s*\+\s*'([^']+)'/);
	if (!hrefBranch || !hrefSuffix) {
		errors.push(`${I18N_REL}: location.href fallback not found — did the resolver change shape?`);
	} else {
		const href = 'https://example.org/ergopti_plus/_shared/ui/metrics_typing/index.html';
		const parts = href.split('/');
		const baseParts = parts.slice(0, parts.length - Number(hrefBranch[1]));
		const resolved = new URL(baseParts.join('/') + hrefSuffix[1] + 'fr.json');
		const repoPath = p.join(ROOT, 'static', ...resolved.pathname.split('/').filter(Boolean));
		if (!fs.existsSync(repoPath)) {
			errors.push(
				`${I18N_REL}: location.href fallback resolves to ${resolved.pathname} — not found at ${repoPath}`
			);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Webview i18n browser fallback is broken:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] i18n browser fallback resolves to the real _shared/data/locales/ directory (both branches replayed).\x1b[0m'
);
