// tools/test/test-locale-catalogue-complete.cjs

/**
 * ==============================================================================
 * MODULE: Locale Catalogue Completeness Guard
 * DESCRIPTION:
 * All 21 shipped catalogues must carry exactly en.json's key set, no value may
 * render blank, and each file must identify itself as the locale its name says.
 *
 * THE GAP THIS CLOSES:
 * Four locale gates already exist and none of them compares two catalogues.
 * `audit-translations.cjs` walks the *code* and checks each key it finds exists
 * in **en.json** — one direction, one locale. `test-locale-order-single-source`
 * matches the file set against locale_order.json. `test-locale-names-single-source`
 * checks every ordered locale has a native name. So the invariant everyone
 * assumes — "a key added to en.json exists in all 21" — was enforced by nobody.
 * Measured at the time of writing: 2 339 keys, identical across all 21 files.
 * That parity was held by discipline alone, and discipline is not a gate.
 *
 * WHY A MISSING KEY IS INVISIBLE WITHOUT THIS:
 * The i18n layer falls back active → en → fr, so a key missing from de.json
 * renders the English string. Nothing errors, nothing logs, and a reviewer
 * reading the German UI sees plausible text. The bug is only visible to someone
 * who both speaks German and knows what that label should say.
 *
 * WHAT THIS DELIBERATELY DOES NOT CHECK — FORMAT PLACEHOLDERS:
 * A "translations must carry the same %s / {n} as English" rule was measured and
 * rejected: it fires on correct work. Czech renders `Disabled in %d application%s`
 * as `Zakázáno v %d aplikaci/aplikacích`, dropping the `%s` that exists only to
 * pluralise an English noun — the Czech is right and the rule would demand it be
 * broken. In the other direction the apparent hits are all prose: `{pct}% du
 * focus` reads as a `% d` conversion to a regex and is a literal percent sign
 * followed by "du". Lua's string.format tolerates surplus arguments, so a
 * dropped specifier does not raise. There is no defect here to gate, and a gate
 * that fires on correct translations is worse than none — the fix it demands
 * damages the product.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const LOCALES = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'locales');

// Floors — a guard that reads nothing passes for free.
const MIN_LOCALES = 21; // The shipped set; adding one raises this deliberately.
const MIN_KEYS = 2000; // 2 339 today.

const REFERENCE = 'en'; // The canonical key set every other catalogue mirrors.

const errors = [];




// =========================================
// =========================================
// ======= 1/ Loading the catalogues =======
// =========================================
// =========================================

/** Flattens nested objects to dotted keys. The files are flat today; this keeps
 *  the comparison honest if that ever changes. */
function flatten(value, prefix = '', out = new Map()) {
	if (value && typeof value === 'object' && !Array.isArray(value)) {
		for (const [k, v] of Object.entries(value)) {
			flatten(v, prefix ? `${prefix}.${k}` : k, out);
		}
	} else {
		out.set(prefix, value);
	}
	return out;
}

const catalogues = new Map(); // code -> Map(key -> value)

if (!fs.existsSync(LOCALES)) {
	errors.push(`${path.relative(ROOT, LOCALES)} does not exist — there is no catalogue to check`);
} else {
	for (const f of fs.readdirSync(LOCALES).sort()) {
		if (!f.endsWith('.json')) continue; // .tsv is a regenerated parse cache
		const code = f.slice(0, -'.json'.length);
		let parsed;
		try {
			parsed = JSON.parse(fs.readFileSync(path.join(LOCALES, f), 'utf8'));
		} catch (e) {
			errors.push(`${f}: invalid JSON — ${e.message}`);
			continue;
		}
		catalogues.set(code, flatten(parsed));
	}
}

if (catalogues.size < MIN_LOCALES) {
	errors.push(
		`found ${catalogues.size} locale catalogue(s), expected at least ${MIN_LOCALES}. Either a ` +
			'shipped locale was deleted, or the scan is broken and this guard now compares nothing.'
	);
}

