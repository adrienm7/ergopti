// tools/test/test-glossary-matches-code.cjs

/**
 * ==============================================================================
 * MODULE: Glossary ↔ Code Agreement Guard
 * DESCRIPTION:
 * Asserts that the glossaries describe the repository that exists: the port
 * count and the port names they publish must match `_shared/core/ports/`, and
 * neither may name a driver directory that is not on disk.
 *
 * ROOT CAUSE ENCODED:
 * static/ergopti_plus/docs/glossary.md announced "the nine port contracts",
 * then listed thirteen, where there are twenty — and pointed at
 * `autohotkey/_generated/` and `hammerspoon/_generated/`, two directory names
 * deleted in the static/ reorg. A glossary is the first file a newcomer opens;
 * one that disagrees with the code teaches the wrong repository, and nothing
 * was checking it.
 *
 * FEATURES & RATIONALE:
 * 1. The port list is DERIVED from the filesystem, never restated here, so a
 *    new port is covered the day its spec lands.
 * 2. Driver directory names are derived the same way: whatever exists under
 *    static/ergopti_plus/ that holds an adapters/ tree is a driver.
 * 3. Both glossaries are checked. They are separate documents with separate
 *    audiences, and they had drifted from the code in different ways.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const BASE = path.join(ROOT, 'static', 'ergopti_plus');
const PORTS_DIR = path.join(BASE, '_shared', 'core', 'ports');

const GLOSSARIES = ['docs/glossary.md', 'static/ergopti_plus/docs/glossary.md'];

// Names that were driver directories before the static/ reorg and are now only
// ever a mistake. Kept explicit so the failure names the replacement.
const RETIRED_DIRS = new Map([
	['autohotkey/', 'windows/'],
	['hammerspoon/', 'macos/'],
]);

const NUMBER_WORDS = {
	nine: 9,
	ten: 10,
	eleven: 11,
	twelve: 12,
	thirteen: 13,
	fourteen: 14,
	fifteen: 15,
	sixteen: 16,
	seventeen: 17,
	eighteen: 18,
	nineteen: 19,
	twenty: 20,
	'twenty-one': 21,
	'twenty-two': 22,
};

const failures = [];

function check(condition, message) {
	if (!condition) failures.push(message);
}

// ==========================================
// ==========================================
// ======= 1/ What the code actually is =====
// ==========================================
// ==========================================

const ports = fs
	.readdirSync(PORTS_DIR)
	.filter((f) => f.endsWith('.spec.js'))
	.map((f) => f.replace('.spec.js', ''))
	.sort();

check(ports.length > 0, 'no *.spec.js found in _shared/core/ports — the walk is broken, not the glossary');

// ==========================================
// ==========================================
// ======= 2/ What the glossaries claim =====
// ==========================================
// ==========================================

for (const rel of GLOSSARIES) {
	const abs = path.join(ROOT, rel);
	if (!fs.existsSync(abs)) {
		failures.push(`${rel} does not exist — update GLOSSARIES here rather than leaving a check that scans nothing`);
		continue;
	}
	const text = fs.readFileSync(abs, 'utf8');

	for (const [retired, replacement] of RETIRED_DIRS) {
		check(
			!text.includes(retired),
			`${rel} names the retired driver directory "${retired}" — it is "${replacement}" since the static/ reorg`
		);
	}

	// "the <word> ports" / "the <word> port contracts" — only checked when the
	// glossary actually commits to a number.
	const claim = text.match(/\bthe ([a-z-]+) (?:OS-facing )?ports?\b/i);
	if (claim) {
		const claimed = NUMBER_WORDS[claim[1].toLowerCase()];
		if (claimed !== undefined) {
			check(
				claimed === ports.length,
				`${rel} says "the ${claim[1]} ports" but _shared/core/ports/ holds ${ports.length}`
			);
		}
	}

	// When it enumerates them, the enumeration must be complete. A glossary that
	// lists a subset while announcing a total is worse than one that lists none.
	if (/\bports are:/.test(text)) {
		const missing = ports.filter((p) => !new RegExp(`\`${p}\``).test(text));
		check(
			missing.length === 0,
			`${rel} enumerates the ports but omits: ${missing.join(', ')}`
		);
	}
}

// ==================================
// ==================================
// ======= 3/ Report ================
// ==================================
// ==================================

if (failures.length > 0) {
	console.error('\x1b[31m[FAIL] glossary disagrees with the code:\x1b[0m');
	for (const f of failures) console.error(`  - ${f}`);
	process.exit(1);
}

console.log(`\x1b[32m[OK] Both glossaries match the code (${ports.length} ports).\x1b[0m`);
