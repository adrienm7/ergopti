// tools/test/test-new-driver-scaffold.cjs

/**
 * ==============================================================================
 * MODULE: new-driver Scaffold Guard
 * DESCRIPTION:
 * `tools/codegen/new-driver.js` must emit one adapter stub per port spec.
 *
 * ROOT CAUSE ENCODED:
 * Every path in the tool was pre-reorg and resolved to nothing:
 *
 *   REPO_ROOT   = resolve(__dirname, '..')      → tools/, not the repo root
 *   DRIVERS_DIR = REPO_ROOT/static/drivers      → the old tree, since renamed
 *   PORTS_DIR   = DRIVERS_DIR/_shared/ports     → moved to _shared/core/ports
 *   DOMAIN_DIR  = DRIVERS_DIR/_shared/domain    → moved to _shared/core/domain
 *
 * So readSpecNames() scanned a directory with no specs in it and returned an
 * empty list. The tool then did exactly what it was told: created the directory
 * tree, wrote ZERO adapter stubs, and generated an adapters/README.md announcing
 * "Ports to implement (0)" — a document stating, in writing, that a new driver
 * has nothing to implement. It exited 0 and printed a "Done. Next steps:"
 * checklist.
 *
 * Nothing failed, because nothing about scanning an empty directory is an error.
 * On some checkouts `static/drivers/` even still exists as a husk of two empty
 * untracked folders, so the path was not obviously wrong to a reader either.
 *
 * WHY THIS TEST SCAFFOLDS FOR REAL:
 * A structural check ("does the source mention _shared/core/ports?") would pass
 * on a tool whose other three paths are still wrong. The only assertion that
 * distinguishes a working scaffold from an empty one is the count of files it
 * actually wrote, so this runs the tool and counts them. The scaffold is removed
 * in a finally block whether the assertions pass or not.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const PORTS = path.join(SP, '_shared', 'core', 'ports');
const DOMAIN = path.join(SP, '_shared', 'core', 'domain');
const TOOL = path.join(ROOT, 'tools', 'codegen', 'new-driver.js');

// A name no real driver will ever take, so a failed cleanup is obvious rather
// than mistaken for a driver somebody added.
const PROBE = 'scaffold-probe-driver';
const TARGET = path.join(SP, PROBE);

// Places a mis-rooted run has been observed to write to, checked and cleaned
// after every run. tools/static/drivers/ is where the tool actually put its
// output while REPO_ROOT resolved to tools/.
const STRAY_LOCATIONS = [
	path.join(ROOT, 'tools', 'static', 'drivers', PROBE),
	path.join(ROOT, 'static', 'drivers', PROBE)
];
const STRAY_PARENTS = [
	path.join(ROOT, 'tools', 'static', 'drivers'),
	path.join(ROOT, 'tools', 'static')
];

const errors = [];

/** Spec basenames in a directory, the same set the tool scans for. */
function specs(dir) {
	if (!fs.existsSync(dir)) return [];
	return fs.readdirSync(dir).filter((f) => f.endsWith('.spec.js'));
}

const portSpecs = specs(PORTS);
const domainSpecs = specs(DOMAIN);

if (portSpecs.length < 18) {
	errors.push(
		`found ${portSpecs.length} port spec(s) in _shared/core/ports — fewer than the 18 the ` +
			'architecture gate also requires, so either the specs moved again or this scan is broken'
	);
}

if (fs.existsSync(TARGET)) {
	errors.push(`${PROBE}/ already exists — a previous run did not clean up; remove it and re-run`);
}

