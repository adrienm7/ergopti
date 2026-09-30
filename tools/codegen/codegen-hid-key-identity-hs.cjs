// tools/codegen/codegen-hid-key-identity-hs.cjs

/**
 * ==============================================================================
 * MODULE: HID Key Identity Codegen (macOS)
 * DESCRIPTION:
 * Generates `macos/_generated/hid_key_identity.lua`, the table the macOS
 * physical-key stream uses to turn a raw HID (usage page, usage) into the macOS
 * virtual keycode the metrics already store, from the one physical-key
 * registry `_shared/data/keycodes/physical_keys.json`.
 *
 * FEATURES & RATIONALE:
 * 1. Single source of truth: the registry already owns every key's macOS
 *    keycode (`hs`), its ISO override (`macos_iso.hs`) and now its HID usage
 *    (`hid`). A hand-written usage table in the keylogger would be a sixth copy
 *    of physical-key identity, the drift the registry was created to end.
 * 2. Form only where it matters: a record whose keycode is the same on every
 *    registry form is emitted as `kc`; only a record whose keycode differs by
 *    form (the ISO swap of the keys left of 1 and left of Z) is emitted with one
 *    keycode per form, so the consumer needs a keyboard type for those keys only.
 * 3. Refuses instead of guessing: a key without a `hid` usage, a duplicate usage
 *    or a usage outside its page's range fails the generation.
 * 4. Pure data, no runtime JSON: the Hammerspoon keylogger requires a Lua table
 *    and never parses the registry on the capture path.
 *
 * USAGE:  node tools/codegen/codegen-hid-key-identity-hs.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const REGISTRY = path.join(SP, '_shared', 'data', 'keycodes', 'physical_keys.json');
const OUT = path.join(SP, 'macos', '_generated', 'hid_key_identity.lua');

// The largest usage of each page a registry key may carry: the Keyboard/Keypad
// page (0x07) addresses one byte, the Consumer page (0x0C) sixteen bits.
const USAGE_MAX = { 7: 0xff, 12: 0xffff };

/** Fails the generation with one message. */
function fail(message) {
	console.error(`[ERROR] ${message}`);
	process.exit(1);
}

const registry = JSON.parse(fs.readFileSync(REGISTRY, 'utf8'));
const forms = registry.forms;
if (!Array.isArray(forms) || forms.length === 0) fail('the registry declares no forms.');

/** The macOS keycode of one registry key on one form. */
function keycodeOn(entry, form) {
	const override = entry['macos_' + form];
	if (override && override.hs !== undefined) return override.hs;
	return entry.hs;
}

const pages = new Map();
for (const [code, entry] of Object.entries(registry.keys || {})) {
	if (entry.kind !== 'key') continue;
	const hid = entry.hid;
	if (!hid || typeof hid !== 'object') fail(`${code} has no hid usage.`);
	const max = USAGE_MAX[hid.page];
	if (max === undefined) fail(`${code}: usage page ${hid.page} is not a key page.`);
	if (!Number.isInteger(hid.usage) || hid.usage < 1 || hid.usage > max)
		fail(`${code}: usage ${hid.usage} is outside page ${hid.page}.`);
	const byForm = forms.map((form) => keycodeOn(entry, form));
	for (const kc of byForm)
		if (!Number.isInteger(kc) || kc < 0) fail(`${code}: keycode ${kc} is not a macOS keycode.`);
	if (!pages.has(hid.page)) pages.set(hid.page, new Map());
	const usages = pages.get(hid.page);
	if (usages.has(hid.usage))
		fail(`${code} and ${usages.get(hid.usage).code} share usage ${hid.page}:${hid.usage}.`);
	usages.set(hid.usage, { code, byForm });
}
if (pages.size === 0) fail('the registry yields no HID usage — refusing an empty table.');

/** A Lua double-quoted literal. */
const q = (s) => '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';

const lines = [];
lines.push('--- _generated/hid_key_identity.lua');
lines.push('--- AUTO-GENERATED from _shared/data/keycodes/physical_keys.json.');
lines.push('--- DO NOT EDIT BY HAND — run `npm run codegen:hid-key-identity:hs` to refresh.');
lines.push('');
lines.push('--- ==============================================================================');
lines.push('--- MODULE: HID Key Identity (macOS)');
lines.push('--- DESCRIPTION:');
lines.push('--- Every registry key by HID usage page and usage, with the macOS virtual');
lines.push('--- keycode the metrics store for it. `kc` is the same on every registry form;');
lines.push('--- a key whose keycode depends on the keyboard type carries one keycode per');
lines.push('--- form instead. modules/keylogger/physical_key_identity.lua owns the policy');
lines.push('--- that reads it.');
lines.push('--- ==============================================================================');
lines.push('');
lines.push('return {');
lines.push(`\tforms = { ${forms.map(q).join(', ')} },`);
lines.push('\tpages = {');
for (const page of [...pages.keys()].sort((a, b) => a - b)) {
	lines.push(`\t\t[${page}] = {`);
	const usages = pages.get(page);
	for (const usage of [...usages.keys()].sort((a, b) => a - b)) {
		const { code, byForm } = usages.get(usage);
		const same = byForm.every((kc) => kc === byForm[0]);
		const fields = same
			? `kc = ${byForm[0]}`
			: forms.map((form, index) => `${form} = ${byForm[index]}`).join(', ');
		lines.push(`\t\t\t[${usage}] = { code = ${q(code)}, ${fields} },`);
	}
	lines.push('\t\t},');
}
lines.push('\t},');
lines.push('}');
lines.push('');

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, lines.join('\n'), 'utf8');
let count = 0;
for (const usages of pages.values()) count += usages.size;
console.log(`  wrote ${path.relative(ROOT, OUT).split(path.sep).join('/')}`);
console.log(`[OK] ${count} HID usage(s) across ${pages.size} page(s) generated.`);
