// tools/test/verify-change.cjs

/**
 * ==============================================================================
 * MODULE: Change-Scoped Verification Gate
 * DESCRIPTION:
 * Looks at what actually changed in the working tree (or in a commit range) and
 * runs exactly the gates that can catch a regression in those files, instead of
 * leaving the choice to whoever is in a hurry.
 *
 * FEATURES & RATIONALE:
 * 1. The AHK runner and the JS gate cover DISJOINT ground. A fully green
 *    3380/3380 AHK suite shipped a broken cross-driver port map, because port
 *    compliance lives in the JS gate and the AHK runner knows nothing about it.
 *    Mapping file -> gate is what removes that guesswork.
 * 2. Two static pre-checks run first because they are instant and because the
 *    failures they catch are SILENT: an unregistered test file never runs, and a
 *    source-scanning test that names a function which does not exist asserts
 *    nothing while still reporting "ok".
 * 3. Advisory by default about scope, strict about outcome: it prints the plan
 *    it derived, then exits non-zero if any selected gate fails.
 * ==============================================================================
 */

'use strict';

const { execFileSync, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { validateAhkSuiteManifest } = require('./validate-ahk-suite-manifest.cjs');
const { validateAhkE2eManifest } = require('./validate-ahk-e2e-manifest.cjs');
const { includeClosure } = require('./test-ahk-test-coverage.cjs');
const { PRETTIER_EXTENSIONS } = require('../lint/format.cjs');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const WINDOWS_TESTS = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'windows', 'tests');
const RUN_ALL = path.join(WINDOWS_TESTS, 'run_all.ahk');

// Candidate install locations for the AHK v2 interpreter, in preference order.
// Absent on CI and on non-Windows checkouts, where the AHK gates are skipped
// rather than failed — a missing interpreter is not a regression.
const AHK_CANDIDATES = [
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe',
	'C:\\Program Files\\AutoHotkey\\AutoHotkey64.exe',
	'C:\\Program Files (x86)\\AutoHotkey\\v2\\AutoHotkey64.exe'
];

// ==================================================
// ==================================================
// ======= 1/ Discovering the changed files =========
// ==================================================
// ==================================================

/**
 * Returns the repo-relative paths this run should reason about.
 * With no argument: everything uncommitted (staged, unstaged and untracked).
 * With a range like "origin/dev..HEAD": every file that range touches.
 * @param {string|null} range - Optional git range.
 * @param {string} repoRoot - Checkout root, injectable for isolated fixtures.
 * @returns {string[]} Repo-relative POSIX-style paths.
 */
function changedFiles(range, repoRoot = REPO_ROOT) {
	// Disabling rename detection in a diff retains the removed driver's path
	// as well as the destination. Porcelain status reports both as NUL records.
	const args = range
		? ['diff', '--name-only', '--no-renames', '-z', '--end-of-options', range, '--']
		: ['status', '--porcelain=v1', '-z', '--untracked-files=all'];
	const out = execFileSync('git', args, {
		cwd: repoRoot,
		encoding: 'utf8',
		stdio: ['ignore', 'pipe', 'pipe']
	});
	return parseChangedPaths(out, !range);
}

/**
 * Decodes Git's machine format without trimming or unquoting real filenames.
 * @param {string} output - NUL-delimited Git output.
 * @param {boolean} status - Whether records contain porcelain status fields.
 * @returns {string[]} Exact repo-relative paths, including both rename endpoints.
 */
function parseChangedPaths(output, status) {
	if (output === '') return [];
	if (!output.endsWith('\0'))
		throw new Error('Git changed-path stream is missing its terminal NUL');
	const records = output.slice(0, -1).split('\0');
	const files = [];
	for (let index = 0; index < records.length; index += 1) {
		const record = records[index];
		if (!record) throw new Error('Git changed-path stream contains an empty path');
		if (!status) {
			files.push(record);
			continue;
		}
		if (record.length <= 3 || !/^[ MADRCU?!T]{2} /.test(record))
			throw new Error('Git status record is missing its status or path');
		files.push(record.slice(3));
		if (/[RC]/.test(record.slice(0, 2))) {
			const original = records[++index];
			if (!original) throw new Error('Git rename/copy record is missing its original path');
			files.push(original);
		}
	}
	return [...new Set(files)];
}

// ==================================================
// ==================================================
// ======= 2/ Silent-failure pre-checks =============
// ==================================================
// ==================================================

/**
 * A test file that run_all.ahk does not #Include never executes, so the suite
 * reports a pass that proves nothing about the fix it was written for.
 * @param {string[]} files - Changed repo-relative paths.
 * @param {string} repoRoot - Checkout root, injectable for isolated fixtures.
 * @returns {string[]} Human-readable problems.
 */
function checkTestsAreRegistered(files, repoRoot = REPO_ROOT) {
	const runner = path.join(repoRoot, 'static/ergopti_plus/windows/tests/run_all.ahk');
	if (!fs.existsSync(runner)) return [];
	const reachable = new Set([...includeClosure(runner)].map((file) => file.toLowerCase()));
	const problems = [];
	for (const f of files) {
		const m = f.match(/^static\/ergopti_plus\/windows\/tests\/((?:meta|unit|startup)\/.+\.ahk)$/i);
		if (!m) continue;
		const absolute = path.resolve(repoRoot, f).replace(/\\/g, '/');
		if (!fs.existsSync(absolute)) continue;
		if (!reachable.has(absolute.toLowerCase())) {
			problems.push(
				`${f} is not #Include'd by tests/run_all.ahk — it will never run, and the suite will pass without it`
			);
		}
	}
	return problems;
}

/**
 * Finds a braced AHK function definition without assuming that its parameter
 * list fits on one line. The scanner deliberately balances nested parentheses
 * and ignores strings/comments: defaults such as `Map("key", Value())` must not
 * truncate the signature, while a column-zero call site must not count as a
 * definition.
 * @param {string} source - One or more AHK source files.
 * @param {string} name - Exact function name to find.
 * @returns {boolean} Whether a matching definition exists.
 */
