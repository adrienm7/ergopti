// tools/test/test-repo-url-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Repository URL Single Source
 * DESCRIPTION:
 * The GitHub owner and repository of Ergopti live in
 * static/ergopti_plus/_shared/modules/updater/defaults.json. Every link the
 * app builds (releases, changelog, bug reports, feature requests) derives from
 * those two fields. Two kinds of drift reached users before this gate:
 * 1. a WRONG repository — the Linux service file and the demo extension
 *    pointed at github.com/ergopti/ergopti, which does not exist;
 * 2. a TYPED copy of the right one in driver code — the Linux changelog bridge
 *    hardcoded the URL and its allow-pattern, so moving the repository would
 *    have silently broken its links while every other surface followed.
 * Scans tracked files under static/ergopti_plus/ and .github/. Tests,
 * corpora and the example extension (which users copy as a standalone file)
 * may spell the URL; driver code may not.
 *
 * HOSTS AND IDENTIFIERS (PAR-83):
 * The same rule covers the other typed identifiers declared once in
 * _shared/data/identifiers.json: the external hosts (GitHub, Ollama, Hugging
 * Face), the bundle ids, the service labels and the ErgoptiPlus.ahk/.exe/.app
 * names. Their code-line copies per file are held to
 * tools/lint/identifier-literal-baseline.json, which may only go down
 * (`--shrink` writes a lower count back). The Lua sites of macOS and Linux are
 * already converted to _shared/lua/identifiers.lua; the AHK, Swift, shell and
 * Python files stay in the baseline until their generators exist.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = 'static/ergopti_plus';
const DEFAULTS = `${SP}/_shared/modules/updater/defaults.json`;
const { owner, repo } = JSON.parse(fs.readFileSync(path.join(ROOT, DEFAULTS), 'utf8')).github;

// Source files whose URLs are executable logic rather than documentation
const CODE_EXTENSIONS = new Set([
	'.lua',
	'.ahk',
	'.js',
	'.cjs',
	'.mjs',
	'.swift',
	'.ps1',
	'.sh',
	'.py'
]);

// Paths allowed to spell the canonical URL: fixtures, tests and the example
// extension users copy as a self-contained file
const EXAMPLE_EXTENSION = /^static\/ergopti_plus\/extensions\//;

// Only canonical test trees hold intentional foreign and copied URLs: a nested
// directory named tests inside production code must not escape either policy.
const FIXTURE_PATH =
	/^static\/ergopti_plus\/(?:(?:windows|macos|linux|_shared)\/tests|_shared\/lua\/test)\//;

/** Classifies the canonical test trees without admitting adjacent owners. */
function isFixturePath(file) {
	return FIXTURE_PATH.test(file);
}

// Self-test: canonical roots are fixtures; a production folder named tests is not.
for (const [file, expected] of [
	['static/ergopti_plus/linux/tests/unit/x.lua', true],
	['static/ergopti_plus/_shared/lua/test/x_contract.lua', true],
	['static/ergopti_plus/macos/modules/tests/x.lua', false],
	['static/ergopti_plus/_shared/ui/tests/x.js', false]
])
	assert.equal(isFixturePath(file), expected, `fixture classification of ${file}`);

// Any GitHub repository whose name is an Ergopti one; "%." is the Lua pattern
// spelling of the dot, which the changelog allow-pattern used
const ERGOPTI_REPO = /github(?:\.|%\.)com\/(?:repos\/)?([A-Za-z0-9-]+)\/(ergopti[A-Za-z0-9_-]*)/gi;

const escapeRegex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const CANONICAL = new RegExp(
	`github(?:\\.|%\\.)com\\/(?:repos\\/)?${escapeRegex(owner)}\\/${escapeRegex(repo)}(?![A-Za-z0-9_-])`,
	'i'
);

/** Applies the same URL policy to indexed source and its adversarial controls. */
function violations(file, text) {
	const errors = [];
	const fixture = isFixturePath(file);
	const literalAllowed = fixture || EXAMPLE_EXTENSION.test(file);
	text.split('\n').forEach((line, index) => {
		for (const match of fixture ? [] : line.matchAll(ERGOPTI_REPO)) {
			if (
				match[1].toLowerCase() !== owner.toLowerCase() ||
				match[2].toLowerCase() !== repo.toLowerCase()
			) {
				errors.push(`${file}:${index + 1}: ${match[0]} is not the repository ${owner}/${repo}`);
			}
		}
		if (CODE_EXTENSIONS.has(path.extname(file)) && !literalAllowed && CANONICAL.test(line)) {
			errors.push(`${file}:${index + 1}: a typed repository URL — derive it from ${DEFAULTS}`);
		}
	});
	return errors;
}

