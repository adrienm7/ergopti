// tools/test/test-changelog-markdown.cjs

/**
 * ==============================================================================
 * MODULE: Changelog Markdown Rendering Regression Test
 * DESCRIPTION:
 * Executes the shared changelog page, exactly as its index.html loads it, against
 * a recording DOM and injects a hostile GitHub release body. The notes must
 * become real Markdown elements (headings, lists, emphasis, code, tables, links)
 * while every HTML fragment stays inert text and no URL outside the repository
 * HTTPS allowlist becomes clickable.
 *
 * FEATURES & RATIONALE:
 * 1. Real page chain: scripts are read from index.html, so a renderer that is
 *    written but never loaded by the document fails here.
 * 2. No HTML parser: the recording DOM throws on innerHTML/outerHTML and
 *    insertAdjacentHTML, so remote text can only reach the page as text nodes.
 * 3. Safe links: anchors carry no href (the WebView never navigates) and a
 *    click is routed to the native open_url action only for repository URLs.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED_UI = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'ui');
const CHANGELOG = path.join(SHARED_UI, 'changelog');

// Scripts the recording sandbox replaces with stubs: they talk to the native
// host or fetch locale files, neither of which this test exercises.
const STUBBED_SCRIPTS = new Set(['host_bridge.js', 'i18n.js']);

const failures = [];

function expect(condition, message) {
	if (!condition) failures.push(message);
}

// ==========================================
// ==========================================
// ======= 1/ Recording DOM ================
// ==========================================
// ==========================================

class FakeNode {
	constructor(tagName, nodeType) {
		this.tagName = tagName;
		this.nodeType = nodeType;
		this.children = [];
		this.attributes = {};
		this.listeners = {};
		this.style = {};
		this.className = '';
		this.id = '';
		this._text = '';
		const node = this;
		this.classList = {
			toggle(name, force) {
				const set = new Set(node.className.split(/\s+/).filter(Boolean));
				if (force === undefined ? !set.has(name) : force) set.add(name);
				else set.delete(name);
				node.className = Array.from(set).join(' ');
			},
			add(name) {
				this.toggle(name, true);
			}
		};
	}

	get textContent() {
		if (this.nodeType === 3) return this._text;
		return this.children.map((child) => child.textContent).join('');
	}

	set textContent(value) {
		if (this.nodeType === 3) {
			this._text = String(value);
			return;
		}
		this.children = [];
		if (value !== '') this.children.push(makeText(String(value)));
	}

	set innerHTML(_value) {
		throw new Error('innerHTML is forbidden for remote release notes');
	}

	set outerHTML(_value) {
		throw new Error('outerHTML is forbidden for remote release notes');
	}

	insertAdjacentHTML() {
		throw new Error('insertAdjacentHTML is forbidden for remote release notes');
	}

	appendChild(child) {
		this.children.push(child);
		return child;
	}

	replaceChildren(...children) {
		this.children = children;
	}

	setAttribute(name, value) {
		this.attributes[name] = String(value);
	}

	getAttribute(name) {
		return Object.prototype.hasOwnProperty.call(this.attributes, name)
			? this.attributes[name]
			: null;
	}

	addEventListener(type, handler) {
		(this.listeners[type] = this.listeners[type] || []).push(handler);
	}

	dispatch(type, event) {
		(this.listeners[type] || []).forEach((handler) => handler(event));
	}
}

function makeText(value) {
	const node = new FakeNode('#text', 3);
	node._text = value;
	return node;
}

/** Depth-first list of every element below (and including) a node. */
function elements(node, acc = []) {
	if (node.nodeType === 1) acc.push(node);
	node.children.forEach((child) => elements(child, acc));
	return acc;
}

function byTag(root, tag) {
	return elements(root).filter((node) => node.tagName === tag);
}

// ==========================================
// ==========================================
// ======= 2/ Page Execution ================
// ==========================================
// ==========================================