function hasAhkFunctionDefinition(source, name) {
	const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const candidates = source.matchAll(new RegExp(`^[ \\t]*${escapedName}[ \\t]*\\(`, 'gm'));

	for (const candidate of candidates) {
		let lexicalIndex = 0;
		let candidateStringQuote = '';
		let candidateInLineComment = false;
		let candidateInBlockComment = false;
		while (lexicalIndex < candidate.index) {
			const char = source[lexicalIndex];
			const next = source[lexicalIndex + 1] || '';
			if (candidateInLineComment) {
				if (char === '\n') candidateInLineComment = false;
			} else if (candidateInBlockComment) {
				if (char === '*' && next === '/') {
					candidateInBlockComment = false;
					lexicalIndex += 1;
				}
			} else if (candidateStringQuote) {
				if (char === '`') lexicalIndex += 1;
				else if (char === candidateStringQuote) candidateStringQuote = '';
			} else if (char === ';') candidateInLineComment = true;
			else if (char === '/' && next === '*') {
				candidateInBlockComment = true;
				lexicalIndex += 1;
			} else if (char === '"' || char === "'") candidateStringQuote = char;
			lexicalIndex += 1;
		}
		if (candidateStringQuote || candidateInLineComment || candidateInBlockComment) continue;

		let index = candidate.index + candidate[0].lastIndexOf('(');
		let depth = 0;
		let stringQuote = '';
		let inLineComment = false;
		let inBlockComment = false;
		let closedAt = -1;

		for (; index < source.length; index += 1) {
			const char = source[index];
			const next = source[index + 1] || '';

			if (inLineComment) {
				if (char === '\n') inLineComment = false;
				continue;
			}
			if (inBlockComment) {
				if (char === '*' && next === '/') {
					inBlockComment = false;
					index += 1;
				}
				continue;
			}
			if (stringQuote) {
				if (char === '`') {
					index += 1;
					continue;
				}
				if (char === stringQuote) stringQuote = '';
				continue;
			}

			if (char === ';') {
				inLineComment = true;
				continue;
			}
			if (char === '/' && next === '*') {
				inBlockComment = true;
				index += 1;
				continue;
			}
			if (char === '"' || char === "'") {
				stringQuote = char;
				continue;
			}
			if (char === '(') depth += 1;
			else if (char === ')') {
				depth -= 1;
				if (depth === 0) {
					closedAt = index;
					break;
				}
			}
		}

		if (closedAt < 0) continue;
		index = closedAt + 1;
		while (index < source.length) {
			if (/\s/.test(source[index])) {
				index += 1;
				continue;
			}
			if (source[index] === ';') {
				const newline = source.indexOf('\n', index + 1);
				index = newline < 0 ? source.length : newline + 1;
				continue;
			}
			if (source[index] === '/' && source[index + 1] === '*') {
				const end = source.indexOf('*/', index + 2);
				index = end < 0 ? source.length : end + 2;
				continue;
			}
			break;
		}
		if (source[index] === '{') return true;
	}

	return false;
}

/**
 * _DriverFuncBody returns "" for a name it cannot find, which makes every
 * ABSENCE assertion built on it pass vacuously. AHK v2 makes this worse: a call
 * to a function that does not exist is not a load-time error, so a typo or a
 * half-finished rename produces a green test and no diagnostic anywhere.
 * @param {string[]} files - Changed repo-relative paths.
 * @returns {string[]} Human-readable problems.
 */
function checkScannedSymbolsExist(files) {
	const testFiles = files.filter(
		(f) =>
			/static\/ergopti_plus\/windows\/tests\/.*\.ahk$/.test(f) &&
			fs.existsSync(path.join(REPO_ROOT, f))
	);
	if (testFiles.length === 0) return [];

	const driverRoot = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'windows');
	let driverSource = '';
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, entry.name);
			const posix = p.replace(/\\/g, '/');
			if (posix.includes('/tests/') || posix.includes('/vendor/') || posix.includes('/_generated/'))
				continue;
			if (entry.isDirectory()) walk(p);
			else if (entry.name.endsWith('.ahk')) driverSource += '\n' + fs.readFileSync(p, 'utf8');
		}
	};
	walk(driverRoot);

	const problems = [];
	for (const f of testFiles) {
		const src = fs.readFileSync(path.join(REPO_ROOT, f), 'utf8');
		for (const m of src.matchAll(/_DriverFuncBody\(\s*"([A-Za-z_][\w]*)"\s*\)/g)) {
			const name = m[1];
			// Match the same definition grammar as _DriverFuncBody, including
			// multiline signatures and nested default expressions.
			const defined = hasAhkFunctionDefinition(driverSource, name);
			if (!defined) {
				problems.push(
					`${f} scans _DriverFuncBody("${name}") but no such function is defined in the driver — the body comes back empty and every absence assertion on it passes vacuously`
				);
			}
		}
	}
	return problems;
}

// ==================================================
// ==================================================
// ======= 3/ Mapping a change to its gates =========
// ==================================================
// ==================================================

/**
 * True for the two `_shared/` sub-trees ADR-006 declares binding on EVERY
 * driver: `core/` holds the port contracts, `tests/` holds the cross-driver
 * corpora the three suites replay. Editing either changes what all three
 * drivers are measured against, so all three suites have to run.
 *
 * Without this, the one file class the architecture calls mandatory everywhere
 * was the only one whose edit selected no driver suite at all — a corpus vector
 * could be changed and land fully "verified" having executed nothing.
 *
 * The layer data belongs here for the same reason: `_shared/keymap/` and the
 * physical-key registry are read by the AHK and Lua layer loaders and replayed
 * by every driver's corpus consumer, and no JS gate runs those loaders.
 * @param {string} f Repo-relative path.
 * @returns {boolean} Whether the path is a cross-driver contract.
 */
function isCrossDriverContract(f) {
	return (
		f.startsWith('static/ergopti_plus/_shared/core/') ||
		f.startsWith('static/ergopti_plus/_shared/tests/') ||
		f.startsWith('static/ergopti_plus/_shared/keymap/') ||
		f === 'static/ergopti_plus/_shared/data/keycodes/physical_keys.json'
	);
}

/**
 * Identifies runtime Lua shared by the macOS and Linux drivers.
 * @param {string} f Repo-relative path, including deleted sources.
 * @returns {boolean} Whether both Lua consumers require verification.
 */
function isSharedLuaSource(f) {
	return f.startsWith('static/ergopti_plus/_shared/lua/') && f.endsWith('.lua');
}

/**
 * Performance audit prose is historical evidence, not a runtime contract.
 * Driver docs, audit manifests, skills and routed memory stay on their existing gates.
 * @param {string} f Repo-relative path.
 * @returns {boolean} Whether only report conventions apply.
 */
function isPerformanceReport(f) {
	return f.startsWith('docs/audits/performance/') && f.endsWith('.md');
}

/**
 * Every rule states WHY the gate is required, because the non-obvious pairings
 * are the whole point of this file.
 */
/** Identifies portable AHK policy parsed and executed by the Windows driver. */
function isSharedAhkSource(f) {
	return f.startsWith('static/ergopti_plus/_shared/') && f.endsWith('.ahk');
}