const canonicalUrl = `https://github.com/${owner}/${repo}`;
const foreignUrl = `https://github.com/${owner}-other/${repo}`;
for (const [name, file, text, count] of [
	[
		'shared contract fixture',
		`${SP}/_shared/lua/test/repository_url_contract.lua`,
		canonicalUrl + '\n' + foreignUrl,
		0
	],
	[
		'driver fixture',
		`${SP}/macos/tests/unit/test_repository.lua`,
		canonicalUrl + '\n' + foreignUrl,
		0
	],
	[
		'adjacent shared owner literal',
		`${SP}/_shared/lua/updater/repository_url.lua`,
		canonicalUrl,
		1
	],
	[
		'adjacent shared owner foreign URL',
		`${SP}/_shared/lua/updater/repository_url.lua`,
		foreignUrl,
		1
	],
	['test-like directory', `${SP}/_shared/lua/test_owner/repository_url.lua`, canonicalUrl, 1],
	['test-like filename', `${SP}/_shared/lua/test.lua`, foreignUrl, 1],
	['other Lua test directory', `${SP}/macos/test/repository_url.lua`, canonicalUrl, 1],
	['standalone example', `${SP}/extensions/example.lua`, canonicalUrl, 0],
	['standalone example foreign URL', `${SP}/extensions/example.lua`, foreignUrl, 1]
]) {
	assert.equal(violations(file, text).length, count, `repository source role: ${name}`);
}

// Exercise classification through the same policy used by the tracked scan.
// A nearby product directory must keep both canonical and foreign checks.
const controlSource = `local canonical = "https://github.com/${owner}/${repo}"
local foreign = "https://github.com/foreign-owner/${repo}"`;
for (const fixture of [
	'static/ergopti_plus/linux/tests/unit/repository_contract.lua',
	'static/ergopti_plus/_shared/lua/test/repository_contract.lua'
]) {
	assert.deepEqual(violations(fixture, controlSource), [], fixture);
}
for (const product of [
	'static/ergopti_plus/_shared/lua/updater/repository_url.lua',
	'static/ergopti_plus/_shared/lua/test_support/repository_url.lua'
]) {
	const found = violations(product, controlSource);
	assert.equal(found.length, 2, product);
	assert.match(found[0], /a typed repository URL/);
	assert.match(found[1], /is not the repository/);
}

const files = execFileSync('git', ['ls-files', '-z', '--', SP, '.github'], {
	cwd: ROOT,
	encoding: 'utf8',
	maxBuffer: 64 * 1024 * 1024
})
	.split('\0')
	.filter(Boolean);

const failures = [];
let scanned = 0;
for (const file of files) {
	if (
		/\.(png|jpe?g|gif|ico|icns|woff2?|ttf|otf|dll|exe|zip|gz|sqlite|db|bin|dylib|so)$/i.test(file)
	)
		continue;
	let text;
	try {
		text = fs.readFileSync(path.join(ROOT, file), 'utf8');
	} catch {
		continue;
	}
	scanned++;
	// Contract fixtures intentionally spell foreign links a parser must refuse.
	// Production owners still retain both the repository and literal checks.
	failures.push(...violations(file, text));
}

// ==================================================
// ======= 1/ Hosts, Bundle Ids and App Names =======
// ==================================================

const IDENTIFIERS_REL = 'static/ergopti_plus/_shared/data/identifiers.json';
const BASELINE_REL = 'tools/lint/identifier-literal-baseline.json';
const identifiers = JSON.parse(fs.readFileSync(path.join(ROOT, IDENTIFIERS_REL), 'utf8'));
const IDENTIFIER_SOURCE = /\.(lua|js|cjs|mjs|ahk|swift|sh|py|ps1|go|mm|hpp|cpp)$/;
// Tests, vendored code, generated copies and the maintainer's diagnostics may
// spell identifiers; so may the example extension users copy as one file.
const IDENTIFIER_EXEMPT =
	/(^|\/)(tests?|vendor|node_modules|_generated|diagnostics)\/|^static\/ergopti_plus\/(extensions|_shared\/lua\/identifiers\.lua)|^tools\/test\/|_test\.(py|go)$|\.generated\.swift$/;
