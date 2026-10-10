// tools/test/test-menu-unavailable-rows.cjs

/**
 * ==============================================================================
 * MODULE: Rows a Platform Lacks Are Hidden or Greyed, as Declared
 * DESCRIPTION:
 * The maintainer's two cases for a menu row restricted by `platforms`, each
 * declared on the row (2026-09-30):
 *   - NOT APPLICABLE on an OS (`unavailable = "hide"`): the row makes no sense
 *     there, is never drawn there and owes no reason, so it carries none.
 *   - NOT YET PORTED to an OS (`unavailable = "grey"`): the feature exists
 *     elsewhere, so the row is drawn disabled with its label and the short
 *     form of its translated reason (the text before its first colon).
 * A restricted row without the field is hidden, as before the field existed.
 * A row its `disabled_when` greys where it is drawn can say why in the same
 * form (`disabled_reason_key`, on a command, check, toggle or identified labelled group row): the Uninstall row of a local
 * version run from source. One rule for both, which differ only in how the
 * condition is evaluated.
 *
 * WHAT THIS HOLDS:
 *   1. Every declaration is one of the two values, on a row whose platforms
 *      leave some platform out; a hidden row has no reason_key; a greyed row
 *      has an i18n label and a reason_key; a disabled_reason_key sits on a
 *      command/check/toggle row or an identified group with an i18n label and the disabled_when that greys it
 *      (the generator refuses the same).
 *   2. Every greyed row's reason opens with a short head in every locale, so
 *      the stand-in label stays narrow on every tray.
 *   3. Both renderers draw the stand-in (shared Lua and AutoHotkey), for both
 *      conditions; each driver's suite renders one.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');
const RENDERERS = [
	path.join(SP, '_shared', 'lua', 'menu', 'renderer.lua'),
	path.join(SP, 'windows', 'infra', 'manifest_menu.ahk')
];

const PLATFORMS = ['ahk', 'hs', 'linux'];
// Wider than this, a greyed stand-in stretches the whole tray.
const MAX_HEAD = 40;

/**
 * The short head of a translated reason: its text before the first colon,
 * ASCII or full-width, as the renderers cut it.
 * @param {string} text
 * @returns {string}
 */
function reasonHead(text) {
	const cuts = [':', '：'].map((mark) => text.indexOf(mark)).filter((at) => at >= 0);
	return (cuts.length > 0 ? text.slice(0, Math.min(...cuts)) : text).trim();
}

/**
 * The declaration errors of one row.
 * @param {string} where Row name for the messages.
 * @param {object} row Manifest row.
 * @returns {string[]}
 */
function rowErrors(where, row) {
	const errors = [];
	if (row.disabled_reason_key !== undefined) {
		if (typeof row.disabled_reason_key !== 'string' || row.disabled_reason_key === '')
			errors.push(`${where}: disabled_reason_key must name a locale key.`);
		if (!['command', 'check', 'toggle', 'group'].includes(row.type))
			errors.push(
				`${where}: disabled_reason_key is read on command/check/toggle rows or identified labelled groups.`
			);
		if (
			row.type === 'group' &&
			(typeof row.id !== 'string' ||
				row.id === '' ||
				typeof row.i18n !== 'string' ||
				row.i18n === '' ||
				!Array.isArray(row.disabled_when) ||
				row.disabled_when.length === 0 ||
				Object.keys(row.disabled_when).length !== row.disabled_when.length ||
				Array.from(row.disabled_when).some((key) => typeof key !== 'string' || key === ''))
		)
			errors.push(
				`${where}: a reasoned group needs its identity, i18n label and nonempty disabled_when keys.`
			);
		if (!Array.isArray(row.disabled_when) || row.disabled_when.length === 0)
			errors.push(`${where}: disabled_reason_key needs the disabled_when that greys the row.`);
		if (typeof row.i18n !== 'string') errors.push(`${where}: a greyed row needs an i18n label.`);
	}
	if (row.unavailable === undefined) return errors;
	if (row.unavailable !== 'hide' && row.unavailable !== 'grey')
		errors.push(`${where}: unavailable must be "hide" or "grey".`);
	const restricted =
		Array.isArray(row.platforms) && PLATFORMS.some((p) => !row.platforms.includes(p));
	if (!restricted) errors.push(`${where}: unavailable needs platforms that leave one out.`);
	if (row.unavailable === 'hide' && row.reason_key !== undefined)
		errors.push(`${where}: a hidden row carries no reason_key.`);
	if (row.unavailable === 'grey') {
		if (typeof row.reason_key !== 'string')
			errors.push(`${where}: a greyed row needs a reason_key.`);
		if (typeof row.i18n !== 'string') errors.push(`${where}: a greyed row needs an i18n label.`);
	}
	return errors;
}