const RULES = [
	{
		gate: 'format',
		why: 'CI checks actual Prettier/Ruff formatting before suites; formatter self-tests do not validate source files',
		match: (f) => PRETTIER_EXTENSIONS.has(path.extname(f)) || f.endsWith('.py')
	},
	{
		gate: 'ahk-encoding',
		why: 'every .ahk must stay UTF-8 BOM + LF; a stray CRLF or a lost BOM breaks the parser in ways that are hard to read',
		match: (f) => f.endsWith('.ahk')
	},
	{
		gate: 'ahk-suite',
		why: 'the AHK unit + meta suite covers the Windows driver — and replays the shared corpora and port contracts',
		match: (f) =>
			(f.startsWith('static/ergopti_plus/windows/') && f.endsWith('.ahk')) ||
			isSharedAhkSource(f) ||
			isCrossDriverContract(f)
	},
	{
		gate: 'ahk-parse',
		// run_all.ahk deliberately excludes the production files that register
		// hotkeys or build menus at top level, so a syntax error in one of them
		// was caught only by the CI compile job. The AHK suite's brace-balance
		// meta test catches the subset that happens to unbalance a brace, and
		// nothing at all catches the rest.
		why: 'a compile parses the WHOLE #Include graph, including the files run_all.ahk cannot include',
		match: (f) =>
			((f.startsWith('static/ergopti_plus/windows/') && f.endsWith('.ahk')) ||
				isSharedAhkSource(f)) &&
			!f.includes('/tests/')
	},
	{
		gate: 'ahk-e2e',
		why: 'driver behaviour changed, and the e2e runner exercises the expansion pipeline end to end',
		match: (f) =>
			((f.startsWith('static/ergopti_plus/windows/') && f.endsWith('.ahk')) ||
				isSharedAhkSource(f)) &&
			!f.includes('/tests/')
	},
	{
		gate: 'report-style',
		why: 'historical performance reports require conventions; driver-doc path guards do not inspect this archive',
		match: isPerformanceReport
	},
	{
		gate: 'js',
		why: 'port compliance, single-source, parity and document-consumer checks live here; doc-paths rejects obsolete roots in driver docs only',
		match: (f) =>
			!isPerformanceReport(f) &&
			(f === '.github/workflows/ci-macos.yml' ||
				f.includes('/adapters/') ||
				f.includes('_shared/') ||
				f.startsWith('static/ergopti_plus/macos/launcher/') ||
				// A .keylayout edit alone changes the registry checksums the drivers verify.
				f.startsWith('static/layouts/registry/') ||
				f.startsWith('tools/') ||
				f.includes('/locales/') ||
				f.endsWith('.json') ||
				f.endsWith('.toml') ||
				f.endsWith('.js') ||
				f.endsWith('.cjs') ||
				f.endsWith('.svelte') ||
				f.endsWith('.md'))
	},
	{
		gate: 'macos-tooltip-canvas',
		why: 'native canvas diagnostic ownership and independent observer controls require their complete pure Python suite',
		match: (f) =>
			f.startsWith('tools/diagnostics/macos_tooltip_canvas') ||
			f === 'tools/diagnostics/macos_owned_process.py' ||
			f === 'tools/test/run-macos-tooltip-canvas-tests.cjs'
	},
	{
		gate: 'xkb-python',
		// The shipped XKB files, the Linux installers and every registry layout's
		// conversion are checked by Python suites no JS or Lua gate runs.
		why: 'the .keylayout to XKB converter, the Linux installers, the layout registry or the shared keycode table changed',
		match: (f) =>
			f.startsWith('static/ergopti/linux/') ||
			f.startsWith('static/layouts/registry/') ||
			f.startsWith('static/ergopti_plus/_shared/modules/layouts/')
	},
	{
		gate: 'swift-launcher',
		why: 'native launcher code must compile and its process-level XCTest must run on macOS; other hosts report the CI deferral explicitly',
		match: (f) => f.startsWith('static/ergopti_plus/macos/launcher/')
	},
	{
		gate: 'hs-e2e',
		// The driver-local branch mirrors ahk-e2e. Its absence is how a keymap
		// change shipped that left the macOS e2e harness red while the unit suite
		// stayed fully green: the two tiers are disjoint, and only CI ran the
		// second one. Excluding tests/ mirrors ahk-e2e — editing the harness
		// itself does not need a behaviour re-run.
		why: 'driver behaviour changed, and the e2e runner exercises the expansion pipeline end to end',
		match: (f) =>
			isSharedLuaSource(f) ||
			(f.startsWith('static/ergopti_plus/macos/') && f.endsWith('.lua') && !f.includes('/tests/'))
	},
	{
		gate: 'hs',
		why: 'the macOS driver, its shared Lua runtime, or a shared corpus/port contract changed',
		// Markdown under a driver tree is documentation, not driver code: it cannot
		// break a Lua suite, and running one for a README edit trains people to
		// ignore the tool's answer.
		match: (f) =>
			(f.startsWith('static/ergopti_plus/macos/') && !f.endsWith('.md')) ||
			isCrossDriverContract(f) ||
			isSharedLuaSource(f)
	},
	{
		gate: 'linux-e2e',
		// Found by tools/test/test-e2e-gate-symmetry.cjs, not by a bug report: the
		// Linux driver ships tests/e2e/run_e2e.lua and a CI job for it, and had the
		// same missing rule macOS did. Widening the guard to the whole class is
		// what surfaced it.
		why: 'driver behaviour changed, and the e2e runner exercises the expansion pipeline end to end',
		match: (f) =>
			isSharedLuaSource(f) ||
			(f.startsWith('static/ergopti_plus/linux/') && f.endsWith('.lua') && !f.includes('/tests/'))
	},
	{
		gate: 'linux-xkb-source',
		why: 'physical contextual shortcuts require actual X11 group/keymap receipts; the owned native fixture also guards honest Wayland refusal',
		match: (f) =>
			[
				'static/ergopti_plus/linux/adapters/xkb_capture.lua',
				'static/ergopti_plus/linux/adapters/xkb_source_probe.lua',
				'static/ergopti_plus/linux/adapters/keyboard_hook.lua',
				'static/ergopti_plus/linux/modules/hotstrings/device_finder.lua',
				'static/ergopti_plus/linux/modules/hotstrings/magic_key_source.lua',
				'static/ergopti_plus/linux/modules/shortcuts/keyboard_shortcuts.lua',
				'static/ergopti_plus/linux/ergopti_hotstrings.lua',
				'static/ergopti_plus/linux/tests/hardware/run_xkb_source_qualification.lua',
				'static/ergopti_plus/_shared/lua/shortcuts/magic_editor.lua',
				'tools/test/run-linux-xkb-source.cjs',
				'.github/workflows/ci-linux.yml'
			].includes(f) || f.startsWith('static/ergopti_plus/_shared/modules/layouts/')
	},
	{
		gate: 'linux-window-switch',
		why: 'scoped window switching requires actual owned X11/RandR, input-focus, source-fence and cleanup receipts through the real dispatcher',
		match: (f) =>
			[
				'static/ergopti_plus/linux/adapters/window_switch.lua',
				'static/ergopti_plus/linux/platform/window_switch_worker.lua',
				'static/ergopti_plus/linux/adapters/program_runner.lua',
				'static/ergopti_plus/linux/infra/libuv_process_group.lua',
				'static/ergopti_plus/linux/infra/libuv_exit.lua',
				'static/ergopti_plus/linux/modules/gestures/manager.lua',
				'static/ergopti_plus/linux/ergopti_hotstrings.lua',
				'static/ergopti_plus/_shared/lua/native_worker_owner.lua',
				'static/ergopti_plus/_shared/lua/cursor_window_policy.lua',
				'static/ergopti_plus/_shared/modules/actions/actions.toml',
				'static/ergopti_plus/linux/_generated/action_catalogue.lua',
				'static/ergopti_plus/linux/_generated/action_emit.lua',
				'static/ergopti_plus/linux/tests/hardware/run_window_switch_receipts.py',
				'static/ergopti_plus/linux/tests/hardware/run_window_switch_operation.lua',
				'tools/test/run-linux-window-switch-receipts.cjs',
				'.github/workflows/ci-linux.yml',
				'.github/linux-ci-coverage.json',
				'static/ergopti_plus/linux/tests/hardware/native_fixture_family.py',
				'static/ergopti_plus/linux/tests/hardware/run_native_fixture_family_receipts.py'
			].includes(f)
	},
	{
		gate: 'linux-http-stream',
		why: 'streaming HTTP receipts require actual libuv/curl status, complete error bodies and native owner settlement',
		match: (f) =>
			[
				'static/ergopti_plus/_shared/lua/network/proxy_policy.lua',
				'static/ergopti_plus/_shared/modules/network/proxy_policy.json',
				'static/ergopti_plus/linux/adapters/curl_http_client.lua',
				'static/ergopti_plus/linux/adapters/system_proxy.lua',
				'static/ergopti_plus/linux/infra/curl_identity.lua',
				'static/ergopti_plus/linux/infra/http_body_pipe.lua',
				'static/ergopti_plus/linux/infra/managed_http.lua',
				'static/ergopti_plus/linux/infra/managed_http_deadline.lua',
				'static/ergopti_plus/linux/infra/native_timer.lua',
				'static/ergopti_plus/linux/infra/proxy_policy.lua',
				'static/ergopti_plus/linux/platform/network/system_proxy_probe.lua',
				'static/ergopti_plus/linux/platform/network/native_proxy_runtime.lua',
				'static/ergopti_plus/linux/_generated/native_runtime.lua',
				'static/ergopti_plus/linux/adapters/http_client.lua',
				'static/ergopti_plus/linux/modules/llm/api_ollama.lua',
				'static/ergopti_plus/linux/modules/llm/local_model_probe.lua',
				'static/ergopti_plus/linux/modules/llm/local_model_offer.lua',
				'static/ergopti_plus/linux/tests/unit/meta/test_http_client_curl.lua',
				'static/ergopti_plus/linux/tests/hardware/run_http_stream_receipts.lua',
				'static/ergopti_plus/linux/tests/hardware/run_local_api_auth.lua',
				'static/ergopti_plus/linux/modules/llm/api_remote.lua',
				'static/ergopti_plus/linux/modules/llm/api_entries.lua',
				'static/ergopti_plus/linux/modules/llm/local_server_catalogue.lua',
				'static/ergopti_plus/_shared/lua/llm/local_server_auth.lua',
				'static/ergopti_plus/_shared/modules/llm/local_servers.json',
				'static/ergopti_plus/_shared/lua/llm/local_model_policy.lua',
				'tools/test/run-linux-http-stream-receipts.cjs',
				'.github/workflows/ci-linux.yml',
				'.github/linux-ci-coverage.json'
			].includes(f)
	},
	{
		gate: 'linux-updater-temp-native',
		why: 'actual temporary updater ownership and allocation require the compiled helper and both original native ABI fixtures',
		match: (f) =>
			[
				'tools/test/run-linux-updater-temp-native.cjs',
				'tools/test/prepare-linux-lua54-native-provider.cjs',
				'tools/test/fixtures/lua54-provider-entry.c',
				'tools/test/test-linux-updater-temp-native.cjs',
				'tools/test/test-linux-updater-temp-registration.cjs',
				'tools/test/prepare-linux-updater-archive-snapshot.py',
				'tools/test/run-linux-managed-http-native.cjs',
				'tools/test/run-linux-managed-http-phase.py',
				'tools/test/run-linux-updater-archive-native.cjs',
				'tools/build/stage-linux-network-runtime.py',
				'tools/build/build-linux-native-output.sh',
				'tools/lib/git-bash.cjs',
				'tools/lib/git_bash.py',
				'tools/__init__.py',
				'static/ergopti_plus/linux/infra/managed_http_deadline.lua',
				'static/ergopti_plus/linux/infra/native_timer.lua',
				'static/ergopti_plus/linux/infra/monotonic.lua',
				'static/ergopti_plus/linux/infra/paths.lua',
				'static/ergopti_plus/linux/tests/hardware/run_native_artifact_cleanup_retry.py',
				'static/ergopti_plus/linux/tests/hardware/run_native_artifact_capture_completion.c',
				'static/ergopti_plus/linux/tests/hardware/run_openssl_byte_input_native.lua',
				'static/ergopti_plus/linux/infra/openssl_digest.lua',
				'static/ergopti_plus/linux/tests/hardware/run_updater_temp_ownership_receipts.py',
				'static/ergopti_plus/linux/tests/hardware/run_updater_temp_allocation_receipts.py',
				'static/ergopti_plus/linux/modules/updater/manager.lua',
				'static/ergopti_plus/linux/modules/updater/archive_transfer.lua',
				'static/ergopti_plus/linux/infra/archive_output.lua',
				'static/ergopti_plus/linux/infra/fd_sha256.lua',
				'static/ergopti_plus/linux/modules/shortcuts/script_actions.lua',
				'static/ergopti_plus/linux/infra/http_output_target.lua',
				'static/ergopti_plus/linux/adapters/curl_http_client.lua',
				'static/ergopti_plus/linux/adapters/http_client.lua',
				'static/ergopti_plus/linux/infra/managed_http.lua',
				'static/ergopti_plus/linux/native/archive_output/archive_publication.c',
				'static/ergopti_plus/linux/native/archive_output/archive_publication.h',
				'static/ergopti_plus/_shared/lua/updater/transfer_budget.lua',
				'static/ergopti_plus/_shared/modules/updater/defaults.json',
				'static/ergopti_plus/_shared/data/linux_native_runtime.json',
				'.github/workflows/ci-linux.yml',
				'.github/linux-ci-coverage.json'
			].includes(f)
	},
	{
		gate: 'linux-updater-archive-native',
		why: 'actual installed updater archive requires checksum, retained FD digest, tar, installation and physical cleanup',
		match: (f) =>
			[
				'tools/test/run-linux-updater-archive-native.cjs',
				'tools/test/prepare-linux-updater-archive-snapshot.py',
				'tools/test/run-linux-managed-http-native.cjs',
				'tools/test/run-linux-managed-http-phase.py',
				'tools/test/linux-updater-archive-evidence.cjs',
				'tools/test/test-linux-updater-archive-receipt.cjs',
				'tools/test/test-linux-updater-archive-registration.cjs',
				'tools/build/build-linux-driver.sh',
				'tools/build/build-linux-native-output.sh',
				'tools/build/stage-linux-network-runtime.py',
				'tools/lib/git_bash.py',
				'tools/__init__.py',
				'static/ergopti_plus/linux/tests/hardware/run_updater_archive_pipeline.py',
				'static/ergopti_plus/linux/tests/hardware/run_updater_archive_pipeline.lua',
				'static/ergopti_plus/linux/tests/hardware/run_native_subreaper.py',
				'static/ergopti_plus/linux/modules/updater/manager.lua',
				'static/ergopti_plus/linux/modules/updater/archive_transfer.lua',
				'static/ergopti_plus/linux/modules/updater/installer.lua',
				'static/ergopti_plus/linux/infra/archive_output.lua',
				'static/ergopti_plus/linux/infra/fd_sha256.lua',
				'static/ergopti_plus/linux/infra/http_output_target.lua',
				'static/ergopti_plus/linux/adapters/curl_http_client.lua',
				'static/ergopti_plus/linux/adapters/http_client.lua',
				'static/ergopti_plus/linux/infra/managed_http.lua',
				'static/ergopti_plus/linux/native/archive_output/archive_publication.c',
				'static/ergopti_plus/linux/native/archive_output/archive_publication.h',
				'static/ergopti_plus/linux/install.sh',
				'static/ergopti_plus/linux/install/ownership.sh',
				'static/ergopti_plus/linux/install/standalone_launcher.sh',
				'static/ergopti_plus/_shared/data/linux_native_runtime.json',
				'static/ergopti_plus/_shared/modules/updater/defaults.json',
				'static/ergopti_plus/_shared/lua/updater/transfer_budget.lua',
				'.github/workflows/ci-linux.yml',
				'.github/linux-ci-coverage.json'
			].includes(f)
	},
	{
		gate: 'linux-archive-source-controls',
		why: 'crypto metadata, bin parent, private Git snapshot and modeled CONNECT guards require their independent controls',
		match: (f) =>
			[
				'tools/test/run-linux-archive-source-controls.cjs',
				'tools/test/test-linux-updater-archive-snapshot.py',
				'tools/test/prepare-linux-updater-archive-snapshot.py',
				'tools/test/fixtures/linux-connect-terminal-protocol.py',
				'static/ergopti_plus/linux/tests/hardware/run_managed_http_native.py',
				'tools/test/fixtures/linux-explicit-crypto-staging.py',
				'tools/test/fixtures/linux-native-bin-parents.py',
				'tools/test/linux-updater-archive-evidence.cjs',
				'tools/test/test-linux-updater-archive-registration.cjs',
				'tools/test/run-linux-managed-http-native.cjs',
				'tools/test/run-linux-managed-http-phase.py',
				'tools/build/stage-linux-network-runtime.py',
				'static/ergopti_plus/linux/install.sh',
				'static/ergopti_plus/_shared/data/linux_native_runtime.json',
				'tools/codegen/codegen-linux-native-runtime.cjs',
				'.github/workflows/ci-linux.yml',
				'.github/linux-ci-coverage.json'
			].includes(f)
	},
	{
		gate: 'linux-managed-http-native',
		why: 'managed HTTP requires actual retained output, per-hop GIO/curl routing and original sole-owner cleanup receipts',
		match: (f) =>
			[
				'tools/test/prepare-linux-managed-http-snapshot.py',
				'tools/test/run-linux-managed-http-native.cjs',
				'tools/test/linux-managed-http-evidence.cjs',
				'tools/test/test-linux-managed-http-ci-registration.cjs',
				'tools/test/fixtures/validation-curl/setup_validation_curl.py',
				'tools/test/fixtures/validation-curl/prepare_validation_keyring.py',
				'tools/test/test_validation_keyring_preparation.py',
				'tools/test/fixtures/validation-curl/PINS.json',
				'tools/test/run-linux-managed-http-phase.py',
				'static/ergopti_plus/linux/tests/hardware/managed_http_gio_error.c',
				'static/ergopti_plus/linux/tests/hardware/run_http_output_target_native.lua',
				'static/ergopti_plus/linux/tests/hardware/run_http_output_target_native_entry.lua',
				'static/ergopti_plus/linux/tests/hardware/run_managed_http_native.lua',
				'static/ergopti_plus/linux/tests/hardware/run_managed_http_native.py',
				'tools/test/fixtures/linux-managed-http-phase-protocol.cjs',
				'tools/test/test-linux-managed-http-phase-protocol.cjs',
				'static/ergopti_plus/linux/adapters/http_client.lua',
				'static/ergopti_plus/_shared/lua/network/http_redirect.lua',
				'static/ergopti_plus/_shared/data/http/redirect_policy.json',
				'static/ergopti_plus/linux/infra/http_redirect_policy.lua',
				'static/ergopti_plus/linux/infra/http_redirect_receipt.lua',
				'static/ergopti_plus/linux/infra/managed_redirect_policy.lua',
				'static/ergopti_plus/linux/infra/http_header_policy.lua',
				'static/ergopti_plus/_shared/data/http/header_policy.json',
				'static/ergopti_plus/_shared/lua/network/http_headers.lua',
				'static/ergopti_plus/linux/infra/http_transport_policy.lua',
				'static/ergopti_plus/_shared/data/http/transport_policy.json',
				'static/ergopti_plus/linux/infra/http_body_pipe.lua',
				'static/ergopti_plus/linux/infra/libuv_process_group.lua',
				'static/ergopti_plus/linux/infra/libuv_exit.lua',
				'static/ergopti_plus/linux/infra/monotonic.lua',
				'static/ergopti_plus/linux/adapters/shell_runner.lua',
				'static/ergopti_plus/linux/_generated/native_runtime.lua',
				'static/ergopti_plus/_shared/data/linux_native_runtime.json',
				'static/ergopti_plus/linux/platform/network/runtime_probe.lua',
				'static/ergopti_plus/linux/infra/timings.lua',
				'static/ergopti_plus/_shared/modules/timings/constants.toml',
				'static/ergopti_plus/linux/adapters/curl_http_client.lua',
				'static/ergopti_plus/linux/adapters/system_proxy.lua',
				'static/ergopti_plus/linux/infra/managed_http.lua',
				'static/ergopti_plus/linux/infra/managed_http_deadline.lua',
				'static/ergopti_plus/linux/infra/native_timer.lua',
				'static/ergopti_plus/linux/infra/archive_output.lua',
				'static/ergopti_plus/linux/infra/http_output_target.lua',
				'static/ergopti_plus/linux/infra/curl_identity.lua',
				'static/ergopti_plus/linux/infra/proxy_policy.lua',
				'static/ergopti_plus/linux/platform/network/system_proxy_probe.lua',
				'static/ergopti_plus/linux/platform/network/native_proxy_runtime.lua',
				'static/ergopti_plus/_shared/lua/network/proxy_policy.lua',
				'static/ergopti_plus/_shared/modules/network/proxy_policy.json',
				'tools/build/stage-linux-network-runtime.py',
				'tools/lib/git_bash.py',
				'tools/__init__.py',
				'static/ergopti_plus/linux/tests/hardware/run_native_subreaper.py',
				'.github/workflows/ci-linux.yml',
				'.github/linux-ci-coverage.json'
			].includes(f)
	},
	{
		gate: 'linux-nix-native',
		why: 'Nix package runtime changes require a genuine derivation and installed wrapper/native admission',
		match: (f) =>
			[
				'tools/build/nix/flake.nix',
				'static/ergopti_plus/linux/ergopti_hotstrings.lua',
				'tools/test/run-linux-managed-http-native.cjs',
				'tools/build/stage-linux-network-runtime.py',
				'tools/build/build-linux-native-output.sh',
				'tools/lib/git_bash.py',
				'tools/__init__.py',
				'static/ergopti_plus/linux/native/archive_output/archive_publication.c',
				'static/ergopti_plus/linux/native/archive_output/archive_publication.h',
				'static/ergopti_plus/linux/infra/paths.lua',
				'static/ergopti_plus/linux/infra/openssl_digest.lua',
				'static/ergopti_plus/linux/platform/network/native_proxy_runtime.lua',
				'static/ergopti_plus/linux/_generated/native_runtime.lua',
				'static/ergopti_plus/_shared/data/linux_native_runtime.json',
				'tools/codegen/codegen-linux-native-runtime.cjs',
				'tools/test/run-linux-nix-native.cjs',
				'tools/test/fixtures/linux-nix-installed-runtime.lua',
				'tools/test/test-linux-nix-native.cjs',
				'tools/test/run-linux-managed-http-phase.py',
				'.github/linux-ci-coverage.json',
				'.github/workflows/ci-linux.yml'
			].includes(f)
	},
	{
		gate: 'linux-network-runtime',
		why: 'managed networking requires actual LuaJIT luv, GIO modules, compiled schemas and installed helper paths',
		match: (f) =>
			[
				'static/ergopti_plus/_shared/data/linux_native_runtime.json',
				'static/ergopti_plus/linux/_generated/native_runtime.lua',
				'static/ergopti_plus/linux/platform/network/native_proxy_runtime.lua',
				'static/ergopti_plus/linux/platform/network/runtime_probe.lua',
				'static/ergopti_plus/linux/platform/network/system_proxy_probe.lua',
				'static/ergopti_plus/linux/install.sh',
				'tools/codegen/codegen-linux-native-runtime.cjs',
				'tools/build/nix/flake.nix',
				'tools/test/run-linux-network-runtime.cjs',
				'tools/test/test-linux-network-runtime.cjs',
				'tools/test/test-linux-network-runtime-registration.cjs',
				'tools/test/linux-network-runtime-evidence.cjs',
				'tools/test/fixtures/linux-network-runtime-factory.lua',
				'.github/linux-ci-coverage.json',
				'.github/workflows/ci-linux.yml'
			].includes(f)
	},
	{
		gate: 'linux-fd-sha256-native',
		why: 'retained archive hashing requires actual LuaJIT, libuv, OpenSSL and descriptor retirement',
		match: (f) =>
			[
				'tools/test/run-linux-fd-sha256-native.cjs',
				'tools/test/test-linux-fd-sha256-native-gate.cjs',
				'static/ergopti_plus/linux/tests/hardware/run_fd_sha256_native.lua',
				'static/ergopti_plus/linux/infra/fd_sha256.lua',
				'static/ergopti_plus/linux/infra/archive_output.lua',
				'static/ergopti_plus/linux/infra/managed_http_deadline.lua',
				'static/ergopti_plus/linux/infra/native_timer.lua',
				'static/ergopti_plus/linux/infra/monotonic.lua',
				'static/ergopti_plus/linux/tests/hardware/run_native_subreaper.py',
				'.github/workflows/ci-linux.yml',
				'.github/linux-ci-coverage.json'
			].includes(f)
	},
	{
		gate: 'linux-portable-network-native',
		why: 'portable network packages require actual installed ELF, GIO, schema and owned timeout retirement',
		match: (f) =>
			[
				'static/ergopti_plus/_shared/data/linux_native_runtime.json',
				'tools/build/build-linux-appimage.sh',
				'tools/build/build-linux-flatpak.sh',
				'tools/build/stage-linux-network-runtime.py',
				'tools/build/templates/linux-portable-runtime-env.sh',
				'tools/codegen/codegen-linux-native-runtime.cjs',
				'tools/test/test-linux-portable-network-runtime.cjs',
				'tools/test/run-linux-portable-network-native.cjs',
				'tools/test/test-linux-portable-network-registration.cjs',
				'.github/workflows/ci-linux.yml'
			].includes(f)
	},
	{
		gate: 'linux-runtime-native',
		why: 'runtime prerequisites require actual process/file receipts on both Linux ABIs and physical wrapper teardown',
		match: (f) =>
			[
				'static/ergopti_plus/_shared/lua/native_worker_owner.lua',
				'static/ergopti_plus/_shared/lua/llm/process_port.lua',
				'static/ergopti_plus/_shared/lua/llm/finite_process_port.lua',
				'static/ergopti_plus/_shared/lua/llm/process_limits.lua',
				'static/ergopti_plus/_shared/lua/llm/ollama_archive_installer.lua',
				'static/ergopti_plus/linux/adapters/owned_process.lua',
				'static/ergopti_plus/linux/modules/llm/ollama_install_files.lua',
				'static/ergopti_plus/linux/tests/hardware/run_owned_process_native.lua',
				'static/ergopti_plus/linux/tests/hardware/run_finite_process_port_native.lua',
				'static/ergopti_plus/linux/tests/hardware/run_service_process_port_native.lua',
				'static/ergopti_plus/linux/tests/hardware/run_service_running_native.lua',
				'static/ergopti_plus/linux/tests/hardware/run_ollama_install_files_native.lua',
				'static/ergopti_plus/linux/tests/hardware/run_ollama_install_files_native.py',
				'static/ergopti_plus/linux/tests/hardware/run_native_subreaper.py',
				'static/ergopti_plus/linux/tests/hardware/run_native_subreaper_teardown.py',
				'static/ergopti_plus/linux/adapters/http_client.lua',
				'static/ergopti_plus/linux/adapters/curl_http_client.lua',
				'static/ergopti_plus/linux/tests/hardware/run_http_owned_post_native.lua',
				'static/ergopti_plus/linux/tests/hardware/run_http_owned_post_native.py',
				'tools/test/run-linux-runtime-native.cjs',
				'.github/workflows/ci-linux.yml'
			].includes(f)
	},
	{
		gate: 'linux',
		why: 'the Linux driver, its shared Lua runtime, or a shared corpus/port contract changed',
		match: (f) =>
			(f.startsWith('static/ergopti_plus/linux/') && !f.endsWith('.md')) ||
			isCrossDriverContract(f) ||
			isSharedLuaSource(f)
	}
];

