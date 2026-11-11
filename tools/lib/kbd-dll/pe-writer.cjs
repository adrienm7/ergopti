// tools/lib/kbd-dll/pe-writer.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout DLL PE Writer
 * DESCRIPTION:
 * Writes the four Windows keyboard layout DLL images of a kbd tables model
 * directly, with no compiler, linker or resource compiler, so a page or a PC
 * without the LLVM toolchain can build them. The tables are the C emitter's
 * (emit-c.cjs mainRows, modNumbers, scanTable), laid out as the C structures
 * that emitter declares: natural alignment, pointers of 4 bytes (x86) or 8
 * (x64, arm64, and wow64, whose kbd.h pointers are 64 bits wide in a 32-bit
 * image). The resources are the ones emitRc describes: string 1000 (the
 * Layout Display Name) and the keyboard-driver version resource.
 *
 * FEATURES & RATIONALE:
 * 1. The images the loader expects from Microsoft's layout DLLs: a DLL with no
 *    entry point, subsystem native, read-only tables, KbdLayerDescriptor at
 *    ordinal 1 returning &KbdTables, base relocations for every table pointer
 *    (HIGHLOW in a 32-bit image, DIR64 in a 64-bit one) and the PE checksum.
 * 2. The same code the clang build produces for KbdLayerDescriptor: mov eax /
 *    ret (x86), lea rax,[rip] / ret (x64), adrp / add / ret (arm64), which the
 *    independent reader (reader.cjs) decodes.
 * 3. Deterministic: the same model gives the same bytes (no timestamp).
 * ==============================================================================
 */

'use strict';

const C = require('./constants.cjs');
const Model = require('./model.cjs');
const Emit = require('./emit-c.cjs');

const SECTION_ALIGN = 0x1000;
const FILE_ALIGN = 0x200;
const HEADERS_SIZE = 0x400;
const PE_OFFSET = 0x40;
const RESOURCE_LANGUAGE = 0x409;
const RT_STRING = 6;
const RT_VERSION = 16;
const REL_HIGHLOW = 3;
const REL_DIR64 = 10;
const SCN = Object.freeze({
	code: 0x60000020,
	rdata: 0x40000040,
	reloc: 0x42000040
});

// Each image: machine, PE32+ or not, pointer width, base and characteristics,
// as lld-link writes them for /dll /noentry /subsystem:native.
const IMAGES = Object.freeze({
	x86: { machine: 0x014c, plus: false, width: 4, base: 0x10000000, chars: 0x2102, dll: 0x0540 },
	wow64: { machine: 0x014c, plus: false, width: 8, base: 0x10000000, chars: 0x2102, dll: 0x0540 },
	x64: { machine: 0x8664, plus: true, width: 8, base: 0x180000000, chars: 0x2022, dll: 0x0160 },
	arm64: { machine: 0xaa64, plus: true, width: 8, base: 0x180000000, chars: 0x2022, dll: 0x0160 }
});

const align = (n, a) => Math.ceil(n / a) * a;

/** A growable little-endian byte area with pointer fixups to named objects. */
class Area {
	constructor() {
		this.bytes = [];
		this.fixups = [];
	}
	pad(to) {
		while (this.bytes.length % to) this.bytes.push(0);
	}
	u8(v) {
		this.bytes.push(v & 0xff);
	}
	u16(v) {
		this.u8(v);
		this.u8(v >>> 8);
	}
	u32(v) {
		this.u16(v & 0xffff);
		this.u16(v >>> 16);
	}
}

/**
 * The read-only data objects of one image, in the C emitter's order: each a
 * {name, align, write(area, ptr)} where ptr(target) writes a pointer slot.
 */
