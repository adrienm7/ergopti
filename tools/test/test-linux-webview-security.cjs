// tools/test/test-linux-webview-security.cjs

/**
 * ==============================================================================
 * MODULE: Linux WebView Security Gate
 * DESCRIPTION:
 * Proves that privileged Linux WebViews load only byte-pinned local browser
 * dependencies and expose one native bridge capability per shared UI page.
 * ==============================================================================
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const UI_ROOT = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'ui');
const VENDOR_ROOT = path.join(UI_ROOT, 'vendor');
const MANIFEST = JSON.parse(fs.readFileSync(path.join(VENDOR_ROOT, 'vendor-manifest.json'), 'utf8'));

function fail(message) {
	throw new Error(message);
}

if (MANIFEST.schema_version !== 1 || !Array.isArray(MANIFEST.assets) || MANIFEST.assets.length !== 4) {
	fail('vendor-manifest.json must declare the four reviewed browser bundles');
}

for (const asset of MANIFEST.assets) {
	if (!/^https:\/\/cdn\.jsdelivr\.net\/npm\/[^@]+@[^/]+\//.test(asset.source)) {
		fail(`${asset.file}: source must be an immutable package@version jsDelivr URL`);
	}
	const body = fs.readFileSync(path.join(VENDOR_ROOT, asset.file));
	const digest = crypto.createHash('sha256').update(body).digest('hex');
	if (digest !== asset.sha256) {
		fail(`${asset.file}: SHA-256 ${digest} does not match reviewed digest ${asset.sha256}`);
	}
}

const remoteExecutable = /<(?:script\b[^>]*\bsrc|link\b[^>]*\brel=["']stylesheet["'][^>]*\bhref)=["'](?:https?:)?\/\//i;
const htmlFiles = fs.readdirSync(UI_ROOT, { withFileTypes: true })
	.filter((entry) => entry.isDirectory())
	.map((entry) => path.join(UI_ROOT, entry.name, 'index.html'))
	.filter((file) => fs.existsSync(file));

for (const file of htmlFiles) {
	if (remoteExecutable.test(fs.readFileSync(file, 'utf8'))) {
		fail(`${path.relative(ROOT, file)} loads executable code from a remote origin`);
	}
}

const host = fs.readFileSync(
	path.join(ROOT, 'static', 'ergopti_plus', 'linux', 'ui', 'webkit_host.lua'),
	'utf8',
);
for (const required of [
	"default-src 'none'",
	'local connect_sources = "\'self\' file:"',
	"object-src 'none'",
	"frame-src 'none'",
	'function M.bridge_for_app(app_name)',
]) {
	if (!host.includes(required)) fail(`webkit_host.lua is missing security invariant: ${required}`);
}
if (!host.includes('if app_name == "changelog" then')
	|| !host.includes('https://api.github.com')) {
	fail('only the changelog may receive the reviewed GitHub API connection capability');
}

const manager = fs.readFileSync(
	path.join(ROOT, 'static', 'ergopti_plus', 'linux', 'ui', 'webview_manager.lua'),
	'utf8',
);
const registrations = manager.match(/register_script_message_handler\(/g) || [];
if (registrations.length !== 1 || manager.includes('for _, bridge_name in ipairs(bridge_names)')) {
	fail('each Linux WebView must register only its page-owned bridge');
}
if (!/M\.route_message\(app_name,\s*bridge_name,\s*payload,\s*window_epoch\)/.test(manager)) {
	fail('bridge routing must carry the trusted app identity and page epoch');
}

console.log(`ok - ${MANIFEST.assets.length} pinned vendors, ${htmlFiles.length} offline pages, one bridge per app`);
