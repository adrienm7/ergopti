// tools/test/test-linux-pages-post-ready.cjs

/**
 * ==============================================================================
 * MODULE: Linux Pages Post Ready
 * DESCRIPTION:
 * A Linux page bridge (linux/updater/ui/<page>/bridge.lua) that answers the page's
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
const linuxUi = path.join(plus, 'linux');
const sharedUi = path.join(plus, '_shared/ui');

// A page no Linux caller opens: its bridge is registered, nothing shows it.
const NOT_OPENED_ON_LINUX = {
	token_prompt: 'webview_manager registers it, but no Linux menu, flow or module opens it'
};

const READY_HANDLED = /==\s*"ready"/;
const READY_POSTED = /\(\s*(?:\{\s*action:\s*)?['"]ready['"]/;

const pages = fs
	.readdirSync(linuxUi, { withFileTypes: true })
	.filter((entry) => entry.isDirectory())
	.map((entry) => entry.name)
	.filter((name) => {
		const bridge = path.join(linuxUi, name, 'bridge.lua');
		return fs.existsSync(bridge) && READY_HANDLED.test(fs.readFileSync(bridge, 'utf8'));
	});

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
