// tools/test/test-shared-test-format.cjs

/**
 * ==============================================================================
 * MODULE: Shared Test Format Single-Source Guard
 * DESCRIPTION:
 * `inspect()`, `deep_equal()`, and `caller_site()/fail_msg_for()` live exactly
 * once in `_shared/lua/test/format.lua`. Both the Linux and macOS test helpers
 * require that module — they must NOT define their own copies of these helpers.
 *
 * ROOT CAUSE ENCODED:
 * Before extraction (commits ab30b99, 6ee69ff3), `inspect()` (~40 lines) and
 * `deep_equal()` (~8 lines) were byte-identical across Linux and macOS
 * helpers. Every fix had to be applied twice. The `_caller_site()` wrappers
 * differed only in the skip_pattern, handled by `fail_msg_for()` accepting a
 * parameter. This guard fails if either driver re-introduces its own local
 * definition of `inspect`, `deep_equal`, `_caller_site`, or `_fail_msg`.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static/ergopti_plus/_shared');
const LINUX = path.join(ROOT, 'static/ergopti_plus/linux');
const MACOS = path.join(ROOT, 'static/ergopti_plus/macos');

function read(rel, base) {
	return fs.readFileSync(path.join(base, rel), 'utf8');
}

// Strip Lua line comments so an explanatory comment mentioning a function name
// is never mistaken for a live definition.
function stripLua(src) {
	return src
		.split(/\r?\n/)
		.map((line) => line.replace(/--.*$/, ''))
		.join('\n');
}

const errors = [];

// ── 1. Shared module exists and exports the three helpers ──────────────────
const formatSrc = read('lua/test/format.lua', SHARED);
if (!formatSrc.includes('M.inspect')) {
	errors.push('_shared/lua/test/format.lua: must export M.inspect');
}
if (!formatSrc.includes('M.deep_equal')) {
	errors.push('_shared/lua/test/format.lua: must export M.deep_equal');
}
if (!formatSrc.includes('fail_msg_for')) {
	errors.push('_shared/lua/test/format.lua: must export fail_msg_for(skip_pattern)');
}

// ── 2. Linux helpers must require, not define ──────────────────────────────
{
	const raw = read('tests/helpers.lua', LINUX);
	const code = stripLua(raw);

	// Must require the shared module
	if (!raw.includes('require("test.format")')) {
		errors.push('linux/tests/helpers.lua: must require("test.format")');
	}

	// Must re-export inspect and deep_equal (anchored, not substring match)
	if (!/M\.inspect\s*=\s*fmt\.inspect\b/.test(code)) {
		errors.push('linux/tests/helpers.lua: must set M.inspect = fmt.inspect');
	}
	if (!/M\.deep_equal\s*=\s*fmt\.deep_equal\b/.test(code)) {
		errors.push('linux/tests/helpers.lua: must set M.deep_equal = fmt.deep_equal');
	}

	// Must use fail_msg_for(), not define _caller_site locally
	if (!raw.includes('fail_msg_for')) {
		errors.push('linux/tests/helpers.lua: must use fail_msg_for() from format.lua');
	}

	// Must NOT contain a local inspect() definition
	if (/^function\s+M\.inspect\s*\(/m.test(code)) {
		errors.push('linux/tests/helpers.lua: must NOT define its own function M.inspect()');
	}

	// Must NOT contain a local deep_equal() definition
	if (/^function\s+M\.deep_equal\s*\(/m.test(code)) {
		errors.push('linux/tests/helpers.lua: must NOT define its own function M.deep_equal()');
	}

	// Must NOT contain a raw _caller_site definition
	if (/^local\s+function\s+_caller_site\s*\(/m.test(code)) {
		errors.push('linux/tests/helpers.lua: must NOT define its own _caller_site()');
	}
}

// ── 3. macOS helpers must require, not define ──────────────────────────────
{
	const raw = read('tests/helpers/init.lua', MACOS);
	const code = stripLua(raw);

	if (!raw.includes('require("test.format")')) {
		errors.push('macos/tests/helpers/init.lua: must require("test.format")');
	}

	if (!/M\.inspect\s*=\s*fmt\.inspect\b/.test(code)) {
		errors.push('macos/tests/helpers/init.lua: must set M.inspect = fmt.inspect');
	}
	if (!/M\.deep_equal\s*=\s*fmt\.deep_equal\b/.test(code)) {
		errors.push('macos/tests/helpers/init.lua: must set M.deep_equal = fmt.deep_equal');
	}

	if (!raw.includes('fail_msg_for')) {
		errors.push('macos/tests/helpers/init.lua: must use fail_msg_for() from format.lua');
	}

	if (/^function\s+M\.inspect\s*\(/m.test(code)) {
		errors.push('macos/tests/helpers/init.lua: must NOT define its own function M.inspect()');
	}

	if (/^function\s+M\.deep_equal\s*\(/m.test(code)) {
		errors.push('macos/tests/helpers/init.lua: must NOT define its own function M.deep_equal()');
	}

	if (/^local\s+function\s+_caller_site\s*\(/m.test(code)) {
		errors.push('macos/tests/helpers/init.lua: must NOT define its own _caller_site()');
	}
}

// ── 4. Ratchet: both assert_eq implementations must use inspect, not tostring ─
// The old assert_eq used tostring() which produces opaque pointers like
// "table: 0x1a2b3c". The new one uses M.inspect() for readable values.
for (const [driver, f] of [['linux', 'tests/helpers.lua'], ['macos', 'tests/helpers/init.lua']]) {
	const base = driver === 'linux' ? LINUX : MACOS;
	const code = read(f, base);
	// assert_eq must call M.inspect for debug output, not raw tostring
	const fnBody = code.match(/function\s+M\.assert_eq[^}]+end/ms);
	if (fnBody && fnBody[0].includes('M.inspect(')) {
		// Good: uses inspect for pretty-printing
	} else if (fnBody && fnBody[0].includes('tostring(')) {
		errors.push(`${driver}/${f}: assert_eq must use M.inspect(), not raw tostring()`);
	}
}

// ---- 5. Banner alignment in _shared/lua/test/format.lua ----
// ROOT CAUSE: the five major-section banners carried a right-hand "=" run that
// did not equal the mandated 7 (e.g. "======= 1/ inspect() ==============" had
// 14 on the right), and every border row above/below a title was a fixed 35
// "=" wide instead of matching the title line's own length. Nothing caught it
// because lint-conventions.js scans macos/ only, never _shared/lua/. This guard
// fails on any unbalanced (leftEq != rightEq) or wrong-length border banner.
{
	const bannerLines = formatSrc.replace(/^﻿/, '').replace(/\r\n/g, '\n').split('\n');
	const TITLE_RE = /^(;|---?) (=+) (.+?) (=+)$/;
	const BORDER_RE = /^(;|---?) (=+)$/;
	bannerLines.forEach((line, i) => {
		const m = line.match(TITLE_RE);
		if (!m) return;
		const marker = m[1];
		const prefix = marker + ' ';
		const leftEq = m[2].length;
		const title = m[3];
		const rightEq = m[4].length;
		const loc = `_shared/lua/test/format.lua:${i + 1}`;
		if (leftEq !== rightEq) {
			errors.push(`${loc}: banner "${title}" is unbalanced (${leftEq} left vs ${rightEq} right) — both sides must be 7`);
			return;
		}
		const expectedLen = prefix.length + leftEq + 1 + title.length + 1 + rightEq;
		for (const adj of [i - 1, i + 1]) {
			if (adj < 0 || adj >= bannerLines.length) continue;
			const bm = bannerLines[adj].match(BORDER_RE);
			if (!bm || bm[1] !== marker) continue;
			if (bannerLines[adj].length !== expectedLen) {
				errors.push(`${loc}: border row (line ${adj + 1}) length ${bannerLines[adj].length} != title-line length ${expectedLen} for "${title}"`);
			}
		}
	});
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] test.format is not single-sourced in _shared/lua/test/format.lua:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] test.format single-sourced — _shared/lua/test/format.lua (inspect, deep_equal, fail_msg_for) consumed by Linux + macOS helpers; no local definitions.\x1b[0m'
);