// The rules on the shapes they must tell apart.
{
	const base = { type: 'command', id: 'x', i18n: 'menu.x', platforms: ['ahk'] };
	assert.deepEqual(rowErrors('f', { ...base, unavailable: 'hide' }), []);
	assert.deepEqual(rowErrors('f', { ...base, unavailable: 'grey', reason_key: 'r' }), []);
	assert.equal(rowErrors('f', { ...base, unavailable: 'hide', reason_key: 'r' }).length, 1);
	assert.equal(rowErrors('f', { ...base, unavailable: 'grey' }).length, 1);
	assert.equal(
		rowErrors('f', { ...base, i18n: undefined, unavailable: 'grey', reason_key: 'r' }).length,
		1
	);
	assert.equal(rowErrors('f', { ...base, platforms: undefined, unavailable: 'hide' }).length, 1);
	assert.equal(rowErrors('f', { ...base, platforms: PLATFORMS, unavailable: 'hide' }).length, 1);
	assert.equal(rowErrors('f', { ...base, unavailable: 'greyed' }).length, 1);
	const drawn = { type: 'command', id: 'y', i18n: 'menu.y', disabled_when: ['installed_build'] };
	assert.deepEqual(rowErrors('f', { ...drawn, disabled_reason_key: 'r' }), []);
	assert.deepEqual(rowErrors('f', { ...drawn, type: 'toggle', disabled_reason_key: 'r' }), []);
	assert.equal(rowErrors('f', { ...drawn, disabled_reason_key: '' }).length, 1);
	assert.equal(rowErrors('f', { ...drawn, type: 'label', disabled_reason_key: 'r' }).length, 1);
	assert.equal(
		rowErrors('f', { ...drawn, disabled_when: undefined, disabled_reason_key: 'r' }).length,
		1
	);
	assert.equal(rowErrors('f', { ...drawn, i18n: undefined, disabled_reason_key: 'r' }).length, 1);
	assert.equal(reasonHead('Not on macOS yet: its key combinations…'), 'Not on macOS yet');
	assert.equal(reasonHead('暂不适用于 macOS：在'), '暂不适用于 macOS');
	assert.equal(reasonHead('Catalogue reload — Linux only'), 'Catalogue reload — Linux only');
}

// The existing native check owner already supports inert reason rows.
// Validate the compiler boundary itself, including refusal of malformed guards.
{
	const { classifyMenuRow } = require('../lib/menu-row-availability.cjs');
	const check = {
		type: 'check',
		id: 'start_at_login',
		i18n: 'menu.global.start_at_login',
		checked_when: ['start_at_login_enabled'],
		disabled_when: ['startup_command_available'],
		disabled_reason_key: 'menu.about.startup_other_command_reason'
	};
	assert.equal(classifyMenuRow(check, 'startup'), 'unclassified');
	assert.deepEqual(rowErrors('startup', check), []);
	const toggle = { ...check, type: 'toggle', category: 'LLM' };
	assert.equal(classifyMenuRow(toggle, 'startup'), 'unclassified');
	assert.deepEqual(rowErrors('startup', toggle), []);
	for (const bad of [
		{ ...check, disabled_when: undefined },
		{ ...check, i18n: undefined },
		{ ...check, type: 'label' },
		{ ...check, disabled_reason_key: '' }
	]) {
		assert.throws(() => classifyMenuRow(bad, 'startup'));
	}
}

