// tools/lib/kbd-dll/reader.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout DLL Reader
 * DESCRIPTION:
 * Reads a built Windows keyboard layout DLL back, independently of the emitter
 * (it shares no code or constant with emit-c.cjs, model.cjs or constants.cjs):
 * the PE image (headers, sections, exports, base relocations), the address
 * KbdLayerDescriptor returns (decoded from its x86, x64 or arm64 instructions)
 * and every KBDTABLES table, with structural checks, then the logical layout
 * (columns, keys, dead keys, ligatures, names, scan codes) for golden tests.
 *
 * FEATURES & RATIONALE:
 * 1. Every pointer must land inside one read-only, initialized section, be
 *    aligned for what it points to, and carry the base relocation of its width
 *    (HIGHLOW for a 32-bit image, DIR64 for a 64-bit one), so a relocated image
 *    cannot hold a stale table address.
 * 2. Every count and size is cross-checked: cbSize against nModifications,
 *    cbLgEntry against nLgMax, ModNumber against the columns, the KBD_VERSION
 *    word, list terminators inside their section.
 * 3. The pointer width of a 32-bit image is detected from its tables: a SysWOW64
 *    image stores 64-bit pointers (high word zero) in the same layout as x64.
 * ==============================================================================
 */

'use strict';

// Kept here on purpose, written from the PE/COFF specification and kbd.h docs.
const MACHINES = { 0x014c: 'x86', 0x8664: 'x64', 0xaa64: 'arm64' };
const SCN_EXECUTE = 0x20000000;
const SCN_WRITE = 0x80000000;
const SCN_INITIALIZED = 0x00000040;
const REL_HIGHLOW = 3;
const REL_DIR64 = 10;
const NONE_UNIT = 0xf000;
const DEAD_UNIT = 0xf001;
const LIG_UNIT = 0xf002;
const FOLLOW_VK = 0xff;
const SGCAPS_ATTR = 0x02;
const CHAIN_FLAG = 0x0001;
const NO_COLUMN = 0x0f;

/** A structural fault of the image, with what was being read. */
class DllError extends Error {
	constructor(reason, where) {
		super(`kbd dll: ${reason}${where ? ` (${where})` : ''}`);
		this.name = 'DllError';
		this.code = 'kbd_dll_invalid';
		this.reason = reason;
	}
}

const refuse = (reason, where) => {
	throw new DllError(reason, where);
};