function tableObjects(model) {
	const n = model.columns.length;
	const rows = Emit.mainRows(model);
	const mods = Emit.modNumbers(model);
	const ligatures = [];
	model.keys.forEach((key) =>
		key.cells.forEach((cell, column) => {
			if (cell && cell.ligature) ligatures.push({ vk: key.vk, column, units: cell.ligature });
		})
	);
	const lgMax = ligatures.reduce((a, l) => Math.max(a, l.units.length), 0);
	const deadRows = [];
	for (const dead of model.dead_keys)
		for (const rule of dead.rules)
			deadRows.push({
				both: ((dead.dead << 16) | rule.base) >>> 0,
				result: rule.result,
				flags: rule.dead ? C.DKF_DEAD : 0
			});
	const named = model.dead_keys.filter((dead) => dead.name);
	const scan = Emit.scanTable(model);
	const objects = [];
	const add = (name, alignment, write) => objects.push({ name, align: alignment, write });
	const wchars = (area, text) => {
		for (let i = 0; i < text.length; i++) area.u16(text.charCodeAt(i));
		area.u16(0);
	};

	add('aVkToBits', 1, (a) => {
		for (const key of Model.modifierKeys(model)) {
			a.u8(key.vk);
			a.u8(key.bit);
		}
		a.u8(0);
		a.u8(0);
	});
	add('CharModifiers', 'ptr', (a, ptr, P) => {
		ptr('aVkToBits');
		a.u16(mods.length - 1);
		for (const m of mods) a.u8(m);
		a.pad(P.align);
	});
	add('aVkToWchMain', 2, (a) => {
		for (const row of rows) {
			a.u8(row.vk);
			a.u8(row.attr);
			for (const u of row.wch) a.u16(u);
		}
		for (let i = 0; i < 2 + 2 * n; i++) a.u8(0);
	});
	add('aVkToWchNumpad', 2, (a) => {
		for (const key of C.NUMPAD_KEYS) {
			a.u8(C.VK[key.vk]);
			a.u8(0);
			a.u16(key.char);
		}
		a.u32(0);
	});
	add('aVkToWcharTable', 'ptr', (a, ptr, P) => {
		const entry = (target, count, size) => {
			ptr(target);
			a.u8(count);
			a.u8(size);
			a.pad(P.align);
		};
		entry('aVkToWchMain', n, 2 + 2 * n);
		entry('aVkToWchNumpad', 1, 4);
		entry(null, 0, 0);
	});
	if (deadRows.length)
		add('aDeadKey', 4, (a) => {
			for (const row of deadRows) {
				a.u32(row.both);
				a.u16(row.result);
				a.u16(row.flags);
			}
			a.u32(0);
			a.u32(0);
		});
	const nameTable = (id, list) => {
		list.forEach((entry, i) => add(`${id}_${i}`, 2, (a) => wchars(a, entry.name)));
		add(id, 'ptr', (a, ptr, P) => {
			for (const [i, entry] of list.entries()) {
				a.u8(entry.sc);
				a.pad(P.align);
				ptr(`${id}_${i}`);
			}
			a.u8(0);
			a.pad(P.align);
			ptr(null);
		});
	};
	nameTable('aKeyNames', model.key_names || []);
	nameTable('aKeyNamesExt', model.key_names_ext || []);
	if (named.length) {
		named.forEach((dead, i) =>
			add(`aDeadName_${i}`, 2, (a) => wchars(a, String.fromCharCode(dead.dead) + dead.name))
		);
		add('aKeyNamesDead', 'ptr', (a, ptr) => {
			named.forEach((_, i) => ptr(`aDeadName_${i}`));
			ptr(null);
		});
	}
	add('ausVSCtoVK', 2, (a) => {
		for (const v of scan) a.u16(v);
	});
	const vscVk = (pairs) => (a) => {
		for (const [sc, vk] of pairs) {
			a.u8(sc);
			a.u8(0);
			a.u16(vk);
		}
		a.u32(0);
	};
	add('aE0VscToVk', 2, vscVk(Model.e0Table(model).map(([sc, vk]) => [sc, vk | C.SC_FLAGS.EXT])));
	add('aE1VscToVk', 2, vscVk(C.DEFAULT_E1));
	if (lgMax)
		add('aLigature', 2, (a) => {
			for (const lig of ligatures) {
				a.u8(lig.vk);
				a.u8(0);
				a.u16(lig.column);
				for (let i = 0; i < lgMax; i++) a.u16(i < lig.units.length ? lig.units[i] : C.WCH.NONE);
			}
			for (let i = 0; i < 4 + 2 * lgMax; i++) a.u8(0);
		});
	add('KbdTables', 'ptr', (a, ptr, P) => {
		ptr('CharModifiers');
		ptr('aVkToWcharTable');
		ptr(deadRows.length ? 'aDeadKey' : null);
		ptr('aKeyNames');
		ptr('aKeyNamesExt');
		ptr(named.length ? 'aKeyNamesDead' : null);
		ptr('ausVSCtoVK');
		a.u8(scan.length);
		a.pad(P.align);
		ptr('aE0VscToVk');
		ptr('aE1VscToVk');
		a.u32(Model.localeFlags(model));
		a.u8(lgMax);
		a.u8(lgMax ? 4 + 2 * lgMax : 0);
		a.pad(P.align);
		ptr(lgMax ? 'aLigature' : null);
		a.u32(C.KEYBOARD_TYPE);
		a.u32(0);
		a.pad(P.align);
	});
	return objects;
}

