// tools/test/test-shared-toml-codec-purity.cjs

/**
 * ==============================================================================
 * MODULE: Shared TOML Codec Purity Guard
 * DESCRIPTION:
 * Regression guard for audit SS-2. The shared TOML codec
 * (_shared/lua/toml_codec/*) is the single implementation meant to load on EVERY
 * Lua runtime — the macOS Hammerspoon driver, the Linux daemon, LuaJIT test
 * runners, and the Node/Lua build scripts. A hard `require("infra.logger")` /
 * `require("infra.i18n")` (macOS-driver-only packages) in reader.lua / writer.lua
 * silently broke that promise: those modules could not load off macOS, which is
 * why the Linux driver forked its own zero-dependency TOML parser
 * (linux/modules/hotstrings/loader.lua).
 *
 * The fix resolves Logger / i18n SOFTLY (pcall, preferring the real macOS logger
 * when present, else the platform-neutral logger.shim / a key-passthrough i18n).
 * This test fails if anyone reintroduces a hard, top-level require of a
 * driver-only module into the shared codec, so the impurity cannot come back.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const CODEC_DIR = path.join(ROOT, 'static/ergopti_plus/_shared/lua/toml_codec');
const FILES = ['reader.lua', 'writer.lua', 'codec.lua', 'init.lua'];

// A HARD require is the call form `require("infra.foo")` / `require('hs')`.
// The SOFT form `pcall(require, "infra.logger")` uses a comma, not parentheses
// around the string, so it is intentionally NOT matched here.
const HARD_REQUIRE = /require\(\s*["'](lib\.[\w.]+|hs(?:\.[\w.]+)?)["']\s*\)/g;

let failures = 0;
const pass = (m) => console.log(`  ✓ ${m}`);
const fail = (m) => { console.log(`  ✗ ${m}`); failures++; };

console.log('\n=== Shared TOML codec purity (audit SS-2) ===');

for (const f of FILES) {
	const p = path.join(CODEC_DIR, f);
	let src;
	try {
		src = fs.readFileSync(p, 'utf8');
	} catch (e) {
		fail(`${f}: unreadable (${e.message})`);
		continue;
	}
	// Strip Lua line comments (-- … EOL) first: the module docstrings legitimately
	// mention `require("infra.logger")` to explain the SS-2 fix, and that prose must
	// not trip the guard — only real code requires count.
	const code = src.replace(/--[^\n]*/g, '');
	const hits = code.match(HARD_REQUIRE);
	if (hits) {
		fail(`${f}: hard require of a driver-only module would break non-macOS loads: ${[...new Set(hits)].join(', ')}`);
	} else {
		pass(`${f}: no hard require of a driver-only module`);
	}
}

// reader.lua and writer.lua MUST keep the neutral fallback wired up, so the
// modules degrade to print()/key-passthrough off macOS instead of crashing.
for (const f of ['reader.lua', 'writer.lua']) {
	const src = fs.readFileSync(path.join(CODEC_DIR, f), 'utf8');
	if (src.includes('require("logger.shim")')) {
		pass(`${f}: keeps the logger.shim neutral fallback`);
	} else {
		fail(`${f}: must fall back to require("logger.shim") when lib.logger is absent`);
	}
}

console.log('');
if (failures > 0) {
	console.log(`❌  ${failures} shared-codec purity check(s) FAILED.`);
	process.exit(1);
}
console.log('✅  Shared TOML codec stays runtime-neutral (no hard driver requires).');
process.exit(0);
