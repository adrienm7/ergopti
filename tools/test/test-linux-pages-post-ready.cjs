// tools/test/test-linux-pages-post-ready.cjs

/**
 * ==============================================================================
 * MODULE: Linux Pages Post Ready
 * DESCRIPTION:
 * A Linux page bridge (the module webview_manager's BRIDGE_MODULES names for
 * the page, wherever it lives) that answers the page's
 * "ready" message pushes the page its first state only then: the WebKit host
 * routes no load-finished signal to it, while Windows and macOS also push on
 * navigation. A shared page (_shared/ui/<page>/) that never posts "ready"
 * therefore opens empty on Linux only: the hotstrings settings window did
 * (WVH-001), while the hardware harness sent the message itself and stayed
 * green. This gate holds every such page to posting it.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const plus = path.resolve(__dirname, '../../static/ergopti_plus');
const linux = path.join(plus, 'linux');
const sharedUi = path.join(plus, '_shared/ui');

// A page no Linux caller opens: its bridge is registered, nothing shows it.
const NOT_OPENED_ON_LINUX = {
	token_prompt: 'webview_manager registers it, but no Linux menu, flow or module opens it'
};

const READY_HANDLED = /==\s*"ready"/;
const READY_POSTED = /\(\s*(?:\{\s*action:\s*)?['"]ready['"]/;

/** Every Lua file of the Linux driver outside its tests. */
function driverLua(dir, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (!['tests', '_generated'].includes(entry.name)) driverLua(full, out);
		} else if (entry.name.endsWith('.lua')) out.push(full);
	}
	return out;
}

// The pages come from the table that loads their bridges, found by its
// declaration, and each bridge from its module name: a page's bridge may
// live in any feature folder, under any file name.
const owners = driverLua(linux).filter((file) =>
	/^local BRIDGE_MODULES = \{$/m.test(fs.readFileSync(file, 'utf8'))
);
assert.equal(owners.length, 1, 'exactly one Linux module declares BRIDGE_MODULES');
const table = fs
	.readFileSync(owners[0], 'utf8')
	.match(/^local BRIDGE_MODULES = \{$([\s\S]*?)^\}$/m)[1];
const bridges = new Map(
	[...table.matchAll(/^\s*([\w]+)\s*=\s*"([\w.]+)",/gm)].map((m) => [
		m[1],
		path.join(linux, `${m[2].replace(/\./g, '/')}.lua`)
	])
);
assert.ok(bridges.size >= 15, `only ${bridges.size} bridge modules declared: the table moved`);
const pages = [...bridges]
	.filter(([, file]) => fs.existsSync(file) && READY_HANDLED.test(fs.readFileSync(file, 'utf8')))
	.map(([name]) => name);

assert.ok(pages.length >= 15, `only ${pages.length} Linux bridges answer "ready": the scan moved`);
const missing = [];
for (const name of pages) {
	if (NOT_OPENED_ON_LINUX[name]) continue;
	const folder = path.join(sharedUi, name);
	assert.ok(fs.existsSync(folder), `${name}: the Linux bridge has no shared page folder`);
	const sources = fs
		.readdirSync(folder)
		.filter((file) => /\.(js|html)$/.test(file))
		.map((file) => fs.readFileSync(path.join(folder, file), 'utf8'));
	if (!sources.some((text) => READY_POSTED.test(text))) missing.push(name);
}
for (const name of Object.keys(NOT_OPENED_ON_LINUX)) {
	assert.ok(pages.includes(name), `${name} is exempted but its bridge no longer waits for "ready"`);
}
if (missing.length > 0) {
	console.error(
		`\x1b[31m[FAIL] these pages never post "ready", so they open empty on Linux: ${missing.join(', ')}\x1b[0m`
	);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] ${pages.length - Object.keys(NOT_OPENED_ON_LINUX).length} Linux pages post "ready".\x1b[0m`
);