/** The .rdata area of one image: every table, then the export directory. */
function rdata(model, image, rva) {
	const P = { width: image.width, align: image.width };
	const area = new Area();
	const at = new Map();
	for (const object of tableObjects(model)) {
		area.pad(object.align === 'ptr' ? P.align : object.align);
		at.set(object.name, area.bytes.length);
		const ptr = (target) => {
			area.pad(P.align);
			if (target !== null) area.fixups.push({ offset: area.bytes.length, target });
			for (let i = 0; i < P.width; i++) area.u8(0);
		};
		object.write(area, ptr, P);
	}
	// The export directory: KbdLayerDescriptor at ordinal 1, as the .def names it.
	area.pad(4);
	const exportAt = area.bytes.length;
	const dllName = `${model.dll_name}.dll`;
	const fn = 'KbdLayerDescriptor';
	const eat = exportAt + 40;
	const enpt = eat + 4;
	const eot = enpt + 4;
	const nameAt = eot + 2;
	const fnAt = nameAt + dllName.length + 1;
	const exportsDir = {
		offset: exportAt,
		size: fnAt + fn.length + 1 - exportAt,
		patch: (bytes, codeRva) => {
			const w = (off, v) => {
				bytes.writeUInt32LE(v >>> 0, off);
			};
			w(exportAt + 12, rva + nameAt);
			w(exportAt + 16, 1);
			w(exportAt + 20, 1);
			w(exportAt + 24, 1);
			w(exportAt + 28, rva + eat);
			w(exportAt + 32, rva + enpt);
			w(exportAt + 36, rva + eot);
			w(eat, codeRva);
			w(enpt, rva + fnAt);
		}
	};
	for (let i = exportAt; i < nameAt; i++) area.u8(0);
	for (const ch of dllName) area.u8(ch.charCodeAt(0));
	area.u8(0);
	for (const ch of fn) area.u8(ch.charCodeAt(0));
	area.u8(0);
	const bytes = Buffer.from(area.bytes);
	// Pointer slots hold virtual addresses; the relocations let the loader move them.
	const relocations = [];
	for (const fix of area.fixups) {
		const va = image.base + rva + at.get(fix.target);
		if (image.plus) bytes.writeBigUInt64LE(BigInt(va), fix.offset);
		else bytes.writeUInt32LE(va >>> 0, fix.offset);
		relocations.push({ rva: rva + fix.offset, type: image.plus ? REL_DIR64 : REL_HIGHLOW });
	}
	return { bytes, relocations, tablesRva: rva + at.get('KbdTables'), exportsDir };
}

/** KbdLayerDescriptor's code: return &KbdTables. */
function descriptorCode(image, codeRva, tablesRva) {
	if (image.machine === 0x014c) {
		const code = Buffer.from([0xb8, 0, 0, 0, 0, 0xc3]);
		code.writeUInt32LE((image.base + tablesRva) >>> 0, 1);
		return { code, relocations: [{ rva: codeRva + 1, type: REL_HIGHLOW }] };
	}
	if (image.machine === 0x8664) {
		const code = Buffer.from([0x48, 0x8d, 0x05, 0, 0, 0, 0, 0xc3]);
		code.writeInt32LE(tablesRva - (codeRva + 7), 3);
		return { code, relocations: [] };
	}
	const pages = (tablesRva >> 12) - (codeRva >> 12);
	const immlo = pages & 3;
	const immhi = (pages >> 2) & 0x7ffff;
	const code = Buffer.alloc(12);
	code.writeUInt32LE((0x90000000 | (immlo << 29) | (immhi << 5)) >>> 0, 0);
	code.writeUInt32LE((0x91000000 | ((tablesRva & 0xfff) << 10)) >>> 0, 4);
	code.writeUInt32LE(0xd65f03c0, 8);
	return { code, relocations: [] };
}