const reference = catalogues.get(REFERENCE);
if (!reference) {
	errors.push(`${REFERENCE}.json is missing — it is the canonical key set every other locale mirrors`);
} else if (reference.size < MIN_KEYS) {
	errors.push(
		`${REFERENCE}.json has only ${reference.size} key(s), expected at least ${MIN_KEYS} — the parse ` +
			'produced almost nothing and every comparison below would be vacuous'
	);
}




// =============================================
// =============================================
// ======= 2/ Key parity against en.json =======
// =============================================
// =============================================

if (reference && reference.size >= MIN_KEYS) {
	const refKeys = new Set(reference.keys());

	for (const [code, kv] of [...catalogues].sort()) {
		if (code === REFERENCE) continue;

		const missing = [...refKeys].filter((k) => !kv.has(k));
		const extra = [...kv.keys()].filter((k) => !refKeys.has(k));

		if (missing.length > 0) {
			errors.push(
				`${code}.json is missing ${missing.length} key(s) present in ${REFERENCE}.json: ` +
					`${missing.slice(0, 6).join(', ')}${missing.length > 6 ? ', …' : ''}. The UI falls back ` +
					'to English for these, so the only symptom is a German window with English labels — ' +
					'nothing errors and nothing logs. Run "python tools/locale/check_locales.py --fix" and ' +
					'review what it writes.'
			);
		}
		if (extra.length > 0) {
			errors.push(
				`${code}.json carries ${extra.length} key(s) that ${REFERENCE}.json does not: ` +
					`${extra.slice(0, 6).join(', ')}${extra.length > 6 ? ', …' : ''}. Either the key was ` +
					`renamed in ${REFERENCE}.json and this file kept the old name — in which case the ` +
					'translation is dead weight nothing reads — or it belongs in the canonical set.'
			);
		}
	}
}




// ===========================================
// ===========================================
// ======= 3/ Values that render blank =======
// ===========================================
// ===========================================

// A key whose value is "" passes every parity check above and blanks the UI. It
// reads as a layout bug, which is where the time goes.
for (const [code, kv] of [...catalogues].sort()) {
	const blank = [...kv].filter(([, v]) => typeof v === 'string' && v.trim() === '').map(([k]) => k);
	if (blank.length > 0) {
		errors.push(
			`${code}.json has ${blank.length} empty value(s): ${blank.slice(0, 6).join(', ')}` +
				`${blank.length > 6 ? ', …' : ''}. The key exists, so every parity check passes and the ` +
				'label simply renders blank — which looks like a layout bug, not a missing translation.'
		);
	}
}

// Each catalogue states its own code. A file copied from a neighbour and only
// half-edited keeps the source's identity, and the language menu then labels
// itself wrongly while every key is present and every check passes.
for (const [code, kv] of [...catalogues].sort()) {
	const declared = kv.get('_meta.locale');
	if (declared === undefined) {
		errors.push(`${code}.json has no "_meta.locale" — the catalogue does not say which locale it is`);
	} else if (declared !== code) {
		errors.push(
			`${code}.json declares _meta.locale = "${declared}". A catalogue copied from a neighbour and ` +
				'only half-edited keeps the source\'s identity, and the language menu then mislabels itself ' +
				'while every key is present.'
		);
	}
	for (const field of ['_meta.name', '_meta.flag']) {
		const v = kv.get(field);
		if (typeof v !== 'string' || v.trim() === '') {
			errors.push(`${code}.json has no usable "${field}" — the language menu row would render bare`);
		}
	}
}




// ==========================
// ==========================
// ======= 4/ Verdict =======
// ==========================
// ==========================

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] locale catalogue completeness:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${catalogues.size} locale catalogue(s) carry the same ${reference ? reference.size : 0} ` +
		'key(s), no value renders blank, and each names itself.\x1b[0m'
);