/** The PE image: sections, image base, relocations and exports. */
function parsePe(bytes) {
	const b = Buffer.from(bytes);
	if (b.length < 64 || b.readUInt16LE(0) !== 0x5a4d) refuse('no MZ header');
	const pe = b.readUInt32LE(0x3c);
	if (pe + 24 > b.length || b.readUInt32LE(pe) !== 0x00004550) refuse('no PE signature');
	const machine = MACHINES[b.readUInt16LE(pe + 4)];
	if (!machine) refuse('unknown machine');
	const count = b.readUInt16LE(pe + 6);
	const optSize = b.readUInt16LE(pe + 20);
	const characteristics = b.readUInt16LE(pe + 22);
	if (!(characteristics & 0x2000)) refuse('not a DLL');
	const opt = pe + 24;
	const magic = b.readUInt16LE(opt);
	const plus = magic === 0x20b;
	if (!plus && magic !== 0x10b) refuse('unknown optional header');
	if ((machine === 'x86') === plus) refuse('machine and optional header disagree');
	const imageBase = plus ? Number(b.readBigUInt64LE(opt + 24)) : b.readUInt32LE(opt + 28);
	const entry = b.readUInt32LE(opt + 16);
	const subsystem = b.readUInt16LE(opt + 68);
	const dirOffset = opt + (plus ? 112 : 96);
	const dirs = [];
	for (let i = 0; i < 16; i++)
		dirs.push({
			rva: b.readUInt32LE(dirOffset + 8 * i),
			size: b.readUInt32LE(dirOffset + 8 * i + 4)
		});
	const sections = [];
	const table = opt + optSize;
	for (let i = 0; i < count; i++) {
		const at = table + 40 * i;
		sections.push({
			name: b.toString('latin1', at, at + 8).replace(/\0+$/, ''),
			vsize: b.readUInt32LE(at + 8),
			rva: b.readUInt32LE(at + 12),
			rawSize: b.readUInt32LE(at + 16),
			raw: b.readUInt32LE(at + 20),
			flags: b.readUInt32LE(at + 36)
		});
	}
	const section = (rva) =>
		sections.find((s) => rva >= s.rva && rva < s.rva + Math.max(s.vsize, s.rawSize));
	const offset = (rva, size = 1) => {
		const s = section(rva);
		if (!s) refuse('address outside every section', `rva 0x${rva.toString(16)}`);
		const off = rva - s.rva;
		if (off + size > s.rawSize) refuse('read past initialized data', `rva 0x${rva.toString(16)}`);
		return s.raw + off;
	};
	const relocs = new Map();
	const relocDir = dirs[5];
	for (let at = relocDir.rva; at < relocDir.rva + relocDir.size; ) {
		const page = b.readUInt32LE(offset(at, 8));
		const size = b.readUInt32LE(offset(at, 8) + 4);
		if (size < 8 || size % 2) refuse('bad relocation block');
		for (let e = 8; e < size; e += 2) {
			const v = b.readUInt16LE(offset(at + e, 2));
			const type = v >> 12;
			if (type !== 0) relocs.set(page + (v & 0xfff), type);
		}
		at += size;
	}
	const exportsDir = dirs[0];
	const exports = [];
	if (exportsDir.rva) {
		const e = offset(exportsDir.rva, 40);
		const base = b.readUInt32LE(e + 16);
		const nFunc = b.readUInt32LE(e + 20);
		const nNames = b.readUInt32LE(e + 24);
		const funcs = b.readUInt32LE(e + 28);
		const names = b.readUInt32LE(e + 32);
		const ords = b.readUInt32LE(e + 36);
		for (let i = 0; i < nNames; i++) {
			const nameRva = b.readUInt32LE(offset(names + 4 * i, 4));
			let end = offset(nameRva);
			while (b[end] !== 0) end++;
			const index = b.readUInt16LE(offset(ords + 2 * i, 2));
			if (index >= nFunc) refuse('export index out of range');
			exports.push({
				name: b.toString('latin1', offset(nameRva), end),
				ordinal: base + index,
				rva: b.readUInt32LE(offset(funcs + 4 * index, 4))
			});
		}
	}
	return {
		b,
		machine,
		plus,
		imageBase,
		entry,
		subsystem,
		dirs,
		sections,
		section,
		offset,
		relocs,
		exports
	};
}

/** The table address KbdLayerDescriptor returns, decoded from its instructions. */
function descriptorTarget(img) {
	const exp = img.exports.find((e) => e.name === 'KbdLayerDescriptor');
	if (!exp) refuse('KbdLayerDescriptor is not exported');
	const s = img.section(exp.rva);
	if (!s || !(s.flags & SCN_EXECUTE)) refuse('KbdLayerDescriptor is not in code');
	const at = img.offset(exp.rva, 12);
	const code = img.b.subarray(at, at + 12);
	if (img.machine === 'x86' && code[0] === 0xb8 && code[5] === 0xc3) {
		if (img.relocs.get(exp.rva + 1) !== REL_HIGHLOW) refuse('descriptor address not relocated');
		return { rva: code.readUInt32LE(1) - img.imageBase, ordinal: exp.ordinal };
	}
	if (
		img.machine === 'x64' &&
		code[0] === 0x48 &&
		code[1] === 0x8d &&
		code[2] === 0x05 &&
		code[7] === 0xc3
	)
		return { rva: exp.rva + 7 + code.readInt32LE(3), ordinal: exp.ordinal };
	if (img.machine === 'arm64') {
		const adrp = code.readUInt32LE(0);
		const add = code.readUInt32LE(4);
		const ret = code.readUInt32LE(8);
		if (
			(adrp & 0x9f00001f) >>> 0 === 0x90000000 &&
			(add & 0xffc003ff) >>> 0 === 0x91000000 &&
			ret === 0xd65f03c0
		) {
			const imm = (((adrp >> 5) & 0x7ffff) << 2) | ((adrp >> 29) & 3);
			const signed = imm & 0x100000 ? imm - 0x200000 : imm;
			const page = (exp.rva & ~0xfff) + signed * 4096;
			return { rva: page + ((add >> 10) & 0xfff), ordinal: exp.ordinal };
		}
	}
	refuse('unrecognized KbdLayerDescriptor code');
}

