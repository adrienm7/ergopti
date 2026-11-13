// tools/test/test-value-schema.cjs

/**
 * ==============================================================================
 * MODULE: User Value Schema Contract
 * DESCRIPTION:
 * Pins the one validation contract of every user-entered value: the shared
 * declarations of _shared/settings/data/value_schema/value_schema.json, the
 * canonical check value_check.js and the vectors its Lua and AHK ports replay.
 *
 * FEATURES & RATIONALE:
 * 1. value_check.js replays value_check_vectors.json: stored values, typed
 *    text, the bounds a refusal names and the localized message parts.
 * 2. Every declaration is well formed: a known file and type, both bounds on
 *    a number (a refusal must name the range), known units and special-value
 *    labels, and no field outside the declared vocabulary.
 * 3. Defaults are not repeated in the schema: each `default_from` names the
 *    feature manifest or the timing registry, and the default found there
 *    must pass its own declaration. Each `max_from` names the timing value the
 *    maximum equals, so the two cannot drift.
 * 4. config.schema.json and tap_hold.schema.json, the CI-only JSON schemas of
 *    the generated templates, agree with the declarations they share.
 * 5. Every i18n key a refusal message can use exists in the 21 locales.
 * 6. The Lua and AHK ports and their vector tests exist and are wired into
 *    their suites, and the generated AHK data equals a fresh render.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');
const TOML = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const DIR = path.join(SP, '_shared', 'settings', 'data', 'value_schema');
const SCHEMA_PATH = path.join(DIR, 'value_schema.json');
const VECTORS_PATH = path.join(DIR, 'value_check_vectors.json');
const CHECK_PATH = path.join(DIR, 'value_check.js');
const MANIFEST_PATH = path.join(SP, '_shared', 'settings', 'data', 'features', 'manifest.toml');
const TIMINGS_PATH = path.join(SP, '_shared', 'core', 'timing', 'data', 'constants.toml');
const CONFIG_SCHEMA_PATH = path.join(
	SP,
	'_shared',
	'settings',
	'data',
	'config_schema',
	'config.schema.json'
);
const LOCALES_DIR = path.join(SP, '_shared', 'core', 'i18n', 'data', 'locales');
const GENERATOR = path.join(ROOT, 'tools', 'codegen', 'codegen-value-schema.cjs');
const LOCALE_COUNT = 21;

const FILES = ['config.toml', 'tap_hold.toml', 'hotstrings_config.toml', 'personal_info.toml'];
const UNITS = ['ms', 's', 'mm', 'characters', 'words'];
const FIELDS = {
	common: ['file', 'type', 'default_from', 'platforms'],
	number: ['unit', 'min', 'max', 'special', 'entry_scale', 'entry_type', 'entry_unit', 'max_from'],
	enum: ['values'],
	string: ['max_length', 'allow_empty'],
	path: ['allow_empty'],
	boolean: []
};
const MESSAGE_KEYS = [
	'dialog.value_check.title',
	'dialog.value_check.range_integer',
	'dialog.value_check.range_integer_unit',
	'dialog.value_check.range_decimal',
	'dialog.value_check.range_decimal_unit',
	'dialog.value_check.special',
	'dialog.value_check.too_long',
	'dialog.value_check.not_allowed',
	'dialog.value_check.empty'
];

// Each port and the suite entry that runs its vector test.
const PORTS = [
	{
		port: '_shared/settings/engine/value_check.lua',
		test: 'macos/tests/unit/infra/config/test_value_check_vectors.lua'
	},
	{
		port: '_shared/settings/engine/value_check.lua',
		test: 'linux/tests/unit/infra/config/test_value_check_vectors.lua',
		wiring: {
			file: 'linux/tests/test_manifest.lua',
			needle: '"tests.unit.infra.config.test_value_check_vectors"'
		}
	},
	{
		port: 'windows/infra/value_check.ahk',
		test: 'windows/tests/unit/infra/test_value_check_vectors.ahk',
		wiring: {
			file: 'windows/tests/run_all.ahk',
			needle: '#Include unit/infra/test_value_check_vectors.ahk'
		}
	}
];

const failures = [];
let checks = 0;

function check(condition, message) {
	checks++;
	if (!condition) failures.push(message);
}

function readJson(file) {
	return JSON.parse(fs.readFileSync(file, 'utf8'));
}

// Values JSON cannot spell, only for numeric declarations.
function decode(declaration, value) {
	if (declaration.type !== 'integer' && declaration.type !== 'decimal') return value;
	if (value === 'nan') return NaN;
	if (value === 'inf') return Infinity;
	if (value === '-inf') return -Infinity;
	return value;
}

// ==========================================
// ==========================================
// ======= 1/ Vectors ======================
// ==========================================
// ==========================================

function replayVectors(V) {
	const corpus = readJson(VECTORS_PATH);
	check(corpus.stored.length >= 30, 'value check vectors: at least 30 stored vectors');
	check(corpus.entry.length >= 25, 'value check vectors: at least 25 entry vectors');
	for (const row of corpus.stored) {
		const declaration = corpus.declarations[row.declaration];
		const result = V.checkValue(declaration, decode(declaration, row.value));
		check(result.ok === row.ok, `stored ${row.id}: ok ${result.ok}, expected ${row.ok}`);
		if (!row.ok) check(result.reason === row.reason, `stored ${row.id}: reason ${result.reason}`);
	}
	for (const row of corpus.entry) {
		const result = V.parseEntry(corpus.declarations[row.declaration], row.text);
		check(result.ok === row.ok, `entry ${row.id}: ok ${result.ok}, expected ${row.ok}`);
		if (row.ok) check(result.value === row.value, `entry ${row.id}: value ${result.value}`);
		else check(result.reason === row.reason, `entry ${row.id}: reason ${result.reason}`);
		if (row.min !== undefined) {
			check(
				result.min === row.min && result.max === row.max,
				`entry ${row.id}: bounds ${result.min}..${result.max}`
			);
		}
	}
	for (const row of corpus.messages) {
		const declaration = corpus.declarations[row.declaration];
		const parts = V.messageParts(declaration, V.parseEntry(declaration, row.text));
		check(
			JSON.stringify(parts) === JSON.stringify(row.parts),
			`message ${row.id}: ${JSON.stringify(parts)}`
		);
	}
	const templates = {
		'dialog.value_check.range_integer_unit': 'From {1} to {2} {3}.',
		'value_check.unit.ms': 'ms',
		'dialog.value_check.range_integer': 'From {1} to {2}.',
		'dialog.value_check.special': '{1} = {2}.',
		'value_check.special.no_time_limit': 'no limit'
	};
	const delay = corpus.declarations.delay_seconds;
	check(
		V.renderMessage(V.messageParts(delay, V.parseEntry(delay, '0')), (key) => templates[key]) ===
			'From 1 to 10000 ms.',
		'a rendered message fills the bounds and the translated unit'
	);
	const timeout = corpus.declarations.timeout_ms;
	check(
		V.renderMessage(
			V.messageParts(timeout, V.parseEntry(timeout, '-3')),
			(key) => templates[key]
		) === 'From 1 to 600000. 0 = no limit.',
		'a rendered message lists the special values'
	);
	check(
		V.formatNumber(0.001) === '0.001' && V.formatNumber(2) === '2',
		'bounds are written without a trailing .0'
	);
	let threw = false;
	try {
		V.requireValue({ settings: { 'a.b': timeout } }, 'a.b', '42');
	} catch (error) {
		threw = /a\.b refused \(wrong_type\)/.test(error.message);
	}
	check(threw, 'the boundary throws with the setting name and reason');
	return corpus;
}

// ==========================================
// ==========================================
// ======= 2/ Declarations =================
// ==========================================
// ==========================================

function manifestRow(manifest, key) {
	const segments = key.split('.');
	const id = segments.pop();
	let node = manifest.features;
	for (const segment of segments) {
		// [[features.llm.generation]] after [[features.llm]] rows attaches to an
		// element of the features.llm array (TOML array-of-tables semantics).
		if (Array.isArray(node)) {
			node = node.flatMap((element) => (element && element[segment]) || []);
			if (node.length === 0) node = undefined;
		} else node = node && node[segment];
	}
	return (Array.isArray(node) && node.find((item) => item.id === id)) || null;
}

function manifestDefault(manifest, key) {
	const row = manifestRow(manifest, key);
	return row ? row.default : undefined;
}

function timingValue(timings, key) {
	const [section, leaf] = key.split('.');
	return timings[section] ? timings[section][leaf] : undefined;
}

function checkDeclarations(V, en) {
	const schema = readJson(SCHEMA_PATH);
	const manifest = TOML.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));
	const timings = TOML.parse(fs.readFileSync(TIMINGS_PATH, 'utf8'));
	check(schema.version === 1, 'value_schema.json version is 1');
	const names = Object.keys(schema.settings);
	check(names.length > 0, 'value_schema.json declares settings');
	for (const name of names) {
		const entry = schema.settings[name];
		const where = `value_schema ${name}`;
		check(/^[a-z0-9_]+(\.([a-z0-9_]+|\*))*$/.test(name), `${where}: a dotted snake_case path`);
		check(FILES.includes(entry.file), `${where}: file ${entry.file} is one of ${FILES.join(', ')}`);
		check(V.TYPES.includes(entry.type), `${where}: type ${entry.type} is known`);
		const numeric = entry.type === 'integer' || entry.type === 'decimal';
		const allowed = FIELDS.common.concat(FIELDS[numeric ? 'number' : entry.type] || []);
		for (const field of Object.keys(entry))
			check(allowed.includes(field), `${where}: unknown field ${field}`);
		if (numeric) {
			check(
				Number.isFinite(entry.min) && Number.isFinite(entry.max),
				`${where}: both bounds are declared`
			);
			check(entry.min <= entry.max, `${where}: min <= max`);
			for (const unit of [entry.unit, entry.entry_unit].filter(Boolean)) {
				check(UNITS.includes(unit), `${where}: unit ${unit} is known`);
				check(
					typeof en[`value_check.unit.${unit}`] === 'string',
					`${where}: en.json has value_check.unit.${unit}`
				);
			}
			if (entry.entry_scale !== undefined) {
				check(
					entry.entry_scale > 0 && entry.entry_unit,
					`${where}: a scaled entry names its typed unit`
				);
			}
			if (entry.entry_type !== undefined) {
				check(
					['integer', 'decimal'].includes(entry.entry_type),
					`${where}: entry_type is a number type`
				);
			}
			for (const item of entry.special || []) {
				check(Number.isFinite(item.value), `${where}: a special value is a number`);
				check(typeof en[item.label_key] === 'string', `${where}: en.json has ${item.label_key}`);
			}
			if (entry.max_from && entry.max_from.file) {
				// A maximum another shared file owns: read it there, never restate it.
				const text = fs.readFileSync(path.join(SP, '_shared', entry.max_from.file), 'utf8');
				const found = new RegExp(entry.max_from.pattern).exec(text);
				check(
					found && Number(found[1]) === entry.max,
					`${where}: max ${entry.max} equals ${entry.max_from.file}`
				);
			} else if (entry.max_from) {
				const value = timingValue(timings, entry.max_from.timing);
				check(
					value !== undefined && Math.abs(value * entry.max_from.scale - entry.max) < 1e-9,
					`${where}: max ${entry.max} equals timing ${entry.max_from.timing}`
				);
			}
		}
		if (entry.type === 'enum')
			check(Array.isArray(entry.values) && entry.values.length > 0, `${where}: values`);
		if (entry.default_from) {
			let value;
			if (entry.default_from.manifest)
				value = manifestDefault(manifest, entry.default_from.manifest);
			else if (entry.default_from.timing) {
				const timing = timingValue(timings, entry.default_from.timing);
				value = timing === undefined ? undefined : timing * entry.default_from.scale;
			}
			check(value !== undefined, `${where}: default_from names a declared default`);
			if (value !== undefined) {
				const result = V.checkValue(entry, value);
				check(result.ok, `${where}: its default ${value} is refused (${result.reason})`);
			}
		}
		// A menu that offers presets must offer only values the load admits.
		const row =
			entry.default_from && entry.default_from.manifest
				? manifestRow(manifest, entry.default_from.manifest)
				: null;
		for (const preset of (row && row.preset_values) || []) {
			const result = V.checkValue(entry, preset);
			check(result.ok, `${where}: its menu preset ${preset} is refused (${result.reason})`);
		}
	}
	return schema;
}

// The gesture step choices live in the shared Lua owner and its AHK copy;
// their ends are the declared range, so neither can drift from the other.
function checkGestureChoices(V, schema) {
	const entry = schema.settings['gestures.sensitivities.*'];
	const sources = [
		['_shared/gestures/engine/sensitivity.lua', /local OPTIONS = \{([^}]*)\}/],
		['windows/modules/gestures/raw_touchpad.ahk', /GESTURE_SENSITIVITY_OPTIONS := \[([^\]]*)\]/]
	];
	for (const [file, pattern] of sources) {
		const found = pattern.exec(fs.readFileSync(path.join(SP, file), 'utf8'));
		check(found, `${file}: the gesture step choices are found`);
		if (!found) continue;
		const values = found[1].split(',').map((item) => Number(item.trim()));
		check(
			values.length > 1 && values[0] === entry.min && values[values.length - 1] === entry.max,
			`${file}: the gesture step choices span the declared ${entry.min}..${entry.max} mm`
		);
		for (const value of values)
			check(V.checkValue(entry, value).ok, `${file}: the gesture step ${value} is admitted`);
	}
}

// The JSON schema of the generated templates must not admit another range.
function checkConfigSchema(schema) {
	const config = readJson(CONFIG_SCHEMA_PATH);
	for (const [name, entry] of Object.entries(schema.settings)) {
		if (entry.file !== 'config.toml' || name.includes('*')) continue;
		let node = config;
		for (const segment of name.split('.')) {
			node = node && node.properties && node.properties[segment];
			// A section is often a reference into $defs.
			if (node && node.$ref) node = config.$defs[node.$ref.replace('#/$defs/', '')];
		}
		if (!node) continue;
		const where = `config.schema.json ${name}`;
		if (entry.type === 'integer') check(node.type === 'integer', `${where}: type integer`);
		if (entry.type === 'integer' || entry.type === 'decimal') {
			// A JSON schema bound cannot skip a gap: a special value outside the
			// range (the debounce's -1 = never) widens it to that value.
			const specials = (entry.special || []).map((item) => item.value);
			const min = Math.min(entry.min, ...specials);
			const max = Math.max(entry.max, ...specials);
			check(
				node.minimum === min && node.exclusiveMinimum === undefined,
				`${where}: minimum ${min}`
			);
			check(node.maximum === max, `${where}: maximum ${max}`);
		}
	}
}

// ==========================================
// ==========================================
// ======= 3/ Locales and ports ============
// ==========================================
// ==========================================

function checkLocales(schema, en) {
	const locales = fs.readdirSync(LOCALES_DIR).filter((file) => file.endsWith('.json'));
	check(locales.length === LOCALE_COUNT, `${LOCALE_COUNT} locales`);
	const keys = new Set(MESSAGE_KEYS);
	for (const entry of Object.values(schema.settings)) {
		for (const unit of [entry.unit, entry.entry_unit].filter(Boolean))
			keys.add(`value_check.unit.${unit}`);
		for (const item of entry.special || []) keys.add(item.label_key);
	}
	for (const file of locales) {
		const locale = readJson(path.join(LOCALES_DIR, file));
		for (const key of keys) {
			check(typeof locale[key] === 'string' && locale[key] !== '', `${file}: ${key} is translated`);
		}
		for (const key of ['dialog.value_check.range_integer', 'dialog.value_check.range_decimal']) {
			check(
				/\{1\}/.test(locale[key] || '') && /\{2\}/.test(locale[key] || ''),
				`${file}: ${key} names both bounds`
			);
		}
	}
	check(typeof en['dialog.value_check.title'] === 'string', 'en.json has the refusal title');
}

function checkPorts() {
	for (const item of PORTS) {
		check(fs.existsSync(path.join(SP, item.port)), `port ${item.port} exists`);
		check(fs.existsSync(path.join(SP, item.test)), `vector test ${item.test} exists`);
		if (item.wiring) {
			const text = fs.readFileSync(path.join(SP, item.wiring.file), 'utf8');
			check(text.includes(item.wiring.needle), `${item.wiring.file} runs ${item.test}`);
		}
	}
	const { render, renderLua, renderBrowser, OUTPUT, LUA_OUTPUT, BROWSER_OUTPUT } = require(
		GENERATOR
	);
	for (const [file, content] of [
		[OUTPUT, render()],
		[LUA_OUTPUT, renderLua()],
		[BROWSER_OUTPUT, renderBrowser()]
	]) {
		check(
			fs.readFileSync(file, 'utf8') === content,
			`${path.relative(ROOT, file)} is stale: run npm run codegen:value-schema`
		);
	}
}

// The WebView pages load the generated classic copy: it must behave as the
// canonical check, and every page field the schema covers must go through it.
function checkBrowserCopy() {
	const vm = require('vm');
	const { BROWSER_OUTPUT } = require(GENERATOR);
	const sandbox = { window: {} };
	vm.runInNewContext(fs.readFileSync(BROWSER_OUTPUT, 'utf8'), sandbox);
	const V = sandbox.window.ErgoptiValueCheck;
	check(
		V && typeof V.parseEntry === 'function',
		'the browser copy exposes window.ErgoptiValueCheck'
	);
	const priority = V.entryFor(V.SCHEMA, V.KEY.HOTSTRINGS_CONFIG_ANY_PRIORITY);
	const refused = V.parseEntry(priority, '101');
	check(!refused.ok && refused.reason === 'above_maximum', 'the browser copy refuses priority 101');
	const delay = V.entryFor(V.SCHEMA, V.KEY.HOTSTRINGS_CONFIG_ANY_DELAY);
	check(V.parseEntry(delay, '375').value === 0.375, 'the browser copy reads a typed delay in ms');
	const page = path.join(SP, '_shared', 'ui', 'hotstrings_config_window');
	const html = fs.readFileSync(path.join(page, 'index.html'), 'utf8');
	check(
		html.indexOf('../value_check.js') > 0 &&
			html.indexOf('../value_check.js') < html.indexOf('"script.js"'),
		'the hotstrings settings window loads the value check before its script'
	);
	const script = fs.readFileSync(path.join(page, 'script.js'), 'utf8');
	for (const key of [
		'HOTSTRINGS_CONFIG_ANY_DELAY',
		'HOTSTRINGS_CONFIG_ANY_ANY_DELAY',
		'HOTSTRINGS_CONFIG_ANY_PRIORITY',
		'HOTSTRINGS_CONFIG_ANY_ANY_PRIORITY'
	]) {
		check(script.includes(`KEY.${key}`), `the hotstrings settings window checks ${key}`);
	}
	check(
		script.includes('setCustomValidity'),
		'a refused field shows its localized range on the field'
	);
}

async function main() {
	const V = await import(pathToFileURL(CHECK_PATH).href);
	const en = readJson(path.join(LOCALES_DIR, 'en.json'));
	replayVectors(V);
	const schema = checkDeclarations(V, en);
	checkConfigSchema(schema);
	checkGestureChoices(V, schema);
	checkLocales(schema, en);
	checkPorts();
	checkBrowserCopy();
	if (failures.length) {
		console.error(`value schema contract: ${failures.length} of ${checks} checks failed`);
		for (const failure of failures) console.error(`  - ${failure}`);
		process.exit(1);
	}
	console.log(`value schema contract: ${checks} checks passed`);
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
