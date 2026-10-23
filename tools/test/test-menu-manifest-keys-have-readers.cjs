// tools/test/test-menu-manifest-keys-have-readers.cjs

/**
 * ==============================================================================
 * MODULE: Manifest Reader Guard
 * DESCRIPTION:
 * Every field and every top-level section of `menu_manifest.json` must be read
 * by at least one driver. A key nobody reads is a configuration that lies.
 *
 * ROOT CAUSE ENCODED — THREE DECLARATIONS, THREE CODE COPIES:
 * The manifest is meant to describe what the user sees. Three keys described it
 * to nobody, while a copy of the same data drove the render from AutoHotkey
 * source:
 *
 *   * `i18n_dynamic`, on the two metrics rows whose label is computed at
 *     runtime, named the locale key for the prefix. It had **zero** readers
 *     anywhere in the repo; both handlers carried their own literal
 *     `t("menu.metrics.show_typing")`.
 *   * `accented_letters_group` listed four letter_picker ids while the builder
 *     looped over a hardcoded array of the same four paths.
 *   * `modifier_combos_group` listed three feature-section paths while the same
 *     builder read them from a `_SHORTCUTS_SUBMAP_V1V2` Map.
 *
 * None of it looked broken, because the copies were in sync. The failure is the
 * NEXT edit: adding a fourth accented letter to the manifest changes nothing at
 * all, and there is no error to read — the same silence that let a menu ship
 * with 2 locales out of 21.
 *
 * THE TWO KEYS THAT CAME FIRST:
 * `dynamic_hotstrings_order` duplicated _DYNAMIC_HOTSTRINGS_ORDER in
 * windows/ui/tray_menu.ahk — and DISAGREED with it, spelling the separator
 * "---" where the live one spells it "-". Whichever a reader trusted, one of
 * them was lying. `word_delimiter_defs` carried 20 entries no driver asked for.
 * Both are gone; this guard is what keeps the next pair from accumulating.
 *
 * WHY A COMMENT IS NOT A READER:
 * `manifest_menu.ahk` mentioned both dead sections by name in a comment
 * ("Built-in group: modifier_combos_group, accented_letters_group."). A scan
 * that counted any occurrence would have called them read and found nothing.
 * Comment-only lines are skipped here for exactly that reason.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { delegatedMenuSources } = require('../lib/menu-shared-delegation.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(DRIVERS, '_shared', 'modules', 'menu', 'menu_manifest.json');

// Floors — a scan that finds nothing must not pass for free.
const MIN_SOURCES = 400; // 533 non-test driver sources today (tests are excluded below).
const MIN_FIELDS = 10; // 19 today.
const MIN_SECTIONS = 10; // 15 today.

const errors = [];

// =======================================
// =======================================
// ======= 1/ Reading the manifest =======
// =======================================
// =======================================

let manifest;
try {
	manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
} catch (e) {
	console.error(`\x1b[31m[ERROR] cannot read menu_manifest.json: ${e.message}\x1b[0m`);
	process.exit(1);
}

// `_comment*` keys are prose addressed to humans and declare no behaviour.
const sections = Object.keys(manifest).filter((k) => !k.startsWith('_'));

// Field names carried by entries, at any depth below the top level.
const fields = new Set();
(function collect(node, depth) {
	if (Array.isArray(node)) {
		for (const v of node) collect(v, depth + 1);
	} else if (node && typeof node === 'object') {
		for (const [k, v] of Object.entries(node)) {
			if (depth > 0) fields.add(k);
			collect(v, depth + 1);
		}
	}
})(manifest, 0);

for (const s of sections) fields.delete(s);
for (const f of [...fields]) {
	if (f.startsWith('_') || /^\d+$/.test(f)) fields.delete(f);
}

// `type` values name a renderer branch rather than a field; they are covered by
// the renderer's own dispatch and would otherwise be reported as unread fields.
const typeValues = new Set();
(function collectTypes(node) {
	if (Array.isArray(node)) {
		for (const v of node) collectTypes(v);
	} else if (node && typeof node === 'object') {
		if (typeof node.type === 'string') typeValues.add(node.type);
		for (const v of Object.values(node)) collectTypes(v);
	}
})(manifest);
for (const t of typeValues) fields.delete(t);

if (sections.length < MIN_SECTIONS) {
	errors.push(`parsed only ${sections.length} manifest section(s) — the parse is broken`);
}
if (fields.size < MIN_FIELDS) {
	errors.push(`parsed only ${fields.size} manifest field(s) — the parse is broken`);
}

// =======================================
// =======================================
// ======= 2/ Scanning the drivers =======
// =======================================
// =======================================

const sources = [];
(function collectSources(dir) {
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'vendor' && e.name !== 'node_modules') collectSources(p);
		} else if (/\.(lua|ahk|js)$/.test(e.name)) {
			const rel = path.relative(DRIVERS, p).split(path.sep).join('/');
			// The shared tree holds the manifest itself and its schema docs; only a
			// DRIVER reading a key makes that key load-bearing.
			if (rel.startsWith('_shared/')) continue;
			// Nor do tests count. A test naming a section proves the section exists,
			// not that anything renders from it — and this guard's own regression
			// test names both group sections, so counting tests made it pass with
			// the composition it exists to protect deleted. Found by probing it.
			if (/(^|\/)tests?\//.test(rel)) continue;
			sources.push({ rel, src: fs.readFileSync(p, 'utf8') });
		}
	}
})(DRIVERS);

if (sources.length < MIN_SOURCES) {
	errors.push(
		`scanned only ${sources.length} driver source(s) (floor ${MIN_SOURCES}) — the walk is broken, ` +
			'and every key below would then look unread'
	);
}

// Shared policy is a reader only through a real native method delegation.
sources.push(...delegatedMenuSources(sources, path.join(DRIVERS, '_shared', 'lua')));

// This owner captured every source before querying fields and sections. Keep
// that exact ordered snapshot, splitting and excluding full-line comments once.
const readerSources = sources.map(({ rel, src }) => {
	const lines = src.split('\n').filter((line) => {
		const t = line.trimStart();
		return !t.startsWith('--') && !t.startsWith(';') && !t.startsWith('//');
	});
	// Every reader pattern contains the token literally, so a file whose kept
	// lines never contain it cannot match: one substring search replaces five
	// regular expressions per line for the hundreds of tokens queried below.
	return { rel, lines, text: lines.join('\n') };
});

/** Files that reference a token outside a comment. */
function readersOf(token) {
	const escaped = token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const patterns = [
		new RegExp(`\\.${escaped}\\b`), // entry.platforms
		new RegExp(`\\["${escaped}"\\]`), // entry["platforms"]
		new RegExp(`\\['${escaped}'\\]`),
		new RegExp(`"${escaped}"`), // Has(entry, "platforms")
		new RegExp(`'${escaped}'`)
	];
	const hits = [];
	for (const { rel, lines, text } of readerSources) {
		if (!text.includes(token)) continue;
		for (const line of lines) {
			if (patterns.some((p) => p.test(line))) {
				hits.push(rel);
				break;
			}
		}
	}
	return hits;
}

