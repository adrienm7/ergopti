// tools/test/test-layout-source.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source Contract
 * DESCRIPTION:
 * Replays registry and edge-case imports through the real TOML codec, preserving
 * XML the conversion projection cannot represent. Exercises superset validation,
 * conservative target reporting and the CLI's no-overwrite/no-loss boundary.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { loadLayoutSource } = require('../lib/layout-source.cjs');
const { exportXkb } = require('../lib/layout-source-xkb.cjs');
const { exportKlc } = require('../lib/layout-source-klc.cjs');
const { targetReport } = require('../lib/layout-source-report.cjs');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

const Source = loadLayoutSource();
const clone = (value) => JSON.parse(JSON.stringify(value));
const registry = path.join(REPO_ROOT, 'static', 'layouts', 'registry');
const index = JSON.parse(fs.readFileSync(path.join(registry, 'index.json'), 'utf8'));
const edges = JSON.parse(
	fs.readFileSync(shared('tests', 'corpus', 'keylayout', 'edge_cases.json'), 'utf8')
);
const preserved = [];

/** The source TOML must preserve bytes, not merely the reader's folded model. */
function roundTrip(xml, id, convention) {
	const imported = Source.importKeylayout(xml, id, convention);
	const text = Source.write(imported);
	const reloaded = Source.read(`# Source comments are ordinary TOML.\n${text}`);
	assert.equal(Source.exportKeylayout(reloaded), xml, `${id}: exact XML`);
	assert.equal(Source.write(reloaded), text, `${id}: deterministic TOML`);
	const report = clone(Source.capabilities(reloaded));
	assert.equal(report.length, 7, `${id}: every target reports`);
	assert.deepEqual(
		report.filter((entry) => entry.status === 'native').map((entry) => entry.target),
		['macos']
	);
	assert(report.every((entry) => entry.reason.length > 0));
	assert.deepEqual(
		report.find((entry) => entry.artifact === 'xkb'),
		{
			target: 'linux',
			status: 'unavailable',
			artifact: 'xkb',
			reason: 'tooling_export_required',
			blockers: ['tooling_export_required']
		},
		'the explicit export catalogue reports tool availability independently of the host'
	);
	preserved.push(xml);
	return imported;
}

assert(index.layouts.length >= 5, 'registry import coverage floor');
for (const entry of index.layouts)
	roundTrip(
		fs.readFileSync(path.join(registry, entry.file), 'utf8'),
		entry.id,
		entry.keycode_convention
	);
let edgeCount = 0;
for (const entry of edges.vectors) {
	if (!entry.canonical || !entry.canonical.name) continue;
	roundTrip(entry.keylayout, `edge_${edgeCount++}`, 'iso');
}
assert(edgeCount >= 1, 'edge import coverage floor');

// State ranges, multiplier, alternative hardware maps, sided modifiers, comments,
// non-BMP output and control entities survive even when parseModel folds/omits them.
const richXml = `<?xml version="1.1" encoding="UTF-8"?>
<!DOCTYPE keyboard SYSTEM "file://localhost/System/Library/DTDs/KeyboardLayout.dtd">
<keyboard group="126" id="-42" name="Complete &amp; retained" maxout="12">
<!-- Preserve this comment, exact quotes and unrelated metadata. -->
<layouts><layout first="0" last="17" modifiers="m" mapSet="base"/><layout first="18" last="255" modifiers="other" mapSet="jis"/></layouts>
<modifierMap id="m" defaultIndex="0"><keyMapSelect mapIndex="1"><modifier keys="rightShift rightOption?"/></keyMapSelect></modifierMap>
<modifierMap id="other" defaultIndex="9"><keyMapSelect mapIndex="9"><modifier keys="anyControl caps?"/></keyMapSelect></modifierMap>
<keyMapSet id="base"><keyMap index="0"><key code="0" action="a"/><key code="1" output="𐐀🦆ffi&#x0009;"/></keyMap><keyMap index="1" baseMapSet="base" baseIndex="0"/></keyMapSet>
<keyMapSet id="jis"><keyMap index="9"><key code="0" output="違う"/></keyMap></keyMapSet>
<actions><action id="a"><when state="none" next="10"/><when state="10" through="19" next="20" multiplier="2" output="é🦆"/><when state="20" output="complete"/></action></actions>
<terminators><when state="10" through="20" output="^"/></terminators>
</keyboard>
`;
const imported = roundTrip(richXml, 'rich', 'iso');
roundTrip('\ufeff' + richXml.replace(/\n/g, '\r\n'), 'original_bytes', 'ansi');

