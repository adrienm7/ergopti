// tools/test/test-config-schema.cjs

/**
 * ==============================================================================
 * MODULE: Config Schema Validator
 * DESCRIPTION:
 * Validates the generated `config_template.toml` (the default config copied into
 * the user profile on first boot, for EVERY driver) against the strict JSON
 * Schema at `_shared/core/config_schema/config.schema.json`. Until now that schema was
 * consumed by zero tests, so it silently drifted from the manifest-generated
 * template. This gate keeps the two in lock-step: a manifest change that the
 * schema does not allow (or a schema that forbids a real key) fails CI.
 *
 * THE TARGET LIST USED TO BE HAND-WRITTEN, AND NAMED TWO OF THREE:
 * build-features-manifest.js has emitted a Linux template all along; nothing
 * validated it. Worse, a missing target was logged as "not found, skipping" and
 * the run still exited 0 — so a driver whose template stopped being generated
 * would have left this gate reporting a clean pass over less and less. Drivers
 * are now discovered by their adapters/ tree, a missing template is a failure,
 * and the discovered count has a floor.
 *
 * FEATURES & RATIONALE:
 * 1. No external validator: there is no ajv in node_modules, so this hand-rolls a
 *    minimal JSON-Schema (draft 2020-12 subset) validator covering exactly the
 *    constructs config.schema.json uses — $ref/$defs, type (incl. unions),
 *    properties, required, additionalProperties (false|true|schema), enum, const,
 *    oneOf, allOf, minimum/maximum, minLength/maxLength, pattern, items.
 * 2. TOML via smol-toml: the same parser the rest of the toolchain already uses.
 * 3. Reports every violation (not fail-fast) so the full schema/template gap is
 *    visible in one run.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');
const { shared } = require('../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SCHEMA_PATH = shared('core/config_schema/config.schema.json');

// A driver is a directory with an adapters/ tree — the hexagonal marker. Naming
// the drivers by hand is what let Linux be missed; listing every subdirectory
// would sweep in docs/, extensions/, kanata/ and old/.
const DRIVERS_DIR = path.join(ROOT, 'static', 'ergopti_plus');
const DRIVERS = fs
	.readdirSync(DRIVERS_DIR, { withFileTypes: true })
	.filter((e) => e.isDirectory() && fs.existsSync(path.join(DRIVERS_DIR, e.name, 'adapters')))
	.map((e) => e.name)
	.sort();

// A discovery that collapses must fail rather than report a clean run over less.
const MIN_DRIVERS = 3;

// Violations that are known, understood, and pinned. This is a ratchet, not an
// exemption: an unlisted violation fails, AND a listed one that no longer occurs
// fails too, so the list cannot outlive the gap it describes.
//
// linux / "missing required property 'script'": [sections.script] in the feature
// manifest is platforms = ["ahk", "hs"], so the Linux template carries no
// [script] block at all. That is not an oversight in the template — the Linux
// driver keeps its locale in its own XDG store (lib/i18n.lua's s.get("locale")),
// not in config.toml. Closing it means re-platforming the section, which is the
// one-namespace migration's job, not a gate's. Until then the divergence is
// written down rather than invisible.
const KNOWN_GAPS = {
	linux: [": missing required property 'script'"]
};

const schema = JSON.parse(fs.readFileSync(SCHEMA_PATH, 'utf8'));

// ==================================================
// ==================================================
// ======= 1/ Minimal JSON-Schema validator =======
// ==================================================
// ==================================================

/**
 * Resolves a local `#/$defs/Name` reference against the root schema.
 * @param {string} ref
 * @returns {object}
 */
