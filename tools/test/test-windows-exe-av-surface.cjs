// tools/test/test-windows-exe-av-surface.cjs
// Fails when the ErgoptiPlus.exe antivirus-surface gate could let the v1.0.4
// class of verdict through: the PE resource reader must find the compiled
// script and the bundle, a forbidden inline PowerShell P/Invoke stage must
// fail, a ceiling must not be exceeded, and the build stage must run the gate
// on the compiled exe before it is signed. Synthetic PE images keep the test
// independent of a compiler; CI runs the same gate on the real build.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const {
	parsePe,
	readZip,
	validatePolicy,
	scanExecutable,
	POLICY_PATH
} = require('../ci/windows-exe-av-surface.cjs');

const root = path.resolve(__dirname, '../..');

/** Builds a ZIP with one deflated member per entry. */
function zip(entries) {
	const locals = [];
	const centrals = [];
	let offset = 0;
	for (const [name, text] of entries) {
		const nameBytes = Buffer.from(name, 'utf8');
		const raw = Buffer.from(text, 'utf8');
		const packed = zlib.deflateRawSync(raw);
		const local = Buffer.alloc(30);
		local.writeUInt32LE(0x04034b50, 0);
		local.writeUInt16LE(8, 8);
		local.writeUInt32LE(packed.length, 18);
		local.writeUInt32LE(raw.length, 22);
		local.writeUInt16LE(nameBytes.length, 26);
		const central = Buffer.alloc(46);
		central.writeUInt32LE(0x02014b50, 0);
		central.writeUInt16LE(8, 10);
		central.writeUInt32LE(packed.length, 20);
		central.writeUInt32LE(raw.length, 24);
		central.writeUInt16LE(nameBytes.length, 28);
		central.writeUInt32LE(offset, 42);
		locals.push(local, nameBytes, packed);
		centrals.push(central, nameBytes);
		offset += local.length + nameBytes.length + packed.length;
	}
	const directory = Buffer.concat(centrals);
	const end = Buffer.alloc(22);
	end.writeUInt32LE(0x06054b50, 0);
	end.writeUInt16LE(entries.length, 8);
	end.writeUInt16LE(entries.length, 10);
	end.writeUInt32LE(directory.length, 12);
	end.writeUInt32LE(offset, 16);
	return Buffer.concat([...locals, directory, end]);
}

/**
 * Builds a PE32+ image whose .rsrc holds RCDATA resources, keyed by numeric
 * id or by name, the way Ahk2Exe stores the script and the bundle.
 */
