// tools/test/test-hotstring-bare-colon-catalogue.cjs

/**
 * ==============================================================================
 * MODULE: Bare Colon End Character Against the Shipped Catalogue
 * DESCRIPTION:
 * Since the maintainer decision HCD-2 (2026-11-21) a bare ":" or ";" ends a
 * hotstring trigger on the three OS, where Windows and the shared engine once
 * required the no-break space the Ergopti layout types before them. A bare
 * colon follows text meant to stay literal: a URL scheme (« https: »), a drive
 * letter (« C: »), a clock time (« 12:30 »). This gate reads every shipped
 * catalogue TOML and proves that no end-character rule rewrites such text:
 * the only rules a bare colon can reach there re-case a token whose case does
 * not matter (URL schemes and drive letters are case-insensitive), and none
 * holds a digit or the colon itself.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const TOML = require('smol-toml');

const root = path.resolve(__dirname, '..', '..');
const catalogue = path.join(
	root,
	'static',
	'ergopti_plus',
	'_shared',
	'hotstrings',
	'data',
	'catalogue'
);

// Common URL schemes (RFC 3986 makes the scheme case-insensitive) and other
// tokens a bare colon follows in code, paths and addresses.
const COLON_TOKENS = new Set(
	(
		'about afp chrome data edge file ftp ftps git http https irc javascript ldap ' +
		'localhost magnet mailto news sftp slack sms smb spotify ssh std steam svn tel ' +
		'vscode ws wss zoom'
	).split(' ')
);

/** Every TOML file under the catalogue, recursively. */
function catalogueFiles(dir) {
	const files = [];
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) files.push(...catalogueFiles(full));
		else if (entry.name.endsWith('.toml')) files.push(full);
	}
	return files;
}

/** The end-character rules (auto_expand false) of every shipped catalogue. */
function endCharacterRules() {
	const rules = [];
	for (const file of catalogueFiles(catalogue)) {
		const document = TOML.parse(fs.readFileSync(file, 'utf8'));
		for (const [section, tables] of Object.entries(document)) {
			if (section.startsWith('_') || !Array.isArray(tables)) continue;
			for (const table of tables) {
				for (const [trigger, entry] of Object.entries(table)) {
					if (
						entry &&
						typeof entry === 'object' &&
						'output' in entry &&
						entry.auto_expand !== true
					) {
						rules.push({ file: path.relative(catalogue, file), trigger, output: entry.output });
					}
				}
			}
		}
	}
	return rules;
}

const rules = endCharacterRules();
assert.ok(rules.length > 100, `the catalogue holds end-character rules (read ${rules.length})`);

for (const rule of rules) {
	assert.ok(
		!/[0-9:;]/.test(rule.trigger),
		`${rule.file} "${rule.trigger}" holds a digit or a colon`
	);
}

const reachable = rules.filter(
	(rule) => COLON_TOKENS.has(rule.trigger.toLowerCase()) || [...rule.trigger].length === 1
);
for (const rule of reachable) {
	assert.equal(
		rule.output.toLowerCase(),
		rule.trigger.toLowerCase(),
		`${rule.file} "${rule.trigger}" > "${rule.output}" rewrites a token a bare colon follows`
	);
}
assert.deepEqual(
	reachable.map((rule) => rule.trigger).sort(),
	['r', 'ssh', 'vscode'],
	'the rules a bare colon can reach are reviewed: a new one needs the same review'
);

console.log(
	`[OK] ${rules.length} end-character rules: none rewrites text a bare colon follows ` +
		`(${reachable.length} only re-case a case-insensitive token).`
);
