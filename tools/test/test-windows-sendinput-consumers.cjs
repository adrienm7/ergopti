// tools/test/test-windows-sendinput-consumers.cjs

/**
 * ==============================================================================
 * MODULE: Windows SendInput Consumers Gate
 * DESCRIPTION:
 * Every SendInput makes AutoHotkey reinstall its keyboard hook in front of the
 * native owner's. docs/design/windows-input-hooks.md decides, site by site, why
 * the driver can live with that. This gate pins the sites to that decision, and
 * pins the two facts which make hook order harmless: the native owner never
 * cycles (its routes are parked) and it reasserts itself after a burst.
 *
 * WHY:
 * A new SendInput, or a native route added back beside an AutoHotkey hotkey,
 * would make a decision depend on the hook order again with every suite green,
 * since no test can observe the order without a physical keyboard.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const WINDOWS = path.join(ROOT, 'static', 'ergopti_plus', 'windows');
const DESIGN = path.join(ROOT, 'docs', 'design', 'windows-input-hooks.md');
const EXCLUDED = new Set(['tests', 'build']);
const SITE = /(^|[^_A-Za-z"\\])SendInput\(/;

// Each file and how many direct calls the design note has decided on.
const DECIDED = {
	'adapters/text_sender.ahk': 1,
	'infra/config_io.ahk': 1,
	'infra/hotstrings/hotstring_send.ahk': 5,
	'infra/input_probe.ahk': 3
};

const found = {};
const walk = (dir) => {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (!EXCLUDED.has(entry.name)) walk(full);
		} else if (entry.name.endsWith('.ahk')) {
			for (const line of fs.readFileSync(full, 'utf8').split('\n')) {
				if (line.trimStart().startsWith(';') || !SITE.test(line)) continue;
				const key = path.relative(WINDOWS, full).replace(/\\/g, '/');
				found[key] = (found[key] || 0) + 1;
			}
		}
	}
};
walk(WINDOWS);

const errors = [];
for (const file of new Set([...Object.keys(DECIDED), ...Object.keys(found)])) {
	if (found[file] !== DECIDED[file]) {
		errors.push(
			`${file}: ${found[file] || 0} direct SendInput call(s), ${DECIDED[file] || 0} decided in the design note`
		);
	}
}
const design = fs.readFileSync(DESIGN, 'utf8');
for (const file of Object.keys(DECIDED)) {
	if (!design.includes(`\`${file}\``)) errors.push(`the design note does not name ${file}`);
}
const adapter = fs.readFileSync(path.join(WINDOWS, 'adapters', 'llm_nav_event_owner.ahk'), 'utf8');
if (!adapter.includes('LLM_NAV_EVENT_OWNER_PARKED_CYCLE_ROUTES'))
	errors.push('the native cycle routes are no longer parked');
const native = fs.readFileSync(
	path.join(WINDOWS, 'native', 'nav_event_owner', 'nav_event_owner.c'),
	'utf8'
);
if (!/reinstall/i.test(native)) errors.push('the native owner no longer reasserts its hook');

if (errors.length) {
	console.error(`windows SendInput consumers: FAILED\n  ${errors.join('\n  ')}`);
	process.exit(1);
}
console.log('windows SendInput consumers: OK');
