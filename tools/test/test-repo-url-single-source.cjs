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
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const DEFAULTS = 'static/ergopti_plus/_shared/modules/updater/defaults.json';
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
const LITERAL_ALLOWED = [/\/tests\//, /^static\/ergopti_plus\/extensions\//];

// Any GitHub repository whose name is an Ergopti one; "%." is the Lua pattern
// spelling of the dot, which the changelog allow-pattern used
const ERGOPTI_REPO = /github(?:\.|%\.)com\/(?:repos\/)?([A-Za-z0-9-]+)\/(ergopti[A-Za-z0-9_-]*)/gi;

const escapeRegex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const CANONICAL = new RegExp(
	`github(?:\\.|%\\.)com\\/(?:repos\\/)?${escapeRegex(owner)}\\/${escapeRegex(repo)}(?![A-Za-z0-9_-])`,
	'i'
);

const files = execFileSync('git', ['ls-files', '-z', '--', 'static/ergopti_plus', '.github'], {
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
	// Tests and corpora spell other repositories on purpose (a foreign link a
	// parser must refuse); every shipped file must name the real one
	const isFixture = /\/tests\//.test(file);
	const literalAllowed = LITERAL_ALLOWED.some((re) => re.test(file));
	const lines = text.split('\n');
	lines.forEach((line, index) => {
		for (const match of isFixture ? [] : line.matchAll(ERGOPTI_REPO)) {
			if (
				match[1].toLowerCase() !== owner.toLowerCase() ||
				match[2].toLowerCase() !== repo.toLowerCase()
			) {
				failures.push(`${file}:${index + 1}: ${match[0]} is not the repository ${owner}/${repo}`);
			}
		}
		if (CODE_EXTENSIONS.has(path.extname(file)) && !literalAllowed && CANONICAL.test(line)) {
			failures.push(`${file}:${index + 1}: a typed repository URL — derive it from ${DEFAULTS}`);
		}
	});
}

if (scanned < 500)
	failures.push(`only ${scanned} file(s) scanned — the tracked-file listing is broken`);

if (failures.length > 0) {
	console.error(`[FAIL] repository URL single source: ${failures.length} violation(s)`);
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log(
	`[OK] repository URL single source: ${scanned} tracked file(s), every link derives from ${DEFAULTS}.`
);
