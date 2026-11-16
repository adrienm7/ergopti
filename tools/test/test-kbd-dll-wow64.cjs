// tools/test/test-kbd-dll-wow64.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout DLL WOW64 ABI Tests
 * DESCRIPTION:
 * Proves, with no compiler, that the compiler-free writer's SysWOW64 image
 * (pe-writer.cjs, the one the site and CI build) follows Microsoft's WOW64
 * keyboard layout ABI: kbd.h's KBD_LONG_POINTER is 64 bits wide under
 * BUILD_WOW6432, for the table pointers and for KbdLayerDescriptor's return.
 * The reference is the MSVC + Windows SDK wow64 build of the registry Ergopti
 * (kbdergop-wow64-msvc.dll, from the builder's own cl/rc/link steps) and the
 * .klc the same generator writes for it (kbdergop.klc, see the NOTICE).
 *
 * FEATURES & RATIONALE:
 * 1. Structure: the same export at ordinal 1, the same descriptor code
 *    (mov eax, imm32; cdq; ret: 64 bits in EDX:EAX), 64-bit table pointers
 *    with a zero high word, and the same tables once read back: every key
 *    and column (wherever each image puts its system keys), dead key, name,
 *    scan code, modifier and locale flag.
 * 2. The differences that are choices, pinned so a change is seen: dwType 4
 *    against MSVC's (and Microsoft's) 0, and MSVC's writable .data against
 *    this tool's read-only tables.
 * 3. The reader takes Microsoft's form and refuses a truncated one: a wow64
 *    image whose descriptor returns EAX alone, or a native x86 image that
 *    returns 64 bits. On Windows, Microsoft's own SysWOW64 KBDFR.DLL reads.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { fromKlc } = require('../lib/kbd-dll/klc.cjs');
const PeWriter = require('../lib/kbd-dll/pe-writer.cjs');
const { readDll, parsePe } = require('../lib/kbd-dll/reader.cjs');
const { compareLayout } = require('../lib/kbd-dll/compare.cjs');

const FIXTURES = path.join(__dirname, 'fixtures', 'kbd-dll');
const MSVC_WOW64 = fs.readFileSync(path.join(FIXTURES, 'kbdergop-wow64-msvc.dll'));
const model = fromKlc(fs.readFileSync(path.join(FIXTURES, 'kbdergop.klc')));
const written = PeWriter.writeDlls(model);
const WOW64 = Buffer.from(written.wow64);
const X86 = Buffer.from(written.x86);
// The KBDTABLES pointers both images set (MSVC's and the writer's Ergopti).
const TABLE_POINTERS = Object.freeze([
	'pCharModifiers',
	'pVkToWcharTable',
	'pDeadKey',
	'pKeyNames',
	'pKeyNamesExt',
	'pKeyNamesDead',
	'pusVSCtoVK',
	'pVSCtoVK_E0',
	'pVSCtoVK_E1',
	'pLigature',
	'pVkToBit'
]);
let checks = 0;

/** KbdLayerDescriptor's bytes up to its ret, the address it loads zeroed, and that address. */
function descriptor(bytes) {
	const img = parsePe(bytes);
	const exp = img.exports.find((e) => e.name === 'KbdLayerDescriptor');
	const at = img.offset(exp.rva, 8);
	const code = Buffer.from(img.b.subarray(at, at + 8));
	const tables = code.readUInt32LE(1) - img.imageBase;
	code.fill(0, 1, 5);
	return {
		at,
		code: [...code.subarray(0, code.indexOf(0xc3, 5) + 1)],
		tables,
		exports: img.exports.map((e) => [e.name, e.ordinal])
	};
}

/** Every key of every character table by virtual key, its cells padded to the columns. */
function keyTable(layout) {
	const keys = new Map();
	for (const key of layout.keys.concat(layout.extra_keys)) {
		assert.ok(!keys.has(key.vk), `vk 0x${key.vk.toString(16)} is in one table only`);
		const cells = layout.columns.map((_, c) => (key.cells[c] === undefined ? null : key.cells[c]));
		keys.set(key.vk, { attributes: key.attributes, cells, caps_cells: key.caps_cells || null });
	}
	return [...keys].sort((a, b) => a[0] - b[0]);
}

// 1. The reference is what the TODO finding recorded: MSVC's wow64 returns EDX:EAX.
const msvc = readDll(MSVC_WOW64, { foreign: true });
assert.deepEqual(
	[msvc.machine, msvc.pointer, msvc.wow64, msvc.descriptor_bits],
	['x86', 8, true, 64],
	'the MSVC fixture is a wow64 image'
);
checks++;

