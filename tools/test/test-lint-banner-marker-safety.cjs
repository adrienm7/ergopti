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
// The fixer must only see an owned miniature tree; a gate must never rewrite
// unrelated source files in the checkout it is validating.
const assert = require('node:assert/strict');
const os = require('node:os');
const FIXTURE_ROOT = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-banner-owner-'));
const FIXTURE_DIR = path.join(FIXTURE_ROOT, 'static/ergopti_plus/macos/infra');
const FIXTURE_PATH = path.join(FIXTURE_DIR, '_zzz_lint_banner_marker_safety_fixture.lua');
const FIXTURE_LINT = path.join(FIXTURE_ROOT, 'tools/lint/lint-conventions.js');

/** Runs the unchanged CLI against small, explicit language scan roots. */
function prepareLintFixture() {
	for (const relative of ['tools/lint/lint-conventions.js', 'tools/lib/paths.cjs']) {
		const target = path.join(FIXTURE_ROOT, relative);
		fs.mkdirSync(path.dirname(target), { recursive: true });
		fs.copyFileSync(path.join(REPO_ROOT, relative), target);
	}
	fs.writeFileSync(path.join(FIXTURE_ROOT, 'package.json'), '{"type":"module"}\n');
	for (const driver of ['macos', 'linux']) {
		for (const directory of ['adapters', 'infra', 'modules', 'ui', 'tests', 'platform']) {
			const target = path.join(
				FIXTURE_ROOT,
				'static/ergopti_plus',
				driver,
				directory,
				'fixture.lua'
			);
			fs.mkdirSync(path.dirname(target), { recursive: true });
			fs.writeFileSync(target, `-- ${directory}/fixture.lua\nreturn {}\n`);
		}
	}
	const shared = path.join(FIXTURE_ROOT, 'static/ergopti_plus/_shared');
	fs.mkdirSync(path.join(shared, 'lua'), { recursive: true });
	fs.writeFileSync(path.join(shared, 'lua/fixture.lua'), '-- lua/fixture.lua\nreturn {}\n');
	fs.writeFileSync(path.join(shared, 'fixture.toml'), 'enabled = true\n');
}

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
const FIXTURE_CONTENT = 'local M = {}\n\n\n\n\n' + buildAlignedBanner(TITLE) + '\n\nreturn M\n';

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
	assert.equal(
		path.relative(FIXTURE_ROOT, FIXTURE_LINT).replace(/\\/g, '/'),
		'tools/lint/lint-conventions.js',
		'the fixer executable belongs to the isolated tree'
	);
	return spawnSync(process.execPath, [FIXTURE_LINT, '--warn-only', ...extraArgs], {
		cwd: FIXTURE_ROOT,
		encoding: 'utf8'
	});
}

/** Verifies commit admission against both published release histories. */
function checkPublishedCommitBoundaries() {
	const assert = require('node:assert/strict');
	const os = require('node:os');
	const vm = require('node:vm');
	const { execFileSync, execSync } = require('node:child_process');
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-commit-scope-'));
	const owner = fs
		.readFileSync(LINT_SCRIPT, 'utf8')
		.match(/function checkNoCoAuthor\(\) \{[\s\S]*?\n\}/);
	assert(owner, 'the actual commit-admission owner must exist');
	const options = { cwd: fixture, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] };
	const git = (...args) => execFileSync('git', args, options).trim();
	const commit = (subject, forbidden = false) => {
		const message = path.join(fixture, 'message.txt');
		fs.writeFileSync(
			message,
			subject + (forbidden ? '\n\nCo-Authored-By: Fixture <fixture@example.invalid>\n' : '\n')
		);
		git('commit', '--allow-empty', '-F', message);
	};
	const check = (name, expected) => {
		const scope = { execSync, REPO_ROOT: fixture, totalViolations: 0, console: { warn() {} } };
		vm.runInNewContext(owner[0] + '\ncheckNoCoAuthor();', scope);
		test(
			name,
			scope.totalViolations === expected,
			`expected ${expected}, got ${scope.totalViolations}`
		);
	};
	try {
		git('init', '--initial-branch=main');
		git('config', 'user.name', 'Commit fixture');
		git('config', 'user.email', 'fixture@example.invalid');
		git('config', 'commit.gpgSign', 'false');
		git('config', 'core.hooksPath', path.join(fixture, 'empty-hooks'));
		commit('chore: establish published dev');
		git('update-ref', 'refs/remotes/origin/dev', 'HEAD');
		commit('chore: retain published main history', true);
		git('update-ref', 'refs/remotes/origin/main', 'HEAD');
		git('switch', '-c', 'topic');
		commit('fix: integrate both accepted histories');
		check('published main trailers do not require rewriting accepted history', 0);
		commit('fix: reject a new forbidden trailer', true);
		check('new topic trailers remain forbidden after release-branch integration', 1);
		git('update-ref', '-d', 'refs/remotes/origin/main');
		check('an unavailable main boundary does not exempt its commits', 2);
		git('update-ref', 'refs/remotes/origin/main', 'HEAD~2');
		git('update-ref', '-d', 'refs/remotes/origin/dev');
		check('a main-only checkout still checks unpublished topic commits', 1);
		git('update-ref', '-d', 'refs/remotes/origin/main');
		check('a checkout without release refs preserves the recent-history check', 2);
		git('update-ref', 'refs/remotes/origin/main', 'HEAD~2');
		git('update-ref', 'refs/remotes/origin/dev', 'HEAD~3');
		git('switch', '-c', 'unpublished-side', 'refs/remotes/origin/dev');
		commit('fix: reject an unpublished second-parent trailer', true);
		git('switch', 'topic');
		git('merge', '--no-ff', '--no-edit', 'unpublished-side');
		check('unpublished second-parent trailers are checked as well', 2);
	} finally {
		assert.equal(path.dirname(fixture), path.resolve(os.tmpdir()));
		assert(path.basename(fixture).startsWith('ergopti-commit-scope-'));
		fs.rmSync(fixture, { recursive: true, force: true });
	}
}

try {
	checkPublishedCommitBoundaries();
	prepareLintFixture();
	fs.writeFileSync(FIXTURE_PATH, FIXTURE_CONTENT, 'utf8');

	// 1) The checker must not flag an already-aligned "--"-marker banner.
	const checkResult = runLint([]);
	const fixtureRel = path.relative(FIXTURE_ROOT, FIXTURE_PATH).replace(/\\/g, '/');
	assert.equal(checkResult.status, 0, checkResult.stderr);
	assert.match(
		checkResult.stdout,
		/Lua files\s*:\s*14/,
		'every declared Lua scan root was exercised'
	);
	const flaggedThisFixture = (checkResult.stdout + checkResult.stderr)
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
	const fixed = runLint(['--fix-banners']);
	assert.equal(fixed.status, 0, fixed.stderr);
	const afterFix = fs.readFileSync(FIXTURE_PATH, 'utf8');
	test(
		'fix-banners leaves an aligned "--"-marker banner byte-identical',
		afterFix === FIXTURE_CONTENT,
		afterFix !== FIXTURE_CONTENT ? `expected unchanged content, got:\n${afterFix}` : undefined
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
		markersConsistent
			? undefined
			: `banner block:\n${lines.slice(titleIdx - 2, titleIdx + 3).join('\n')}`
	);
} finally {
	assert.equal(path.dirname(FIXTURE_ROOT), path.resolve(os.tmpdir()));
	assert.ok(path.basename(FIXTURE_ROOT).startsWith('ergopti-banner-owner-'));
	fs.rmSync(FIXTURE_ROOT, { recursive: true, force: true });
}

report();
