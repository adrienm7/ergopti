// tools/test/test-windows-exe-av-surface.cjs
// Fails when the ErgoptiPlus.exe antivirus-surface gate could let the v1.0.4
// class of verdict through: the PE resource reader must find the compiled
// script and the bundle, a forbidden inline PowerShell P/Invoke stage or an
// encoded-command stage must fail, a ceiling must not be exceeded, and the
// build stage must run the gate on the compiled exe before it is signed.
// Synthetic PE images keep the test
// independent of a compiler; CI runs the same gate on the real build.
'use strict';
const assert = require('node:assert/strict');
const childProcess = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const {
	parsePe,
	readZip,
	countSection,
	breakdownFiles,
	readSourceFiles,
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

// 5. The v1.0.5 updater stage: worker source carried as Base64 in the
// environment, decoded, compiled with ScriptBlock::Create and launched through
// -EncodedCommand. Sandboxes score that chain as a malware stage.
const v105Stage =
	CLEAN_SCRIPT +
	'Args := ["-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", Payload]\n' +
	"Bootstrap := '$source=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($p));$worker=[ScriptBlock]::Create($source)'\n";
const v105Errors = scanExecutable(exe(v105Stage), policy).errors.join('\n');
for (const id of ['powershell_encoded_command', 'scriptblock_create', 'base64_decode'])
	assert.match(
		v105Errors,
		new RegExp(`script: forbidden ${id}`),
		`${id} must be forbidden in the script`
	);
assert.match(
	scanExecutable(
		exe(CLEAN_SCRIPT, [['vendor/a.ps1', 'powershell -EncodedCommand AAAA']]),
		policy
	).errors.join('\n'),
	/bundle: forbidden powershell_encoded_command/,
	'a bundled worker cannot launch an encoded command either'
);

// 6. A ceiling fails when exceeded and asks to be lowered when undershot.
const bypassMax = policy.script.ceilings.powershell_policy_bypass.max;
const tooMany = CLEAN_SCRIPT + '"-ExecutionPolicy", "Bypass"\n'.repeat(bypassMax + 1);
assert.match(
	scanExecutable(exe(tooMany), policy).errors.join('\n'),
	new RegExp(`powershell_policy_bypass .* occurs ${bypassMax + 1} times, ceiling ${bypassMax}`)
);
assert.ok(
	scanExecutable(exe(CLEAN_SCRIPT), policy).notes.some((note) =>
		note.includes('powershell_policy_bypass dropped to 0; lower its ceiling')
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

// 7. The naming left over from the keystats rename and the API families that
// engines weigh are gated: the wording is forbidden in the script and the
// bundle, a family with a legitimate use is held at its measured count.
for (const [label, entries, script] of [
	['script', undefined, CLEAN_SCRIPT + 'KeylogInit()\n'],
	['bundle', [['vendor/a.ps1', 'function Start-Keylogger {}']], CLEAN_SCRIPT]
])
	assert.match(
		scanExecutable(exe(script, entries), policy).errors.join('\n'),
		new RegExp(`${label}: forbidden keylog_wording`),
		`the keylog wording must be forbidden in the ${label}`
	);
assert.deepEqual(
	scanExecutable(exe(CLEAN_SCRIPT + 'DllCall("user32\\SetWindowsHookExW")\n'), policy).errors,
	[],
	'a documented hook import stays inside its ceiling'
);
const hookMax = policy.script.ceilings.keyboard_hook_api.max;
assert.match(
	scanExecutable(
		exe(CLEAN_SCRIPT + 'DllCall("user32\\SetWindowsHookExW")\n'.repeat(hookMax + 1)),
		policy
	).errors.join('\n'),
	new RegExp(`keyboard_hook_api .* occurs ${hookMax + 1} times, ceiling ${hookMax}`),
	'the keyboard hook import count is capped'
);
for (const [id, sample] of [
	['key_state_polling', 'GetAsyncKeyState'],
	['injection_wording', 'LoadLibraryW'],
	['elevation_wording', 'requireAdministrator'],
	['registry_run_key', 'CurrentVersion\\Run'],
	['clipboard_listener', 'AddClipboardFormatListener'],
	['screen_capture_api', 'BitBlt']
])
	assert.match(
		scanExecutable(exe(CLEAN_SCRIPT, [['vendor/a.ps1', sample]]), policy).errors.join('\n'),
		new RegExp(`bundle: forbidden ${id}`),
		`${id} must be forbidden in the bundle`
	);
assert.match(
	scanExecutable(exe(CLEAN_SCRIPT + 'URLDownloadToFile(a, b)\n'), policy).errors.join('\n'),
	/script: forbidden download_api/,
	'a download API call must not appear in the compiled script'
);

// 8. Counts of every family are returned for the per-build record, and the
// breakdown names the files that hold them, largest first.
const surface = scanExecutable(
	exe(CLEAN_SCRIPT + 'SendInput\nSendInput\n', [
		['vendor/a.ps1', 'powershell powershell'],
		['vendor/b.ps1', 'powershell']
	]),
	policy
);
assert.equal(surface.counts.script.send_input_api, 2);
assert.equal(surface.counts.bundle.powershell_mentions, 3);
assert.deepEqual(surface.bundleBreakdown.powershell_mentions, [
	['vendor/a.ps1', 2],
	['vendor/b.ps1', 1]
]);
assert.deepEqual(countSection('a SendInput', { reported: { x: 'SendInput', y: 'zzz' } }), {
	x: 1,
	y: 0
});
assert.deepEqual(
	breakdownFiles(
		[
			{ name: 'low.ahk', text: 'x' },
			{ name: 'b.ahk', text: 'xx' },
			{ name: 'a.ahk', text: 'xx' }
		],
		{ reported: { x: 'x' } },
		2
	),
	{
		x: [
			['a.ahk', 2],
			['b.ahk', 2]
		]
	}
);
assert.equal(surface.signed, false);

// 9. The source breakdown reads the driver folder without its tests.
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'av-surface-'));
try {
	fs.mkdirSync(path.join(scratch, 'tests'));
	fs.mkdirSync(path.join(scratch, 'adapters'));
	fs.writeFileSync(path.join(scratch, 'tests', 't.ahk'), 'SendInput');
	fs.writeFileSync(path.join(scratch, 'adapters', 'a.ahk'), 'SendInput');
	fs.writeFileSync(path.join(scratch, 'adapters', 'note.txt'), 'SendInput');
	assert.deepEqual(readSourceFiles(scratch), [{ name: 'adapters/a.ahk', text: 'SendInput' }]);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}

// 10. The command line records the counts with the exe hash.
const recordDir = fs.mkdtempSync(path.join(os.tmpdir(), 'av-surface-'));
try {
	const image = exe(CLEAN_SCRIPT + 'SendInput\n');
	const exePath = path.join(recordDir, 'ErgoptiPlus.exe');
	const recordPath = path.join(recordDir, 'counts.json');
	fs.writeFileSync(exePath, image);
	const run = childProcess.spawnSync(
		process.execPath,
		[path.join(root, 'tools/ci/windows-exe-av-surface.cjs'), '--record', recordPath, exePath],
		{ encoding: 'utf8' }
	);
	assert.equal(run.status, 0, run.stderr);
	const record = JSON.parse(fs.readFileSync(recordPath, 'utf8'));
	assert.equal(record.sha256, crypto.createHash('sha256').update(image).digest('hex'));
	assert.equal(record.bytes, image.length);
	assert.equal(record.authenticode, false);
	assert.equal(record.script.send_input_api, 1);
	assert.equal(record.bundle.powershell_mentions, 0);
	assert.equal(
		childProcess.spawnSync(process.execPath, [
			path.join(root, 'tools/ci/windows-exe-av-surface.cjs'),
			'--record'
		]).status,
		1,
		'--record without a value must fail loudly'
	);
} finally {
	fs.rmSync(recordDir, { recursive: true, force: true });
}

assert.throws(
	() => validatePolicy({ ...policy, schema: 2 }),
	/schema 1/,
	'an unknown policy schema must be refused'
);

// 11. The build stage runs the gate on the compiled exe between compile and sign.
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
assert.ok(
	step.includes('--record') && step.includes('GITHUB_STEP_SUMMARY'),
	'the gate step records the counts and prints the hash in the job summary'
);
assert.ok(
	step.indexOf('--record') < step.indexOf('throw "ErgoptiPlus.exe exceeds'),
	'the record is written before a failing gate throws'
);
const keep = workflow.indexOf('- name: Keep the ErgoptiPlus.exe antivirus surface record');
assert.ok(
	keep > gate && keep < sign && workflow.slice(keep, sign).includes('actions/upload-artifact@'),
	'the record is uploaded with the build, before signing'
);

console.log(
	'[OK] ErgoptiPlus.exe antivirus surface: resources read, stages forbidden, ceilings held.'
);