function pe(resources, { signed = false } = {}) {
	const SECTION_RVA = 0x1000;
	const named = resources.filter(([key]) => typeof key === 'string');
	const numbered = resources.filter(([key]) => typeof key === 'number');
	const ordered = [...named, ...numbered];
	const parts = [];
	let size = 0;
	const reserve = (length) => {
		const at = size;
		const buffer = Buffer.alloc(length);
		parts.push(buffer);
		size += length;
		return { at, buffer };
	};
	const rootDir = reserve(16 + 8);
	const typeDir = reserve(16 + 8 * ordered.length);
	const langDirs = ordered.map(() => reserve(16 + 8));
	const dataEntries = ordered.map(() => reserve(16));
	const names = named.map(([key]) => {
		const text = Buffer.from(key, 'utf16le');
		const entry = reserve(2 + text.length);
		entry.buffer.writeUInt16LE(key.length, 0);
		text.copy(entry.buffer, 2);
		return entry;
	});
	const blobs = ordered.map(([, data]) => {
		const blob = reserve(data.length + ((8 - (data.length % 8)) % 8));
		data.copy(blob.buffer);
		return blob;
	});
	rootDir.buffer.writeUInt16LE(1, 14);
	rootDir.buffer.writeUInt32LE(10, 16);
	rootDir.buffer.writeUInt32LE((0x80000000 | typeDir.at) >>> 0, 20);
	typeDir.buffer.writeUInt16LE(named.length, 12);
	typeDir.buffer.writeUInt16LE(numbered.length, 14);
	ordered.forEach(([key, data], index) => {
		const id = typeof key === 'string' ? (0x80000000 | names[index].at) >>> 0 : key;
		typeDir.buffer.writeUInt32LE(id, 16 + index * 8);
		typeDir.buffer.writeUInt32LE((0x80000000 | langDirs[index].at) >>> 0, 20 + index * 8);
		langDirs[index].buffer.writeUInt16LE(1, 14);
		langDirs[index].buffer.writeUInt32LE(1033, 16);
		langDirs[index].buffer.writeUInt32LE(dataEntries[index].at, 20);
		dataEntries[index].buffer.writeUInt32LE(SECTION_RVA + blobs[index].at, 0);
		dataEntries[index].buffer.writeUInt32LE(data.length, 4);
	});
	const rsrc = Buffer.concat(parts);
	const headers = Buffer.alloc(0x400);
	headers.writeUInt16LE(0x5a4d, 0);
	headers.writeUInt32LE(0x40, 0x3c);
	headers.writeUInt32LE(0x00004550, 0x40);
	headers.writeUInt16LE(0x8664, 0x44);
	headers.writeUInt16LE(1, 0x46);
	headers.writeUInt16LE(240, 0x54);
	const optional = 0x58;
	headers.writeUInt16LE(0x20b, optional);
	const directories = optional + 112;
	headers.writeUInt32LE(SECTION_RVA, directories + 2 * 8);
	headers.writeUInt32LE(rsrc.length, directories + 2 * 8 + 4);
	if (signed) {
		headers.writeUInt32LE(0x400 + rsrc.length, directories + 4 * 8);
		headers.writeUInt32LE(8, directories + 4 * 8 + 4);
	}
	const section = optional + 240;
	headers.write('.rsrc', section, 'latin1');
	headers.writeUInt32LE(rsrc.length, section + 8);
	headers.writeUInt32LE(SECTION_RVA, section + 12);
	headers.writeUInt32LE(rsrc.length, section + 16);
	headers.writeUInt32LE(0x400, section + 20);
	return Buffer.concat([headers, rsrc, signed ? Buffer.alloc(8) : Buffer.alloc(0)]);
}

const policy = validatePolicy(JSON.parse(fs.readFileSync(POLICY_PATH, 'utf8')));
const CLEAN_SCRIPT = '; <COMPILER: v1.1.37.02a2>\nRunWait(Cmd, , "Hide")\n';
const exe = (script, bundleEntries = [['vendor/worker.ps1', 'Write-Output 1']], options) =>
	pe(
		[
			['BUILD\\STATIC_BUNDLE.ZIP', zip(bundleEntries)],
			[1, Buffer.from(script, 'utf8')]
		],
		options
	);

// 1. The reader finds both resources and the members of the deflated bundle.
const parsed = parsePe(exe(CLEAN_SCRIPT));
assert.equal(parsed.signed, false);
assert.equal(parsed.resources.get('10/1').toString('utf8'), CLEAN_SCRIPT);
assert.deepEqual(
	readZip(parsed.resources.get('10/BUILD\\STATIC_BUNDLE.ZIP')).map((member) => [
		member.name,
		member.data.toString('utf8')
	]),
	[['vendor/worker.ps1', 'Write-Output 1']]
);
assert.equal(parsePe(exe(CLEAN_SCRIPT, undefined, { signed: true })).signed, true);
assert.throws(() => parsePe(Buffer.from('not a pe')), /MZ/);
assert.throws(
	() => scanExecutable(pe([[1, Buffer.from(CLEAN_SCRIPT)]]), policy),
	/STATIC_BUNDLE\.ZIP/,
	'an exe without its bundle cannot be admitted as scanned'
);