function resolveRef(ref) {
	const m = ref.match(/^#\/\$defs\/(.+)$/);
	if (!m || !schema.$defs || !schema.$defs[m[1]]) {
		throw new Error(`unsupported or unknown $ref: ${ref}`);
	}
	return schema.$defs[m[1]];
}

/**
 * JSON-Schema instance type of a parsed TOML value (integers reported distinctly).
 * @param {*} v
 * @returns {string}
 */
function instanceType(v) {
	if (Array.isArray(v)) return 'array';
	if (v === null) return 'null';
	if (typeof v === 'number') return Number.isInteger(v) ? 'integer' : 'number';
	if (typeof v === 'bigint') return 'integer';
	return typeof v; // string | boolean | object
}

/**
 * Whether a value satisfies a single JSON-Schema `type` keyword.
 * @param {*} v
 * @param {string} t
 * @returns {boolean}
 */
function matchesType(v, t) {
	const actual = instanceType(v);
	if (t === 'number') return actual === 'number' || actual === 'integer';
	return actual === t;
}

/**
 * Validates a value against a (sub)schema, pushing human-readable messages.
 * @param {*} value
 * @param {object} sch
 * @param {string} p     Dotted path for messages.
 * @param {string[]} errors
 */
function validate(value, sch, p, errors) {
	if (sch.$ref) {
		validate(value, resolveRef(sch.$ref), p, errors);
		return;
	}
	if (Array.isArray(sch.allOf)) {
		for (const sub of sch.allOf) validate(value, sub, p, errors);
	}
	if (Array.isArray(sch.oneOf)) {
		const matches = sch.oneOf.filter((sub) => {
			const e = [];
			validate(value, sub, p, e);
			return e.length === 0;
		}).length;
		if (matches !== 1) {
			errors.push(`${p}: must match exactly one of oneOf (matched ${matches})`);
		}
	}
	if (Object.prototype.hasOwnProperty.call(sch, 'const') && value !== sch.const) {
		errors.push(`${p}: must equal ${JSON.stringify(sch.const)}`);
	}
	if (Array.isArray(sch.enum) && !sch.enum.includes(value)) {
		errors.push(`${p}: ${JSON.stringify(value)} not in enum ${JSON.stringify(sch.enum)}`);
	}
	if (sch.type) {
		const types = Array.isArray(sch.type) ? sch.type : [sch.type];
		if (!types.some((t) => matchesType(value, t))) {
			errors.push(`${p}: type ${instanceType(value)} not allowed (expected ${types.join('|')})`);
		}
	}
	if (typeof value === 'number') {
		if (sch.minimum !== undefined && value < sch.minimum) {
			errors.push(`${p}: ${value} below minimum ${sch.minimum}`);
		}
		if (sch.maximum !== undefined && value > sch.maximum) {
			errors.push(`${p}: ${value} above maximum ${sch.maximum}`);
		}
	}
	if (typeof value === 'string') {
		if (sch.minLength !== undefined && value.length < sch.minLength) {
			errors.push(`${p}: shorter than minLength ${sch.minLength}`);
		}
		if (sch.maxLength !== undefined && value.length > sch.maxLength) {
			errors.push(`${p}: longer than maxLength ${sch.maxLength}`);
		}
		if (sch.pattern && !new RegExp(sch.pattern).test(value)) {
			errors.push(`${p}: does not match pattern ${sch.pattern}`);
		}
	}
	if (Array.isArray(value) && sch.items) {
		value.forEach((item, i) => validate(item, sch.items, `${p}[${i}]`, errors));
	}
	if (instanceType(value) === 'object') {
		const props = sch.properties || {};
		if (Array.isArray(sch.required)) {
			for (const key of sch.required) {
				if (!Object.prototype.hasOwnProperty.call(value, key)) {
					errors.push(`${p}: missing required property '${key}'`);
				}
			}
		}
		for (const [key, sub] of Object.entries(value)) {
			const kp = p ? `${p}.${key}` : key;
			if (props[key]) {
				validate(sub, props[key], kp, errors);
			} else if (sch.additionalProperties === false) {
				errors.push(`${kp}: additional property not permitted by schema`);
			} else if (sch.additionalProperties && typeof sch.additionalProperties === 'object') {
				validate(sub, sch.additionalProperties, kp, errors);
			}
			// additionalProperties === true / undefined → allowed, no descent
		}
	}
}

// ==================================================
// ==================================================
// ======= 2/ Runner =======
// ==================================================
// ==================================================

let totalFail = 0;
console.log('config schema validation (config_template.toml vs config.schema.json)');

for (const driver of DRIVERS) {
	const rel = `static/ergopti_plus/${driver}/_generated/config_template.toml`;
	const abs = path.join(ROOT, rel);
	if (!fs.existsSync(abs)) {
		console.log(`  ✗  ${rel} — missing. Every driver ships a default config; run \`npm run build:manifest\`.`);
		totalFail++;
		continue;
	}
	let data;
	try {
		data = TOML.parse(fs.readFileSync(abs, 'utf8'));
	} catch (err) {
		console.log(`  ✗  ${rel} — TOML parse error: ${err.message}`);
		totalFail++;
		continue;
	}
	const errors = [];
	validate(data, schema, '', errors);

	const gaps = KNOWN_GAPS[driver] || [];
	const unexpected = errors.filter((e) => !gaps.includes(e));
	const closed = gaps.filter((g) => !errors.includes(g));

	if (unexpected.length === 0 && closed.length === 0) {
		const suffix = gaps.length > 0 ? ` (${gaps.length} pinned gap(s))` : '';
		console.log(`  ✓  ${rel} — conforms to config.schema.json${suffix}`);
	}
	if (unexpected.length > 0) {
		console.log(`  ✗  ${rel} — ${unexpected.length} violation(s):`);
		for (const e of unexpected) console.log(`       - ${e}`);
		totalFail += unexpected.length;
	}
	// A gap that no longer occurs means the schema and the template agree again;
	// the entry must go, or it will hide the next real violation of that shape.
	for (const g of closed) {
		console.log(`  ✗  ${rel} — KNOWN_GAPS still lists "${g}", but it no longer occurs. Delete the entry.`);
		totalFail++;
	}
}

if (DRIVERS.length < MIN_DRIVERS) {
	console.log(
		`  ✗  discovered only ${DRIVERS.length} driver(s) under static/ergopti_plus, expected at least ${MIN_DRIVERS} — ` +
			'the walk is broken, and this gate would validate almost nothing.'
	);
	totalFail++;
}

console.log('');
console.log(`Total: ${totalFail} violation(s) across ${DRIVERS.length} driver template(s).`);
process.exit(totalFail > 0 ? 1 : 0);