function selectGates(files) {
	const selected = new Map();
	for (const rule of RULES) {
		const hits = files.filter(rule.match);
		if (hits.length > 0) selected.set(rule.gate, { why: rule.why, sample: hits.slice(0, 3) });
	}
	return omitCoveredGates(selected);
}

/**
 * Avoid repeating a standalone check already executed by a selected suite.
 * @param {Map} gates Selected commands and their explanations.
 * @returns {Map} The same selection with proven duplicate commands removed.
 */
function omitCoveredGates(gates) {
	for (const gate of gates.keys()) {
		const owner = GATE_COMMANDS[gate]?.coveredBy;
		if (owner && gates.has(owner)) gates.delete(gate);
	}
	return gates;
}

// ==================================================
// ==================================================
// ======= 4/ Running the selected gates ============
// ==================================================
// ==================================================

function findAhk() {
	return AHK_CANDIDATES.find((p) => fs.existsSync(p)) || null;
}

/**
 * npm is a .cmd shim on Windows, and Node 20+ refuses to spawn one without a
 * shell (the CVE-2024-27980 hardening). Without shell:true the call fails to
 * start and reports a null status, which reads as "the gate failed" even though
 * the gate never ran — a false red is as damaging here as a false green.
 */
function runNpm(script) {
	return spawnSync('npm', ['run', script], {
		cwd: REPO_ROOT,
		stdio: 'inherit',
		shell: true
	});
}

