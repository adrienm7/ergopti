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
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED_CHANGELOG = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'ui', 'changelog');
const WINDOWS_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'windows');

const index = fs.readFileSync(path.join(SHARED_CHANGELOG, 'index.html'), 'utf8');
const script = fs.readFileSync(path.join(SHARED_CHANGELOG, 'script.js'), 'utf8');
const markdown = fs.readFileSync(path.join(SHARED_CHANGELOG, '..', 'markdown.js'), 'utf8');
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
	!script.includes('marked.parse') && script.includes('renderMarkdownInto(bodyEl, raw'),
	'remote release notes must reach the document only through the shared DOM-only renderer'
);
const markdownPos = index.indexOf('src="../markdown.js"');
const scriptPos = index.indexOf('src="script.js"');
expect(
	markdownPos >= 0 && scriptPos > markdownPos,
	'the local Markdown renderer must load before the page script that calls it'
);
// Behavioural coverage of the renderer lives in test-changelog-markdown.cjs;
// this pins the absence of every HTML-parsing sink in both scripts.
for (const [name, source] of [['script.js', script], ['markdown.js', markdown]]) {
	expect(
		!/\binnerHTML\b|\bouterHTML\b|insertAdjacentHTML|DOMParser|document\.write|\beval\s*\(|new Function/.test(source),
		`${name} must never hand remote release text to an HTML parser or evaluator`
	);
}

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

/** Concatenates the text of a recorded node and all of its descendants. */
function renderedText(node) {
	return node.textContent + node.children.map(renderedText).join('');
}

/** Executes the shared page against the Linux response protocol. */
function checkLinuxProtocol() {
	const elements = new Map();
	function element(id) {
		if (elements.has(id)) return elements.get(id);
		const value = {
			id,
			textContent: '',
			className: '',
			style: {},
			children: [],
			attributes: {},
			classList: { toggle() {} },
			addEventListener() {},
			appendChild(child) { this.children.push(child); return child; },
			replaceChildren(...children) { this.children = children; },
			setAttribute(name, value) { this.attributes[name] = String(value); },
			getAttribute(name) { return this.attributes[name] || null; },
		};
		elements.set(id, value);
		return value;
	}

	const posted = [];
	const sandbox = {
		console,
		URL,
		Date,
		document: {
			readyState: 'complete',
			getElementById: id => element(id),
			querySelectorAll: () => [],
			createElement: tag => element(`created-${tag}-${elements.size}`),
			createTextNode: text => ({ textContent: String(text), children: [] }),
		},
		makeHostBridge: name => payload => posted.push({ name, payload }),
		decodeHostBridgeResponse: (_isBase64, payload) => JSON.parse(payload),
		setTimeout: () => 1,
		clearTimeout() {},
	};
	sandbox.window = sandbox;
	sandbox.__ergopti_host = 'linux';
	vm.createContext(sandbox);
	vm.runInContext(markdown, sandbox, { filename: 'markdown.js' });
	vm.runInContext(script, sandbox, { filename: 'changelog/script.js' });

	expect(
		posted.length === 1 && posted[0].name === 'changelog_bridge' && posted[0].payload === 'ready',
		'the Linux changelog must announce readiness over its owned bridge'
	);
	const release = {
		tag_name: 'v9.8.7',
		body: 'Native cache marker',
		html_url: 'https://github.com/adrienm7/ergopti/releases/tag/v9.8.7',
		published_at: '2026-08-31T12:00:00Z',
		prerelease: false,
	};
	sandbox.__hostBridgeResponse('changelog_bridge', false, JSON.stringify({
		action: 'releases', channel: 'main', cache_miss: false, releases: [release],
	}));
	expect(
		element('release-tag').textContent === 'v9.8.7'
			&& renderedText(element('release-body')) === 'Native cache marker',
		'the Linux native response must render the canonical release schema into the DOM'
	);

	sandbox.openOnGitHub();
	const open = posted[posted.length - 1].payload;
	expect(
		open.action === 'open_url' && open.url === release.html_url,
		'the selected Linux release must use the canonical open_url action'
	);
	sandbox.__hostBridgeResponse('changelog_bridge', false, JSON.stringify({
		action: 'open_url', opened: false, error: 'Native opener marker',
	}));
	expect(
		element('error-text').textContent === 'Native opener marker'
			&& element('error-overlay').style.display === 'flex',
		'a refused Linux opener must become a visible page error'
	);

	sandbox.setChannel('dev');
	const fetchRequest = posted[posted.length - 1].payload;
	expect(
		fetchRequest.action === 'fetch' && fetchRequest.channel === 'dev',
		'channel changes must use the canonical native fetch action'
	);
}

try {
	checkLinuxProtocol();
} catch (error) {
	expect(false, `the executable Linux changelog protocol raised: ${error.message}`);
}

console.log(`1..${failures.length === 0 ? 1 : failures.length}`);
if (failures.length === 0) {
	console.log('ok 1 - changelog remote content and bridge boundary are authenticated');
	process.exit(0);
}
failures.forEach((message, index) => console.log(`not ok ${index + 1} - ${message}`));
process.exit(1);
