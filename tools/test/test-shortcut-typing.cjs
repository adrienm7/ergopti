// tools/test/test-shortcut-typing.cjs

/**
 * The « typed with the Ergopti+ shortcuts » transform
 * (_shared/ui/layout_analysis/shortcut_typing.js): replays the shared vectors
 * (_shared/tests/corpus/layout_analysis/shortcut_typing_vectors.json) on the
 * generated catalogue, checks that expanding the stream through the same
 * hotstrings gives the clean text back (vectors, a seeded property test and a
 * slice of a built-in corpus), that only the enabled sections and the personal
 * hotstrings are used, the magic key's layout rule against
 * magic_key_vectors.json, and that the generated catalogue is current.
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '../..');
const SHARED = path.join(ROOT, 'static/ergopti_plus/_shared');
const MODULE = path.join(SHARED, 'ui/layout_analysis/shortcut_typing.js');
const CATALOGUE = path.join(SHARED, 'ui/layout_analysis/_generated/hotstring_catalogue.js');
const VECTORS = path.join(SHARED, 'tests/corpus/layout_analysis/shortcut_typing_vectors.json');
const MAGIC_VECTORS = path.join(SHARED, 'tests/corpus/hotstrings/magic_key_vectors.json');
const CORPORA = path.join(SHARED, 'layouts/data/analysis/corpora.json');
const { buildCatalogue, buildSource } = require('../codegen/codegen-hotstring-catalogue-js.cjs');
// The built-in corpus a slice of which is typed and expanded back.
const SLICE_CORPUS = 'fr_swann';
const SLICE_CHARS = 40000;
// The seeded property test's size.
const PROPERTY_RUNS = 300;
const PROPERTY_SEED = 20261126;

const sandbox = {};
vm.createContext(sandbox);
for (const file of [CATALOGUE, MODULE])
	vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
const T = vm.runInContext('LAYOUT_SHORTCUT_TYPING', sandbox);
const C = vm.runInContext('LAYOUT_HOTSTRING_CATALOGUE', sandbox);

// Values made in the vm context have its prototypes: compare their JSON.
function same(actual, expected, message) {
	assert.strictEqual(JSON.stringify(actual), JSON.stringify(expected), message);
}

let failures = 0;
function check(name, fn) {
	try {
		fn();
		console.log(`  ok  ${name}`);
	} catch (error) {
		failures += 1;
		console.error(`  FAIL ${name}: ${error.message}`);
	}
}

/** The registry of these sections and personal hotstrings. */
function registry(sections, personal) {
	return T.compile(T.catalogueMappings(C, sections).concat(T.personalMappings(personal || [])), {
		terminators: C.terminators
	});
}

// 1/ The generated catalogue is the codegen's output.
check('generated catalogue is current', () => {
	assert.strictEqual(fs.readFileSync(CATALOGUE, 'utf8'), buildSource(buildCatalogue()));
});

// 2/ Shared vectors.
for (const v of JSON.parse(fs.readFileSync(VECTORS, 'utf8')).vectors)
	check(`vector ${v.id}`, () => {
		const reg = registry(v.sections, v.personal);
		const out = T.toTyped(v.text, reg);
		assert.strictEqual(out.typed, v.typed);
		same(out.undos, v.undos);
		assert.strictEqual(out.report.saved, v.saved);
		const used = {};
		for (const t of out.report.triggers) used[t.trigger] = (used[t.trigger] || 0) + t.count;
		const sorted = (o) => Object.fromEntries(Object.entries(o).sort());
		same(sorted(used), sorted(v.used));
		for (const trigger of v.absent || []) assert(!(trigger in used), `${trigger} used`);
		assert.strictEqual(T.expand(out.typed, reg, out.undos), v.text);
	});

// 3/ A disabled section is never used; a personal hotstring is.
check('only enabled sections and personal hotstrings', () => {
	const text = 'Elle a dit que c’est très bien, ma Studio Ergopti.';
	const enabled = ['french_magickey.text_expansion'];
	const personal = [{ trigger: 'se★', output: 'Studio Ergopti', is_word: true, auto_expand: true }];
	const out = T.toTyped(text, registry(enabled, personal));
	const sources = new Set(out.report.triggers.map((t) => t.source));
	same([...sources].sort(), [T.PERSONAL_SOURCE, ...enabled].sort());
	assert.throws(() => T.catalogueMappings(C, ['no_group.no_section']), /section_unknown/);
});