const complete = {
	format: Source.FORMAT,
	version: Source.VERSION,
	layout: { id: 'sample', name: 'Sample', languages: ['fr', 'en'], author: 'Example' },
	physical: { base: 'iso', ansi_extra_key: 'Backquote' },
	modifiers: [
		{ id: 'roya', mode: 'locked', keys: ['ScrollLock'] },
		{ id: 'navigation', mode: 'held', keys: ['CapsLock'] }
	],
	layers: [
		{
			id: 'base',
			required: [],
			optional: [],
			keys: { KeyA: { text: 'a' }, KeyB: { text: 'ffi🦆' }, KeyC: { dead_key: 'acute' } }
		},
		{ id: 'caps', required: ['caps_lock'], optional: ['shift'], keys: { KeyA: { text: 'A' } } },
		{
			id: 'nav',
			required: ['navigation'],
			optional: [],
			keys: { KeyJ: { action: 'arrow_left' }, KeyK: { key: 'ArrowRight', modifiers: ['shift'] } },
			platform_keys: { macos: { KeyJ: { key: 'ArrowLeft', modifiers: ['meta'] } } }
		}
	],
	dead_keys: [
		{
			id: 'acute',
			name: 'Acute',
			terminator: '´',
			rules: [
				{ input: 'a', text: 'á' },
				{ input: '^', next: 'circumflex' }
			]
		},
		{
			id: 'circumflex',
			terminator: '^',
			rules: [
				{ input: 'a', text: 'á̂🦆' },
				{ input: '^', text: '^', next: 'acute' }
			]
		}
	],
	keys: {
		KeyA: {
			name: 'First letter',
			caps_lock: 'separate',
			caps_layer: 'caps',
			caps_shift_layer: 'base',
			caps_altgr: true,
			virtual_key: 65
		}
	},
	remap: { CapsLock: 'ControlLeft', MetaRight: '' },
	shortcuts: [
		{ key: 'KeyA', modifiers: ['control'], send_key: 'KeyB', send_modifiers: ['control'] }
	],
	tap_holds: [{ key: 'CapsLock', tap: { key: 'Escape' }, hold_layer: 'nav', threshold_ms: 180 }],
	windows: {
		flags: ['shiftlock'],
		nls: [
			{
				key: 'KeyA',
				modifiers: ['control'],
				function: 'send_parameter',
				parameter_key: 'ContextMenu',
				keyup_function: 'send_base'
			}
		]
	},
	exports: {
		macos: { format: 'bundle' },
		windows: { locale: 'fr-FR', layout_id: 'a000040c', dll_name: 'ergsample' },
		linux: { name: 'sample', description: 'Sample layout' }
	}
};
assert.deepEqual(
	clone(Source.read(Source.write(complete))),
	complete,
	'all superset records survive TOML'
);
assert(
	Source.capabilities(complete).every((entry) => entry.status === 'unavailable'),
	'uncompiled source is never presented as native/emulated'
);
assert.throws(() => Source.exportKeylayout(complete), { code: 'source_export_unavailable' });

const minimal = `format = "ergopti-layout"
version = 1
[layout]
id = "dates"
name = "Dates are not records"
[physical]
base = "iso"
[[layers]]
id = "base"
required = []
optional = []
keys = {}
`;
// The actual TOML codec returns Date instances; a typeof-object check admits
// them as empty records unless the model explicitly requires a TOML table.
for (const literal of ['2026-11-07T10:00:00Z', '2026-11-07', '10:00:00']) {
	for (const field of ['windows', 'keys', 'remap', 'exports']) {
		assert.throws(() => Source.read(`${field} = ${literal}\n${minimal}`), {
			code: 'source_invalid'
		});
	}
	assert.throws(() => Source.read(minimal.replace('keys = {}', `keys = ${literal}`)), {
		code: 'source_invalid'
	});
	assert.throws(() => Source.read(`${minimal}\n[keys]\nKeyA = ${literal}\n`), {
		code: 'source_invalid'
	});
	assert.throws(() => Source.read(`${minimal}\n[exports]\nwindows = ${literal}\n`), {
		code: 'source_invalid'
	});
}

