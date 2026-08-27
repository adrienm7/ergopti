// tools/test/test-changelog-security.cjs

/**
 * ==============================================================================
 * MODULE: Changelog Security Boundary Regression Test
 * DESCRIPTION:
 * Pins the shared changelog renderer and the Windows native bridge to one
 * authenticated document session. Remote release notes remain inert, foreign
 * documents cannot post privileged messages, and only repository HTTPS URLs
 * can reach the native launcher.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED_CHANGELOG = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'ui', 'changelog');
const WINDOWS_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'windows');

const index = fs.readFileSync(path.join(SHARED_CHANGELOG, 'index.html'), 'utf8');
const script = fs.readFileSync(path.join(SHARED_CHANGELOG, 'script.js'), 'utf8');
const bridge = fs.readFileSync(path.join(WINDOWS_ROOT, 'ui', 'changelog', 'init.ahk'), 'utf8');
const updater = fs.readFileSync(path.join(WINDOWS_ROOT, 'modules', 'updater', 'core.ahk'), 'utf8');

const failures = [];

function expect(condition, message) {
	if (!condition) failures.push(message);
}

expect(
	index.includes('Content-Security-Policy') && index.includes("default-src 'self'"),
	'the changelog document must declare a restrictive CSP'
);
expect(
	!index.includes('cdn.jsdelivr.net') && !index.includes('marked'),
	'the changelog must not execute a remotely mutable Markdown renderer'
);
expect(
	!script.includes('marked.parse') && script.includes('notes.textContent = raw'),
	'remote release notes must reach the document only through textContent'
);
expect(
	!script.includes('bodyEl.innerHTML = marked.parse'),
	'active Markdown must never be assigned to a live element as HTML'
);

expect(
	script.includes('window.__changelog_session'),
	'the shared page must attach the native session token to bridge messages'
);
expect(
	script.includes('message.session = _bridgeSession'),
	'every privileged Windows bridge payload must carry its exact session'
);
expect(
	bridge.includes('Args.Source'),
	'the Windows bridge must authenticate WebMessageReceivedEventArgs.Source'
);
expect(
	bridge.includes('_CLW_BridgeSessionIsCurrent'),
	'the Windows bridge must reject stale window/session identities'
);

const readPos = bridge.indexOf('Args.TryGetWebMessageAsString()');
const sourcePos = bridge.indexOf('_CLW_BridgeSourceMatches(');
expect(
	sourcePos >= 0 && readPos > sourcePos,
	'source provenance must be accepted before reading or dispatching the message'
);

const allowPos = updater.indexOf('_Updater_IsAllowedManualUrl(Url)');
const runPos = updater.indexOf('RunFn.Call(Url)', allowPos);
expect(
	allowPos >= 0 && runPos > allowPos,
	'the HTTPS repository allowlist must run before any injected/native runner'
);

console.log(`1..${failures.length === 0 ? 1 : failures.length}`);
if (failures.length === 0) {
	console.log('ok 1 - changelog remote content and bridge boundary are authenticated');
	process.exit(0);
}
failures.forEach((message, index) => console.log(`not ok ${index + 1} - ${message}`));
process.exit(1);
