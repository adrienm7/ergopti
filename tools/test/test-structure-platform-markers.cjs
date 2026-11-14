// tools/test/test-structure-platform-markers.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Platform Markers
 * DESCRIPTION:
 * Convention P: every driver ships every platform/ sub-folder, and one with
 * nothing to put there ships a README.md explaining the mechanism it uses
 * instead. S13 moved linux/desktop_focus and S16 windows/native into platform
 * domains that only one driver fills, and Convention P failed on the four
 * missing folders. Each step that fills a domain now writes the listed markers
 * (edits.cjs PLATFORM_MARKERS) of the drivers without it. This test holds the
 * plan complete: once every move is made, every platform domain a driver fills
 * exists on every driver, as moved files or as a listed marker.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');
const Edits = require('../audit/structure/edits.cjs');
const Rules = require('../audit/structure/rules.cjs');

const REPO = path.resolve(__dirname, '..', '..');
const DRIVERS = ['linux', 'macos', 'windows'];

function run() {
	const { map } = Plan.moveMap();
	const steps = Plan.steps(map);
	// Each marker is triggered by a real move and authored once.
	for (const marker of Edits.PLATFORM_MARKERS) {
		assert.ok(map.has(marker.moves), `${marker.file}: ${marker.moves} is no planned move`);
		const source = path.join(REPO, 'tools/audit/structure/markers', marker.file);
		assert.ok(fs.existsSync(source), `${marker.file}: no authored source`);
		assert.match(fs.readFileSync(source, 'utf8'), /^# \S+ \((Linux|macOS|Windows)\)\n/);
	}
	// After every move, each platform domain is on every driver.
	const filled = new Map(Rules.PLATFORM_DOMAINS.map((d) => [d, new Set()]));
	const tracked = [
		...map.values(),
		...[...map.keys()].filter((o) => !map.has(o) || map.get(o) === o)
	];
	for (const file of tracked.filter(Boolean)) {
		const [driver, root, domain] = file.split('/');
		if (DRIVERS.includes(driver) && root === 'platform' && filled.has(domain))
			filled.get(domain).add(driver);
	}
	for (const marker of Edits.PLATFORM_MARKERS) {
		const [driver, , domain] = marker.file.split('/');
		filled.get(domain).add(driver);
	}
	for (const [domain, drivers] of filled)
		if (drivers.size > 0)
			assert.deepEqual([...drivers].sort(), DRIVERS, `platform/${domain} on every driver`);
	// The step that fills a domain writes its markers.
	const s13 = steps.find((s) => s.key === 'platform/desktop_focus');
	if (s13)
		assert.deepEqual(
			Apply.platformMarkers(s13)
				.map((m) => m.file)
				.sort(),
			['macos/platform/desktop_focus/README.md', 'windows/platform/desktop_focus/README.md']
		);
	// Once written, a marker stays where it is: the singleton pass, which
	// retires a code folder holding only a README, leaves a Convention P
	// marker in place. S13 wrote two and retiring them left S14 unnumbered.
	const written = new Map(Edits.PLATFORM_MARKERS.map((m) => [m.file, m.file]));
	written.set('macos/platform/zz_probe_only/README.md', 'macos/platform/zz_probe_only/README.md');
	Plan.foldSingletons(written, new Map());
	for (const m of Edits.PLATFORM_MARKERS) assert.equal(written.get(m.file), m.file, m.file);
	assert.equal(
		written.get('macos/platform/zz_probe_only/README.md'),
		null,
		'an unlisted README-only folder retires'
	);
	console.log(
		'[OK] every platform domain the plan fills is on every driver, by files or a marker.'
	);
}

run();
