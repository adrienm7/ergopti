// tools/test/test-ahk-loop-capture.cjs

/**
 * ==============================================================================
 * MODULE: AHK Loop-Capture Guard
 * DESCRIPTION:
 * Rejects a closure declared inside a `for` loop that reads a variable of the
 * ENCLOSING function — the shape that makes every per-item test replay the last
 * item.
 *
 * ROOT CAUSE ENCODED:
 * AHK v2 closures capture by REFERENCE. Copying the loop variable into another
 * outer local first (`VecCopy := Vec`) looks like a per-iteration snapshot and
 * is not: `VecCopy` is one slot in the enclosing function, every registered
 * closure shares it, and they all run AFTER the loop — so they all read the
 * final value.
 *
 * Measured 2026-07-31, three corpus consumers: dropping a keystroke from the
 * FIRST vector of a 13-vector corpus produced 13 green tests. With `.Bind(Vec)`
 * the same corruption produces one red naming the vector. Twelve of the
 * thirteen tests had been asserting nothing at all, because the runner
 * dispatches on `Vec["id"]` and every closure saw the last id.
 *
 * FEATURES & RATIONALE:
 * 1. Flags the SHAPE, not a spelling: any `Test(…, () => …)` or nested function
 *    reference registered inside a `for` body is reported. `.Bind(args…)` is the
 *    fix and is what the guard steers to, because Bind evaluates its arguments
 *    at registration and stores them per callable.
 * 2. A baseline, because the shape is occasionally harmless (a closure reading
 *    nothing from the loop). It only turns down.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const TESTS = path.join(ROOT, 'static', 'ergopti_plus', 'windows', 'tests');

// Occurrences that are known-good today. NEVER raise this to admit a new one:
// the fix is always .Bind, and it is a two-word change.
const BASELINE = 0;

function walk(dir, acc = []) {
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) walk(p, acc);
		else if (e.name.endsWith('.ahk')) acc.push(p);
	}
	return acc;
}

const findings = [];
for (const file of walk(TESTS)) {
	const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
	let depth = 0;      // brace depth inside the innermost for-loop, -1 when outside
	let inLoop = false;
	lines.forEach((raw, i) => {
		const line = raw.replace(/;.*$/, '');
		if (!inLoop && /^\s*for\s+\w/.test(line)) {
			inLoop = true;
			depth = 0;
		}
		if (inLoop) {
			depth += (line.match(/\{/g) || []).length;
			depth -= (line.match(/\}/g) || []).length;
			// A registration whose callable is an inline fat-arrow closes over the
			// enclosing scope. Bind does not.
			// `.*` on purpose: the fat arrow's own `()` closes a paren before the
			// `=>`, so a [^)]* scan stops short and matches nothing — the first
			// version of this guard did exactly that and reported zero findings
			// against a file that had one.
			if (/\bTest\s*\(.*=>/.test(line)) {
				findings.push({
					file: path.relative(ROOT, file).replace(/\\/g, '/'),
					line: i + 1,
					text: line.trim().slice(0, 110),
				});
			}
			if (depth <= 0 && /\}/.test(line)) inLoop = false;
		}
	});
}

if (findings.length > BASELINE) {
	console.error(
		`\x1b[31m[ERROR] ${findings.length} test registration(s) use an inline closure inside a for loop (baseline ${BASELINE}).\x1b[0m`
	);
	console.error(
		'  AHK v2 closures capture by REFERENCE, and copying the loop variable into another\n' +
			'  outer local first freezes nothing — every closure shares that slot and reads the\n' +
			"  LAST iteration's value, so every per-item test runs the same item.\n" +
			'  Fix: Test(name, _RunOne.Bind(item)) — Bind evaluates its arguments at registration.\n'
	);
	for (const f of findings) console.error(`    ${f.file}:${f.line}  ${f.text}`);
	process.exit(1);
}

console.log(`\x1b[32m[OK] No inline loop closures in test registrations (${findings.length}/${BASELINE}).\x1b[0m`);