/** One length-prefixed VS_VERSIONINFO node (wLength, wValueLength, wType, key, value, children). */
function versionNode(key, value, type, children) {
	const parts = [];
	const head = Buffer.alloc(6);
	const keyBytes = Buffer.from(`${key}\0`, 'utf16le');
	let body = Buffer.concat([head, keyBytes]);
	body = Buffer.concat([body, Buffer.alloc(align(body.length, 4) - body.length)]);
	let valueLength = 0;
	if (value !== null) {
		body = Buffer.concat([body, value.bytes]);
		valueLength = value.length;
	}
	for (const child of children) {
		body = Buffer.concat([body, Buffer.alloc(align(body.length, 4) - body.length), child]);
	}
	body.writeUInt16LE(body.length, 0);
	body.writeUInt16LE(valueLength, 2);
	body.writeUInt16LE(type, 4);
	parts.push(body);
	return Buffer.concat(parts);
}

/** The keyboard-driver version resource emitRc describes. */
function versionResource(model) {
	const v = (model.version_string || '1.0').split('.').map(Number);
	while (v.length < 4) v.push(0);
	const fixed = Buffer.alloc(52);
	const words = [
		0xfeef04bd,
		0x00010000,
		((v[0] << 16) | v[1]) >>> 0,
		((v[2] << 16) | v[3]) >>> 0,
		((v[0] << 16) | v[1]) >>> 0,
		((v[2] << 16) | v[3]) >>> 0,
		0x3f,
		0,
		0x40004,
		3,
		2,
		0,
		0
	];
	words.forEach((word, i) => fixed.writeUInt32LE(word, 4 * i));
	const text = (s) => {
		const bytes = Buffer.from(`${s}\0`, 'utf16le');
		return { bytes, length: bytes.length / 2 };
	};
	const strings = [
		['CompanyName', model.company || model.layout_text],
		['FileDescription', `${model.layout_text} keyboard layout`],
		['FileVersion', model.version_string || '1.0'],
		['InternalName', model.dll_name],
		['LegalCopyright', model.copyright || ''],
		['OriginalFilename', `${model.dll_name}.dll`],
		['ProductName', model.layout_text],
		['ProductVersion', model.version_string || '1.0']
	].map(([key, value]) => versionNode(key, text(value), 1, []));
	const translation = Buffer.alloc(4);
	translation.writeUInt16LE(0x409, 0);
	translation.writeUInt16LE(1200, 2);
	return versionNode('VS_VERSION_INFO', { bytes: fixed, length: 52 }, 0, [
		versionNode('StringFileInfo', null, 1, [versionNode('040904B0', null, 1, strings)]),
		versionNode('VarFileInfo', null, 1, [
			versionNode('Translation', { bytes: translation, length: 4 }, 0, [])
		])
	]);
}

/** The string-table block holding the Layout Display Name (string 1000). */
function stringBlock(model) {
	const id = C.DISPLAY_NAME_RESOURCE;
	const parts = [];
	for (let i = 0; i < 16; i++) {
		const s = i === id % 16 ? model.layout_text : '';
		const len = Buffer.alloc(2);
		len.writeUInt16LE(s.length, 0);
		parts.push(len, Buffer.from(s, 'utf16le'));
	}
	return { name: Math.floor(id / 16) + 1, data: Buffer.concat(parts) };
}