/**
 * Reads and checks every table of a layout DLL.
 * @param {Uint8Array} bytes
 * @returns {{machine: string, pointer: number, wow64: boolean, checks: string[], layout: object}}
 */
function readDll(bytes) {
	const img = parsePe(bytes);
	if (img.entry !== 0) refuse('a layout DLL has no entry point');
	for (const s of img.sections)
		if (s.flags & SCN_WRITE && s.rawSize > 0 && s.name !== '.reloc')
			refuse('writable section', s.name);
	const target = descriptorTarget(img);
	const b = img.b;
	const u8 = (rva) => b[img.offset(rva, 1)];
	const u16 = (rva) => b.readUInt16LE(img.offset(rva, 2));
	const u32 = (rva) => b.readUInt32LE(img.offset(rva, 4));
	const tablesRva = target.rva;
	// A 32-bit image's own pointer width: SysWOW64 tables are 64 bits wide.
	const width = img.plus ? 8 : u32(tablesRva + 4) === 0 ? 8 : 4;
	const wow64 = !img.plus && width === 8;
	const checked = new Set();
	/** A pointer slot: null, or the RVA it names, after every check. */
	const pointer = (slot, align, what) => {
		let va;
		if (width === 8) {
			const lo = u32(slot);
			const hi = u32(slot + 4);
			if (img.plus) va = Number(b.readBigUInt64LE(img.offset(slot, 8)));
			else {
				if (hi !== 0) refuse('high word of a wow64 pointer is not zero', what);
				va = lo;
			}
		} else va = u32(slot);
		if (va === 0) {
			if (img.relocs.has(slot)) refuse('relocation on a null pointer', what);
			return null;
		}
		const expected = img.plus ? REL_DIR64 : REL_HIGHLOW;
		if (img.relocs.get(slot) !== expected) refuse('pointer without its base relocation', what);
		const rva = va - img.imageBase;
		const s = img.section(rva);
		if (!s) refuse('pointer outside the image', what);
		if (s.flags & SCN_WRITE || s.flags & SCN_EXECUTE || !(s.flags & SCN_INITIALIZED))
			refuse('pointer into a code or writable section', what);
		if (rva % align) refuse('misaligned table', what);
		checked.add(what);
		return rva;
	};
	const field = (n) => n * width;
	if (tablesRva % width) refuse('misaligned KBDTABLES');
	const ligOffset = Math.ceil((field(10) + 6) / width) * width;
	const t = {
		modifiers: pointer(tablesRva + field(0), width, 'pCharModifiers'),
		wchTables: pointer(tablesRva + field(1), width, 'pVkToWcharTable'),
		dead: pointer(tablesRva + field(2), 4, 'pDeadKey'),
		names: pointer(tablesRva + field(3), width, 'pKeyNames'),
		namesExt: pointer(tablesRva + field(4), width, 'pKeyNamesExt'),
		namesDead: pointer(tablesRva + field(5), width, 'pKeyNamesDead'),
		scan: pointer(tablesRva + field(6), 2, 'pusVSCtoVK'),
		scanCount: u8(tablesRva + field(7)),
		e0: pointer(tablesRva + field(8), 2, 'pVSCtoVK_E0'),
		e1: pointer(tablesRva + field(9), 2, 'pVSCtoVK_E1'),
		flags: u32(tablesRva + field(10)),
		lgMax: u8(tablesRva + field(10) + 4),
		lgSize: u8(tablesRva + field(10) + 5),
		// The two BYTEs after fLocaleFlags pad pLigature to the pointer width.
		lig: pointer(tablesRva + ligOffset, 2, 'pLigature'),
		type: u32(tablesRva + ligOffset + width),
		subType: u32(tablesRva + ligOffset + width + 4)
	};
	if (t.flags >>> 16 !== 1) refuse('KBD_VERSION is not 1');
	if (t.modifiers === null || t.wchTables === null || t.scan === null)
		refuse('a mandatory table is missing');
	if (t.type !== 4) refuse('keyboard type is not 4');

	// Modifiers: VK_TO_BIT list, then wMaxModBits and its ModNumber bytes.
	const toBit = pointer(t.modifiers, 1, 'pVkToBit');
	const bits = [];
	for (let at = toBit; ; at += 2) {
		const vk = u8(at);
		const bit = u8(at + 1);
		if (vk === 0 && bit === 0) break;
		bits.push({ vk, bit });
	}
	const maxBits = u16(t.modifiers + width);
	const modNumber = [];
	for (let i = 0; i <= maxBits; i++) modNumber.push(u8(t.modifiers + width + 2 + i));

	// VK_TO_WCHAR tables: rows, their follow rows, the ligature and dead cells.
	const tables = [];
	const entrySize = width === 8 ? 16 : 8;
	for (let at = t.wchTables; ; at += entrySize) {
		const rows = pointer(at, 2, `pVkToWchars@${tables.length}`);
		const n = u8(at + width);
		const size = u8(at + width + 1);
		if (rows === null) {
			if (n !== 0 || size !== 0) refuse('table terminator carries a size');
			break;
		}
		if (n === 0 || size !== 2 + 2 * n)
			refuse('cbSize does not match nModifications', `table ${tables.length}`);
		const list = [];
		for (let r = rows; ; r += size) {
			const vk = u8(r);
			if (vk === 0) break;
			const wch = [];
			for (let i = 0; i < n; i++) wch.push(u16(r + 2 + 2 * i));
			list.push({ vk, attributes: u8(r + 1), wch });
		}
		tables.push({ columns: n, rows: list });
	}
	const columns = [];
	modNumber.forEach((col, combo) => {
		if (col === NO_COLUMN) return;
		if (columns[col] !== undefined) refuse('two modifier combinations share a column');
		columns[col] = combo;
	});
	if (columns.some((c) => c === undefined)) refuse('a column no combination selects');
	const width0 = tables[0] ? tables[0].columns : 0;
	if (width0 > columns.length) refuse('more cells than columns');

	// Ligatures.
	const ligatures = [];
	if (t.lig !== null) {
		if (t.lgSize !== 4 + 2 * t.lgMax) refuse('cbLgEntry does not match nLgMax');
		for (let at = t.lig; ; at += t.lgSize) {
			const vk = u8(at);
			if (vk === 0) break;
			const column = u16(at + 2);
			const units = [];
			for (let i = 0; i < t.lgMax; i++) {
				const u = u16(at + 4 + 2 * i);
				if (u !== NONE_UNIT) units.push(u);
			}
			ligatures.push({ vk, column, units });
		}
	} else if (t.lgMax || t.lgSize) refuse('ligature sizes without a ligature table');

	const keys = [];
	const extra = [];
	tables.forEach((table, index) => {
		for (let i = 0; i < table.rows.length; i++) {
			const row = table.rows[i];
			if (row.vk === FOLLOW_VK) refuse('a follow row without its key', `table ${index}`);
			const decode = (unit, column) => {
				if (unit === NONE_UNIT) return null;
				if (unit === LIG_UNIT) {
					const lig = ligatures.find((l) => l.vk === row.vk && l.column === column);
					if (!lig) refuse('ligature cell without its entry', `vk 0x${row.vk.toString(16)}`);
					return { ligature: lig.units };
				}
				return { char: unit };
			};
			const cells = row.wch.map(decode);
			const key = { vk: row.vk, attributes: row.attributes, cells };
			if (row.wch.includes(DEAD_UNIT)) {
				const follow = table.rows[++i];
				if (!follow || follow.vk !== FOLLOW_VK)
					refuse('dead cell without its dead row', `vk 0x${row.vk.toString(16)}`);
				row.wch.forEach((u, c) => {
					if (u === DEAD_UNIT) cells[c] = { dead: follow.wch[c] };
					else if (follow.wch[c] !== NONE_UNIT)
						refuse('dead row holds a character under a live cell');
				});
			}
			if (row.attributes & SGCAPS_ATTR) {
				const follow = table.rows[++i];
				if (!follow || follow.vk !== FOLLOW_VK) refuse('SGCAPS key without its Caps row');
				key.caps_cells = follow.wch.map(decode);
			}
			(index === 0 ? keys : extra).push(key);
		}
	});

	// Dead keys and their chains.
	const dead = new Map();
	if (t.dead !== null)
		for (let at = t.dead; ; at += 8) {
			const both = u32(at);
			if (both === 0) break;
			const accent = both >>> 16;
			const rule = { base: both & 0xffff, result: u16(at + 4) };
			const flags = u16(at + 6);
			if (flags & ~CHAIN_FLAG) refuse('unknown dead-key flags');
			if (flags & CHAIN_FLAG) rule.dead = true;
			if (!dead.has(accent)) dead.set(accent, []);
			dead.get(accent).push(rule);
		}
	const readString = (rva, what) => {
		if (rva % 2) refuse('misaligned string', what);
		let out = '';
		for (let at = rva; ; at += 2) {
			const u = u16(at);
			if (u === 0) return out;
			out += String.fromCharCode(u);
			if (out.length > 4096) refuse('unterminated string', what);
		}
	};
	const nameList = (rva, what) => {
		const list = [];
		if (rva === null) return list;
		for (let at = rva; ; at += 2 * width) {
			const sc = u8(at);
			const p = pointer(at + width, 2, `${what}[${list.length}]`);
			if (sc === 0 && p === null) break;
			if (p === null) refuse('key name without text', what);
			list.push({ sc, name: readString(p, what) });
		}
		return list;
	};
	const deadNames = new Map();
	if (t.namesDead !== null)
		for (let at = t.namesDead; ; at += width) {
			const p = pointer(at, 2, `pKeyNamesDead[${deadNames.size}]`);
			if (p === null) break;
			const text = readString(p, 'pKeyNamesDead');
			deadNames.set(text.charCodeAt(0), text.slice(1));
		}
	for (const [unit] of deadNames) if (!dead.has(unit)) refuse('a dead name without its dead key');
	for (const [, rules] of dead)
		for (const rule of rules)
			if (rule.dead && !dead.has(rule.result)) refuse('a dead chain to no dead key');
	const vscList = (rva) => {
		const list = [];
		if (rva === null) return list;
		for (let at = rva; ; at += 4) {
			const sc = u8(at);
			const vk = u16(at + 2);
			if (sc === 0 && vk === 0) break;
			list.push({ sc, vk });
		}
		return list;
	};
	const scan = [];
	for (let i = 0; i < t.scanCount; i++) scan.push(u16(t.scan + 2 * i));
	// Every key a dead cell names must have its table, as Windows looks it up.
	for (const key of keys)
		for (const cell of key.cells)
			if (cell && cell.dead !== undefined && !dead.has(cell.dead))
				refuse('dead cell without rules');
	return {
		machine: img.machine,
		pointer: width,
		wow64,
		subsystem: img.subsystem,
		ordinal: target.ordinal,
		checks: [...checked].sort(),
		layout: {
			columns,
			modifiers: bits,
			flags: t.flags & 0xffff,
			keys,
			extra_tables: tables.slice(1).map((table) => table.rows),
			extra_keys: extra,
			dead_keys: [...dead].map(([unit, rules]) => {
				const entry = { dead: unit, rules };
				if (deadNames.has(unit)) entry.name = deadNames.get(unit);
				return entry;
			}),
			key_names: nameList(t.names, 'pKeyNames'),
			key_names_ext: nameList(t.namesExt, 'pKeyNamesExt'),
			scancodes: scan,
			e0: vscList(t.e0),
			e1: vscList(t.e1)
		}
	};
}

module.exports = { readDll, parsePe, DllError };
