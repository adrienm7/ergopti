// tools/test/test-manifest-menu-labels-resolve.cjs

/**
 * ==============================================================================
 * MODULE: Manifest Menu-Label Resolution Guard (whole class)
 * DESCRIPTION:
 * Every tray-menu row gets its label from the manifest's `description_key`,
 * resolved through the candidate chain in
 * `static/ergopti_plus/windows/lib/manifest_descriptions.ahk`. When no candidate
 * hits, `MenuLabelFromDescriptionKey` falls back to the LAST SEGMENT OF THE PATH
 * — so the user sees a raw snake_case id in the menu.
 *
 * ROOT CAUSE THIS ENCODES: the locale files store these labels in a folded form
 * (`layout.ergopti_base` -> `layout.ergoptibase`) and the resolver folds by
 * stripping underscores only. `hotstrings.sfbs_reduction.i_e_acute` folds to
 * `sfbsreduction.ieacute`, but the locale key had been authored in the DISPLAY
 * alphabet as `sfbsreduction.ié` — reachable from no candidate at all — so that
 * row rendered as "i_e_acute" in all 21 languages.
 *
 * WHY A FULL ENUMERATION AND NOT A SAMPLE: the sibling guard
 * `test-dynamic-hotstrings-menu-labels.cjs` was written for this exact class
 * (the `dynamic` -> `dynamichotstrings` gap) but pins three hand-picked keys.
 * `sfbs_reduction.i_e_acute` was not among them, so the sibling slipped through
 * — the repo's documented dominant failure mode: an invariant applied per site
 * with one site forgotten. This walks EVERY manifest entry instead.
 *
 * FEATURES & RATIONALE:
 * 1. Faithful port of `_MenuLabelCandidateKeys` + the `t()` cascade (active
 *    locale -> en -> fr, with "" treated as missing at every level), so a key
 *    that resolves here resolves in the driver and vice versa.
 * 2. Entries of `type: "feature"` are the rows the tray menu actually renders.
 *    Those MUST resolve — a failure is a user-visible raw id.
 * 3. Every other entry type (scalars, stored widget state, selections) is
 *    carried by a RATCHET that can only shrink, because those keys are not
 *    passed through this resolver at runtime and fixing all of them is a
 *    separate job. A new one still fails the build.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');
const MANIFEST = 'static/ergopti_plus/windows/_generated/features_manifest.ahk';
const RESOLVER = 'static/ergopti_plus/windows/lib/manifest_descriptions.ahk';
const LOCALE_DIR = 'static/ergopti_plus/_shared/data/locales';

// Non-feature entries whose label does not resolve today. This number may only
// go DOWN. It is not a target to be raised: every entry behind it is a menu
// label that would render as a raw id if it were ever rendered.
const NON_FEATURE_FALLTHROUGH_BASELINE = 82;

// Feature rows that legitimately have no locale key, because their label comes
// from a DIFFERENT source. `hotstrings.personal.*` are the user's own sections:
// `manifest_descriptions.ahk` exposes TryMenuLabelFrom… precisely so these
// callers can chain to the user's TOML section description instead of showing a
// key. Verified empirically before exempting them — across nine days of real
// driver logs, not one `hotstrings.personal.*` candidate key ever reached `t()`,
// so these rows never touch the cascade this test models.
const NO_LOCALE_KEY_BY_DESIGN = [{ prefix: 'hotstrings.personal.', why: "user-authored sections; label comes from the TOML section description" }];

function isExemptByDesign(entryPath) {
	return NO_LOCALE_KEY_BY_DESIGN.some((e) => entryPath.startsWith(e.prefix));
}

let total_pass = 0;
let total_fail = 0;

function check(label, cond, detail) {
	if (cond) {
		total_pass++;
		console.log(`  ${PASS_SYMBOL}  ${label}`);
	} else {
		total_fail++;
		console.log(`  ${FAIL_SYMBOL}  ${label}`);
		if (detail) console.log(`       ${detail}`);
	}
}

function flatten(obj, prefix, out) {
	for (const k of Object.keys(obj)) {
		const v = obj[k];
		const key = prefix ? `${prefix}.${k}` : k;
		if (v && typeof v === 'object' && !Array.isArray(v)) flatten(v, key, out);
		else out[key] = v;
	}
	return out;
}

function readLocale(name) {
	const p = path.join(REPO_ROOT, LOCALE_DIR, `${name}.json`);
	return flatten(JSON.parse(fs.readFileSync(p, 'utf8')), '', {});
}

// ==============================================================
// ==============================================================
// ======= 1/ Port of the driver's resolution cascade ===========
// ==============================================================
// ==============================================================

const EN = readLocale('en');
const FR = readLocale('fr');

// lib/locale.ahk t(): active locale, then en, then fr. An empty string counts as
// MISSING at every level. A total miss returns the raw key.
function t(key) {
	if (EN[key] !== undefined && EN[key] !== '') return EN[key];
	if (FR[key] !== undefined && FR[key] !== '') return FR[key];
	return key;
}

const strip = (s) => s.split('_').join('');

// Port of _MenuLabelCandidateKeys (AHK SubStr is 1-based; offsets adjusted).
function candidateKeys(descKey, entryPath) {
	const out = [];
	if (descKey !== '') out.push(descKey);
	if (descKey.length > 5 && descKey.slice(0, 5) === 'menu.') {
		const noMenu = descKey.slice(5);
		out.push(noMenu, strip(noMenu));
		if (noMenu.length > 11 && noMenu.slice(0, 11) === 'hotstrings.') {
			const noHs = noMenu.slice(11);
			out.push(noHs, strip(noHs));
		}
	}
	if (entryPath !== '' && entryPath !== descKey) {
		out.push(entryPath);
		let trimmed = entryPath;
		if (trimmed.length > 4 && trimmed.slice(0, 4) === 'ahk.') {
			trimmed = trimmed.slice(4);
			out.push(trimmed);
		}
		if (trimmed.length > 11 && trimmed.slice(0, 11) === 'hotstrings.') {
			trimmed = trimmed.slice(11);
			out.push(trimmed);
		}
		out.push(strip(trimmed));
	}
	const combined = descKey !== '' ? descKey : entryPath;
	const dyn = combined.indexOf('.dynamic.');
	if (dyn >= 0) {
		const section = combined.slice(dyn + 9);
		if (section !== '') out.push(`dynamichotstrings.${section}`, `dynamichotstrings.${strip(section)}`);
	}
	return out;
}

// Port of TryMenuLabelFromDescriptionKey: first candidate that resolves wins.
function resolvesToALabel(descKey, entryPath) {
	for (const c of candidateKeys(descKey, entryPath)) {
		if (c === '') continue;
		const r = t(c);
		if (r !== '' && r !== c) return true;
	}
	return false;
}

// What the menu would show instead: the path's tail segment, else the raw key.
function fallbackLabel(descKey, entryPath) {
	if (entryPath !== '') {
		const parts = entryPath.split('.');
		return parts[parts.length - 1];
	}
	return descKey;
}

// ==============================================================
// ==============================================================
// ======= 2/ Every manifest entry, enumerated ==================
// ==============================================================
// ==============================================================

function manifestRows() {
	const src = fs.readFileSync(path.join(REPO_ROOT, MANIFEST), 'utf8');
	const rows = [];
	const rowRe = /Map\("path",\s*"([^"]*)"[^\n]*?"description_key",\s*"([^"]*)"/g;
	let m;
	while ((m = rowRe.exec(src)) !== null) {
		const lineEnd = src.indexOf('\n', m.index);
		const line = src.slice(m.index, lineEnd === -1 ? undefined : lineEnd);
		const typeMatch = line.match(/"type",\s*"([^"]*)"/);
		rows.push({ path: m[1], key: m[2], type: typeMatch ? typeMatch[1] : '' });
	}
	return rows;
}

console.log('Manifest menu-label resolution guard');
console.log('='.repeat(50));

const rows = manifestRows();
check(
	`manifest yields entries with a description_key (found ${rows.length})`,
	rows.length >= 150,
	'a scan that matches almost nothing cannot fail — check the generated manifest shape'
);

// The resolver must still be the thing this test models.
const resolverSrc = fs.readFileSync(path.join(REPO_ROOT, RESOLVER), 'utf8');
check(
	'the resolver still folds underscores and bridges the dynamic category',
	resolverSrc.includes('_StripUnderscores') && resolverSrc.includes('dynamichotstrings.'),
	'lib/manifest_descriptions.ahk no longer matches the cascade this test ports — update both together'
);
check(
	'the resolver still falls back to the path tail segment',
	resolverSrc.includes('Parts[Parts.Length]'),
	'the raw-id fallback is what makes an unresolved label user-visible; if it changed, revisit this guard'
);

const featureBad = [];
const otherBad = [];
const exempt = [];
for (const r of rows) {
	if (resolvesToALabel(r.key, r.path)) continue;
	if (r.type === 'feature' && isExemptByDesign(r.path)) {
		exempt.push(r);
		continue;
	}
	(r.type === 'feature' ? featureBad : otherBad).push(r);
}

// An exemption that outlives the gap it records silently suppresses the
// guarantee, so each prefix must still match something unresolved.
for (const e of NO_LOCALE_KEY_BY_DESIGN) {
	check(
		`the "${e.prefix}" exemption is still needed (${e.why})`,
		exempt.some((r) => r.path.startsWith(e.prefix)),
		`no unresolved row starts with "${e.prefix}" any more — delete the exemption rather than leaving a rule this guard can never apply`
	);
}

check(
	`every manifest feature row resolves to a translated label (${rows.filter((r) => r.type === 'feature').length} row(s) checked, ${exempt.length} exempt by design)`,
	featureBad.length === 0,
	featureBad.length
		? `these rows render their RAW ID in the tray menu: ${featureBad
				.map((r) => `${r.path} -> "${fallbackLabel(r.key, r.path)}"`)
				.join(', ')}. Add the folded locale key (underscores stripped) to en.json and every sibling locale.`
		: ''
);

check(
	`non-feature label fall-throughs did not grow (${otherBad.length} <= ${NON_FEATURE_FALLTHROUGH_BASELINE})`,
	otherBad.length <= NON_FEATURE_FALLTHROUGH_BASELINE,
	`${otherBad.length} entries do not resolve, baseline is ${NON_FEATURE_FALLTHROUGH_BASELINE}. New offenders: ${otherBad
		.map((r) => r.path)
		.join(', ')}. Never raise the baseline to make a change pass — add the folded locale key instead.`
);

if (otherBad.length < NON_FEATURE_FALLTHROUGH_BASELINE) {
	console.log(
		`  ${PASS_SYMBOL}  ratchet can be tightened: NON_FEATURE_FALLTHROUGH_BASELINE is ${NON_FEATURE_FALLTHROUGH_BASELINE}, actual is ${otherBad.length}`
	);
}

// The specific key the audit found, pinned by name so the exact regression
// cannot come back through a locale edit.
check(
	'the IE/EI bigram row uses the folded locale key reachable by the resolver',
	EN['sfbsreduction.ieacute'] !== undefined && EN['sfbsreduction.ié'] === undefined,
	'sfbsreduction.ieacute must exist and the accented sfbsreduction.ié must not: the resolver folds i_e_acute to ieacute and can never reach a key spelled with é'
);

console.log('='.repeat(50));
console.log(`${total_pass} passed, ${total_fail} failed`);
process.exit(total_fail === 0 ? 0 : 1);