// How each gate is actually executed. A TABLE rather than a switch so a test can
// assert that every rule above resolves to a real command without spawning any of
// them: a rule whose gate has no entry here selects silently and runs nothing,
// which is indistinguishable from "the gate passed".
// Explicit full audits use this same inventory and order: generated writers
// in the JS gate finish before any Lua driver readers execute.
const GATE_COMMANDS = {
	format: { npm: 'format:check' },
	'ahk-encoding': { npm: 'test:ahk-encoding' },
	'report-style': { npm: 'lint:conventions:strict', coveredBy: 'js' },
	js: { npm: 'test:js' },
	'macos-tooltip-canvas': { npm: 'test:macos-tooltip-canvas' },
	'swift-launcher': { npm: 'test:macos-swift-launcher' },
	'xkb-python': { npm: 'test:xkb' },
	hs: { npm: 'test:hs' },
	'hs-e2e': { npm: 'test:hs:e2e' },
	linux: { npm: 'test:linux' },
	'linux-e2e': { npm: 'test:linux:e2e' },
	'linux-xkb-source': { npm: 'test:linux:xkb-source' },
	'linux-http-stream': { npm: 'test:linux:http-stream' },
	'linux-network-runtime': { npm: 'test:linux:network-runtime' },
	'linux-nix-native': { npm: 'test:linux:nix-native', platform: 'linux' },
	'linux-updater-temp-native': { npm: 'test:linux:updater-temp-native', platform: 'linux' },
	'linux-updater-archive-native': { npm: 'test:linux:updater-archive-native', platform: 'linux' },
	'linux-archive-source-controls': { npm: 'test:linux:archive-source-controls', platform: 'linux' },
	'linux-managed-http-native': { npm: 'test:linux:managed-http-native', platform: 'linux' },
	'linux-window-switch': { npm: 'test:linux:window-switch', platform: 'linux' },
	'linux-runtime-native': { npm: 'test:linux:runtime-native' },
	'linux-portable-network-native': { npm: 'test:linux:portable-network-native' },
	'linux-fd-sha256-native': { npm: 'test:linux:fd-sha256-native' },
	'ahk-parse': { npm: 'test:ahk-parse' },
	'ahk-suite': { ahk: 'run_all.ahk' },
	'ahk-e2e': { ahk: 'e2e/run_e2e.ahk' }
};