if (errors.length === 0) {
	try {
		const run = spawnSync('node', [TOOL, PROBE, 'lua'], { cwd: ROOT, encoding: 'utf8' });

		if (run.status !== 0) {
			errors.push(
				`the scaffold tool exited ${run.status}:\n      ` +
					((run.stdout || '') + (run.stderr || '')).trim().split('\n').join('\n      ')
			);
		} else {
			const adapterDir = path.join(TARGET, 'adapters');
			const written = fs.existsSync(adapterDir)
				? fs.readdirSync(adapterDir).filter((f) => f.endsWith('.lua'))
				: [];

			if (written.length !== portSpecs.length) {
				errors.push(
					`the scaffold wrote ${written.length} adapter stub(s) for ${portSpecs.length} port ` +
						'spec(s). Zero means the spec path is stale again — which is how this tool came to ' +
						'produce an empty driver and a README saying "Ports to implement (0)", while ' +
						'exiting 0 and printing a next-steps checklist.'
				);
			}

			// The README is the artifact that made the bug legible, so it is checked
			// rather than assumed: a count of 0 there is the tool telling you, in
			// writing, that there is nothing to implement.
			const readmePath = path.join(adapterDir, 'README.md');
			if (!fs.existsSync(readmePath)) {
				errors.push('adapters/README.md was not generated');
			} else {
				const readme = fs.readFileSync(readmePath, 'utf8');
				if (/\(0\)/.test(readme) || /implement \(0\)/i.test(readme)) {
					errors.push(
						'adapters/README.md reports zero ports to implement — the exact symptom of the ' +
							'stale spec path'
					);
				}
				for (const spec of portSpecs.slice(0, 5)) {
					const port = spec.replace(/\.spec\.js$/, '');
					if (!readme.includes(port)) {
						errors.push(`adapters/README.md does not list the port "${port}"`);
					}
				}
			}

			// The tool reports its own counts; they must match what is on disk, or
			// the summary is reassuring the user about something else.
			const reported = (run.stdout || '').match(/Ports found:\s*(\d+)/);
			if (!reported || Number(reported[1]) !== portSpecs.length) {
				errors.push(
					`the tool reported "Ports found: ${reported ? reported[1] : '?'}" but there are ` +
						`${portSpecs.length} port spec(s)`
				);
			}
			const reportedDomain = (run.stdout || '').match(/Domain specs:\s*(\d+)/);
			if (!reportedDomain || Number(reportedDomain[1]) !== domainSpecs.length) {
				errors.push(
					`the tool reported "Domain specs: ${reportedDomain ? reportedDomain[1] : '?'}" but ` +
						`there are ${domainSpecs.length} domain spec(s) — the second stale path`
				);
			}
		}
	} finally {
		// Unconditional: a failed assertion must not leave a fake driver in the
		// tree, where the next run would refuse to start and every driver-parity
		// gate would count it as real.
		fs.rmSync(TARGET, { recursive: true, force: true });

		// And clean up where a WRONG path would have put it. This is not
		// hypothetical: with REPO_ROOT resolving to tools/, the tool wrote its
		// scaffold to tools/static/drivers/<name>/ — so proving the bug left a
		// stray tree behind that cleanup aimed at the correct location could not
		// see. A cleanup that only works when the tool works is not a cleanup.
		for (const stray of STRAY_LOCATIONS) {
			if (fs.existsSync(stray)) {
				errors.push(
					`the scaffold wrote outside static/ergopti_plus/ — found ${path.relative(ROOT, stray)}. ` +
						'That is what a wrong REPO_ROOT looks like from the outside.'
				);
				fs.rmSync(stray, { recursive: true, force: true });
			}
		}
		// Remove the now-empty parents so the repo is left exactly as found.
		for (const dir of STRAY_PARENTS) {
			try {
				if (fs.existsSync(dir) && fs.readdirSync(dir).length === 0) fs.rmdirSync(dir);
			} catch {
				/* a non-empty parent is somebody else's directory — leave it alone */
			}
		}
	}
}

if (fs.existsSync(TARGET)) {
	errors.push(`${PROBE}/ survived cleanup — remove it by hand`);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] new-driver scaffold:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] new-driver scaffolds one adapter stub per port spec ` +
		`(${portSpecs.length} port(s), ${domainSpecs.length} domain spec(s)), and cleans up.\x1b[0m`
);