/** Returns the local scripts index.html loads, in document order. */
function pageScripts() {
	const html = fs.readFileSync(path.join(CHANGELOG, 'index.html'), 'utf8');
	const scripts = [];
	const pattern = /<script\s+src="([^"]+)"/g;
	let match;
	while ((match = pattern.exec(html)) !== null) scripts.push(match[1]);
	if (scripts.length === 0) throw new Error('index.html loads no scripts; the scan is broken');
	return scripts;
}

function runPage() {
	const byId = new Map();
	const posted = [];
	const document = {
		readyState: 'complete',
		getElementById(id) {
			if (!byId.has(id)) {
				const node = new FakeNode('div', 1);
				node.id = id;
				byId.set(id, node);
			}
			return byId.get(id);
		},
		querySelectorAll: () => [],
		createElement: (tag) => new FakeNode(String(tag).toLowerCase(), 1),
		createTextNode: (value) => makeText(String(value)),
		addEventListener() {}
	};
	const sandbox = {
		console,
		URL,
		Date,
		document,
		makeHostBridge: (name) => (payload) => posted.push({ name, payload }),
		decodeHostBridgeResponse: (_isBase64, payload) => JSON.parse(payload),
		setTimeout: () => 1,
		clearTimeout() {}
	};
	sandbox.window = sandbox;
	vm.createContext(sandbox);
	for (const src of pageScripts()) {
		const file = path.resolve(CHANGELOG, src);
		if (STUBBED_SCRIPTS.has(path.basename(file))) continue;
		expect(file.startsWith(SHARED_UI + path.sep), `page script ${src} escapes the shared UI root`);
		vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: src });
	}
	return { sandbox, document, posted };
}

// ==========================================
// ==========================================
// ======= 3/ Hostile Release Body =========
// ==========================================
// ==========================================

const REPO_PR = 'https://github.com/adrienm7/ergopti/pull/42';
const BODY = [
	'## What changed',
	'',
	'Some **bold claim** and *emphasis* with `inline <b>code</b>` and snake_case_name.',
	'<script>window.pwned = 1</script>',
	'<img src=x onerror="window.pwned = 2">',
	'',
	'- First item with [the PR](' + REPO_PR + ')',
	'- Second item [evil](javascript:alert(1)) and [elsewhere](https://evil.example/x)',
	'  - Nested item',
	'',
	'1. Ordered one',
	'2. Ordered two',
	'',
	'> Quoted **note**',
	'',
	'```',
	'<script>alert(3)</script>',
	'```',
	'',
	'| Col A | Col B |',
	'| ----- | ----- |',
	'| a1 | **b1** |',
	'',
	'---',
	'<!-- hidden maintainer note -->',
	'Full Changelog: https://github.com/adrienm7/ergopti/compare/v1.0.0...v1.1.0'
].join('\r\n');