const invalid = [
	[
		'source_version',
		(s) => {
			s.version = 2;
		}
	],
	[
		'source_format',
		(s) => {
			s.format = 'another-format';
		}
	],
	[
		'source_base_convention',
		(s) => {
			s.physical.base = 'ansi';
		}
	],
	[
		'source_unknown_field',
		(s) => {
			s.layres = [];
		}
	],
	[
		'source_unicode',
		(s) => {
			s.layers[0].keys.KeyA.text = '\ud800';
		}
	],
	[
		'source_reference',
		(s) => {
			s.layers[0].keys.KeyC.dead_key = 'missing';
		}
	],
	[
		'source_reference',
		(s) => {
			s.dead_keys[0].rules[1].next = 'missing';
		}
	],
	[
		'source_duplicate',
		(s) => {
			s.layers.push(clone(s.layers[0]));
		}
	],
	[
		'source_duplicate',
		(s) => {
			s.modifiers.push(clone(s.modifiers[0]));
		}
	],
	[
		'source_duplicate',
		(s) => {
			s.dead_keys[0].rules.push({ input: 'a', text: 'other' });
		}
	],
	[
		'source_modifier_overlap',
		(s) => {
			s.layers[1].optional.push('caps_lock');
		}
	],
	[
		'source_invalid',
		(s) => {
			s.layers[0].keys.KeyA.dead_key = 'acute';
		}
	],
	[
		'source_invalid',
		(s) => {
			s.keys.KeyA.caps_lock = 'shift';
		}
	],
	[
		'source_invalid',
		(s) => {
			s.tap_holds[0].threshold_ms = Infinity;
		}
	],
	[
		'source_invalid',
		(s) => {
			s.tap_holds[0].hold_modifier = 'shift';
		}
	],
	[
		'source_reference',
		(s) => {
			s.shortcuts[0].send_modifiers = ['missing'];
		}
	],
	[
		'source_unknown_field',
		(s) => {
			s.exports.macos.unknown = true;
		}
	],
	[
		'source_base_layer',
		(s) => {
			s.layers = s.layers.filter((layer) => layer.id !== 'base');
		}
	]
];
for (const [code, mutate] of invalid) {
	const source = clone(complete);
	mutate(source);
	assert.throws(() => Source.validate(source), { code });
}
assert.throws(() => Source.importKeylayout('<keyboard/>', 'missing', 'iso'), {
	code: 'source_keylayout'
});
assert.throws(
	() =>
		Source.importKeylayout(
			richXml.replace('<keyboard', '<!ENTITY custom "hidden">\n<keyboard'),
			'entity',
			'iso'
		),
	{ code: 'source_xml_entity' }
);
assert.throws(
	() => Source.read('format = "ergopti-layout"\nformat = "duplicate"'),
	/already|duplicate/i
);

// Every admitted edit category must prevent the preservation-only exporter from
// returning the old XML. The source itself stays available for future compilers.
for (const field of [
	'modifiers',
	'layers',
	'dead_keys',
	'keys',
	'remap',
	'shortcuts',
	'tap_holds',
	'windows'
]) {
	const edited = clone(imported);
	// Cross-references stay valid: use the complete superset and exercise the
	// independent category as well wherever it does not require another record.
	Object.assign(edited, clone(complete), {
		imported_keylayout: clone(imported.imported_keylayout),
		layout: clone(imported.layout),
		physical: { base: 'iso' }
	});
	assert(Source.capabilities(edited)[0].blockers.includes(field), `${field} is reported`);
	assert.throws(() => Source.exportKeylayout(edited), { code: 'source_export_unavailable' });
}
for (const mutate of [
	(s) => {
		s.layout.name = 'Renamed';
	},
	(s) => {
		s.physical.base = 'ansi';
	},
	(s) => {
		s.physical.ansi_extra_key = 'Backquote';
	},
	(s) => {
		s.exports = { macos: { format: 'bundle' } };
	}
]) {
	const edited = clone(imported);
	mutate(edited);
	assert.throws(() => Source.exportKeylayout(edited), { code: 'source_export_unavailable' });
}