const errors = [];
const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const locales = fs
	.readdirSync(LOCALES)
	.filter((file) => file.endsWith('.json'))
	.map((file) => ({ file, table: JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8')) }));
if (locales.length !== 21) errors.push(`read ${locales.length} locale file(s), expected 21.`);

/**
 * Holds a greyed row's reason to a short head in every locale.
 * @param {string} where Row name for the messages.
 * @param {string} key The reason's locale key.
 */
function checkReasonHead(where, key) {
	for (const { file, table } of locales) {
		const text = table[key];
		if (typeof text !== 'string' || text === '') {
			errors.push(`${where}: ${file} has no text for ${key}.`);
		} else if (reasonHead(text).length === 0 || reasonHead(text).length > MAX_HEAD) {
			errors.push(
				`${where}: ${file} opens ${key} with "${reasonHead(text)}", ` +
					`which must be 1 to ${MAX_HEAD} characters before its colon.`
			);
		}
	}
}

let declared = 0;
let greyed = 0;
let disabledWithReason = 0;
for (const [menu, rows] of Object.entries(manifest)) {
	if (!Array.isArray(rows)) continue;
	for (const row of rows) {
		if (!row || typeof row !== 'object') continue;
		if (row.unavailable === undefined && row.disabled_reason_key === undefined) continue;
		const where = `${menu}.${row.id || row.i18n || row.type}`;
		errors.push(...rowErrors(where, row));
		if (typeof row.disabled_reason_key === 'string') {
			disabledWithReason += 1;
			checkReasonHead(where, row.disabled_reason_key);
		}
		if (row.unavailable === undefined) continue;
		declared += 1;
		if (row.unavailable !== 'grey' || typeof row.reason_key !== 'string') continue;
		greyed += 1;
		checkReasonHead(where, row.reason_key);
	}
}
if (declared < 4) errors.push(`found ${declared} declared row(s), expected at least 4.`);
if (greyed < 1) errors.push('found no greyed row — the stand-in is untested by the manifest.');
if (disabledWithReason < 1)
	errors.push('found no disabled_reason_key — the runtime stand-in is untested by the manifest.');

/**
 * Extract one complete top-level native owner, without matching another helper.
 * @param {string} text Native source.
 * @param {string} name Function name.
 * @returns {string}
 */
function ahkOwner(text, name) {
	const match = text.match(new RegExp('^' + name + '\\([^\\n]*\\) \\{\\n([\\s\\S]*?)^\\}', 'm'));
	return match ? match[1].replace(/^\s*;.*$/gm, '') : '';
}

/**
 * The command-data owner passes the disabled reason to the original inert owner.
 * Provider data is not asserted to render reasons by itself: this checks only
 * the full command renderer, which owns the disabled stand-in publication.
 * @param {string} text Native renderer source.
 * @returns {boolean}
 */
function ahkDisabledReasonStandIn(text) {
	const data = ahkOwner(text, '_MR_CommandRowData');
	const render = ahkOwner(text, '_MR_RenderCommand');
	const standIn = ahkOwner(text, '_MR_RenderGreyedStandIn');
	return (
		/Disabled := MenuRenderer_ResolveDisabledWhen\(ManifestKey, Id, StateGetters\)/.test(data) &&
		/ReasonKey := _MR_Get\(Item, "disabled_reason_key"\)/.test(data) &&
		/if Disabled && ReasonKey != ""\s+return Map\("label", t\(I18nKey\), "disabled", true, "disabled_reason_key", ReasonKey\)/.test(
			data
		) &&
		/Row := _MR_CommandRowData\(Item, ManifestKey, Commands, StateGetters\)/.test(render) &&
		/if !\(Row is Map\)\s+return 0/.test(render) &&
		/if Row\.Has\("disabled_reason_key"\)\s+return _MR_RenderGreyedStandIn\(ResultMenu,\s*Map\("id", _MR_Get\(Item, "id"\), "i18n", _MR_Get\(Item, "i18n"\),\s*"reason_key", Row\["disabled_reason_key"\]\), ManifestKey\)/.test(
			render
		) &&
		/ReasonKey := _MR_Get\(Item, "reason_key"\)/.test(standIn) &&
		/Label := t\(I18nKey\) \. " — " \. _MR_ReasonHead\(t\(ReasonKey\)\)/.test(standIn) &&
		/ResultMenu\.Add\(Label, \(\*\) => ""\)/.test(standIn) &&
		/ResultMenu\.Disable\(Label\)/.test(standIn)
	);
}

// Literal owner shapes pin every link; production source alone cannot prove
// the scanner is sensitive to a lost reason, condition, callback or disable.
const AHK_STAND_IN_FIXTURE = `
_MR_CommandRowData(Item, ManifestKey, Commands, StateGetters) {
	Disabled := MenuRenderer_ResolveDisabledWhen(ManifestKey, Id, StateGetters)
	ReasonKey := _MR_Get(Item, "disabled_reason_key")
	if Disabled && ReasonKey != ""
		return Map("label", t(I18nKey), "disabled", true, "disabled_reason_key", ReasonKey)
}
_MR_RenderCommand(ResultMenu, Item, ManifestKey, Commands, StateGetters) {
	Row := _MR_CommandRowData(Item, ManifestKey, Commands, StateGetters)
	if !(Row is Map)
		return 0
	if Row.Has("disabled_reason_key")
		return _MR_RenderGreyedStandIn(ResultMenu,
			Map("id", _MR_Get(Item, "id"), "i18n", _MR_Get(Item, "i18n"),
				"reason_key", Row["disabled_reason_key"]), ManifestKey)
}
_MR_RenderGreyedStandIn(ResultMenu, Item, ManifestKey) {
	ReasonKey := _MR_Get(Item, "reason_key")
	Label := t(I18nKey) . " — " . _MR_ReasonHead(t(ReasonKey))
	ResultMenu.Add(Label, (*) => "")
	ResultMenu.Disable(Label)
}
`;
assert.equal(ahkDisabledReasonStandIn(AHK_STAND_IN_FIXTURE), true);
for (const [before, after] of [
	['MenuRenderer_ResolveDisabledWhen(', 'AnotherCondition('],
	['if Disabled && ReasonKey != ""', 'if ReasonKey != ""'],
	['"disabled", true', '"disabled", false'],
	['Row := _MR_CommandRowData(', 'Row := AnotherDataOwner('],
	['if !(Row is Map)', 'if false'],
	['if Row.Has("disabled_reason_key")', 'if false'],
	['Row["disabled_reason_key"]', 'Row["another_reason"]'],
	['_MR_ReasonHead(t(ReasonKey))', 't(ReasonKey)'],
	['ResultMenu.Add(Label, (*) => "")', 'ResultMenu.Add(Label, Action)'],
	['ResultMenu.Disable(Label)', 'ResultMenu.Enable(Label)']
]) {
	assert.notEqual(AHK_STAND_IN_FIXTURE.replace(before, after), AHK_STAND_IN_FIXTURE);
	assert.equal(ahkDisabledReasonStandIn(AHK_STAND_IN_FIXTURE.replace(before, after)), false);
}

// One stand-in for both conditions: each full renderer draws the row its
// disabled_when greys through the same native stand-in as an unavailable row.
const STAND_IN = {
	'renderer.lua': (text) =>
		/greyed_stand_in\(manifest_key,\s*\{[^}]*reason_key = item\.disabled_reason_key/.test(text),
	'manifest_menu.ahk': ahkDisabledReasonStandIn
};
for (const file of RENDERERS) {
	const text = fs.readFileSync(file, 'utf8');
	if (!/unavailable/.test(text) || !/"grey"/.test(text))
		errors.push(`${path.relative(ROOT, file)} does not draw a greyed stand-in.`);
	if (!STAND_IN[path.basename(file)](text))
		errors.push(
			`${path.relative(ROOT, file)} does not draw a row its disabled_when greys with a reason ` +
				'through the greyed stand-in.'
		);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] A row a platform lacks must be declared hidden or greyed:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${declared} row(s) declare how a platform lacks them (${greyed} greyed with a ` +
		`short reason in all 21 locales), ${disabledWithReason} greyed by disabled_when with one; ` +
		`both renderers draw the stand-in for both.\x1b[0m`
);

// Canonical declarations and I2 share the actual pure owner; the independent
// historical assertions above remain unchanged, including their own classifier.
{
	const availability = require('../lib/menu-row-availability.cjs');
	const coverage = require('./test-platform-restrictions-explained.cjs');
	const { stripComments } = require('../lib/script-source.cjs');
	const base = { type: 'command', id: 'i2_hand', i18n: 'menu.hand', platforms: ['linux'] };
	assert.equal(
		availability.classifyMenuRow({ ...base, unavailable: 'hide' }, 'hand'),
		'not-applicable'
	);
	assert.equal(
		availability.classifyMenuRow(
			{ ...base, unavailable: 'grey', reason_key: 'hand.reason' },
			'hand'
		),
		'not-ported'
	);
	assert.equal(availability.classifyMenuRow(base, 'hand'), 'unclassified');
	for (const [patch, message] of [
		[{ unavailable: true }, /unavailable must be/],
		[{ unavailable: '' }, /unavailable must be/],
		[{ unavailable: 'HIDE' }, /unavailable must be/],
		[{ unavailable: 'hide', reason_key: '' }, /hidden row carries no reason_key/],
		[{ unavailable: 'hide', reason_key: 'reason' }, /hidden row carries no reason_key/],
		[{ unavailable: 'hide', platforms: [] }, /unavailable needs platforms/],
		[{ unavailable: 'hide', platforms: new Array(1) }, /unavailable needs platforms/],
		[
			{ unavailable: 'hide', platforms: Object.assign(new Array(2), { 0: 'hs' }) },
			/unavailable needs platforms/
		],
		[{ unavailable: 'hide', platforms: ['linux', 'linux'] }, /unavailable needs platforms/],
		[{ unavailable: 'hide', platforms: ['unknown'] }, /unavailable needs platforms/],
		[{ unavailable: 'hide', platforms: ['both'] }, /unavailable needs platforms/],
		[{ unavailable: 'hide', platforms: PLATFORMS }, /unavailable needs platforms/],
		[{ unavailable: 'hide', platforms: 'linux' }, /unavailable needs platforms/],
		[{ unavailable: 'hide', type: 'invented' }, /known menu row type/],
		[{ unavailable: 'hide', id: '' }, /labelled command identity/],
		[{ unavailable: 'hide', i18n: '' }, /labelled command identity/],
		[{ unavailable: 'grey' }, /greyed row needs its reason_key/],
		[{ unavailable: 'grey', reason_key: '' }, /greyed row needs its reason_key/],
		[{ unavailable: 'grey', reason_key: 'r', i18n: '' }, /greyed row needs an i18n label/],
		[{ disabled_reason_key: 'r', disabled_when: [] }, /needs the disabled_when/],
		[
			{ disabled_reason_key: 'r', disabled_when: ['ready'], type: 'label' },
			/command\/check\/toggle rows/
		]
	])
		assert.throws(() => availability.classifyMenuRow({ ...base, ...patch }, 'hand'), message);

	// Exercise the compiler's actual wrappers with the real imported pure owner,
	// without executing build() or writing generated metadata.
	const compiler = fs.readFileSync(path.join(ROOT, 'tools/build/build-menu-manifest.js'), 'utf8');
	function compilerWrapper(source, name) {
		const declarations = require('acorn')
			.parse(source, { ecmaVersion: 'latest', sourceType: 'module' })
			.body.filter((node) => node.type === 'FunctionDeclaration' && node.id?.name === name);
		assert.equal(declarations.length, 1, name + ' has one genuine top-level function owner');
		const declaration = declarations[0];
		assert(declaration.body.body.length > 0, name + ' actual wrapper is nonempty');
		assert.equal(declaration.params.length, 1);
		assert.equal(declaration.params[0].name, 'menu');
		return source.slice(declaration.start, declaration.end);
	}
	for (const name of ['validateGreyedRows', 'validateChildTemplates']) {
		const owner = [compilerWrapper(compiler, name)];
		assert.ok(owner, name + ' must retain its actual compiler call boundary');
		for (const replacement of [
			'',
			'const WrapperAsData = ' + JSON.stringify(owner[0]) + ';',
			owner[0]
				.split('\n')
				.map((line) => '// ' + line)
				.join('\n')
		])
			assert.throws(
				() => compilerWrapper(compiler.replace(owner[0], replacement), name),
				/one genuine top-level function owner/,
				'missing or data-only wrapper cannot borrow compiler authority'
			);
		assert.throws(
			() => compilerWrapper(compiler.replace(owner[0], 'function ' + name + '(menu) {}'), name),
			/actual wrapper is nonempty/,
			'empty actual body refuses'
		);

		const validate = new Function(
			'menuAvailability',
			'readFileSync',
			'shared',
			owner[0] + '; return ' + name
		)(availability, fs.readFileSync, require('../lib/paths.cjs').shared);
		validate({ hand: [{ ...base, unavailable: 'hide' }] });
		if (name === 'validateGreyedRows')
			assert.throws(
				() => validate({ hand: [{ ...base, unavailable: 'hide', reason_key: 'r' }] }),
				/hidden row carries no reason_key/
			);
		else
			assert.throws(
				() =>
					validate({
						hand: [
							{
								type: 'label',
								id: 'hand',
								i18n: 'menu.hand',
								platforms: ['linux'],
								unavailable: 'hide',
								command: 'bad'
							}
						]
					}),
				/inert label/
			);
	}

	// Handwritten semantic fixtures carry the real original completeness floor;
	// they do not import or regenerate the frozen104 identity corpus.
	const complete =
		'[menu]\n' +
		Array.from(
			{ length: 305 },
			(_, index) => `[sections.hand_floor_${index}]\ndescription_key = "hand"\n`
		).join('\n');
	const knownDebt = '[sections.ui]\nplatforms = ["hs"]\n';
	const command =
		'[[menu.hand_commands]]\ntype = "command"\nid = "new_hand_command"\ni18n = "menu.hand"\nplatforms = ["linux"]\n';
	const hidden = command + 'unavailable = "hide"\n';
	const separator =
		'[[menu.hand_tail]]\ntype = "---"\nplatforms = ["linux"]\nunavailable = "hide"\n';
	function errorsFor(source) {
		return coverage.coverageErrors(coverage.readCoverage(source));
	}
	assert.deepEqual(errorsFor(complete + knownDebt), []);
	const valid = coverage.readCoverage(complete + knownDebt + hidden + separator);
	assert.equal(valid.unexplained.length, 1);
	assert.equal(valid.notApplicable.length, 2);
	assert.deepEqual(coverage.coverageErrors(valid), []);
	assert.ok(
		errorsFor(complete + command).some((error) =>
			error.includes('new unexplained platform restriction')
		)
	);
	// Retirement creates headroom, but cannot pay for this new command.
	assert.ok(errorsFor(complete + command).some((error) => error.includes('new_hand_command')));
	assert.ok(
		errorsFor(complete + knownDebt + command).some((error) => error.includes('new_hand_command'))
	);
	assert.ok(errorsFor('[menu]\n').some((error) => error.includes('floor 300')));
	const inlineTables =
		'[menu]\n' +
		Array.from({ length: 305 }, (_, index) => `inline_${index} = { id = \"hand\" }\n`).join('');
	assert.ok(errorsFor(inlineTables).some((error) => error.includes('floor 300')));
	for (const declaration of [
		'[[features.hand]]\nid = "new_hand_feature"\ntype = "boolean"\nplatforms = ["linux"]\nunavailable = "hide"\n',
		'[sections.new_hand_section]\nplatforms = ["linux"]\nunavailable = "hide"\n'
	]) {
		const observed = coverage.readCoverage(complete + declaration);
		assert.equal(observed.notApplicable.length, 0);
		assert.ok(
			coverage
				.coverageErrors(observed)
				.some((error) => error.includes('new unexplained platform restriction'))
		);
	}
	for (const text of [
		command + '# unavailable = "hide"\n',
		command + "note = '''\nunavailable = \"hide\"\n'''\n"
	])
		assert.ok(errorsFor(complete + text).some((error) => error.includes('new_hand_command')));
	for (const text of [
		command + 'unavailable = "grey"\n',
		command + 'unavailable = true\n',
		command + 'unavailable = "hide"\nreason_key = "r"\n',
		hidden.replace('["linux"]', '[]'),
		hidden.replace('["linux"]', '["unknown"]'),
		hidden.replace('["linux"]', '["linux", "linux"]'),
		hidden + 'unavailable = "hide"\n',
		hidden.replace('type = "command"', 'type = "invented"'),
		'[[menu.hand_labels]]\ntype = "label"\nid = "hand"\ni18n = "menu.hand"\nplatforms = ["linux"]\nunavailable = "hide"\ncommand = "bad"\n',
		'[[menu.hand_include]]\ntype = "include"\nsection = "hand_commands"\nplatforms = ["linux"]\nunavailable = "hide"\n' +
			hidden
	])
		assert.throws(() => coverage.readCoverage(complete + text));

	// All four original anonymous separators remain four distinct roles; neither
	// a fifth separator nor an action borrowing an old index is grandfathered.
	const anonymous = Array.from({ length: 19 }, (_, index) =>
		[10, 12, 14, 18].includes(index)
			? `[[menu.gestures_menu]]\ntype = "---"\nplatforms = ["${index === 18 ? 'linux' : 'hs'}"]\n`
			: `[[menu.gestures_menu]]\ntype = "label"\nid = "hand_${index}"\ni18n = "menu.hand"\n`
	).join('\n');
	const anonymousCoverage = coverage.readCoverage(complete + anonymous);
	assert.equal(anonymousCoverage.unexplained.length, 4);
	assert.equal(new Set(anonymousCoverage.unexplained.map((entry) => entry.identity)).size, 4);
	assert.deepEqual(coverage.coverageErrors(anonymousCoverage), []);
	assert.ok(
		errorsFor(
			complete + anonymous + '[[menu.gestures_menu]]\ntype = "---"\nplatforms = ["hs"]\n'
		).some((error) => error.includes('new unexplained'))
	);
	assert.ok(
		errorsFor(complete + anonymous.replace('type = "---"', 'type = "command"')).some((error) =>
			error.includes('new unexplained')
		)
	);
	const namedKnown =
		'[[menu.apps_menu]]\ntype = "list"\nid = "apps_installed"\nplatforms = ["hs"]\n';
	assert.deepEqual(errorsFor(complete + namedKnown), []);
	assert.ok(
		errorsFor(complete + namedKnown + namedKnown).some((error) =>
			error.includes('duplicate unexplained identity')
		)
	);

	// Source inspection qualifies the numeric row as a presentation difference,
	// not a removed capability. Strip comments and require each actual owner to
	// exist before checking prompt, setting and persistence routes.
	const numericPaths = {
		linux: path.join(SP, 'linux/ui/menu/menu_builder.lua'),
		mac: path.join(SP, 'macos/ui/menu/menu_llm/settings_manager.lua'),
		windows: path.join(SP, 'windows/ui/menu/menu_llm/menu_settings.ahk'),
		persist: path.join(SP, 'windows/ui/menu/menu_llm/persist.ahk')
	};
	const numeric = Object.fromEntries(
		Object.entries(numericPaths).map(([driver, file]) => [
			driver,
			stripComments(fs.readFileSync(file, 'utf8'), path.extname(file))
		])
	);
	function numericCounterparts(source) {
		const linux = source.linux.match(
			/local bounds = Settings\.bounds\(setting\.name\)([\s\S]*?)\}, ctx\.webview\)/
		);
		const mac = source.mac.match(
			/local function generic_numeric_prompt\(([\s\S]*?)local function reset_to_default\(/
		);
		const windows = ahkOwner(source.windows, 'LLM_Menu_PromptNumeric');
		const temperature = ahkOwner(source.windows, 'LLM_Menu_PromptTemperature');
		const context = ahkOwner(source.windows, 'LLM_Menu_PromptCtxChars');
		return (
			!!linux &&
			!!mac &&
			windows !== '' &&
			temperature !== '' &&
			context !== '' &&
			/Prompt\.ask\(/.test(linux[1]) &&
			/value = Settings\.get\(setting\.name\)/.test(linux[1]) &&
			/min = bounds\.min/.test(linux[1]) &&
			/max = bounds\.max/.test(linux[1]) &&
			/local saved = Settings\.set\(setting\.name, value\)/.test(linux[1]) &&
			/if saved and type\(ctx\.on_menu_changed\) == "function" then ctx\.on_menu_changed\(\) end/.test(
				linux[1]
			) &&
			/pcall\(dialog\.text_prompt/.test(mac[1]) &&
			/apply_setting_transaction\(\{/.test(mac[1]) &&
			/key = key/.test(mac[1]) &&
			/value = final_val/.test(mac[1]) &&
			/runtime_fn = hs_fn/.test(mac[1]) &&
			/publish_setting = true/.test(mac[1]) &&
			/"llm_temperature", nil, "set_llm_temperature"/.test(source.mac) &&
			/"llm_context_length", nil, "set_llm_context_length"/.test(source.mac) &&
			/Ui_InputBox\(/.test(windows) &&
			/_LLM_Menu_TryNormalizeIntegerPrompt\(/.test(windows) &&
			/LLM_Menu_CommitMutation\(/.test(windows) &&
			/_LLM_Menu_SetCandidateValue\(Candidate, key, val\)/.test(windows) &&
			/_LLM_Menu_ApplyStandardCommitted/.test(windows) &&
			/Ui_InputBox\(/.test(temperature) &&
			/_LLM_Menu_TryNormalizeTemperaturePrompt\(/.test(temperature) &&
			/"temperature", Normalized/.test(temperature) &&
			/_LLM_Menu_ApplyStandardCommitted/.test(temperature) &&
			/LLM_Menu_PromptNumeric\("ctx_chars"/.test(context) &&
			/\["ctx_chars", llm\["generation"\]\["context_length"\], "llm\.generation\.context_length"\]/.test(
				source.persist
			) &&
			/Format\("\{:\.2f\}", TemperatureRaw \+ 0\), "llm\.generation\.temperature"/.test(
				source.persist
			)
		);
	}
	assert.equal(numericCounterparts(numeric), true);
	for (const driver of Object.keys(numeric))
		assert.equal(numericCounterparts({ ...numeric, [driver]: '' }), false);
	for (const [driver, before] of [
		['linux', 'Settings.set(setting.name, value)'],
		['linux', 'ctx.on_menu_changed()'],
		['mac', 'pcall(dialog.text_prompt'],
		['mac', 'runtime_fn = hs_fn'],
		['mac', 'publish_setting = true'],
		['windows', '_LLM_Menu_SetCandidateValue(Candidate, key, val)'],
		['windows', '"temperature", Normalized'],
		['persist', '"llm.generation.context_length"'],
		['persist', '"llm.generation.temperature"']
	]) {
		assert.ok(numeric[driver].includes(before));
		assert.equal(
			numericCounterparts({
				...numeric,
				[driver]: numeric[driver].replaceAll(before, 'REMOVED_OWNER')
			}),
			false
		);
	}
	console.log(
		'[OK] canonical MENU-only HIDE and semantic debt identities; numeric counterpart source routes (native execution not claimed).'
	);
}

// The generic group owners now support the same reasoned projection as group_row.
// Keep the earlier command/check invalid controls unchanged.
{
	const owner = require('../lib/menu-row-availability.cjs');
	const parent = {
		type: 'group',
		id: 'native_parent',
		i18n: 'menu.llm.title',
		disabled_when: ['ready'],
		disabled_reason_key: 'menu.llm.unavailable'
	};
	assert.equal(owner.classifyMenuRow(parent, 'qualified'), 'unclassified');
	assert.deepEqual(rowErrors('qualified', parent), []);
	for (const patch of [
		{ id: '' },
		{ i18n: '' },
		{ disabled_when: [] },
		{ disabled_when: [''] },
		{ disabled_when: [false] },
		{ disabled_when: new Array(1) }
	]) {
		assert.throws(
			() => owner.classifyMenuRow({ ...parent, ...patch }, 'qualified'),
			/reasoned group needs/
		);
		assert.ok(rowErrors('qualified', { ...parent, ...patch }).length > 0);
	}
}
