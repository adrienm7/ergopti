// tools/test/test-model-identity-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Model-identity normaliser single source (llm-model-identity-single-normaliser)
 * DESCRIPTION:
 * A model reaches the shared model-browser page under two identities: the
 * catalogue display name ("Qwen3 8B") and the backend-native tag ("qwen3:8b").
 * Deciding which row is ACTIVE and which rows are INSTALLED both require
 * reducing those to one comparison key, and the two decisions are made in
 * different files — M.build in the shared catalogue, and the per-driver bridge's
 * installed lookup.
 *
 * ROOT CAUSE ENCODED:
 * The projection was extracted into _shared/lua/llm/model_catalogue.lua, but the
 * Linux bridge kept a byte-identical private copy of the normaliser. Nothing
 * failed, because the copies agreed on the day they were written. That is
 * exactly the shape this repository has been bitten by before: two hand-
 * maintained copies with no test between them. The moment one side learns a new
 * rule — strip a registry prefix, fold a "-instruct" suffix — the browser marks
 * a model active while reporting it as not installed, and no test notices.
 *
 * This guard fails if any driver declares its own normalise_name, or if a bridge
 * stops referencing the shared one (which would delete the fix rather than keep
 * it).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');

// The one home for the rule.
const SSOT = 'static/ergopti_plus/_shared/lua/llm/model_catalogue.lua';

// Every driver file that compares model identities and must borrow the rule.
const CONSUMERS = ['static/ergopti_plus/linux/ui/model_browser/bridge.lua'];

// Any Lua tree that must not grow a second implementation. The shared module is
// scanned too — its own declaration is recognised and allowed by name.
const DRIVER_TREES = [
	'static/ergopti_plus/linux',
	'static/ergopti_plus/macos',
	'static/ergopti_plus/_shared/lua',
];

/**
 * Reads one repository file as UTF-8.
 * @param {string} rel Repository-relative path.
 * @returns {string} File contents.
 */
function read(rel) {
	return fs.readFileSync(path.join(ROOT, rel), 'utf8');
}

/**
 * Collects every .lua file under a repository-relative directory.
 * @param {string} rel Repository-relative directory.
 * @returns {string[]} Repository-relative Lua file paths.
 */
function luaFiles(rel) {
	const out = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
			const child = `${dir}/${entry.name}`;
			if (entry.isDirectory()) {
				// vendor/ carries third-party Lua nobody here maintains.
				if (entry.name === 'vendor' || entry.name === 'node_modules') continue;
				walk(child);
			} else if (entry.name.endsWith('.lua')) {
				out.push(child);
			}
		}
	};
	walk(rel);
	return out;
}

const errors = [];

// 1. The rule must exist, publicly, in exactly one place.
const ssotSource = read(SSOT);
if (!/function\s+M\.normalise_name\s*\(/.test(ssotSource)) {
	errors.push(`${SSOT}: must declare a public M.normalise_name — every driver borrows it`);
}

// 2. No driver may declare its own. A `local normalise_name = <something>.…`
//    binding is a borrow, not a declaration, so only definitions are matched.
const DECLARATION_RE = /(?:local\s+)?function\s+normalise_name\s*\(/;
for (const tree of DRIVER_TREES) {
	for (const rel of luaFiles(tree)) {
		// The shared module's own public declaration is the source of truth.
		if (rel === SSOT) continue;
		// Test files may build fixtures around the rule; production may not.
		if (rel.includes('/tests/')) continue;
		const source = read(rel);
		if (DECLARATION_RE.test(source)) {
			errors.push(`${rel}: declares its own normalise_name — borrow ModelCatalogue.normalise_name instead`);
		}
	}
}

// 3. Each consumer must positively reference the shared rule, so the guard above
//    cannot be satisfied by simply deleting the comparison.
for (const rel of CONSUMERS) {
	const source = read(rel);
	if (!/ModelCatalogue\.normalise_name/.test(source)) {
		errors.push(`${rel}: must resolve model identities through ModelCatalogue.normalise_name`);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] the model-identity normaliser must have exactly one home.\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(`\x1b[32m[OK] One model-identity normaliser, borrowed by ${CONSUMERS.length} consumer(s).\x1b[0m`);