/** The .rsrc section: type → name → language directories, data entries, data. */
function resources(model, rva) {
	const block = stringBlock(model);
	const leaves = [
		{ type: RT_STRING, name: block.name, data: block.data },
		{ type: RT_VERSION, name: 1, data: versionResource(model) }
	];
	const dir = (count) => {
		const b = Buffer.alloc(16 + 8 * count);
		b.writeUInt16LE(count, 14);
		return b;
	};
	// Layout: root, one name directory per type, one language directory per name.
	const root = dir(leaves.length);
	const names = leaves.map(() => dir(1));
	const langs = leaves.map(() => dir(1));
	let at = root.length + names.reduce((a, b) => a + b.length, 0);
	at += langs.reduce((a, b) => a + b.length, 0);
	const entriesAt = at;
	at += 16 * leaves.length;
	const dataAt = [];
	for (const leaf of leaves) {
		at = align(at, 8);
		dataAt.push(at);
		at += leaf.data.length;
	}
	const out = Buffer.alloc(at);
	let cursor = root.length;
	const nameAt = [];
	for (const b of names) {
		nameAt.push(cursor);
		cursor += b.length;
	}
	const langAt = [];
	for (const b of langs) {
		langAt.push(cursor);
		cursor += b.length;
	}
	leaves.forEach((leaf, i) => {
		root.writeUInt32LE(leaf.type, 16 + 8 * i);
		root.writeUInt32LE((0x80000000 | nameAt[i]) >>> 0, 20 + 8 * i);
		names[i].writeUInt32LE(leaf.name, 16);
		names[i].writeUInt32LE((0x80000000 | langAt[i]) >>> 0, 20);
		langs[i].writeUInt32LE(RESOURCE_LANGUAGE, 16);
		langs[i].writeUInt32LE(entriesAt + 16 * i, 20);
		const entry = entriesAt + 16 * i;
		out.writeUInt32LE(rva + dataAt[i], entry);
		out.writeUInt32LE(leaf.data.length, entry + 4);
		leaf.data.copy(out, dataAt[i]);
	});
	root.copy(out, 0);
	names.forEach((b, i) => b.copy(out, nameAt[i]));
	langs.forEach((b, i) => b.copy(out, langAt[i]));
	return out;
}

/** The .reloc section: one block per 4 KiB page, padded to a 4-byte size. */
function relocationSection(relocations) {
	const pages = new Map();
	for (const r of relocations.slice().sort((a, b) => a.rva - b.rva)) {
		const page = r.rva & ~0xfff;
		if (!pages.has(page)) pages.set(page, []);
		pages.get(page).push(((r.type << 12) | (r.rva & 0xfff)) >>> 0);
	}
	const blocks = [];
	for (const [page, entries] of pages) {
		if (entries.length % 2) entries.push(0);
		const b = Buffer.alloc(8 + 2 * entries.length);
		b.writeUInt32LE(page, 0);
		b.writeUInt32LE(b.length, 4);
		entries.forEach((e, i) => b.writeUInt16LE(e, 8 + 2 * i));
		blocks.push(b);
	}
	return Buffer.concat(blocks);
}

/** The PE checksum: 16-bit one's-complement sum of the file, checksum field skipped, plus its length. */
function peChecksum(bytes, checksumOffset) {
	let sum = 0;
	for (let i = 0; i < bytes.length; i += 2) {
		if (i === checksumOffset || i === checksumOffset + 2) continue;
		sum += i + 1 < bytes.length ? bytes.readUInt16LE(i) : bytes[i];
		sum = (sum & 0xffff) + Math.floor(sum / 0x10000);
	}
	sum = (sum & 0xffff) + (sum >>> 16);
	return (sum + bytes.length) >>> 0;
}

/**
 * One layout DLL image.
 * @param {object} model - A checked kbd tables model.
 * @param {string} arch - x86, wow64, x64 or arm64.
 * @returns {Buffer}
 */