function checkRendering() {
	const { sandbox, document, posted } = runPage();
	sandbox.injectReleases(
		[
			{
				tag_name: 'v1.1.0',
				body: BODY,
				html_url: 'https://github.com/adrienm7/ergopti/releases/tag/v1.1.0',
				published_at: '2026-09-01T12:00:00Z',
				prerelease: false
			}
		],
		'main'
	);
	const body = document.getElementById('release-body');
	const all = elements(body);
	const text = body.textContent;

	expect(
		byTag(body, 'pre').every((pre) => pre.className !== 'release-notes-plain'),
		'release notes must no longer be dumped as one raw preformatted block'
	);
	expect(
		byTag(body, 'h2').some((h) => h.textContent === 'What changed'),
		'an ATX heading must render as an h2 element without its # marker'
	);
	expect(!text.includes('## What changed'), 'heading markers must not leak into the text');
	expect(
		byTag(body, 'strong').some((s) => s.textContent === 'bold claim'),
		'**bold** must render as a strong element'
	);
	expect(
		byTag(body, 'em').some((s) => s.textContent === 'emphasis'),
		'*emphasis* must render as an em element'
	);
	expect(text.includes('snake_case_name'), 'intra-word underscores must stay literal');
	expect(
		byTag(body, 'code').some((c) => c.textContent === 'inline <b>code</b>'),
		'inline code must render as a code element whose HTML stays literal text'
	);

	const lists = byTag(body, 'ul');
	expect(lists.length >= 2, 'a nested bullet list must render as nested ul elements');
	expect(
		byTag(body, 'li').some((li) => li.textContent === 'Nested item'),
		'the nested list item must be its own li'
	);
	expect(
		byTag(body, 'ol').length === 1 && byTag(byTag(body, 'ol')[0], 'li').length === 2,
		'an ordered list must render as one ol with two items'
	);
	expect(
		byTag(body, 'blockquote').some((q) => byTag(q, 'strong').length === 1),
		'a blockquote must render its own inline Markdown'
	);
	expect(
		byTag(body, 'pre').some((pre) => pre.textContent.includes('<script>alert(3)</script>')),
		'a fenced block must keep its content as literal code text'
	);
	expect(
		byTag(body, 'table').length === 1 &&
			byTag(body, 'th').length === 2 &&
			byTag(body, 'td').some((td) => byTag(td, 'strong').length === 1),
		'a GFM table must render as a table with a header row and inline cells'
	);
	expect(byTag(body, 'hr').length === 1, 'a thematic break must render as an hr element');
	expect(!text.includes('hidden maintainer note'), 'HTML comments stay invisible, as on GitHub');

	// The HTML payload is text, never markup.
	expect(
		all.every((node) => !['script', 'img', 'iframe', 'object'].includes(node.tagName)),
		'raw HTML in a release body must never create active elements'
	);
	expect(
		text.includes('<script>window.pwned = 1</script>'),
		'raw HTML must remain visible as literal, inert text'
	);
	expect(sandbox.pwned === undefined, 'no payload may execute');
	expect(
		all.every((node) => Object.keys(node.attributes).every((name) => !/^on/i.test(name))),
		'no rendered element may carry an event-handler attribute'
	);

	// Links: no href anywhere, only repository URLs become actionable.
	const anchors = byTag(body, 'a');
	expect(
		anchors.every((a) => a.getAttribute('href') === null),
		'rendered links must not carry an href the WebView could navigate to'
	);
	const prLink = anchors.find((a) => a.textContent === 'the PR');
	expect(Boolean(prLink), 'a repository link must render as an anchor');
	expect(
		!anchors.some((a) => a.textContent === 'evil' || a.textContent === 'elsewhere'),
		'javascript: and non-repository URLs must not become clickable links'
	);
	expect(
		text.includes('evil') && text.includes('elsewhere'),
		'a refused link keeps its label as plain text'
	);
	expect(
		anchors.some(
			(a) =>
				a.getAttribute('data-url') === 'https://github.com/adrienm7/ergopti/compare/v1.0.0...v1.1.0'
		),
		'a bare repository URL must autolink'
	);
	if (prLink) {
		let prevented = false;
		const before = posted.length;
		prLink.dispatch('click', {
			preventDefault() {
				prevented = true;
			}
		});
		const message = posted[posted.length - 1];
		expect(
			prevented &&
				posted.length === before + 1 &&
				message.payload.action === 'open_url' &&
				message.payload.url === REPO_PR,
			'clicking a repository link must post the native open_url action and never navigate'
		);
	}
}

try {
	checkRendering();
} catch (error) {
	expect(false, `the changelog Markdown rendering raised: ${error.message}`);
}

console.log(`1..${failures.length === 0 ? 1 : failures.length}`);
if (failures.length === 0) {
	console.log('ok 1 - changelog release notes render as inert, sanitized Markdown');
	process.exit(0);
}
failures.forEach((message, index) => console.log(`not ok ${index + 1} - ${message}`));
process.exit(1);
