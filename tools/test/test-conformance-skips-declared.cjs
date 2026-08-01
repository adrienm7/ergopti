// tools/test/test-conformance-skips-declared.cjs

/**
 * ==============================================================================
 * MODULE: Conformance Skip Ledger
 * DESCRIPTION:
 * Every skipped conformance case in the three suites must name a row of
 * `_shared/tests/conformance/manifest.json`, and every row must be referenced by
 * a real skip.
 *
 * WHY SKIPS BECOME DATA:
 * A skip written only as prose cannot be distinguished from a skip nobody
 * remembers. It reads as deliberate whether it is a design decision, a platform
 * that never got built, or a test somebody disabled during a bad afternoon. The
 * suite is green either way, and the count of green tests goes UP when a
 * behaviour stops being exercised.
 *
 * The ledger makes the difference checkable: `platform_gap` says the feature does
 * not exist and names where the work is tracked, `by_design` says another layer
 * owns the behaviour and closing it would assert the wrong component, and
 * `environment` says the behaviour IS implemented and this host merely lacks a
 * tool — a skip that fires on one machine and not another.
 *
 * WHAT THIS CATCHES:
 *   - a new skip added with no ledger row (the drift this exists to stop);
 *   - a ledger row nothing references any more, which claims coverage is missing
 *     when it may have been restored — a stale excuse is its own defect;
 *   - a row missing its reason or its tracking pointer, which is prose again.
 *
 * It deliberately does NOT try to verify that a reason is still TRUE. "Linux has
 * no Lua tap-hold engine" is a statement about the product that no regex can
 * check. What is checkable is that somebody wrote it down, tied it to a site, and
 * has to look at it again when the site moves.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const LEDGER = path.join(SP, '_shared', 'tests', 'conformance', 'manifest.json');

const SUITES = [
	{ driver: 'windows', dir: path.join(SP, 'windows', 'tests'), ext: '.ahk' },
	{ driver: 'macos', dir: path.join(SP, 'macos', 'tests'), ext: '.lua' },
	{ driver: 'linux', dir: path.join(SP, 'linux', 'tests'), ext: '.lua' }
];

const REQUIRED_FIELDS = ['id', 'driver', 'subject', 'status', 'reason', 'tracked'];
const VALID_STATUS = new Set(['platform_gap', 'by_design', 'environment']);

// A skip TEST — a registered case whose name announces it is not exercising the
// behaviour. Prose in a docstring is not a skip; only a case the runner counts.
const SKIP_SITE = /\b(?:helpers\.)?(?:it|Test)\s*\(\s*"SKIP\b([^"]*)"/;
const ID_IN_NAME = /\[([A-Z][A-Z0-9-]+)\]/;

// Floor: the ledger describes real skips, so an empty scan means the site
// detection broke rather than that every skip was fixed at once.
const MIN_SITES = 6;

const errors = [];

let ledger;
try {
	ledger = JSON.parse(fs.readFileSync(LEDGER, 'utf8'));
} catch (e) {
	console.error(`\x1b[31m[ERROR] cannot read the conformance ledger: ${e.message}\x1b[0m`);
	process.exit(1);
}

const entries = Array.isArray(ledger.entries) ? ledger.entries : null;
if (!entries) {
	console.error('\x1b[31m[ERROR] the conformance ledger has no "entries" array.\x1b[0m');
	process.exit(1);
}

const byId = new Map();
for (const e of entries) {
	for (const f of REQUIRED_FIELDS) {
		if (typeof e[f] !== 'string' || e[f].trim() === '') {
			errors.push(`ledger entry ${e.id || '(no id)'}: "${f}" is missing or empty — the row is prose again`);
		}
	}
	if (e.status && !VALID_STATUS.has(e.status)) {
		errors.push(
			`ledger entry ${e.id}: status "${e.status}" is not one of ${[...VALID_STATUS].join(', ')}. The ` +
				'status is what separates "not built" from "built elsewhere" from "this host lacks a tool".'
		);
	}
	if (e.status === 'platform_gap' && e.tracked === 'none') {
		errors.push(
			`ledger entry ${e.id}: a platform_gap must say where the work is tracked. "none" means the gap ` +
				'is permanent, which is what by_design is for.'
		);
	}
	if (e.id) {
		if (byId.has(e.id)) errors.push(`ledger entry ${e.id}: duplicate id`);
		byId.set(e.id, { entry: e, sites: [] });
	}
}

// Collect every skip site across the three suites.
let siteCount = 0;
for (const suite of SUITES) {
	if (!fs.existsSync(suite.dir)) {
		errors.push(`${suite.driver}: no tests directory at ${path.relative(ROOT, suite.dir)}`);
		continue;
	}
	(function collect(dir) {
		for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, e.name);
			if (e.isDirectory()) {
				if (e.name !== 'node_modules') collect(p);
				continue;
			}
			if (path.extname(e.name) !== suite.ext) continue;
			const rel = path.relative(SP, p).split(path.sep).join('/');
			fs.readFileSync(p, 'utf8')
				.split(/\r?\n/)
				.forEach((line, i) => {
					const m = line.match(SKIP_SITE);
					if (!m) return;
					siteCount++;
					const where = `${rel}:${i + 1}`;
					const idMatch = m[1].match(ID_IN_NAME);
					if (!idMatch) {
						errors.push(
							`${where}: a skipped case with no ledger id. Add a row to ` +
								'_shared/tests/conformance/manifest.json and name it here as "SKIP [ID] — …". ' +
								'A skip that is only prose cannot be told apart from a test somebody disabled.'
						);
						return;
					}
					const id = idMatch[1];
					const row = byId.get(id);
					if (!row) {
						errors.push(`${where}: names ledger id "${id}", which does not exist in the ledger`);
						return;
					}
					if (row.entry.driver !== suite.driver) {
						errors.push(
							`${where}: names "${id}", whose ledger row is for driver "${row.entry.driver}" — ` +
								`this site is in the ${suite.driver} suite`
						);
					}
					row.sites.push(where);
				});
		}
	})(suite.dir);
}

if (siteCount < MIN_SITES) {
	errors.push(
		`found only ${siteCount} skip site(s) (floor ${MIN_SITES}) — the site detection is broken, and ` +
			'this guard would then approve a ledger it never compared against anything'
	);
}

for (const [id, { sites }] of byId) {
	if (sites.length === 0) {
		errors.push(
			`ledger entry ${id}: no skip site references it. Either the skip was removed — in which case ` +
				'delete the row, because a stale excuse claims coverage is missing when it is not — or the ' +
				'site lost its id.'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] conformance skip ledger:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

const byStatus = {};
for (const e of entries) byStatus[e.status] = (byStatus[e.status] || 0) + 1;
const breakdown = Object.entries(byStatus)
	.map(([s, n]) => `${n} ${s}`)
	.join(', ');

console.log(
	`\x1b[32m[OK] all ${siteCount} skipped conformance case(s) name a ledger row ` +
		`(${entries.length} row(s): ${breakdown}).\x1b[0m`
);
