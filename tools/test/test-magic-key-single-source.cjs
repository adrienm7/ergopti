// tools/test/test-magic-key-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Magic Key — One Declared Default
 * DESCRIPTION:
 * The magic key is the character every star trigger ends with. It is declared
 * once, as `features.hotstrings.trigger_char` in the shared feature manifest,
 * and every driver is supposed to read it from there.
 *
 * WHAT THIS CAUGHT:
 * the Linux driver hardcoded a BACKSLASH in two places — the dynamic-hotstring
 * (@-tag) initialiser and the personal-info editor bridge — while the manifest,
 * both other drivers, the shared engine's MAGIC_KEY_CHAR and the onboarding
 * page all say "★". So on Linux the @-tag expansions listened for a key nothing
 * else in the product used, and the editor rendered that key in front of every
 * field name it offered. Nothing failed: a hardcoded default is a valid string,
 * and no test compared it to anything.
 *
 * WHY A LITERAL SCAN AND NOT A BEHAVIOURAL TEST:
 * the value only reaches a user through a running daemon and a WebView, neither
 * of which the suites drive. What IS checkable, and what actually regressed, is
 * that a second copy of the character exists at all. The check therefore has two
 * halves: the manifest still declares the default (so this gate cannot go
 * vacuous by the key being renamed away), and no driver spells a magic-key
 * default out again.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'features', 'manifest.toml');

const errors = [];

// ===== 1) The declaration itself must still be there =====

const manifestSrc = fs.existsSync(MANIFEST) ? fs.readFileSync(MANIFEST, 'utf8') : '';
const declared = /id\s*=\s*"trigger_char"[\s\S]{0,200}?default\s*=\s*"([^"]+)"/.exec(manifestSrc);
if (!declared) {
	errors.push(
		'features.hotstrings.trigger_char no longer declares a default in the shared manifest. ' +
			'If the key moved, re-point this gate; if it was deleted, every driver just lost its ' +
			'single source and the hardcoded copies are free to come back.'
	);
}
const MAGIC = declared ? declared[1] : null;

// Every platform the declaration covers must be able to READ it: the generator
// filters the per-driver manifests by platform, so a driver left off the list
// gets no entry at all and has no choice but to hardcode. That is exactly how
// the Linux backslash survived.
if (MAGIC) {
	const section = /\[sections\.hotstrings\][\s\S]{0,300}?platforms\s*=\s*\[([^\]]*)\]/.exec(manifestSrc);
	const platforms = section ? section[1] : '';
	for (const p of ['ahk', 'hs', 'linux']) {
		if (!platforms.includes(`"${p}"`)) {
			errors.push(
				`[sections.hotstrings] does not list "${p}", so that driver's generated manifest ` +
					'carries no trigger_char entry and cannot read the shared default.'
			);
		}
	}
}

// ===== 2) No driver may spell a magic-key default out again =====

/** Production Lua/AHK sources of a driver (tests and generated code excluded). */
function driverSources(driver) {
	const out = [];
	const root = path.join(SP, driver);
	(function walk(d) {
		if (!fs.existsSync(d)) return;
		for (const e of fs.readdirSync(d, { withFileTypes: true })) {
			const p = path.join(d, e.name);
			if (e.isDirectory()) {
				if (e.name !== 'tests' && e.name !== '_generated' && e.name !== 'vendor') walk(p);
			} else if (/\.(lua|ahk)$/.test(e.name)) {
				out.push({ rel: path.relative(ROOT, p).split(path.sep).join('/'), src: fs.readFileSync(p, 'utf8') });
			}
		}
	})(root);
	return out;
}

// An assignment to a magic-key-shaped name with a STRING LITERAL on the right.
// Reading the manifest, a setting or another module is what this gate wants, so
// only literals are reported.
const HARDCODED = /(?:trigger_char|magic_key|MagicKey)\s*(?::?=)\s*"((?:[^"\\]|\\.)+)"/g;

// Deliberate literals, each with the reason it is not a second source of truth.
const ALLOWED = new Set([
	// The canonical character itself, as the shared engine's exported constant and
	// as the onboarding page's option list — those ARE the declaration's twins and
	// are locked to it by the value check below rather than by absence.
	'static/ergopti_plus/_shared/lua/hotstring_engine/init.lua',
]);

let scanned = 0;
for (const driver of ['windows', 'macos', 'linux']) {
	for (const { rel, src } of driverSources(driver)) {
		scanned += 1;
		if (ALLOWED.has(rel)) continue;
		HARDCODED.lastIndex = 0;
		let m;
		while ((m = HARDCODED.exec(src)) !== null) {
			const value = m[1];
			// A literal that MATCHES the canonical key is still a second copy, but a
			// harmless one today and often a test fixture inside production code; a
			// literal that DIFFERS is the live bug. Both are reported, worded apart,
			// because only the second one is currently costing a user anything.
			if (MAGIC && value === MAGIC) {
				errors.push(
					`${rel}: assigns the magic key as a literal "${value}". It agrees with the ` +
						'manifest today and nothing holds it there — read the declared default instead.'
				);
			} else {
				errors.push(
					`${rel}: assigns the magic key as "${value}" while the shared manifest declares ` +
						`"${MAGIC}". Every star trigger in the corpus ends with the declared one, so ` +
						'this driver listens for a key that expands nothing.'
				);
			}
		}
	}
}

if (scanned < 200) {
	errors.push(`walked only ${scanned} driver source file(s) — the scan is broken, not clean`);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] magic key is not single-sourced:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] magic key single-sourced — "${MAGIC}" declared once in the feature manifest, ` +
		`readable by all three drivers, no hardcoded copy across ${scanned} driver source file(s).\x1b[0m`
);