// 2. The writer's wow64 image has the same export, descriptor code and pointer widths.
const mine = readDll(WOW64);
assert.deepEqual(
	[mine.machine, mine.pointer, mine.wow64, mine.descriptor_bits, mine.ordinal],
	[msvc.machine, msvc.pointer, msvc.wow64, msvc.descriptor_bits, msvc.ordinal]
);
assert.deepEqual(descriptor(WOW64).exports, [['KbdLayerDescriptor', 1]]);
assert.deepEqual(descriptor(WOW64).exports, descriptor(MSVC_WOW64).exports);
assert.deepEqual(
	descriptor(WOW64).code,
	[0xb8, 0, 0, 0, 0, 0x99, 0xc3],
	'mov eax, imm32; cdq; ret (wow64-descriptor-64)'
);
assert.deepEqual(descriptor(WOW64).code, descriptor(MSVC_WOW64).code, "MSVC's descriptor code");
assert.deepEqual(descriptor(X86).code, [0xb8, 0, 0, 0, 0, 0xc3], 'the x86 image keeps 32 bits');
assert.equal(readDll(X86).descriptor_bits, 32);
// Every KBDTABLES pointer of both images was read as 8 bytes with a zero high word.
for (const read of [mine, msvc])
	for (const field of TABLE_POINTERS) assert.ok(read.checks.includes(field), field);
checks++;

// 3. The same tables: every key x column, dead key, name, scan code and modifier.
assert.deepEqual(compareLayout(model, mine.layout), [], 'the writer image is its model');
assert.deepEqual(keyTable(mine.layout), keyTable(msvc.layout), 'every key and column');
for (const field of [
	'columns',
	'modifiers',
	'flags',
	'dead_keys',
	'key_names',
	'key_names_ext',
	'e0',
	'e1'
])
	assert.deepEqual(mine.layout[field], msvc.layout[field], field);
// MSVC's generator ends the scan-code table at 0x7E; the writer's adds 0x7F.
assert.equal(msvc.layout.scancodes.length, 0x7f);
assert.deepEqual(mine.layout.scancodes.slice(0, 0x7f), msvc.layout.scancodes, 'scan codes');
checks++;

// 4. The choices that differ, pinned: dwType and the tables' section.
assert.equal(mine.keyboard_type, 4, 'KEYBOARD_TYPE_GENERIC_101; kbd.h calls dwType optional');
assert.equal(msvc.keyboard_type, 0, 'MSVC and Microsoft leave dwType 0');
assert.throws(() => readDll(MSVC_WOW64), /writable section/, "MSVC's merged .data is writable");
checks++;

// 5. A truncated wow64 descriptor (EAX alone) is refused, in either image.
const truncate = (bytes) => {
	const out = Buffer.from(bytes);
	const { at, code } = descriptor(out);
	assert.equal(code.length, 7);
	out[at + 5] = 0xc3;
	return out;
};
assert.throws(() => readDll(truncate(WOW64)), /wow64 KbdLayerDescriptor returns 32 bits/);
assert.throws(
	() => readDll(truncate(MSVC_WOW64), { foreign: true }),
	/wow64 KbdLayerDescriptor returns 32 bits/
);
// And a native x86 image returning 64 bits.
const widened = Buffer.from(X86);
const x86At = descriptor(widened).at;
widened[x86At + 5] = 0x99;
widened[x86At + 6] = 0xc3;
assert.throws(() => readDll(widened), /32-bit KbdLayerDescriptor returns 64 bits/);
checks++;

// 6. KBDFR.DLL-shaped data: Microsoft's SysWOW64 KBDFR keeps its tables in the code
// section (.data, code|execute|read) and dwType 0. The writer's image made that way reads
// as a foreign image, with the same layout, and is refused as this tool's own.
{
	const shaped = Buffer.from(WOW64);
	const img = parsePe(shaped);
	const pe = shaped.readUInt32LE(0x3c);
	const table = pe + 24 + shaped.readUInt16LE(pe + 20);
	const tablesSection = img.sections.findIndex(
		(s) => descriptor(shaped).tables >= s.rva && descriptor(shaped).tables < s.rva + s.vsize
	);
	shaped.writeUInt32LE(0x60000020, table + 40 * tablesSection + 36);
	// dwType: after the two BYTEs and the 8-byte pLigature that follow fLocaleFlags (offset 80).
	const typeAt = img.offset(descriptor(shaped).tables + 96, 4);
	assert.equal(shaped.readUInt32LE(typeAt), 4);
	shaped.writeUInt32LE(0, typeAt);
	const read = readDll(shaped, { foreign: true });
	assert.equal(read.keyboard_type, 0);
	assert.equal(read.descriptor_bits, 64);
	assert.deepEqual(read.layout, mine.layout);
	assert.throws(() => readDll(shaped), /pointer into a code or writable section/);
	checks++;
}

// 7. Microsoft's own SysWOW64 layouts, where this runs on 64-bit Windows.
const system = process.env.SystemRoot || process.env.SYSTEMROOT || 'C:\\Windows';
const microsoft = ['KBDFR.DLL', 'KBDUS.DLL'].map((f) => path.join(system, 'SysWOW64', f));
if (process.platform === 'win32' && microsoft.every((f) => fs.existsSync(f))) {
	for (const file of microsoft) {
		const read = readDll(fs.readFileSync(file), { foreign: true });
		assert.deepEqual(
			[read.machine, read.pointer, read.wow64, read.descriptor_bits, read.keyboard_type],
			['x86', 8, true, 64, 0],
			file
		);
		checks++;
	}
} else console.log('[SKIP] no SysWOW64 layouts here: Microsoft DLL read is Windows-only');

console.log(
	`[OK] kbd dll wow64: ${checks} checks (the writer's SysWOW64 image against the MSVC build: export, 64-bit descriptor and pointers, tables; truncated descriptors refused; KBDFR-shaped data read)`
);
