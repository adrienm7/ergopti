// tools/test/test-shared-js-is-loadable.cjs

/**
 * ==============================================================================
 * MODULE: Shared JS Reachability Guard
 * DESCRIPTION:
 * Every `_shared/**\/*.js` module that exports via `module.exports` must have a
 * consumer that can actually load it, or be recorded as specification-only.
 *
 * ROOT CAUSE ENCODED:
 * package.json declares `"type": "module"`, so a bare `.js` file is ESM and
 * `module.exports = {…}` exports **nothing** — `require()` rejects it,
 * `import()` returns an empty namespace, and neither says a word. Measured
 * across `_shared/`: **32 modules** are in that state.
 *
 * It only stayed survivable because codegen-contracts-json.cjs carried a
 * CommonJS-in-ESM shim, which happened to cover the 27 port specs. The five
 * tooltip modules had no such consumer, so `layoutTestVectors()` — the declared
 * source of truth for a corpus both drivers replay — was unreachable from every
 * tool in the repo, and the gate that claimed to compare against it could not
 * have. That is what this guard exists to prevent recurring.
 *
 * WHY "RECORDED AS SPEC-ONLY" IS AN ALLOWED ANSWER:
 * Three of them genuinely are. `draw_calls.js`, `lifecycle.js` and `tint.js`
 * describe behaviour the Lua and AutoHotkey drivers implement by hand; nothing
 * executes them, and nothing can — the drivers cannot load JS. Being read only
 * by humans is a legitimate role for a specification. Being read by nobody
 * because of a module-system detail is not, and the two are indistinguishable
 * from the outside unless the difference is written down.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');

// Modules that no tool loads, on purpose. Each needs a reason, because the
// alternative reading — "nothing can load it and nobody noticed" — is the bug.
const SPEC_ONLY = {
	'modules/tooltip/draw_calls.js':
		'Describes the draw-call sequence the Lua and AHK renderers implement by hand. ' +
		'No tool executes it and no driver can (they cannot load JS).',
	'modules/tooltip/lifecycle.js':
		'Describes the show/hide/replace lifecycle each driver implements natively.',
	'modules/tooltip/tint.js':
		'Describes the tint derivation; both drivers reimplement it in their own language.',
	'core/domain/Expander.spec.js':
		'Domain specification cited by core/domain/SPEC.md and config_schema/SCHEMA.md. No tool ' +
		'loads it; the expander is implemented per driver.',
	'core/domain/GestureRecognizer.spec.js':
		'Domain specification cited by SPEC.md and SCHEMA.md; gesture recognition is implemented ' +
		'per driver.',
	'core/domain/ProfileSelector.js':
		'Profile-selection reference implementation cited by SPEC.md. Nothing executes it — the ' +
		'drivers select profiles in their own language.'
};

const errors = [];

function walk(dir, acc = []) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'node_modules' && e.name !== '_generated') walk(p, acc);
		} else if (e.name.endsWith('.js')) {
			acc.push(p);
		}
	}
	return acc;
}

/** Tool sources that could load a shared module. */
const consumers = [];
for (const d of ['tools', 'src']) {
	const base = path.join(ROOT, d);
	if (!fs.existsSync(base)) continue;
	(function collect(dir) {
		for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, e.name);
			if (e.isDirectory()) {
				if (e.name !== 'node_modules') collect(p);
			} else if (/\.(js|cjs|mjs)$/.test(e.name)) {
				// Never count THIS file. It names the spec-only modules and contains
				// the very tokens the sweep check looks for, so including it made the
				// guard treat its own source as a consumer — and pass with an
				// unreachable module sitting right there. Found by probing it.
				if (path.resolve(p) === path.resolve(__filename)) continue;
				consumers.push({ rel: path.relative(ROOT, p).split(path.sep).join('/'), src: fs.readFileSync(p, 'utf8') });
			}
		}
	})(base);
}

if (consumers.length < 20) {
	errors.push(`found only ${consumers.length} tool file(s) — the consumer scan is broken`);
}

let cjsOnly = 0;
for (const abs of walk(SHARED)) {
	const rel = path.relative(SHARED, abs).split(path.sep).join('/');
	const src = fs.readFileSync(abs, 'utf8');
	const hasCjs = /^\s*module\.exports\s*=/m.test(src);
	const hasEsm = /^\s*export\s+(default\s+|\{|const |function |class |let |var )/m.test(src);
	if (!hasCjs || hasEsm) continue;
	cjsOnly++;

	const base = path.basename(abs);
	// A consumer must name the file, or read its directory (the specs are loaded
	// by a readdirSync sweep). Matching the directory alone is not enough — a
	// prose mention of the path would count — so the sweep must be real.
	const dirRel = path.dirname(rel);
	const named = consumers.some((c) => c.src.includes(base));
	// The one real directory sweep in the repo: codegen-contracts-json.cjs reads
	// every *.spec.js in core/ports. Recognised by name rather than inferred from
	// loose token matching, which is what let this guard match its own source.
	const swept = dirRel === 'core/ports'
		&& base.endsWith('.spec.js')
		&& consumers.some((c) => c.rel.endsWith('codegen-contracts-json.cjs'));

	if (named || swept) continue;
	if (rel in SPEC_ONLY) continue;

	errors.push(
		`${rel}: exports only via module.exports, and no tool loads it. In an ESM package that ` +
			'means it exports nothing to anyone — require() rejects it and import() yields an empty ' +
			'namespace, silently. Give it a consumer (tools/lib/load-cjs-module.cjs), convert it to ' +
			'ESM `export`, or record it in SPEC_ONLY with the reason it is read only by humans.'
	);
}

// A stale allowlist entry is its own failure: it asserts a module exists.
for (const rel of Object.keys(SPEC_ONLY)) {
	if (!fs.existsSync(path.join(SHARED, rel))) {
		errors.push(`${rel}: recorded as spec-only but no longer exists — the record is stale`);
	}
}

if (cjsOnly < 10) {
	errors.push(
		`only ${cjsOnly} CommonJS-only module(s) found — the detection is probably broken, and this ` +
			'guard would then pass by inspecting nothing'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] shared JS reachability:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${cjsOnly} CommonJS-only shared module(s) are loadable by a tool, or recorded ` +
		`as specification-only (${Object.keys(SPEC_ONLY).length}).\x1b[0m`
);