// 2. A script within every ceiling passes.
assert.deepEqual(scanExecutable(exe(CLEAN_SCRIPT), policy).errors, []);

// 3. The v1.0.4 stage: inline Add-Type/DllImport P/Invoke in the compiled script.
const v104Stage =
	CLEAN_SCRIPT +
	'Run("powershell.exe -NoProfile -WindowStyle Hidden -Command `"Add-Type -TypeDefinition ' +
	'\'[DllImport(\\"user32.dll\\")] static extern IntPtr GetClipboardData(uint f);\'`"")\n';
const v104Errors = scanExecutable(exe(v104Stage), policy).errors.join('\n');
for (const id of ['inline_csharp_compile', 'pinvoke_declaration', 'pinvoke_type_definition'])
	assert.match(v104Errors, new RegExp(`forbidden ${id}`), `${id} must be forbidden in the script`);

// 4. The first-launch unzip through PowerShell is forbidden again.
assert.match(
	scanExecutable(exe(CLEAN_SCRIPT + 'x := "Expand-Archive -LiteralPath"\n'), policy).errors.join(
		'\n'
	),
	/forbidden powershell_unzip/
);

// 5. A ceiling fails when exceeded and asks to be lowered when undershot.
const encodedMax = policy.script.ceilings.powershell_encoded_command.max;
const tooMany = CLEAN_SCRIPT + '"-EncodedCommand"\n'.repeat(encodedMax + 1);
assert.match(
	scanExecutable(exe(tooMany), policy).errors.join('\n'),
	new RegExp(`powershell_encoded_command .* occurs ${encodedMax + 1} times, ceiling ${encodedMax}`)
);
if (encodedMax > 0)
	assert.ok(
		scanExecutable(exe(CLEAN_SCRIPT), policy).notes.some((note) =>
			note.includes('powershell_encoded_command dropped to 0; lower its ceiling')
		)
	);
const bundleBypass = policy.bundle.ceilings.powershell_policy_bypass.max;
assert.match(
	scanExecutable(
		exe(CLEAN_SCRIPT, [['vendor/a.ps1', '-ExecutionPolicy Bypass\n'.repeat(bundleBypass + 1)]]),
		policy
	).errors.join('\n'),
	/bundle: powershell_policy_bypass/
);
assert.equal(
	scanExecutable(exe(CLEAN_SCRIPT, [['vendor/a.dll', 'Add-Type'.repeat(99)]]), policy).errors
		.length,
	0,
	'binary bundle members are not scanned as text'
);

// 6. The keylogger wording is measured on every build without gating it.
assert.ok(
	scanExecutable(exe(CLEAN_SCRIPT + 'KeyloggerInit()\n'), policy).notes.includes(
		'script: keylogger_wording = 1 (reported only)'
	)
);
assert.throws(
	() => validatePolicy({ ...policy, schema: 2 }),
	/schema 1/,
	'an unknown policy schema must be refused'
);

// 7. The build stage runs the gate on the compiled exe between compile and sign.
const workflow = fs.readFileSync(path.join(root, '.github/workflows/ci-windows.yml'), 'utf8');
const compile = workflow.indexOf('- name: Compile ErgoptiPlus.ahk');
const gate = workflow.indexOf('- name: Check the ErgoptiPlus.exe antivirus surface');
const sign = workflow.indexOf('- name: Sign and verify ErgoptiPlus.exe');
assert.ok(compile > 0 && gate > compile && sign > gate, 'the gate runs between compile and sign');
const step = workflow.slice(gate, workflow.indexOf('- name:', gate + 1));
assert.ok(
	step.includes('node tools/ci/windows-exe-av-surface.cjs') && step.includes('ErgoptiPlus.exe'),
	'the gate step scans the compiled exe'
);
assert.ok(!/continue-on-error/.test(step), 'the gate step must be able to fail the build');

console.log(
	'[OK] ErgoptiPlus.exe antivirus surface: resources read, stages forbidden, ceilings held.'
);
