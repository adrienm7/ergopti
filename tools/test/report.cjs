// tools/test/report.cjs

/**
 * ==============================================================================
 * MODULE: Unified Test Reporter (TAP + Lua → JSON + GitHub annotations)
 * DESCRIPTION:
 * Wraps a test runner, streams its output unchanged, then parses pass/fail
 * results from EITHER format the repo uses:
 *   - strict TAP (AHK run_all.ahk):  "ok N - name" / "not ok N - name [ - diag]"
 *                                    plus the "# N passed, M failed" plan footer.
 *   - the macOS Lua runner:          "  ok   name" / "  FAIL name — err" plus the
 *                                    "Passed tests:  N" / "Failed tests:  M" block.
 * On GitHub Actions it emits one ::error:: annotation per failing test and a
 * ::notice:: summary plus bounded failure details outside the error quota; always
 * writes a JSON summary (--json) and a step summary
 * if GITHUB_STEP_SUMMARY is set. Exits with the wrapped command's exit code so
 * CI gating is unchanged. Counts read by people (annotations, step summary,
 * final line) group thousands; the JSON keeps plain numbers for tools.
 *
 * USAGE:
 *   node tools/test/report.cjs --name <label> [--json out.json] -- <cmd> [args…]
 * ==============================================================================
 */

'use strict';

const { spawn } = require('child_process');
const fs = require('fs');

// =====================================
// ======= 1/ Argument parsing =========
// =====================================

function parseArgs(argv) {
	const opts = { name: 'tests', json: '', cmd: [] };
	let i = 0;
	for (; i < argv.length; i++) {
		const a = argv[i];
		if (a === '--') {
			opts.cmd = argv.slice(i + 1);
			break;
		} else if (a === '--name') opts.name = argv[++i];
		else if (a === '--json') opts.json = argv[++i];
	}
	return opts;
}

// =====================================
// ======= 2/ Result extraction ========
// =====================================

/**
 * Parses failures + counts from combined runner output, format-agnostic.
 * @param {string} out The runner's full stdout/stderr.
 * @returns {{failures: string[], passed: number, failed: number, format: string}}
 */
function parseResults(out) {
	const lines = out.split(/\r?\n/);
	const failures = [];
	let passed = 0,
		failed = 0,
		format = 'unknown';

	for (const line of lines) {
		// TAP: "not ok 12 - some test - diag"
		const tap = line.match(/^not ok\s+\d+\s+-\s+(.+)$/);
		if (tap) {
			failures.push(tap[1].trim());
			format = 'tap';
			continue;
		}
		// Lua: "  FAIL some test — error"  (em-dash or hyphen separator)
		const lua = line.match(/^\s*FAIL\s+(.+?)(?:\s+[—-]\s+.*)?$/);
		if (lua && /^\s*FAIL\s/.test(line)) {
			failures.push(lua[1].trim());
			format = 'lua';
			continue;
		}
	}

	// Counts: prefer the authoritative footers.
	const tapPlan = out.match(/#\s*(\d+)\s+passed,\s+(\d+)\s+failed/);
	if (tapPlan) {
		passed = Number(tapPlan[1]);
		failed = Number(tapPlan[2]);
		format = 'tap';
	}
	const luaPassed = out.match(/Passed tests:\s+(\d+)/);
	const luaFailed = out.match(/Failed tests:\s+(\d+)/);
	if (luaPassed) {
		passed = Number(luaPassed[1]);
		format = format === 'tap' ? 'tap' : 'lua';
	}
	if (luaFailed) {
		failed = Number(luaFailed[1]);
	}

	// De-duplicate failure names (the lua runner lists each failure twice:
	// inline FAIL + DETAILED FAILURES). Keep first occurrence order.
	const seen = new Set();
	const uniqueFailures = failures.filter((f) => (seen.has(f) ? false : (seen.add(f), true)));

	return { failures: uniqueFailures, passed, failed, format };
}

// =====================================
// ======= 3/ Emission =================
// =====================================

// Narrow no-break space: groups thousands as French typography does, and a
// count never wraps between its groups.
const THOUSANDS_SEPARATOR = '\u202F';

/**
 * Formats a count for people: 11507 → "11 507".
 * @param {number} n A non-negative integer count.
 * @returns {string} The count with its thousands grouped.
 */
function formatCount(n) {
	return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, THOUSANDS_SEPARATOR);
}

function ghEscape(s) {
	return String(s).replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
}

/**
 * Retains ordinary failure lists outside GitHub's ten-error annotation quota.
 * Bound the escaped UTF-8 message below the 64 KiB annotation limit; only a
 * genuinely oversized detail is omitted, so it cannot hide later small causes.
 * @param {string[]} failures Ordered, independently parsed failure details.
 * @returns {string} Complete details or an explicit exact omission count.
 */