const COMMENT_LINE = /^\s*(--|;|\/\/|#|\*|\/\*)/;

const KIND_PATTERNS = {
	host: new RegExp(
		Object.values(identifiers.hosts)
			.map((host) => `(?<![A-Za-z0-9.-])${escapeRegex(host)}(?![A-Za-z0-9-])`)
			.join('|'),
		'g'
	),
	bundle_id_or_label: new RegExp(
		[...Object.values(identifiers.bundle_ids), ...Object.values(identifiers.service_labels)]
			.map((id) => `(?<![A-Za-z0-9.-])${escapeRegex(id)}(?![A-Za-z0-9-])`)
			.join('|'),
		'g'
	),
	app_file_name: new RegExp(
		[identifiers.app.ahk, identifiers.app.exe, identifiers.app.bundle]
			.map((name) => `(?<![A-Za-z0-9_-])${escapeRegex(name)}(?![A-Za-z0-9])`)
			.join('|'),
		'g'
	)
};

/** Counts the typed identifier copies on code lines, per file and kind. */
function countIdentifierLiterals() {
	const counts = {};
	const listed = execFileSync('git', ['ls-files', '-z', '--', 'static/ergopti_plus', 'tools'], {
		cwd: ROOT,
		encoding: 'utf8',
		maxBuffer: 64 * 1024 * 1024
	})
		.split('\0')
		.filter((file) => IDENTIFIER_SOURCE.test(file) && !IDENTIFIER_EXEMPT.test(file));
	for (const file of listed) {
		const lines = fs.readFileSync(path.join(ROOT, file), 'utf8').split('\n');
		for (const line of lines) {
			if (COMMENT_LINE.test(line)) continue;
			for (const [kind, pattern] of Object.entries(KIND_PATTERNS)) {
				const hits = line.match(pattern);
				if (!hits) continue;
				counts[file] = counts[file] || {};
				counts[file][kind] = (counts[file][kind] || 0) + hits.length;
			}
		}
	}
	return { counts, listed: listed.length };
}

const identifierScan = countIdentifierLiterals();
if (identifierScan.listed < 500)
	failures.push(`only ${identifierScan.listed} identifier source file(s) scanned — listing broken`);
const baselinePath = path.join(ROOT, BASELINE_REL);
const baseline = JSON.parse(fs.readFileSync(baselinePath, 'utf8'));
let baselineTotal = 0;
for (const [file, kinds] of Object.entries(identifierScan.counts)) {
	for (const [kind, count] of Object.entries(kinds)) {
		const allowed = (baseline.files[file] || {})[kind] || 0;
		baselineTotal += allowed;
		if (count > allowed)
			failures.push(
				`${file}: ${count} typed ${kind} literal(s), baseline ${allowed} — derive them from ` +
					`${IDENTIFIERS_REL} (Lua: require("identifiers"))`
			);
	}
}
const lowered = {};
for (const [file, kinds] of Object.entries(baseline.files)) {
	for (const [kind, allowed] of Object.entries(kinds)) {
		const count = (identifierScan.counts[file] || {})[kind] || 0;
		if (count < allowed) {
			lowered[file] = lowered[file] || {};
			lowered[file][kind] = count;
		}
	}
}
if (process.argv.includes('--shrink')) {
	// Only ever lower a count: a file that grew keeps its old allowance and fails above.
	const next = {};
	for (const [file, kinds] of Object.entries(baseline.files))
		for (const [kind, allowed] of Object.entries(kinds)) {
			const count = Math.min(allowed, (identifierScan.counts[file] || {})[kind] || 0);
			if (count > 0) (next[file] = next[file] || {})[kind] = count;
		}
	baseline.files = next;
	fs.writeFileSync(baselinePath, JSON.stringify(baseline, null, '\t') + '\n');
	console.log(`[OK] ${BASELINE_REL} rewritten from the current counts.`);
} else if (Object.keys(lowered).length > 0) {
	for (const [file, kinds] of Object.entries(lowered))
		failures.push(
			`${file}: baseline is above the ${JSON.stringify(kinds)} found — lower it with ` +
				'node tools/test/test-repo-url-single-source.cjs --shrink'
		);
}

if (scanned < 500)
	failures.push(`only ${scanned} file(s) scanned — the tracked-file listing is broken`);

if (failures.length > 0) {
	console.error(`[FAIL] repository URL single source: ${failures.length} violation(s)`);
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log(
	`[OK] repository URL single source: ${scanned} tracked file(s), every link derives from ${DEFAULTS}; ` +
		`${baselineTotal} typed host/id/name literal(s) held to ${BASELINE_REL}.`
);