function runGate(gate) {
	const spec = GATE_COMMANDS[gate];
	// Fail loudly instead of reporting a pass for a gate nobody wired up.
	if (!spec) {
		return {
			error: new Error(`gate "${gate}" has no command in GATE_COMMANDS`)
		};
	}
	if (spec.platform && spec.platform !== process.platform)
		return {
			skipped: `${gate} requires ${spec.platform}; mandatory native CI remains unexecuted here`
		};
	if (spec.npm) return runNpm(spec.npm);
	const ahk = findAhk();
	if (!ahk) return { skipped: 'AutoHotkey v2 not installed on this machine' };
	// Parser errors occur before script-level diagnostics can run. Keep both
	// native gates noninteractive and route that failure to the inherited receipt.
	const args = ['/ErrorStdOut', spec.ahk];
	const options = { cwd: WINDOWS_TESTS, stdio: 'inherit', windowsHide: true };

	const resultsFile = path.join(
		os.tmpdir(),
		`ergopti_ahk_manifest_${process.pid}_${Date.now()}.tap`
	);
	const result = spawnSync(ahk, args, {
		...options,
		env: { ...process.env, ERGOPTI_AHK_RESULTS_FILE: resultsFile }
	});
	let manifest;
	try {
		const validate = gate === 'ahk-e2e' ? validateAhkE2eManifest : validateAhkSuiteManifest;
		manifest = validate(fs.readFileSync(resultsFile, 'utf8'));
	} catch (error) {
		manifest = {
			complete: false,
			planned: 0,
			executed_count: 0,
			errors: [error.message]
		};
	} finally {
		try {
			fs.rmSync(resultsFile, { force: true });
		} catch {
			/* best-effort temp cleanup */
		}
	}
	if (manifest.complete) {
		console.log(
			`verify-change: AHK execution manifest complete (${manifest.executed_count}/${manifest.planned}).`
		);
		return result;
	}
	console.error(
		`verify-change: AHK execution manifest incomplete (${manifest.executed_count}/${manifest.planned}).`
	);
	for (const error of manifest.errors.slice(0, 20)) console.error(`  - ${error}`);
	return result.status === 0 ? { ...result, status: 1 } : result;
}