function failureNotice(failures) {
	const limit = 48 * 1024;
	const footer = (count) =>
		`\n${count} failure detail${count === 1 ? '' : 's'} omitted because the annotation message budget was exceeded. Full details remain in the runner output.`;
	let text = `${failures.length} failure detail${failures.length === 1 ? '' : 's'}:\n`;
	const complete = text + failures.map((failure, index) => `${index + 1}. ${failure}\n`).join('');
	if (Buffer.byteLength(ghEscape(complete), 'utf8') <= limit) return complete;
	let bytes = Buffer.byteLength(ghEscape(text), 'utf8');
	const reserve = Buffer.byteLength(ghEscape(footer(failures.length)), 'utf8');
	let omitted = 0;
	for (const [index, failure] of failures.entries()) {
		const line = `${index + 1}. ${failure}\n`;
		const size = Buffer.byteLength(ghEscape(line), 'utf8');
		if (bytes + size + reserve > limit) {
			omitted++;
			continue;
		}
		text += line;
		bytes += size;
	}
	return omitted ? text + footer(omitted) : text;
}

function emit(opts, res, code) {
	const onGitHub = !!process.env.GITHUB_ACTIONS;
	if (onGitHub) {
		for (const f of res.failures) {
			process.stdout.write(`::error title=${ghEscape(opts.name)} test failed::${ghEscape(f)}\n`);
		}
		if (res.failures.length)
			process.stdout.write(
				`::notice title=${ghEscape(opts.name)} all failures::${ghEscape(failureNotice(res.failures))}\n`
			);
		// CI-only diagnostic: the annotations API truncates each message at 4 KiB.
		// Preserve every original assertion and verdict, and duplicate bounded details.
		for (let first = 0; first < res.failures.length; first += 8) {
			const details = res.failures
				.slice(first, first + 8)
				.map((failure, index) => `${first + index + 1}. ${failure.slice(0, 320)}`)
				.join('\n');
			process.stdout.write(
				`::notice title=${ghEscape(opts.name)} diagnostic causes ${first + 1}::${ghEscape(details)}\n`
			);
		}
		const summary = `${opts.name}: ${formatCount(res.passed)} passed, ${formatCount(res.failed)} failed`;
		process.stdout.write(`::notice title=${ghEscape(opts.name)}::${ghEscape(summary)}\n`);
		if (process.env.GITHUB_STEP_SUMMARY) {
			const md =
				`### ${opts.name}\n\n- ✅ ${formatCount(res.passed)} passed\n- ${res.failed > 0 ? '❌' : '✅'} ${formatCount(res.failed)} failed\n` +
				(res.failures.length
					? `\n<details><summary>Failures</summary>\n\n${res.failures.map((f) => `- ${f}`).join('\n')}\n</details>\n`
					: '');
			try {
				fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, md);
			} catch {
				/* best-effort */
			}
		}
	}

	if (opts.json) {
		const payload = {
			name: opts.name,
			format: res.format,
			passed: res.passed,
			failed: res.failed,
			exit_code: code,
			failures: res.failures
		};
		try {
			fs.writeFileSync(opts.json, JSON.stringify(payload, null, 2));
		} catch {
			/* best-effort */
		}
	}

	const tag = res.failed > 0 || code !== 0 ? '\x1b[31mFAIL\x1b[0m' : '\x1b[32mPASS\x1b[0m';
	process.stdout.write(
		`\n[report:${opts.name}] ${tag} — ${formatCount(res.passed)} passed, ${formatCount(res.failed)} failed (exit ${code}, format ${res.format}).\n`
	);
}

// =====================================
// ======= 4/ Main =====================
// =====================================

function main() {
	const opts = parseArgs(process.argv.slice(2));
	if (opts.cmd.length === 0) {
		process.stderr.write(
			'Usage: node tools/test/report.cjs --name <label> [--json out.json] -- <cmd> [args…]\n'
		);
		process.exitCode = 2;
		return;
	}

	// PARSE_ONLY mode (for self-tests): read pre-captured output from a file
	// instead of spawning, so the parser can be exercised hermetically.
	if (opts.cmd[0] === 'PARSE_FILE') {
		const out = fs.readFileSync(opts.cmd[1], 'utf8');
		const res = parseResults(out);
		emit(opts, res, res.failed > 0 ? 1 : 0);
		process.exitCode = res.failed > 0 ? 1 : 0;
		return;
	}

	const child = spawn(opts.cmd[0], opts.cmd.slice(1), { shell: false });
	let buf = '';
	let spawnFailed = false;
	child.stdout.on('data', (d) => {
		buf += d;
		process.stdout.write(d);
	});
	child.stderr.on('data', (d) => {
		buf += d;
		process.stderr.write(d);
	});
	child.on('close', (code) => {
		if (spawnFailed) return;
		const res = parseResults(buf);
		emit(opts, res, code ?? 0);
		// Natural shutdown drains both forwarded streams and final annotations.
		// An immediate exit discards pending pipe writes despite a valid JSON file.
		process.exitCode = code ?? 0;
	});
	child.on('error', (err) => {
		spawnFailed = true;
		process.stderr.write(`[report:${opts.name}] failed to spawn: ${err.message}\n`);
		process.exitCode = 2;
	});
}

// Only run when invoked directly — requiring this module (e.g. from the
// self-test) must expose parseResults without spawning anything.
if (require.main === module) main();

module.exports = { parseResults, formatCount };
