// scripts/test-lint-banner-marker-safety.cjs

/**
 * ==============================================================================
 * MODULE: Lint Banner-Marker Safety Regression Test
 * DESCRIPTION:
 * Regression test for a corruption bug in tools/lint/lint-conventions.js: the
 * banner checker/fixer computed each banner's "expected length" from a HARDCODED
 * prefix assumption (isAhk ? '; ' : '--- ') instead of the marker actually
 * captured on the title line. Lua section banners legitimately use either "--"
 * (the language's own comment marker — the dominant convention, e.g.
 * macos/infra/manifest_menu.lua) or "---" (the EmmyLua docstring marker). Against
 * a correctly-aligned "--"-marker banner, the hardcoded 4-char '--- ' assumption
 * was off by one character, so:
 *   1. checkBannerAlignment WARNed on an already-correct banner (false positive).
 *   2. fixBannersInFile then REWROTE the fill lines using the hardcoded "---"
 *      marker, turning an aligned "--"-marker banner into a broken one whose
 *      fill lines used a different marker (and length) than its own title line
 *      — i.e. "fixing" it made it worse, not better.
 *
 * This test proves the fix: a genuinely self-consistent "--"-marker banner must
 * survive both --warn-only (no false-positive warning) and --fix-banners
 * (byte-identical, no-op) untouched.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const LINT_SCRIPT = path.join(REPO_ROOT, 'tools/lint/lint-conventions.js');
// Placed inside the actual scanned tree (static/ergopti_plus/macos/infra/) so the
// CLI's hardcoded scan roots pick it up — lint-conventions.js has no directory
// override flag, so an isolated fixture directory would never be walked.
const FIXTURE_DIR = path.join(REPO_ROOT, 'static/ergopti_plus/macos/infra');
const FIXTURE_PATH = path.join(FIXTURE_DIR, '_zzz_lint_banner_marker_safety_fixture.lua');

/**
 * Builds a genuinely self-consistent 5-line major-section banner using the
 * Lua "--" (2-dash) comment marker — the dominant real-world convention (see
 * macos/infra/manifest_menu.lua sections 1-5).
 * @param {string} title
 * @returns {string} The 5-line banner block (2 fill, title, 2 fill), newline-joined.
 */
function buildAlignedBanner(title) {
	const eq = 7;
	const marker = '--';
	const prefix = `${marker} `;
	const bannerLen = eq + 1 + title.length + 1 + eq;
	const fill = prefix + '='.repeat(bannerLen);
	const titleLine = `${prefix}${'='.repeat(eq)} ${title} ${'='.repeat(eq)}`;
	return [fill, fill, titleLine, fill, fill].join('\n');
}

const TITLE = '1/ Lint Banner Marker Safety Fixture';
const FIXTURE_CONTENT =
	'local M = {}\n\n\n\n\n' + buildAlignedBanner(TITLE) + '\n\nreturn M\n';

let _pass = 0;
let _fail = 0;
const _results = [];

function test(name, ok, detail) {
	_pass += ok ? 1 : 0;
	_fail += ok ? 0 : 1;
	_results.push({ name, ok, detail });
}

function report() {
	const total = _pass + _fail;
	console.log('TAP version 14');
	console.log(`1..${total}`);
	let i = 1;
	for (const r of _results) {
		console.log(`${r.ok ? 'ok' : 'not ok'} ${i++} - ${r.name}`);
		if (!r.ok && r.detail) console.log(`  # ${r.detail}`);
	}
	console.log(`# passed: ${_pass}/${total}`);
	if (_fail > 0) {
		console.log(`# FAILED: ${_fail} test(s)`);
		process.exit(1);
	}
}

function runLint(extraArgs) {
	return spawnSync('node', [LINT_SCRIPT, '--warn-only', ...extraArgs], {
		cwd: REPO_ROOT,
		encoding: 'utf8',
	});
}

try {
	fs.writeFileSync(FIXTURE_PATH, FIXTURE_CONTENT, 'utf8');

	// 1) The checker must not flag an already-aligned "--"-marker banner.
	const checkResult = runLint([]);
	const fixtureRel = path
		.relative(REPO_ROOT, FIXTURE_PATH)
		.replace(/\\/g, '/');
	const flaggedThisFixture = checkResult.stdout
		.split('\n')
		.some((line) => line.includes(fixtureRel) && line.includes('Banner'));
	test(
		'checkBannerAlignment does not flag an aligned "--"-marker banner',
		!flaggedThisFixture,
		flaggedThisFixture
			? checkResult.stdout
					.split('\n')
					.filter((l) => l.includes(fixtureRel))
					.join('\n')
			: undefined
	);

	// 2) --fix-banners must be a byte-identical no-op on an already-aligned banner.
	runLint(['--fix-banners']);
	const afterFix = fs.readFileSync(FIXTURE_PATH, 'utf8');
	test(
		'fix-banners leaves an aligned "--"-marker banner byte-identical',
		afterFix === FIXTURE_CONTENT,
		afterFix !== FIXTURE_CONTENT
			? `expected unchanged content, got:\n${afterFix}`
			: undefined
	);

	// 3) Root-cause guard: every fill line touching the title must share its
	// marker. This is the exact invariant whose violation was the corruption
	// (fill lines rewritten with a "---" marker against a "--" title).
	const lines = afterFix.split('\n');
	const titleIdx = lines.findIndex((l) => l.includes(TITLE));
	const markersConsistent =
		titleIdx > 1 &&
		titleIdx + 2 < lines.length &&
		[lines[titleIdx - 2], lines[titleIdx - 1], lines[titleIdx + 1], lines[titleIdx + 2]].every(
			(l) => l.startsWith('-- =') && !l.startsWith('--- =')
		);
	test(
		'every fill line shares the title line\'s "--" marker (no "---" corruption)',
		markersConsistent,
		markersConsistent ? undefined : `banner block:\n${lines.slice(titleIdx - 2, titleIdx + 3).join('\n')}`
	);
} finally {
	fs.rmSync(FIXTURE_PATH, { force: true });
}

report();