/**
 * Classifies a gate outcome without pretending a red proves causality. A gate
 * selected by the current diff is a candidate regression; an extra full-audit
 * gate is baseline/history until separately reproduced against the baseline.
 * Failure to start is environmental, not a test assertion.
 * @param {string} gate Gate name.
 * @param {object} result spawnSync-like result.
 * @param {boolean} selectedByChange Whether the current diff requires the gate.
 * @returns {{kind: string, blockingInDiagnosis: boolean, detail: string}}
 */
function classifyGateResult(gate, result, selectedByChange) {
	if (result.skipped) {
		return {
			kind: 'environment-deferral',
			blockingInDiagnosis: false,
			detail: result.skipped
		};
	}
	if (result.error || result.status === null) {
		return {
			kind: 'environment-failure',
			blockingInDiagnosis: selectedByChange,
			detail: result.error ? result.error.message : `${gate} process did not start`
		};
	}
	if (result.status === 0) return { kind: 'pass', blockingInDiagnosis: false, detail: '' };
	if (selectedByChange) {
		return {
			kind: 'candidate-regression',
			blockingInDiagnosis: true,
			detail:
				'this gate covers the current diff; inspect the exact assertion before attributing causality'
		};
	}
	return {
		kind: 'baseline-or-history',
		blockingInDiagnosis: false,
		detail:
			'this full-audit gate is not selected by the current diff; reproduce it against the baseline before blocking a scoped change'
	};
}