const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-layout-source-'));
try {
	const input = path.join(directory, 'input.keylayout');
	const toml = path.join(directory, 'source.toml');
	const output = path.join(directory, 'output.keylayout');
	fs.writeFileSync(input, richXml);
	const cli = (...args) =>
		spawnSync(process.execPath, [path.join(REPO_ROOT, 'tools', 'layout-source.cjs'), ...args], {
			encoding: 'utf8'
		});
	assert.equal(cli('import', 'cli_sample', 'iso', input, toml).status, 0);
	assert.equal(JSON.parse(cli('validate', toml).stdout).valid, true);
	assert.equal(JSON.parse(cli('report', toml).stdout).length, 7);
	assert.equal(cli('export-keylayout', toml, output).status, 0);
	assert.equal(fs.readFileSync(output, 'utf8'), richXml);
	assert.equal(cli('export-keylayout', toml, output).status, 1, 'existing output refused');
	assert.equal(fs.readFileSync(output, 'utf8'), richXml, 'existing output retained');
	fs.writeFileSync(toml, Source.write(complete));
	assert.equal(cli('export-keylayout', toml, path.join(directory, 'refused.keylayout')).status, 1);
	assert.equal(
		fs.existsSync(path.join(directory, 'refused.keylayout')),
		false,
		'refusal writes nothing'
	);
	assert.equal(cli('validate', toml, 'extra').status, 1, 'extra argument refused');
	fs.writeFileSync(input, Buffer.from([0xff]));
	assert.equal(
		cli('import', 'invalid_utf8', 'iso', input, path.join(directory, 'invalid.toml')).status,
		1
	);
	assert.equal(fs.existsSync(path.join(directory, 'invalid.toml')), false);

	// Same registry corpus and converter oracle as canonical parity, without the
	// registry's optional driver hints: TOML owns no such transformation request.
	for (const entry of index.layouts) {
		const xmlPath = path.join(registry, entry.file);
		const document = Source.importKeylayout(
			fs.readFileSync(xmlPath, 'utf8'),
			entry.id,
			entry.keycode_convention
		);
		if (entry.id === 'bepo' || entry.id === 'ergol') {
			assert.throws(
				() => exportXkb(document),
				entry.id === 'bepo' ? /multiple_layout/ : /control_output_on_character_key/
			);
			assert.equal(
				targetReport(document).find((report) => report.target === 'linux').status,
				'unavailable'
			);
			continue;
		}
		const compiled = exportXkb(Source.read(Source.write(document)));
		assert.equal(compiled.report.status, 'partial');
		assert(
			compiled.report.modifier_differences.length > 0,
			'actual document modifier losses reported'
		);
		assert(compiled.report.system_key_codes.includes(36), 'Return stays a system key');
		const oracleDirectory = path.join(directory, entry.id);
		fs.mkdirSync(oracleDirectory);
		const oracle = spawnSync(
			'lua',
			[
				path.join(__dirname, 'fixtures', 'keylayout-xkb-convert.lua'),
				shared(),
				path.join(REPO_ROOT, 'static', 'ergopti', 'linux', 'xkb_generation', 'data'),
				xmlPath,
				shared('layouts', 'data', 'mac_keycodes.json'),
				entry.keycode_convention,
				entry.id,
				document.layout.name,
				oracleDirectory
			],
			{ encoding: 'utf8' }
		);
		assert.equal(oracle.status, 0, oracle.stderr);
		for (const extension of ['xkb', 'XCompose'])
			assert.equal(
				compiled.files.get(`${entry.id}.${extension}`),
				fs.readFileSync(path.join(oracleDirectory, `${entry.id}.${extension}`), 'utf8'),
				`${entry.id}: ${extension} golden converter`
			);
	}

	const simpleXml = `<keyboard name="Source export">
<layouts><layout first="0" last="255" mapSet="base" modifiers="m"/></layouts>
<modifierMap id="m" defaultIndex="0"><keyMapSelect mapIndex="1"><modifier keys="command"/></keyMapSelect><keyMapSelect mapIndex="2"><modifier keys="anyControl"/></keyMapSelect></modifierMap>
<keyMapSet id="base"><keyMap index="0"><key code="0" output="a"/><key code="1" output="ffi🦆"/></keyMap><keyMap index="1" baseMapSet="base" baseIndex="0"><key code="0" output="c"/></keyMap><keyMap index="2" baseMapSet="base" baseIndex="0"><key code="0" output="x"/></keyMap></keyMapSet>
</keyboard>`;
	const simple = Source.importKeylayout(simpleXml, 'simple', 'iso');
	const partial = exportXkb(simple);
	assert.deepEqual(partial.report.source_levels[0], [], 'empty base selector is a JSON array');
	assert(
		!partial.report.modifier_differences.some(
			(row) => row.modifiers.length === 1 && row.modifiers[0] === 'command'
		),
		'Mod4 token selects the Command level without a false difference'
	);
	assert.deepEqual(partial.report.system_key_codes, [], 'empty system-key list is a JSON array');
	const noDifferences = exportXkb(
		Source.importKeylayout(
			simpleXml.replace(/<keyMapSelect[^]*?<\/keyMapSelect>/g, ''),
			'constant',
			'iso'
		)
	);
	assert.deepEqual(
		noDifferences.report.modifier_differences,
		[],
		'empty differences are a JSON array'
	);
	assert.deepEqual(
		partial.report.modifier_differences.find(
			(row) => row.modifiers.length === 1 && row.modifiers[0] === 'control'
		),
		{ modifiers: ['control'], level: 5, key_codes: [0] }
	);
	assert(partial.files.get('simple.XCompose').includes('ffi🦆'));
	assert(
		partial.report.empty_cells.length > 0,
		'missing character cells are not claimed as disabled'
	);
	// Independent type oracle: every combination selects a unique source map.
	// Equal neutral text in the second fixture must not hide action identity.
	for (const useActions of [false, true]) {
		const tokens = ['anyShift', 'caps', 'anyOption', 'anyControl', 'command'];
		const masks = Array.from({ length: 32 }, (_, mask) => mask);
		const selectors = masks
			.map(
				(mask) =>
					`<keyMapSelect mapIndex="${mask}"><modifier keys="${tokens.filter((_, bit) => mask & (1 << bit)).join(' ')}"/></keyMapSelect>`
			)
			.join('');
		const maps = masks
			.map(
				(mask) =>
					`<keyMap index="${mask}"><key code="0" ${useActions ? `action="action_${mask}"` : `output="${String.fromCodePoint(0x410 + mask)}"`}/></keyMap>`
			)
			.join('');
		const actions = useActions
			? `<actions>${masks.map((mask) => `<action id="action_${mask}"><when state="none" output="a"/></action>`).join('')}</actions>`
			: '';
		const xml = `<keyboard name="All modifiers"><layouts><layout first="0" last="255" mapSet="base" modifiers="m"/></layouts><modifierMap id="m" defaultIndex="0">${selectors}</modifierMap><keyMapSet id="base">${maps}</keyMapSet>${actions}</keyboard>`;
		const report = exportXkb(Source.importKeylayout(xml, 'all_modifiers', 'iso')).report;
		assert.equal(report.modifier_differences.length, 25);
		for (const mask of masks) {
			const shift = Boolean(mask & 1),
				caps = Boolean(mask & 2),
				option = Boolean(mask & 4),
				shortcut = Boolean(mask & 24);
			const level = shortcut
				? caps || option
					? 1
					: 5
				: option
					? shift
						? 7
						: 6
					: shift
						? caps
							? 4
							: 3
						: caps
							? 2
							: 1;
			const sourceMask = [0, 2, 1, 3, 16, 4, 5][level - 1];
			const modifiers = ['shift', 'caps', 'option', 'control', 'command'].filter(
				(_, bit) => mask & (1 << bit)
			);
			const difference = report.modifier_differences.find(
				(row) => JSON.stringify(row.modifiers) === JSON.stringify(modifiers)
			);
			if (mask === sourceMask) assert.equal(difference, undefined);
			else assert.deepEqual(difference, { modifiers, level, key_codes: [0] });
		}
	}
	for (const [label, mutate, reason] of [
		['sided modifier', (xml) => xml.replace('anyControl', 'rightControl'), /modifier:rightControl/],
		[
			'unknown attribute',
			(xml) => xml.replace('code="0"', 'code="0" surprise="x"'),
			/attribute:key.surprise/
		],
		[
			'duplicate attribute',
			(xml) => xml.replace('code="0"', 'code="0" code="1"'),
			/duplicate_attribute/
		],
		['duplicate key', (xml) => xml.replace('<key code="1"', '<key code="0"'), /duplicate:key:0/],
		['ignored base', (xml) => xml.replace(' baseIndex="0"', ''), /base_without_index/],
		['numeric alias', (xml) => xml.replace('code="1"', 'code="0.0"'), /numeric_attribute:key.code/],
		['leading zero alias', (xml) => xml.replace('code="1"', 'code="00"'), /duplicate:key:0/],
		[
			'undefined default map',
			(xml) => xml.replace('defaultIndex="0"', 'defaultIndex="99"'),
			/undefined_default_keymap/
		],
		[
			'undefined selected map',
			(xml) => xml.replace('mapIndex="1"', 'mapIndex="99"'),
			/undefined_selected_keymap/
		],
		[
			'undefined inherited map',
			(xml) => xml.replace('baseIndex="0"', 'baseIndex="99"'),
			/undefined_base_keymap/
		],
		[
			'action identifier injection',
			(xml) =>
				xml
					.replace('output="a"', 'action="bad&#x000a;name"')
					.replace(
						'</keyboard>',
						'<actions><action id="bad&#x000a;name"><when state="none" next="dead"/></action></actions></keyboard>'
					),
			/control_action_identifier/
		],
		[
			'action without neutral',
			(xml) =>
				xml.replace(
					'</keyboard>',
					'<actions><action id="not_a_keysym"><when state="acute" output="z"/></action></actions></keyboard>'
				),
			/action_without_neutral_transition/
		],
		[
			'unbound stateful action',
			(xml) =>
				xml.replace(
					'</keyboard>',
					'<actions><action id="not_a_keysym"><when state="none" output="ffi"/><when state="acute" output="z"/></action></actions></keyboard>'
				),
			/unbound_stateful_actions/
		],
		[
			'control',
			(xml) => xml.replace('output="a"', 'output="&#x0009;"'),
			/control_output_on_character_key/
		],
		['unplaced key', (xml) => xml.replace('code="0"', 'code="255"'), /unplaced_character_keys/],
		[
			'state range',
			(xml) =>
				xml.replace(
					'</keyboard>',
					'<actions><action id="a"><when state="1" through="9" output="é"/></action></actions></keyboard>'
				),
			/attribute:when.through/
		],
		[
			'output plus next',
			(xml) =>
				xml.replace(
					'</keyboard>',
					'<actions><action id="a"><when state="none" next="acute" output="é"/></action></actions></keyboard>'
				),
			/simultaneous_output_and_next/
		],
		[
			'empty transition',
			(xml) =>
				xml.replace(
					'</keyboard>',
					'<actions><action id="a"><when state="none" output=""/></action></actions></keyboard>'
				),
			/empty_action_transition/
		]
	])
		assert.throws(
			() => exportXkb(Source.importKeylayout(mutate(simpleXml), 'invalid', 'iso')),
			reason,
			label
		);
	const edited = clone(simple);
	edited.remap = { KeyA: 'KeyB' };
	assert.throws(() => exportXkb(edited), /remap/);
	for (const metadata of [
		{ name: '../escape' },
		{ description: 'Bad"name' },
		{ description: 'line\nbreak' }
	])
		assert.throws(() => exportXkb({ ...simple, exports: { linux: metadata } }), /exports.linux/);
	simple.layout.name = 'Renamed';
	simple.exports = {
		linux: { name: 'usable', description: 'Source export metadata' },
		macos: { format: 'bundle' }
	};
	fs.writeFileSync(toml, Source.write(simple));
	const bundle = path.join(directory, 'native');
	const exported = cli('export-xkb', toml, bundle);
	assert.equal(exported.status, 0, exported.stderr);
	assert.deepEqual(fs.readdirSync(bundle).sort(), [
		'export.json',
		'usable.XCompose',
		'usable.xkb',
		'xkb_types.txt'
	]);
	assert(
		fs
			.readFileSync(path.join(bundle, 'usable.xkb'), 'utf8')
			.includes('name[Group1] = "Source export metadata";')
	);
	assert.equal(JSON.parse(exported.stdout).status, 'partial');
	assert.equal(cli('export-xkb', toml, bundle).status, 1, 'existing output directory refused');
	fs.writeFileSync(toml, Source.write(edited));
	assert.equal(cli('export-xkb', toml, path.join(directory, 'refused-native')).status, 1);
	assert.equal(
		fs.existsSync(path.join(directory, 'refused-native')),
		false,
		'conversion refusal creates no output directory'
	);

	const windowsMetadata = { locale: 'fr-FR', layout_id: '0000040c', dll_name: 'kbdtest' };
	const forWindows = (xml, id = 'windows_sample') => ({
		...Source.importKeylayout(xml, id, 'iso'),
		exports: { windows: clone(windowsMetadata) }
	});
	const golden = require('../codegen/codegen-windows-keyboard-layout.cjs').buildSources();
	for (const entry of index.layouts) {
		const document = Source.importKeylayout(
			fs.readFileSync(path.join(registry, entry.file), 'utf8'),
			entry.id,
			entry.keycode_convention
		);
		document.exports = { windows: clone(windowsMetadata) };
		if (entry.id === 'bepo' || entry.id === 'ergol' || entry.id.startsWith('ergopti_plus')) {
			assert.throws(
				() => exportKlc(document),
				entry.id === 'bepo' ? /multiple_layout/ : entry.id === 'ergol' ? /control_output/ : /SGCAP/
			);
			assert.equal(
				targetReport(document).find((row) => row.target === 'windows').status,
				'unavailable'
			);
			continue;
		}
		const compiled = exportKlc(Source.read(Source.write(document)));
		const bytes = compiled.files.get('kbdtest.klc');
		assert(Buffer.isBuffer(bytes));
		assert.deepEqual([...bytes.subarray(0, 2)], [0xff, 0xfe]);
		const decoded = bytes.subarray(2).toString('utf16le');
		assert(!/(?<!\r)\n/u.test(decoded), 'MSKLC uses CRLF');
		assert(decoded.includes('LOCALEID\t"0000040c"'));
		assert.equal(compiled.report.dead_keys, 7);
		assert.equal(compiled.report.ligatures, 9);
		assert.equal(compiled.report.uncompiled_modifiers.length, 24);
		if (entry.id === 'ergopti') {
			const fromLayout = (text) =>
				text.replace(/\r\n/g, '\n').split('\nSHIFTSTATE\n')[1].split('\nDESCRIPTIONS\n')[0];
			assert.equal(
				fromLayout(decoded),
				fromLayout(golden.klc),
				'existing Windows generator golden: all native rows, ligatures, dead transitions and key names'
			);
		}
	}
	const klcXml = `<keyboard name="Portable KLC">
<layouts><layout first="0" last="255" mapSet="base" modifiers="m"/></layouts>
<modifierMap id="m" defaultIndex="0"><keyMapSelect mapIndex="1"><modifier keys="anyShift"/><modifier keys="caps"/></keyMapSelect><keyMapSelect mapIndex="2"><modifier keys="anyOption anyShift? caps?"/></keyMapSelect><keyMapSelect mapIndex="3"><modifier keys="command"/></keyMapSelect></modifierMap>
<keyMapSet id="base"><keyMap index="0"><key code="0" action="letter"/><key code="1" action="acute_key"/><key code="2" output="🦆"/><key code="3" output="ffi"/><key code="4" action="grave_key"/></keyMap><keyMap index="1" baseMapSet="base" baseIndex="0"><key code="0" action="upper"/></keyMap><keyMap index="2" baseMapSet="base" baseIndex="0"><key code="0" output="€"/></keyMap><keyMap index="3" baseMapSet="base" baseIndex="0"><key code="0" output="x"/></keyMap></keyMapSet>
<actions><action id="letter"><when state="none" output="a"/><when state="acute" output="á"/><when state="grave" output="à"/></action><action id="upper"><when state="none" output="A"/><when state="acute" output="Á"/><when state="grave" output="À"/></action><action id="acute_key"><when state="none" next="acute"/><when state="acute" output="´"/></action><action id="grave_key"><when state="none" next="grave"/><when state="acute" next="grave"/><when state="grave" output="&#x0060;"/></action></actions>
<terminators><when state="acute" output="´"/><when state="grave" output="&#x0060;"/></terminators>
</keyboard>`;
	const windowsSource = forWindows(klcXml);
	windowsSource.layout.author = 'Zoë';
	const nativeKlc = exportKlc(windowsSource);
	const klcText = nativeKlc.files.get('kbdtest.klc').subarray(2).toString('utf16le');
	assert(klcText.includes('COMPANY\t"Zoë"'));
	assert(klcText.includes('VERSION\t1.0'));
	assert(klcText.includes('d83e\tdd86'), 'non-BMP output is a UTF-16 ligature');
	assert(klcText.includes('0066\t0066\t0069'), 'three-character ligature retained');
	assert(klcText.includes('0060\t0060@'), 'dead-key chaining retained');
	assert.match(klcText, /\tA\t1\t0061\t0041\t-1\t-1\t20ac\t20ac/, 'Caps Lock is carried by CAPLOK');
	const command = nativeKlc.report.uncompiled_modifiers.find(
		(row) => row.modifiers.length === 1 && row.modifiers[0] === 'command'
	);
	assert.equal(
		command.source_cells.find((cell) => cell.code === 0).text,
		'x',
		'report preserves the actual uncompiled Command cell'
	);
	assert.deepEqual(nativeKlc.report.system_keys, [], 'no system mappings is an array');
	assert.equal(nativeKlc.report.virtual_keys.find((key) => key.key === 'KeyA').virtual_key, 'A');
	assert.throws(
		() =>
			exportKlc({ ...windowsSource, exports: { windows: { ...windowsMetadata, unknown: true } } }),
		{ code: 'source_unknown_field' }
	);
	assert.equal(targetReport(windowsSource).find((row) => row.target === 'windows').artifact, 'klc');
	for (const [label, mutate, reason] of [
		['long ligature', (xml) => xml.replace('output="ffi"', 'output="abcde"'), /at most 4/],
		[
			'long dead result',
			(xml) => xml.replace('output="á"', 'output="á"'),
			/unrepresentable_dead_transitions/
		],
		[
			'non-BMP dead result',
			(xml) => xml.replace('output="á"', 'output="🦆"'),
			/unrepresentable_dead_transitions/
		],
		[
			'long terminator',
			(xml) =>
				xml.replace(
					'<terminators><when state="acute" output="´"/>',
					'<terminators><when state="acute" output="xx"/>'
				),
			/one-unit terminator/
		],
		[
			'missing map',
			(xml) => xml.replace('defaultIndex="0"', 'defaultIndex="99"'),
			/undefined_default_keymap/
		],
		[
			'cyclic base',
			(xml) =>
				xml.replace('<keyMap index="0">', '<keyMap index="0" baseMapSet="base" baseIndex="1">'),
			/cyclic_base_keymap/
		],
		[
			'missing action',
			(xml) => xml.replace('action="letter"', 'action="missing"'),
			/undefined_key_action/
		],
		[
			'control output',
			(xml) => xml.replace('output="ffi"', 'output="&#x0009;"'),
			/control_output_on_character_key/
		],
		[
			'reserved WCH_NONE',
			(xml) => xml.replace('output="ffi"', 'output="&#xF000;"'),
			/reserved_windows_character/
		],
		[
			'reserved WCH_DEAD',
			(xml) => xml.replace('output="á"', 'output="&#xF001;"'),
			/reserved_windows_character/
		],
		[
			'reserved WCH_LGTR',
			(xml) => xml.replace('output="ffi"', 'output="a&#xF002;"'),
			/reserved_windows_character/
		],
		[
			'action identifier newline',
			(xml) => xml.replaceAll('acute_key', 'acute&#x000a;key'),
			/control_action_identifier/
		],
		[
			'sided modifier',
			(xml) => xml.replace('keys="command"', 'keys="rightShift"'),
			/modifier:rightShift/
		],
		[
			'state range',
			(xml) => xml.replace('state="acute" output="á"', 'state="acute" through="9" output="á"'),
			/attribute:when.through/
		]
	]) {
		const mutated = mutate(klcXml);
		assert.notEqual(mutated, klcXml, `${label}: mutation pin exists`);
		assert.throws(() => exportKlc(forWindows(mutated)), reason, label);
	}
	const capsOnly = `<keyboard name="Caps only"><layouts><layout first="0" last="255" mapSet="base" modifiers="m"/></layouts><modifierMap id="m" defaultIndex="0"><keyMapSelect mapIndex="1"><modifier keys="caps"/></keyMapSelect></modifierMap><keyMapSet id="base"><keyMap index="0"><key code="0" output="a"/></keyMap><keyMap index="1" baseMapSet="base" baseIndex="0"><key code="1" output="s"/></keyMap></keyMapSet></keyboard>`;
	assert.throws(() => exportKlc(forWindows(capsOnly)), /unrepresented_caps_character_key/);
	for (const change of [
		{ dll_name: '../file' },
		{ dll_name: 'toolongname' },
		{ locale: 'bad"locale' },
		{ layout_id: 'a000040c' },
		{ layout_id: '00000000' }
	])
		assert.throws(
			() =>
				exportKlc({ ...windowsSource, exports: { windows: { ...windowsMetadata, ...change } } }),
			/exports.windows/
		);
	assert.throws(
		() =>
			exportKlc({ ...windowsSource, layout: { ...windowsSource.layout, author: 'Author\nline' } }),
		/layout.author/
	);
	assert.throws(() => exportKlc({ ...windowsSource, remap: { KeyA: 'KeyB' } }), /remap/);
	fs.writeFileSync(toml, Source.write(windowsSource));
	const klcDirectory = path.join(directory, 'klc');
	assert.equal(cli('export-klc', toml, klcDirectory, 'unexpected').status, 1);
	assert.equal(fs.existsSync(klcDirectory), false, 'unknown KLC arguments precede mkdir');
	const cliKlc = cli('export-klc', toml, klcDirectory);
	assert.equal(cliKlc.status, 0, cliKlc.stderr);
	assert.deepEqual(fs.readdirSync(klcDirectory).sort(), ['export.json', 'kbdtest.klc']);
	assert.deepEqual(
		fs.readFileSync(path.join(klcDirectory, 'kbdtest.klc')),
		nativeKlc.files.get('kbdtest.klc')
	);
	assert.equal(
		cli('export-klc', toml, klcDirectory).status,
		1,
		'existing KLC output directory refused'
	);
	fs.writeFileSync(
		toml,
		Source.write(forWindows(klcXml.replace('output="ffi"', 'output="abcde"')))
	);
	assert.equal(cli('export-klc', toml, path.join(directory, 'refused-klc')).status, 1);
	assert.equal(
		fs.existsSync(path.join(directory, 'refused-klc')),
		false,
		'KLC refusal precedes mkdir'
	);
} finally {
	fs.rmSync(directory, { recursive: true, force: true });
}

console.log(
	`[OK] layout source: ${preserved.length} exact XML/TOML round trips, ${invalid.length} invalid-source controls, XKB/KLC golden corpus and target/CLI refusal boundaries`
);