// 4/ Property: expanding the stream gives the text back, whatever is enabled.
check('expand(toTyped(text)) is the text (seeded)', () => {
	let seed = PROPERTY_SEED;
	const random = () => {
		seed = (seed * 1103515245 + 12345) % 2147483648;
		return seed / 2147483648;
	};
	const pick = (list) => list[Math.floor(random() * list.length)];
	const usable = C.sections.filter((s) => s.entries.length > 0);
	const outputs = usable
		.flatMap((s) => s.entries.map((e) => e[1]))
		.filter((o) => !/[{}\n\t\r]/.test(o));
	const filler = [
		'le',
		'la',
		'Ça',
		'élan',
		"l'ami",
		'qu’il',
		'c’est',
		',',
		'.',
		' ',
		' ',
		' ',
		'\n',
		':',
		'!',
		'MAIS'
	];
	for (let run = 0; run < PROPERTY_RUNS; run++) {
		const sections = usable.filter(() => random() < 0.3).map((s) => s.id);
		const reg = registry(sections, []);
		let text = '';
		const words = 3 + Math.floor(random() * 12);
		for (let w = 0; w < words; w++) {
			const word = random() < 0.5 ? pick(outputs) : pick(filler);
			text += (random() < 0.2 ? word.toUpperCase() : word) + pick([' ', ' ', '', ', ', '. ']);
		}
		const out = T.toTyped(text, reg);
		assert.strictEqual(
			T.expand(out.typed, reg, out.undos),
			text,
			`run ${run}: ${JSON.stringify(text)}`
		);
		assert(out.report.keystrokes === Array.from(out.typed).length + out.undos.length);
	}
});

// 5/ A slice of a built-in corpus with every section enabled.
check(`${SLICE_CORPUS} slice round trip, every section`, () => {
	const spec = JSON.parse(fs.readFileSync(CORPORA, 'utf8')).corpora.find(
		(c) => c.id === SLICE_CORPUS
	);
	const text = T.sourceText(fs.readFileSync(path.join(ROOT, spec.file), 'utf8'), spec).slice(
		0,
		SLICE_CHARS
	);
	const reg = registry(
		C.sections.map((s) => s.id),
		[]
	);
	const out = T.toTyped(text, reg);
	assert.strictEqual(T.expand(out.typed, reg, out.undos), text);
	assert(out.report.saved > 0, 'nothing saved');
});

// 6/ The magic key's character on a layout, as the drivers choose it.
check('layoutMagicChar replays magic_key_vectors.json', () => {
	const vectors = JSON.parse(fs.readFileSync(MAGIC_VECTORS, 'utf8'));
	assert.strictEqual(C.magic_key.fallback, vectors.fallback);
	for (const v of vectors.layout_default)
		assert.strictEqual(
			T.layoutMagicChar((code) => (code in v.base ? v.base[code] : null), C.magic_key),
			v.expected,
			v.id
		);
});

check('withMagicChar renames ★ and merges counts', () => {
	const tables = { chars: { '★': 2, ù: 1, a: 3 }, bigrams: { 'a★': 2 }, trigrams: { 'aa★': 1 } };
	assert.strictEqual(T.withMagicChar(tables, '★'), tables);
	const renamed = T.withMagicChar(tables, 'ù');
	same(renamed.chars, { ù: 3, a: 3 });
	same(renamed.bigrams, { aù: 2 });
	same(renamed.trigrams, { aaù: 1 });
});

check('undo without a fire is refused', () => {
	assert.throws(() => T.expand('ab', registry([], []), [0]), /undo_without_fire/);
});

if (failures) {
	console.error(`test-shortcut-typing: ${failures} failure(s)`);
	process.exit(1);
}
console.log('test-shortcut-typing: all checks passed');