// A section may also be reached by composition: the renderer resolves a group's
// rows as `<id>_group`, so the literal name never appears. That is a real
// reader, and the convention is asserted rather than assumed — if nothing
// composes the suffix, no section is reachable that way.
const COMPOSES_GROUP_SUFFIX = /["'`]_group["'`]/;
const composers = sources.filter(({ src }) =>
	src.split('\n').some((line) => {
		const t = line.trimStart();
		if (t.startsWith('--') || t.startsWith(';') || t.startsWith('//')) return false;
		return COMPOSES_GROUP_SUFFIX.test(line);
	})
);

const groupIds = new Set();
(function collectGroupIds(node) {
	if (Array.isArray(node)) {
		for (const v of node) collectGroupIds(v);
	} else if (node && typeof node === 'object') {
		if (node.type === 'group' && typeof node.id === 'string') groupIds.add(node.id);
		for (const v of Object.values(node)) collectGroupIds(v);
	}
})(manifest);

/** Reaches includes only from sections that already have a real reader. */
function includedSections(menu, roots, consumerAvailable) {
	const reachable = new Set(roots);
	if (!consumerAvailable) return reachable;
	const visiting = new Set();
	const visited = new Set();
	function visit(section) {
		if (visiting.has(section))
			throw new Error(`manifest section "${section}" has a cyclic include`);
		if (visited.has(section)) return;
		visiting.add(section);
		const rows = Array.isArray(menu[section]) ? menu[section] : [];
		for (const row of rows) {
			if (row.type !== 'include') continue;
			if (!Array.isArray(menu[row.section]))
				throw new Error(`manifest section "${section}" includes missing section "${row.section}"`);
			reachable.add(row.section);
			visit(row.section);
		}
		visiting.delete(section);
		visited.add(section);
	}
	for (const root of roots) visit(root);
	return reachable;
}

// Dynamic includes need an actual native recursive reader, not merely a
// declaration naming another declaration. Shared code alone is not a driver.
const includeConsumerAvailable = sources.some(({ src }) => {
	const executable = src
		.split('\n')
		.filter((line) => {
			const t = line.trimStart();
			return !t.startsWith('--') && !t.startsWith(';') && !t.startsWith('//');
		})
		.join('\n');
	return (
		/ItemType == "include"/.test(executable) &&
		/_MR_TemplateRows\(_MR_Get\(Item, "section"\),/.test(executable)
	);
});
// New include edges start only at literal driver readers. The historical
// suffix convention remains below, but an orphan group cannot seed new edges.
// Immutable recovery sections are read through their genuine compiler/include/native
// publication route. The closed route rejects a missing or substituted owner;
// section names alone, policy text and uninstalled generated declarations earn nothing.
const { startupInputs, startupReaderSections } = require('../lib/menu-native-startup-binding.cjs');
const startup = startupInputs(ROOT, manifest);
const startupSections = new Set(startupReaderSections(startup));
// A recipe's dynamic result_frame is a reader only through its authenticated
// native construction and real template receiver, never through declaration text.
const { shortcutConstructionReaderEvidence } = require('../lib/menu-row-availability.cjs');
const shortcutConstructionReaderSections = (...args) =>
	shortcutConstructionReaderEvidence(...args)?.sections || [];
const shortcutWindowsSource = sources.find(
	({ rel }) => rel === 'windows/ui/menu/menu_shortcuts.ahk'
)?.src;
const shortcutRendererSource = sources.find(
	({ rel }) => rel === 'windows/infra/manifest_menu.ahk'
)?.src;
const shortcutReaderSections = new Set(
	shortcutConstructionReaderSections(manifest, shortcutWindowsSource, shortcutRendererSource)
);
const directlyReadSections = sections.filter(
	(section) =>
		readersOf(section).length > 0 ||
		startupSections.has(section) ||
		shortcutReaderSections.has(section)
);
let reachableIncludes = new Set(directlyReadSections);
try {
	reachableIncludes = includedSections(manifest, directlyReadSections, includeConsumerAvailable);
} catch (error) {
	errors.push(error.message);
}

// These independent graph controls retain rejection of orphan declarations,
// including mutually referring orphans and declarations without a live reader.
const assert = require('node:assert/strict');
assert(
	startupSections.has('tray_startup_suspend'),
	'actual cold command section has a complete reader'
);
assert(
	startupSections.has('tray_startup_inert_frame'),
	'actual inert section has a complete reader'
);
for (const key of Object.keys(startup.sources)) {
	assert.deepEqual(
		startupReaderSections({ ...startup, sources: { ...startup.sources, [key]: '' } }),
		[],
		'withdrawn actual native route cannot read a compiled section'
	);
}
// The optional replay metadata extends the real native callee ABI. Its exact
// empty default and fail-fast guard retain the three-argument cold caller;
// relaxing either must not earn credit through a signature-only match.
const startupDispatcher = 'windows/infra/menu_dispatcher.ahk';
for (const [name, before, after] of [
	[
		'old native signature',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity := "", CheckedFn := 0) {',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity := "") {'
	],
	[
		'required replay argument',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity := "", CheckedFn := 0) {',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity, CheckedFn := 0) {'
	],
	[
		'nonempty replay default',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity := "", CheckedFn := 0) {',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity := "foreign", CheckedFn := 0) {'
	],
	[
		'required checkmark argument',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity := "", CheckedFn := 0) {',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity := "", CheckedFn) {'
	],
	[
		'nonzero checkmark default',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity := "", CheckedFn := 0) {',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity := "", CheckedFn := 1) {'
	],
	[
		'removed checkmark guard',
		'\t\t_MenuDispatchRequireCheckedFn(CheckedFn)\n\t\tglobal _MenuDispatchCallbacks',
		'\t\tglobal _MenuDispatchCallbacks'
	],
	[
		'removed replay type guard',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity := "", CheckedFn := 0) {\n\t\tif !(ReplayIdentity is String)',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity := "", CheckedFn := 0) {\n\t\tif false'
	],
	[
		'wrong replay type guard',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity := "", CheckedFn := 0) {\n\t\tif !(ReplayIdentity is String)',
		'RegisterMenuItem(MenuObj, ItemName, Callback, ReplayIdentity := "", CheckedFn := 0) {\n\t\tif !(ReplayIdentity is Integer)'
	]
]) {
	const original = startup.sources[startupDispatcher];
	assert.equal(original.split(before).length - 1, 1, name + ' has one actual mutation coordinate');
	const changed = original.replace(before, after);
	assert.notEqual(changed, original, name + ' changes the actual native source');
	assert.deepEqual(
		startupReaderSections({
			...startup,
			sources: { ...startup.sources, [startupDispatcher]: changed }
		}),
		[],
		name + ' cannot authenticate the native startup reader'
	);
}
assert.deepEqual(
	startupReaderSections({ ...startup, generated: '' }),
	[],
	'absent actual compiled artifact cannot read a section'
);
assert.deepEqual(
	startupReaderSections({ ...startup, generator: '' }),
	[],
	'absent actual compiler cannot read a section'
);
const nullPolicy = require('smol-toml').parse(
	fs.readFileSync(path.join(DRIVERS, '_shared', 'modules', 'menu', 'startup_tray.toml'), 'utf8')
);
assert.deepEqual(
	startupReaderSections({ ...startup, policy: nullPolicy }),
	[...startupSections],
	'actual parser null records retain the same native reader'
);
assert.deepEqual(
	startupReaderSections({ ...startup, policy: JSON.parse(JSON.stringify(nullPolicy)) }),
	[...startupSections],
	'plain policy records retain the same native reader'
);
for (const policy of [
	Object.assign(Object.create({ foreign: true }), nullPolicy),
	{ ...nullPolicy, unknown: true },
	{ ...nullPolicy, commands: Object.assign(Object.create({ foreign: true }), nullPolicy.commands) }
])
	assert.deepEqual(
		startupReaderSections({ ...startup, policy }),
		[],
		'foreign or unknown policy refuses'
	);
let policyReads = 0;
const indirectPolicy = { ...nullPolicy };
Object.defineProperty(indirectPolicy, 'commands', {
	enumerable: true,
	get() {
		policyReads++;
		return nullPolicy.commands;
	}
});
assert.deepEqual(
	startupReaderSections({ ...startup, policy: indirectPolicy }),
	[],
	'indirect policy refuses'
);
assert.equal(policyReads, 0, 'refused policy getters are never invoked');
for (const makeSparse of [
	(rows) => {
		rows.length += 1;
	},
	(rows) => {
		delete rows[1];
	}
]) {
	const policy = JSON.parse(JSON.stringify(nullPolicy));
	makeSparse(policy.commands.rows);
	assert.deepEqual(
		startupReaderSections({ ...startup, policy }),
		[],
		'sparse or trailing policy holes cannot acquire a reader by normalization'
	);
}
for (const inputs of [null, {}, { manifest: null }, { manifest: [] }])
	assert.deepEqual(startupReaderSections(inputs), [], 'missing manifest refuses reader credit');

const probeMenu = {
	root: [{ type: 'include', section: 'child' }],
	child: [{ type: 'include', section: 'leaf' }],
	leaf: [],
	orphan: [{ type: 'include', section: 'orphan_cycle' }],
	orphan_cycle: [{ type: 'include', section: 'orphan' }]
};
assert.deepEqual([...includedSections(probeMenu, ['root'], true)], ['root', 'child', 'leaf']);
assert.deepEqual([...includedSections(probeMenu, ['root'], false)], ['root']);
assert.deepEqual([...includedSections(probeMenu, [], true)], []);
assert.throws(
	() => includedSections({ root: [{ type: 'include', section: 'missing' }] }, ['root'], true),
	/missing section/
);
assert.throws(
	() => includedSections({ root: [{ type: 'include', section: 'root' }] }, ['root'], true),
	/cyclic include/
);
assert.deepEqual([...includedSections({ root: { unused: true } }, ['root'], true)], ['root']);

// ======================================
// ======================================
// ======= 3/ Fields and sections =======
// ======================================
// ======================================

for (const field of [...fields].sort()) {
	if (readersOf(field).length > 0) continue;
	errors.push(
		`manifest field "${field}" is declared but no driver reads it. Either a driver holds its own ` +
			'copy of the value — in which case editing the manifest moves nothing and there is no error ' +
			'to read — or the field is dead and belongs deleted (§5.6).'
	);
}

for (const section of [...sections].sort()) {
	if (readersOf(section).length > 0 || reachableIncludes.has(section)) continue;

	// The `<id>_group` convention: reachable when a group entry declares the id
	// AND something actually composes the suffix.
	const base = section.endsWith('_group') ? section.slice(0, -'_group'.length) : null;
	if (base && groupIds.has(base) && composers.length > 0) continue;

	if (base && groupIds.has(base) && composers.length === 0) {
		errors.push(
			`manifest section "${section}" would be reached as "<id>_group", but nothing in the drivers ` +
				'composes that suffix any more — the convention is gone and the section is unreachable'
		);
		continue;
	}

	errors.push(
		`manifest section "${section}" is declared but no driver reads it, and no group entry claims it ` +
			`by id ("${base || section}"). The rows are then decorative: the render comes from somewhere ` +
			'else, and adding a row here changes nothing.'
	);
}

// Independent Source withdrawals retain every original reader assertion above.
assert.deepEqual(
	[...shortcutReaderSections],
	['shortcut_extension_result_frame'],
	'the real declared construction reads its original frame'
);
// Replay metadata runs inside the same closed template route. These helpers
// and its strict field admission cannot be withdrawn or redirected while still
// claiming the declared shortcut result frame is genuinely consumed.
for (const [name, before, after] of [
	[
		'withdraw declared replay parent owner',
		'_MR_DeclaredReplayGroupIdentity(Item, ManifestKey) {',
		'_ForeignReplayParent(Item, ManifestKey) {'
	],
	[
		'withdraw canonical replay identity owner',
		'_MR_ReplayIdentity(ManifestKey, RowId, Kind := "command", Value := unset) {',
		'_ForeignReplayIdentity(ManifestKey, RowId, Kind := "command", Value := unset) {'
	],
	[
		'redirect declared parent identity',
		'return _MR_ReplayIdentity(ManifestKey, _MR_Get(Item, "id"), "container")',
		'return "foreign"'
	],
	[
		'relax replay metadata admission',
		'Type(Row[ReplayField]) != "String"',
		'Type(Row[ReplayField]) != "Integer"'
	]
]) {
	assert.equal(
		shortcutRendererSource.split(before).length - 1,
		1,
		name + ' has one actual coordinate'
	);
	const changed = shortcutRendererSource.replace(before, after);
	assert.notEqual(changed, shortcutRendererSource, name + ' changes the actual route');
	assert.deepEqual(
		shortcutConstructionReaderSections(manifest, shortcutWindowsSource, changed),
		[],
		name + ' cannot authenticate the shortcut frame reader'
	);
}
const shortcutOriginalFrame = manifest.shortcut_extension_construction_ahk.result_frame;
const shortcutCandidate = (mutate) => {
	const candidate = structuredClone(manifest);
	mutate(candidate);
	return candidate;
};
for (const mutate of [
	(m) => delete m.shortcut_extension_construction_ahk,
	(m) => {
		m.foreign_recipe = m.shortcut_extension_construction_ahk;
		delete m.shortcut_extension_construction_ahk;
	},
	(m) => {
		m.shortcut_extension_construction_ahk.result_frame = 'missing_actual_frame';
	},
	(m) => {
		m.shortcut_extension_construction_ahk.program.reverse();
	},
	(m) => {
		delete m.shortcut_extension_construction_ahk.program[0];
	},
	(m) => {
		m.shortcut_extension_construction_ahk.append_outcomes.push('populated');
	},
	(m) => {
		m.shortcut_extension_construction_ahk.extra = true;
	},
	(m) => {
		delete m[shortcutOriginalFrame];
	}
])
	assert.deepEqual(
		shortcutConstructionReaderSections(
			shortcutCandidate(mutate),
			shortcutWindowsSource,
			shortcutRendererSource
		),
		[],
		'malformed or unread recipe gives no reader credit'
	);
const shortcutOtherFrame = shortcutCandidate((m) => {
	m.independent_other_frame = structuredClone(m[shortcutOriginalFrame]);
	m.shortcut_extension_construction_ahk.result_frame = 'independent_other_frame';
});
assert.deepEqual(
	shortcutConstructionReaderSections(
		shortcutOtherFrame,
		shortcutWindowsSource,
		shortcutRendererSource
	),
	['independent_other_frame'],
	'reader follows the actual declared value without duplicating native placement policy'
);
assert(
	!shortcutConstructionReaderSections(
		shortcutOtherFrame,
		shortcutWindowsSource,
		shortcutRendererSource
	).includes(shortcutOriginalFrame),
	'rerouting cannot grant the old now-unread frame credit'
);
const shortcutOrphan = shortcutCandidate((m) => {
	m.independent_orphan_frame = structuredClone(m[shortcutOriginalFrame]);
});
assert.deepEqual(
	shortcutConstructionReaderSections(shortcutOrphan, shortcutWindowsSource, shortcutRendererSource),
	[shortcutOriginalFrame],
	'an orphan copy is not an additional native reader'
);
for (const [windows, renderer] of [
	['', shortcutRendererSource],
	[shortcutWindowsSource, '']
])
	assert.deepEqual(
		shortcutConstructionReaderSections(manifest, windows, renderer),
		[],
		'withdrawn genuine native source refuses'
	);
const shortcutConstructorStart =
	shortcutRendererSource.indexOf('\nMenuRenderer_ConstructObservedMenu(') + 1;
assert(shortcutConstructorStart > 0, 'actual constructor interval exists');
const shortcutConstructor = shortcutRendererSource.slice(shortcutConstructorStart);
assert(shortcutConstructor.endsWith('}\n'), 'constructor is the complete final physical owner');
const shortcutExecutionStart = shortcutConstructor.indexOf(
	'\tObserved := "populated", Native := false\n'
);
const shortcutExecutionEnd = shortcutConstructor.lastIndexOf('\treturn Native\n');
assert(
	shortcutExecutionStart > 0 && shortcutExecutionEnd > shortcutExecutionStart,
	'complete actual interpreter interval exists'
);
const shortcutExecution = shortcutConstructor.slice(shortcutExecutionStart, shortcutExecutionEnd);
const shortcutChanges = [
	[shortcutConstructor, ''],
	['static NativeObserver := _SC_ObserveExtensionMenu', 'static NativeObserver := Foreign'],
	[shortcutConstructor, shortcutConstructor + shortcutConstructor],
	[shortcutConstructor, 'class Foreign {\n' + shortcutConstructor + '}\n'],
	[
		shortcutConstructor,
		shortcutConstructor
			.split('\n')
			.map((line) => '; ' + line)
			.join('\n')
	],
	[shortcutExecution, '\tif false {\n' + shortcutExecution + '\t}\n'],
	[shortcutExecution, '\treturn false\n' + shortcutExecution],
	[
		'ResultRows := TemplateOwner.Call(Recipe["result_frame"],',
		'ResultRows := Foreign.Call(Recipe["result_frame"],'
	],
	['Append.Call(Native, Recipe["result_frame"],', 'Foreign.Call(Native, Recipe["result_frame"],'],
	[
		'if !Current()\n\t\t\tthrow Error("Shortcut extension construction source was withdrawn")',
		'if false\n\t\t\tthrow Error("Shortcut extension construction source was withdrawn")'
	],
	['return _MR_TemplateRows(ManifestKey, Commands, StateGetters, Children, Map())', 'return []'],
	[
		'Def := IsSet(StatusDefinition) ? StatusDefinition : _MR_GetMenuDef(ManifestKey)',
		'return []\n\tDef := IsSet(StatusDefinition) ? StatusDefinition : _MR_GetMenuDef(ManifestKey)'
	],
	[
		'Def := IsSet(StatusDefinition) ? StatusDefinition : _MR_GetMenuDef(ManifestKey)',
		'Def := IsSet(StatusDefinition) ? StatusDefinition : _MR_GetMenuDef(ManifestKey)\n\treturn []'
	],
	['try Present := StateGetters[GetterKey].Call()', 'try Present := Foreign.Call()'],
	[
		'Value := CaptionLayout == "" ? StateGetters[CaptionGetter].Call() : ""',
		'Value := CaptionLayout == "" ? Foreign.Call() : ""'
	],
	[
		'_MR_ExplicitCaption(Item, StateGetters, &Caption, RawTitle)',
		'_MR_ExplicitCaption(Item, Foreign, &Caption, RawTitle)'
	],
	[
		'_MR_ExplicitCaption(Item, Getters, &Caption, RawTitle := unset) {\n\tI18nKey := _MR_Get(Item, "i18n")\n\tCaption := IsSet(RawTitle) ? RawTitle : t(I18nKey)\n\t_MR_CaptionFormat(Caption, "", &SourceSlot)\n\tGetter := _MR_Get(Item, "caption_getter")\n\tif !_MR_CaptionLayoutMetadata(Item) || Type(_MR_Get(Item, "id")) != "String" || _MR_Get(Item, "id") == ""\n\t\t|| Type(I18nKey) != "String" || I18nKey == "" || Type(Caption) != "String" || Caption == ""\n\t\t|| Caption == I18nKey || SourceSlot || !(Getters is Map) || !Getters.Has(Getter)\n\t\t|| !HasMethod(Getters[Getter], "Call") {\n\t\ttry LoggerError("MenuRenderer", "Invalid explicit caption source \u2014 row refused.")\n\t\treturn false\n\t}\n\tValue := Getters[Getter].Call()\n\tif Type(Value) != "String" {\n\t\ttry LoggerError("MenuRenderer", "Invalid explicit caption receipt \u2014 row refused.")\n\t\treturn false\n\t}\n\tCaption := Item["caption_layout"] == "prefix" ? Caption . Item["caption_joiner"] . Value\n\t\t: Value . Item["caption_joiner"] . Caption\n\treturn true\n}\n',
		'_MR_ExplicitCaption(Item, Getters, &Caption, RawTitle := unset) {\n\tI18nKey := _MR_Get(Item, "i18n")\n\tCaption := IsSet(RawTitle) ? RawTitle : t(I18nKey)\n\t_MR_CaptionFormat(Caption, "", &SourceSlot)\n\tGetter := _MR_Get(Item, "caption_getter")\n\tif !_MR_CaptionLayoutMetadata(Item) || Type(_MR_Get(Item, "id")) != "String" || _MR_Get(Item, "id") == ""\n\t\t|| Type(I18nKey) != "String" || I18nKey == "" || Type(Caption) != "String" || Caption == ""\n\t\t|| Caption == I18nKey || SourceSlot || !(Getters is Map) || !Getters.Has(Getter)\n\t\t|| !HasMethod(Getters[Getter], "Call") {\n\t\ttry LoggerError("MenuRenderer", "Invalid explicit caption source \u2014 row refused.")\n\t\treturn false\n\t}\n\tValue := Foreign.Call()\n\tif Type(Value) != "String" {\n\t\ttry LoggerError("MenuRenderer", "Invalid explicit caption receipt \u2014 row refused.")\n\t\treturn false\n\t}\n\tCaption := Item["caption_layout"] == "prefix" ? Caption . Item["caption_joiner"] . Value\n\t\t: Value . Item["caption_joiner"] . Caption\n\treturn true\n}\n'
	]
];
for (const [actual, withdrawn] of shortcutChanges) {
	assert.equal(shortcutRendererSource.split(actual).length, 2, 'one actual withdrawal subject');
	const position = shortcutRendererSource.indexOf(actual);
	const changed =
		shortcutRendererSource.slice(0, position) +
		withdrawn +
		shortcutRendererSource.slice(position + actual.length);
	assert.notEqual(changed, shortcutRendererSource, 'withdrawal actually changes Source');
	assert.deepEqual(
		shortcutConstructionReaderSections(manifest, shortcutWindowsSource, changed),
		[],
		'copy, dead path or withdrawn actual frame receiver is not a reader'
	);
	assert.equal(
		changed.slice(position, position + withdrawn.length),
		withdrawn,
		'withdrawal occupies the original unique Source subject'
	);
	const repaired = changed.slice(0, position) + actual + changed.slice(position + withdrawn.length);
	assert.equal(
		repaired,
		shortcutRendererSource,
		'bounded byte inverse restores the actual receiver'
	);
	assert.deepEqual(
		shortcutConstructionReaderSections(manifest, shortcutWindowsSource, repaired),
		[shortcutOriginalFrame],
		'exact repair restores only the real edge'
	);
}
const shortcutHandoff =
	'ExtMenu := ConstructorOwner.Call("shortcut_extension_construction_ahk", ExtId, ExtName, ObserverOwner, OwnedMenus)';
assert.equal(shortcutWindowsSource.split(shortcutHandoff).length, 2, 'one real native handoff');
for (const withdrawn of [
	shortcutHandoff.replace('ConstructorOwner.Call(', 'Foreign.Call('),
	'if false\n\t\t\t' + shortcutHandoff
]) {
	const changed = shortcutWindowsSource.replace(shortcutHandoff, withdrawn);
	assert.deepEqual(
		shortcutConstructionReaderSections(manifest, changed, shortcutRendererSource),
		[],
		'wrong or dead native handoff cannot loan the reader'
	);
	const repaired = changed.replace(withdrawn, shortcutHandoff);
	assert.equal(
		repaired,
		shortcutWindowsSource,
		'native handoff inverse preserves every other byte'
	);
	assert.deepEqual(shortcutConstructionReaderSections(manifest, repaired, shortcutRendererSource), [
		shortcutOriginalFrame
	]);
}

// ====================================================
// ====================================================
// ======= 3b/ Feature keys read only where declared =======
// ====================================================
// ====================================================

// A configuration key declared for other platforms reaches no generated
// manifest, template or default on this one. Windows wrote
// llm.trigger.disabled_apps and read llm.navigation.nav_modifiers, and macOS
// read mod_combos.*, while the manifest named other drivers: every reader was
// right for its user and the declaration was wrong, which nothing noticed.
{
	const { parse: parseToml } = require('smol-toml');
	const { platformReadViolations } = require('../lib/feature-platform-reads.cjs');
	const featureManifest = parseToml(
		fs
			.readFileSync(path.join(DRIVERS, '_shared', 'modules', 'features', 'manifest.toml'), 'utf8')
			.replace(
				/^\[\[features\.([^\]]+)\]\]\r?$/gm,
				(_match, section) => `[[entries]]\nsection = "${section}"`
			)
	);
	const driverDirs = { ahk: 'windows', hs: 'macos', linux: 'linux' };
	const driverSources = [];
	for (const [driver, dirName] of Object.entries(driverDirs)) {
		(function walk(dir) {
			for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
				const p = path.join(dir, e.name);
				if (e.isDirectory()) {
					if (!['vendor', 'node_modules', 'tests', '_generated'].includes(e.name)) walk(p);
				} else if (/\.(lua|ahk)$/.test(e.name)) {
					driverSources.push({
						driver,
						rel: path.relative(DRIVERS, p).split(path.sep).join('/'),
						source: fs.readFileSync(p, 'utf8')
					});
				}
			}
		})(path.join(DRIVERS, dirName));
	}
	if (featureManifest.entries.length < 200 || driverSources.length < MIN_SOURCES) {
		errors.push('the feature-platform scan found too little to prove anything');
	}
	for (const violation of platformReadViolations(featureManifest, driverSources)) {
		errors.push(violation);
	}

	// The scan must be able to fail: a hs-only key read by Windows is reported.
	const probeManifest = {
		sections: {},
		entries: [{ section: 'probe', id: 'hs_only', platforms: ['hs'] }]
	};
	const probe = (driver, source) =>
		platformReadViolations(probeManifest, [{ driver, rel: 'probe', source }]).length;
	for (const spelling of [
		'x := Cfg("probe.hs_only")',
		'U.Push({ Section: "probe", Key: "hs_only", Value: 1 })',
		'v := Cache["probe"]["hs_only"]'
	]) {
		if (probe('ahk', spelling) !== 1) errors.push(`the probe missed a read: ${spelling}`);
		if (probe('hs', spelling) !== 0) errors.push(`the probe flagged a declared read: ${spelling}`);
		if (probe('ahk', `; ${spelling}`) !== 0)
			errors.push(`the probe flagged a comment: ${spelling}`);
	}
	if (probe('linux', 'p = { sec = "probe", key = "hs_only" }') !== 1)
		errors.push('the probe missed a macOS-style preference row read by another driver');
}

// ==========================
// ==========================
// ======= 4/ Verdict =======
// ==========================
// ==========================

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] menu manifest keys with no reader:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${fields.size} manifest field(s) and ${sections.length} section(s) are read by a ` +
		`driver (${sources.length} source(s) scanned).\x1b[0m`
);
