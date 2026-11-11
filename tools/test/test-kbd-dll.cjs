// tools/test/test-kbd-dll.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout DLL Tests
 * DESCRIPTION:
 * Proves the Windows layout DLL toolchain (tools/lib/kbd-dll) without Windows:
 * the KLC reader on the official bepo.klc and on the KLC the layout source
 * writes for Ergopti, the four images (x86, wow64, x64, arm64) read back by the
 * independent reader and compared key × level × dead key × ligature with their
 * model, a Kana/Roya model with a chained dead key and a non-BMP ligature,
 * negative controls on corrupted images, model refusals and seeded random
 * models, and byte-identical rebuilds.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { fromKlc } = require('../lib/kbd-dll/klc.cjs');
const Model = require('../lib/kbd-dll/model.cjs');
const C = require('../lib/kbd-dll/constants.cjs');
const { buildDlls, toolchainAvailable } = require('../lib/kbd-dll/build.cjs');
const { readDll, parsePe } = require('../lib/kbd-dll/reader.cjs');
const PeWriter = require('../lib/kbd-dll/pe-writer.cjs');
const { compareLayout } = require('../lib/kbd-dll/compare.cjs');
const { loadLayoutSource } = require('../lib/layout-source.cjs');
const { exportKlc } = require('../lib/layout-source-klc.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const BEPO = path.join(__dirname, 'fixtures', 'kbd-dll', 'bepo.klc');
const clone = (value) => JSON.parse(JSON.stringify(value));
let checks = 0;

assert.ok(
	toolchainAvailable(),
	'clang, llvm-rc and lld-link are required (tools/ci/ubuntu_apt.py clang lld llvm)'
);

/** Every resource leaf of an image as hex, keyed type/name/language (read with the reader's PE parser). */
function resourceLeaves(bytes) {
	const img = parsePe(bytes);
	const root = img.dirs[2].rva;
	const leaves = {};
	const walk = (at, keyPath) => {
		const dir = img.offset(root + at, 16);
		const n = img.b.readUInt16LE(dir + 12) + img.b.readUInt16LE(dir + 14);
		for (let i = 0; i < n; i++) {
			const entry = dir + 16 + 8 * i;
			const id = img.b.readUInt32LE(entry);
			const next = img.b.readUInt32LE(entry + 4);
			if (next & 0x80000000) walk(next & 0x7fffffff, keyPath.concat(id));
			else {
				const data = img.offset(root + next, 16);
				const rva = img.b.readUInt32LE(data);
				const size = img.b.readUInt32LE(data + 4);
				const start = img.offset(rva, size);
				leaves[keyPath.concat(id).join('/')] = img.b.toString('hex', start, start + size);
			}
		}
	};
	walk(0, []);
	return leaves;
}

/**
 * The compiler-free writer (pe-writer.cjs) against the clang image of the same
 * model: the reader reads the same tables (every value it reads, pointers as the
 * tables they name), the same layout, the same resources, and the image carries
 * a valid PE checksum, as the clang one does.
 */
function provePeWriter(model, label, clangDlls) {
	const written = PeWriter.writeDlls(model);
	assert.deepEqual(Object.keys(written), Object.keys(clangDlls));
	for (const [arch, bytes] of Object.entries(written)) {
		const mine = readDll(bytes, { trace: true });
		const clang = readDll(clangDlls[arch], { trace: true });
		assert.deepEqual(mine.trace, clang.trace, `${label} ${arch}: the same tables as clang's`);
		assert.deepEqual(mine.layout, clang.layout, `${label} ${arch}: the same layout as clang's`);
		assert.deepEqual(
			[mine.machine, mine.pointer, mine.wow64, mine.ordinal, mine.subsystem],
			[clang.machine, clang.pointer, clang.wow64, clang.ordinal, clang.subsystem]
		);
		assert.deepEqual(
			resourceLeaves(bytes),
			resourceLeaves(clangDlls[arch]),
			`${label} ${arch} resources`
		);
		for (const image of [bytes, clangDlls[arch]]) {
			const at = image.readUInt32LE(0x3c) + 24 + 64;
			assert.equal(
				PeWriter.peChecksum(image, at),
				image.readUInt32LE(at),
				`${label} ${arch} checksum`
			);
		}
		checks++;
	}
	return written;
}

/** Builds the four images and requires every one to read back as its model. */
function proveBuild(model, label) {
	const { dlls } = buildDlls(model);
	assert.deepEqual(Object.keys(dlls), ['x86', 'wow64', 'x64', 'arm64']);
	const reads = {};
	for (const [arch, bytes] of Object.entries(dlls)) {
		const read = readDll(bytes);
		assert.deepEqual(compareLayout(model, read.layout), [], `${label} ${arch} matches its model`);
		reads[arch] = read;
		checks++;
	}
	provePeWriter(model, label, dlls);
	assert.equal(reads.x86.pointer, 4);
	assert.equal(reads.wow64.pointer, 8, 'the SysWOW64 image stores 64-bit pointers');
	assert.equal(reads.wow64.wow64, true);
	assert.equal(reads.x64.machine, 'x64');
	assert.equal(reads.arm64.machine, 'arm64');
	for (const read of Object.values(reads)) {
		assert.equal(read.ordinal, 1, 'KbdLayerDescriptor is ordinal 1');
		assert.equal(read.subsystem, 1, 'subsystem native');
	}
	return { dlls, reads };
}

// 1. The official bepo.klc reads completely.
const bepo = fromKlc(fs.readFileSync(BEPO));
assert.deepEqual(bepo.columns, [0, 1, 2, 6, 7]);
assert.deepEqual(bepo.flags, ['altgr']);
assert.equal(bepo.keys.length, 50);
assert.equal(bepo.dead_keys.length, 20);
assert.equal(
	bepo.dead_keys.reduce((n, d) => n + d.rules.length, 0),
	814
);
const key = (model, vk) => model.keys.find((k) => k.vk === vk);
assert.deepEqual(key(bepo, C.VK.B).cells, [
	{ char: 0x62 },
	{ char: 0x42 },
	null,
	{ char: 0x7c },
	{ char: 0xa6 }
]);
assert.deepEqual(key(bepo, C.VK.OEM_1).cells[3], { dead: 0xb4 });
assert.equal(key(bepo, C.VK.O).attributes, C.ATTRIBUTES.caplok | C.ATTRIBUTES.caplokaltgr);
assert.deepEqual(bepo.dead_keys.find((d) => d.dead === 0x2d9).rules[0], {
	base: 0x41,
	result: 0x226
});
assert.equal(bepo.dead_keys.find((d) => d.dead === 0xb4).name, 'ACUTE ACCENT');
assert.deepEqual(
	bepo.scancodes.find((s) => s.sc === 0x10),
	{ sc: 0x10, vk: C.VK.B }
);
assert.equal(
	bepo.scancodes.some((s) => s.sc === 0x53),
	false,
	'the keypad decimal keeps its scan code'
);
checks++;
const bepoBuilt = proveBuild(bepo, 'bepo');

// 2. The KLC the layout source writes for the registry Ergopti (ligatures, Shift+Ctrl).
const source = loadLayoutSource();
const imported = source.importKeylayout(
	fs.readFileSync(
		path.join(ROOT, 'static', 'layouts', 'registry', 'ergopti', 'ergopti.keylayout'),
		'utf8'
	),
	'ergopti',
	'iso'
);
imported.exports = { windows: { locale: 'fr-FR', layout_id: '0000040c', dll_name: 'kbdergo' } };
const klc = exportKlc(imported).files.get('kbdergo.klc');
const ergopti = fromKlc(klc);
assert.deepEqual(ergopti.columns, [0, 1, 2, 3, 6, 7]);
assert.ok(
	ergopti.keys.filter((k) => k.cells.some((c) => c && c.ligature)).length >= 9,
	'Ergopti ligatures'
);
checks++;
proveBuild(ergopti, 'ergopti');

// 3. Kana and Roya columns, a chained dead key and a non-BMP ligature.
const kana = clone(bepo);
kana.dll_name = 'kbdkana';
kana.columns.push(C.MOD_BITS.kana, C.MOD_BITS.kana | C.MOD_BITS.shift, C.MOD_BITS.roya);
kana.keys.forEach((k) => {
	k.cells.push(null, null, null);
	if (k.caps_cells) k.caps_cells.push(null, null, null);
});
key(kana, C.VK.A).cells[5] = { char: 0x3042 };
key(kana, C.VK.A).cells[6] = { char: 0x30a2 };
key(kana, C.VK.A).attributes |= C.ATTRIBUTES.kanalok;
key(kana, C.VK.U).cells[7] = { ligature: [0xd83d, 0xde00] };
key(kana, C.VK.I).cells[5] = { dead: 0x2d9 };
// Dot above, then a base it does not compose, enters dot below: a two-step chain.
const dotAbove = kana.dead_keys.find((d) => d.dead === 0x2d9);
const chainBase = [0x2d8, 0x2c7, 0x2603].find((u) => !dotAbove.rules.some((r) => r.base === u));
dotAbove.rules.push({ base: chainBase, result: 0x323, dead: true });
const kanaBuilt = proveBuild(kana, 'kana');
assert.deepEqual(
	kanaBuilt.reads.x64.layout.modifiers.map((m) => [m.vk, m.bit]),
	[
		[C.VK.SHIFT, 1],
		[C.VK.CONTROL, 2],
		[C.VK.MENU, 4],
		[C.VK.KANA, 8],
		[C.VK.OEM_FJ_ROYA, 16]
	],
	'Kana and Roya are modifier bits'
);

// 4. Negative controls: a changed character is a difference, a broken pointer a refusal.
{
	const x64 = Buffer.from(bepoBuilt.dlls.x64);
	// The bépo B row: VK_B, CAPLOK, b, B, none, |, ¦.
	const row = Buffer.from([C.VK.B, 0x01, 0x62, 0, 0x42, 0, 0x00, 0xf0, 0x7c, 0, 0xa6, 0]);
	const at = x64.indexOf(row);
	assert.ok(at > 0, 'the B row is in the image');
	const changed = Buffer.from(x64);
	changed[at + 8] = 0x7d;
	const diffs = compareLayout(bepo, readDll(changed).layout);
	assert.equal(diffs.length, 1);
	assert.match(diffs[0].path, /vk=0x42.*cells\[6\]/);
	const broken = Buffer.from(x64);
	const pe = broken.readUInt32LE(0x3c);
	broken.writeUInt16LE(0x1234, pe + 4);
	assert.throws(() => readDll(broken), /unknown machine/);
	const noExport = Buffer.from(x64);
	const name = noExport.indexOf(Buffer.from('KbdLayerDescriptor\0', 'latin1'));
	noExport.write('X', name, 'latin1');
	assert.throws(() => readDll(noExport), /not exported/);
	checks += 3;
}

// 5. Invalid models are refused before any file is written.
const refuses = (mutate, code) => {
	const model = clone(bepo);
	mutate(model);
	assert.throws(
		() => Model.check(model),
		(error) => error.code === code,
		code
	);
	checks++;
};
refuses((m) => (key(m, C.VK.B).cells[0] = { dead: 0x1234 }), 'kbd_dead_undeclared');
refuses((m) => (key(m, C.VK.B).cells[0] = { char: C.WCH.DEAD }), 'kbd_unit_reserved');
refuses((m) => (key(m, C.VK.B).cells[0] = { char: 0x10000 }), 'kbd_unit_invalid');
refuses(
	(m) => (key(m, C.VK.B).cells[0] = { ligature: Array(16).fill(0x61) }),
	'kbd_ligature_length'
);
refuses((m) => (key(m, C.VK.B).cells = key(m, C.VK.B).cells.slice(1)), 'kbd_cells_count');
refuses((m) => m.keys.push(clone(key(m, C.VK.B))), 'kbd_key_duplicate');
refuses((m) => (key(m, C.VK.B).attributes |= C.ATTRIBUTES.sgcaps), 'kbd_sgcaps_row');
refuses(
	(m) => m.dead_keys[0].rules.push({ base: 0x2603, result: 0x1111, dead: true }),
	'kbd_dead_chain_undeclared'
);
refuses((m) => m.columns.push(0x40), 'kbd_column_bits');
refuses((m) => (m.columns = Array.from({ length: 127 }, (_, i) => i)), 'kbd_columns');
refuses((m) => (m.dll_name = 'Kbd Bepo'), 'kbd_dll_name');

// 6. Seeded random models: every valid one builds and reads back as itself.
let seed = 20261111;
const random = (n) => {
	seed = (seed * 1103515245 + 12345) & 0x7fffffff;
	return seed % n;
};
for (let round = 0; round < 3; round++) {
	const model = clone(bepo);
	model.dll_name = `kbdfz${round}`;
	for (const k of model.keys)
		k.cells = k.cells.map((cell) => {
			const roll = random(10);
			if (roll === 0) return null;
			if (roll === 1) return { ligature: [0x61 + random(20), 0x62, 0x63].slice(0, 2 + random(2)) };
			if (roll === 2) return { char: 0x100 + random(0xd000) };
			return cell;
		});
	proveBuild(model, `random ${round}`);
}

// 7. Reproducible: the same model gives the same bytes, with clang and without.
const again = buildDlls(bepo).dlls;
for (const arch of Object.keys(again))
	assert.ok(again[arch].equals(bepoBuilt.dlls[arch]), `${arch} is reproducible`);
const writtenOnce = PeWriter.writeDlls(bepo);
const writtenTwice = PeWriter.writeDlls(bepo);
for (const arch of Object.keys(writtenOnce))
	assert.ok(writtenOnce[arch].equals(writtenTwice[arch]), `${arch} written reproducibly`);
checks++;

// 7b. The CLI's verified build without the toolchain: the same checks, writer pe.
{
	const { buildVerified } = require('../kbd-dll.cjs');
	const built = buildVerified(bepo, 'pe');
	assert.equal(built.report.writer, 'pe');
	assert.equal(built.sources, null, 'no C, resource script or module definition is needed');
	for (const arch of Object.keys(writtenOnce))
		assert.ok(built.dlls[arch].equals(writtenOnce[arch]), `${arch} is the writer's image`);
	assert.throws(() => buildVerified(bepo, 'msvc'), /unknown writer/);
	checks++;
}

// 8. Negative control for the writer proof: one changed table byte changes the trace.
{
	const x64 = Buffer.from(writtenOnce.x64);
	const row = Buffer.from([C.VK.B, 0x01, 0x62, 0, 0x42, 0]);
	const at = x64.indexOf(row);
	assert.ok(at > 0, 'the B row is in the written image');
	x64[at + 2] = 0x63;
	assert.notDeepEqual(
		readDll(x64, { trace: true }).trace,
		readDll(bepoBuilt.dlls.x64, { trace: true }).trace,
		'a changed character is a different trace'
	);
	checks++;
}

console.log(
	`[OK] kbd dll: ${checks} checks (bepo.klc and Ergopti KLC golden on x86, wow64, x64, arm64; the compiler-free writer equal to clang in tables, layout, resources and checksum; Kana/Roya; controls; refusals; random models)`
);