// ==================================================
// ==================================================
// ======= 5/ Entry point ===========================
// ==================================================
// ==================================================

function main() {
	const args = process.argv.slice(2);
	const planOnly = args.includes('--plan');
	const all = args.includes('--all');
	const diagnose = args.includes('--diagnose');
	const range = (args.find((a) => a.startsWith('--range=')) || '').replace('--range=', '') || null;
	if (diagnose && !all) {
		console.error('verify-change: --diagnose is a full-audit classifier and requires --all.');
		return 2;
	}

	const files = changedFiles(range);
	if (!all && files.length === 0) {
		console.log('verify-change: nothing changed — nothing to verify.');
		return 0;
	}

	if (files.length > 0) {
		console.log(`verify-change: ${files.length} changed file(s).`);
		const problems = [...checkTestsAreRegistered(files), ...checkScannedSymbolsExist(files)];
		if (problems.length > 0) {
			console.error(
				'\n  SILENT-FAILURE PRE-CHECKS FAILED — these would not have shown up as a red suite:\n'
			);
			for (const p of problems) console.error(`   - ${p}`);
			console.error('');
			return 1;
		}
		console.log('verify-change: silent-failure pre-checks passed.');
	}

	const changeGates = selectGates(files);
	const gates = all
		? omitCoveredGates(new Map(Object.keys(GATE_COMMANDS).map((gate) => [gate, {}])))
		: changeGates;

	if (gates.size === 0) {
		console.log('verify-change: no gate matches these files. Run with --all if in doubt.');
		return 0;
	}

	console.log('\n  Gates required by this change:');
	for (const [gate, info] of gates) {
		console.log(`   - ${gate}${info.why ? `  (${info.why})` : ''}`);
		if (info.sample) console.log(`       e.g. ${info.sample.join(', ')}`);
	}
	console.log('');
	if (planOnly) return 0;

	let failed = 0;
	let diagnosticBlockers = 0;
	const classifications = [];
	for (const [gate] of gates) {
		console.log(`\n=== ${gate} ===`);
		const res = runGate(gate);
		// A full audit may run a selected standalone check through its parent
		// suite. Its failure still covers this change and cannot be exonerated.
		const coversChange =
			changeGates.has(gate) ||
			[...changeGates.keys()].some((changedGate) => GATE_COMMANDS[changedGate]?.coveredBy === gate);
		const classification = classifyGateResult(gate, res, coversChange);
		classifications.push({ gate, ...classification });
		if (classification.kind === 'environment-deferral')
			console.log(`  skipped: ${classification.detail}`);
		else if (classification.kind !== 'pass') {
			failed += 1;
			if (classification.blockingInDiagnosis) diagnosticBlockers += 1;
			console.error(`  ${gate} ${classification.kind.toUpperCase()}: ${classification.detail}`);
		}
	}

	console.log('');
	if (diagnose) {
		const nonPassing = classifications.filter((item) => item.kind !== 'pass');
		console.log('verify-change diagnosis:');
		if (nonPassing.length === 0) console.log('  every full-audit gate passed.');
		for (const item of nonPassing) {
			console.log(
				`  - ${item.gate}: ${item.kind}${item.blockingInDiagnosis ? ' (blocks this scoped change)' : ' (reported, non-blocking for this scoped change)'}`
			);
		}
		if (diagnosticBlockers === 0) {
			console.log(
				'verify-change: gates required by the current diff passed or were explicitly deferred; unrelated historical reds were not promoted to regressions.'
			);
			return 0;
		}
		console.error(
			`verify-change: ${diagnosticBlockers} current-diff gate(s) still require diagnosis.`
		);
		return 1;
	}
	if (failed > 0) {
		console.error(`verify-change: ${failed} gate(s) failed.`);
		return 1;
	}
	console.log(
		classifications.some((item) => item.kind === 'environment-deferral')
			? 'verify-change: required gates passed or were explicitly deferred; deferred native validation remains unexecuted.'
			: 'verify-change: every required gate passed.'
	);
	return 0;
}

// Exported so a regression test can assert which gates a change SELECTS, and that
// every selectable gate resolves to a real command, without spawning any suite.
// The auto-run stays guarded on require.main so `node verify-change.cjs` behaves
// exactly as before.
module.exports = {
	RULES,
	GATE_COMMANDS,
	changedFiles,
	parseChangedPaths,
	classifyGateResult,
	selectGates,
	hasAhkFunctionDefinition,
	checkTestsAreRegistered
};

if (require.main === module) {
	process.exit(main());
}
