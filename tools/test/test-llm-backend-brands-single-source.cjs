// tools/test/test-llm-backend-brands-single-source.cjs

/**
 * ==============================================================================
 * MODULE: AI Backend Brand Single-Source Guard
 * DESCRIPTION:
 * The brand and emoji of every AI backend live in
 * _shared/modules/llm/backends.json. The tray's model button on Windows, macOS
 * and Linux reads "<emoji> <model>" from it, and the model selector page draws
 * the same emoji, injected by the drivers.
 *
 * ROOT CAUSE ENCODED:
 * Each driver typed its own "Ollama 🦙" (five copies on macOS alone), so a new
 * emoji would have reached one tray and not the others. This guard fails when a
 * production file types a brand with its emoji outside the reviewed log-label
 * sites, when a reader stops naming the shared file, when the three caption
 * builders stop putting the emoji first, or when the page hardcodes an emoji.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const brands = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared', 'modules', 'llm', 'backends.json'), 'utf8')
);

// Log-label sites of the prediction engines: they name the backend in a log
// line, not in the UI, and are compared to the shared file below.
const REVIEWED_LITERAL_SITES = new Set([
	'macos/modules/llm/prediction_engine.lua',
	'windows/modules/llm/prediction_exec.ahk'
]);

const READERS = {
	'macos/ui/menu/menu_llm/backend_labels.lua': 'modules/llm/backends.json',
	'windows/modules/llm/models.ahk': 'LLM_GetSharedPath("backends.json")',
	'linux/modules/llm/backend_brands.lua': 'modules/llm/backends.json'
};

/** Collects the production sources of the three drivers and the shared tree. */
function collect(dir, acc) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (/^(tests|_generated|vendor|node_modules|locales)$/.test(entry.name)) continue;
			collect(full, acc);
		} else if (/\.(lua|ahk|js)$/.test(entry.name)) {
			acc.push(full);
		}
	}
	return acc;
}

const ids = brands.order;
assert.deepEqual(
	[...ids].sort(),
	Object.keys(brands.backends).sort(),
	'backends.json orders exactly the backends it declares'
);
for (const id of ids) {
	const entry = brands.backends[id];
	assert.equal(typeof entry.brand, 'string', `${id} has a brand`);
	assert.equal(typeof entry.emoji, 'string', `${id} has an emoji`);
	assert.ok(['local', 'remote'].includes(entry.kind), `${id} declares its kind`);
}

const literals = ids.map((id) => `${brands.backends[id].brand} ${brands.backends[id].emoji}`);
const offenders = [];
for (const file of collect(SP, [])) {
	const rel = path.relative(SP, file).split(path.sep).join('/');
	if (rel.startsWith('_shared/ui/vendor')) continue;
	const source = fs.readFileSync(file, 'utf8');
	for (const literal of literals) {
		if (!source.includes(literal)) continue;
		if (REVIEWED_LITERAL_SITES.has(rel)) continue;
		// A documentation comment that quotes the label is not a second copy.
		const codeLines = source
			.split(/\r?\n/)
			.filter((line) => line.includes(literal))
			.filter((line) => !/^\s*(--|;|\/\/|\*|\/\*)/.test(line));
		if (codeLines.length > 0) offenders.push(`${rel}: ${literal}`);
	}
}
assert.deepEqual(offenders, [], 'a backend brand and emoji are typed outside backends.json');

for (const rel of REVIEWED_LITERAL_SITES) {
	const source = fs.readFileSync(path.join(SP, rel), 'utf8');
	for (const match of source.matchAll(/"(Ollama|MLX|API) ([^"\s]+)"/g)) {
		const id = Object.keys(brands.backends).find((key) => brands.backends[key].brand === match[1]);
		assert.equal(
			match[2],
			brands.backends[id].emoji,
			`${rel} names ${match[1]} with the shared emoji`
		);
	}
}

for (const [rel, needle] of Object.entries(READERS)) {
	const source = fs.readFileSync(path.join(SP, rel), 'utf8');
	assert.ok(source.includes(needle), `${rel} reads the shared brand file`);
}

// The three button builders put the emoji first, then one space, then the model.
const mac = fs.readFileSync(path.join(SP, READERS_KEY('macos')), 'utf8');
assert.match(mac, /return emoji \.\. " " \.\. model_text/, 'macOS button: emoji first');
const win = fs.readFileSync(path.join(SP, 'windows/modules/llm/models.ahk'), 'utf8');
assert.match(
	win,
	/return LLM_BackendEmoji\(BackendId\) \. " " \. ModelText/,
	'Windows button: emoji first'
);
const lin = fs.readFileSync(path.join(SP, 'linux/modules/llm/backend_brands.lua'), 'utf8');
assert.match(
	lin,
	/return M\.emoji\(backend\) \.\. " " \.\. model_text/,
	'Linux button: emoji first'
);

// The page draws what the driver injects; it types no emoji of its own.
const page = fs.readFileSync(path.join(SP, '_shared/ui/model_browser/script.js'), 'utf8');
for (const id of ids) {
	assert.ok(!page.includes(brands.backends[id].emoji), `the page hardcodes the ${id} emoji`);
}

/** The macOS reader path. */
function READERS_KEY(driver) {
	return Object.keys(READERS).find((rel) => rel.startsWith(driver + '/'));
}

console.log(
	`[OK] backend brands: ${ids.length} backends from backends.json, ${Object.keys(READERS).length} readers, emoji-first buttons.`
);