function writeImage(model, arch) {
	const image = IMAGES[arch];
	if (!image) throw new Model.ModelError('kbd_arch_unknown', arch);
	const codeRva = SECTION_ALIGN;
	const codeSize = image.machine === 0x014c ? 6 : image.machine === 0x8664 ? 8 : 12;
	const rdataRva = codeRva + align(codeSize, SECTION_ALIGN);
	const data = rdata(model, image, rdataRva);
	const code = descriptorCode(image, codeRva, data.tablesRva);
	data.exportsDir.patch(data.bytes, codeRva);
	const rsrcRva = rdataRva + align(data.bytes.length, SECTION_ALIGN);
	const rsrc = resources(model, rsrcRva);
	const relocRva = rsrcRva + align(rsrc.length, SECTION_ALIGN);
	const reloc = relocationSection(code.relocations.concat(data.relocations));
	const sections = [
		{ name: '.text', rva: codeRva, bytes: code.code, flags: SCN.code },
		{ name: '.rdata', rva: rdataRva, bytes: data.bytes, flags: SCN.rdata },
		{ name: '.rsrc', rva: rsrcRva, bytes: rsrc, flags: SCN.rdata },
		{ name: '.reloc', rva: relocRva, bytes: reloc, flags: SCN.reloc }
	];
	let raw = HEADERS_SIZE;
	for (const s of sections) {
		s.raw = raw;
		s.rawSize = align(s.bytes.length, FILE_ALIGN);
		raw += s.rawSize;
	}
	const file = Buffer.alloc(raw);
	file.writeUInt16LE(0x5a4d, 0);
	file.writeUInt32LE(PE_OFFSET, 0x3c);
	const pe = PE_OFFSET;
	file.writeUInt32LE(0x00004550, pe);
	const optSize = image.plus ? 0xf0 : 0xe0;
	file.writeUInt16LE(image.machine, pe + 4);
	file.writeUInt16LE(sections.length, pe + 6);
	file.writeUInt16LE(optSize, pe + 20);
	file.writeUInt16LE(image.chars, pe + 22);
	const opt = pe + 24;
	const sizeOf = (flags) =>
		sections.filter((s) => s.flags === flags).reduce((a, s) => a + s.rawSize, 0);
	file.writeUInt16LE(image.plus ? 0x20b : 0x10b, opt);
	file[opt + 2] = 14;
	file.writeUInt32LE(sizeOf(SCN.code), opt + 4);
	file.writeUInt32LE(sizeOf(SCN.rdata) + sizeOf(SCN.reloc), opt + 8);
	file.writeUInt32LE(0, opt + 16);
	file.writeUInt32LE(codeRva, opt + 20);
	if (image.plus) file.writeBigUInt64LE(BigInt(image.base), opt + 24);
	else {
		file.writeUInt32LE(rdataRva, opt + 24);
		file.writeUInt32LE(image.base, opt + 28);
	}
	file.writeUInt32LE(SECTION_ALIGN, opt + 32);
	file.writeUInt32LE(FILE_ALIGN, opt + 36);
	file.writeUInt16LE(6, opt + 40);
	file.writeUInt16LE(6, opt + 48);
	file.writeUInt32LE(relocRva + align(reloc.length, SECTION_ALIGN), opt + 56);
	file.writeUInt32LE(HEADERS_SIZE, opt + 60);
	file.writeUInt16LE(1, opt + 68);
	file.writeUInt16LE(image.dll, opt + 70);
	const reserve = [0x100000, 0x1000, 0x100000, 0x1000];
	let field = opt + 72;
	for (const value of reserve) {
		if (image.plus) {
			file.writeBigUInt64LE(BigInt(value), field);
			field += 8;
		} else {
			file.writeUInt32LE(value, field);
			field += 4;
		}
	}
	field += 4;
	file.writeUInt32LE(16, field);
	const dirs = field + 4;
	const dirEntry = (index, rva, size) => {
		file.writeUInt32LE(rva, dirs + 8 * index);
		file.writeUInt32LE(size, dirs + 8 * index + 4);
	};
	dirEntry(0, rdataRva + data.exportsDir.offset, data.exportsDir.size);
	dirEntry(2, rsrcRva, rsrc.length);
	dirEntry(5, relocRva, reloc.length);
	const table = opt + optSize;
	sections.forEach((s, i) => {
		const at = table + 40 * i;
		file.write(s.name, at, 'latin1');
		file.writeUInt32LE(s.bytes.length, at + 8);
		file.writeUInt32LE(s.rva, at + 12);
		file.writeUInt32LE(s.rawSize, at + 16);
		file.writeUInt32LE(s.raw, at + 20);
		file.writeUInt32LE(s.flags, at + 36);
		s.bytes.copy(file, s.raw);
	});
	const checksumAt = opt + 64;
	file.writeUInt32LE(peChecksum(file, checksumAt), checksumAt);
	return file;
}

/**
 * The four layout DLL images of a model, written without a toolchain.
 * @param {object} input - A kbd tables model.
 * @returns {Object<string, Buffer>} x86, wow64, x64 and arm64 images.
 */
function writeDlls(input) {
	const model = Model.check(input);
	return Object.fromEntries(Object.keys(IMAGES).map((arch) => [arch, writeImage(model, arch)]));
}

module.exports = { IMAGES, writeDlls, writeImage, peChecksum };
