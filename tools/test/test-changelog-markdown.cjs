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
 * 1. Real page chain: tools/test/support/changelog-page-dom.cjs reads the
 *    scripts from index.html, so a renderer that is written but never loaded by
 *    the document fails here.
 * 2. No HTML parser: the recording DOM throws on innerHTML/outerHTML and
 *    insertAdjacentHTML, so remote text can only reach the page as text nodes.
 * 3. Safe links: anchors carry no href (the WebView never navigates) and a
 *    click is routed to the native open_url action only for repository URLs.
 * 4. Folds: CI wraps the changelog in <details>/<summary> for github.com, which
 *    the renderer showed as literal tags. Exact fold lines must build
 *    attribute-free elements while an attribute, a script or a fenced fold
 *    stays text, and a </details> quoted in code inside a fold stays code.
 * ==============================================================================
 */

'use strict';

const { byTag, elements, runPage, textOutside } = require('./support/changelog-page-dom.cjs');

const failures = [];

function expect(condition, message) {
	if (!condition) failures.push(message);
}

// ==========================================
// ==========================================
// ======= 1/ Hostile Release Body =========
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

// ==========================================
// ==========================================
// ======= 2/ Details Folds ================
// ==========================================
// ==========================================

// CI folds the changelog in <details>/<summary> for github.com. Exact structural
// lines must become real folds; any other tag, attribute or script stays text.
const FOLD_BODY = [
	'Intro line',
	'<details>',
	'<summary><b>Changelog</b> (click to expand)</summary>',
	'',
	'- Folded **item**',
	'',
	'</details>',
	'',
	'<details open>',
	'<summary>Open fold</summary>',
	'Inside the open fold.',
	'<details>',
	'<summary>Nested</summary>',
	'Nested body.',
	'</details>',
	'</details>',
	'',
	'<details ontoggle="window.pwned=3">',
	'<summary onclick="window.pwned=4">Hostile</summary>',
	'</details>',
	'',
	'<details>',
	'<summary>Scripted</summary>',
	'<script>window.pwned = 5</script>',
	'</details>',
	'',
	'<details>',
	'<summary class="x">Classy</summary>',
	'</details>',
	'',
	'```',
	'<details>',
	'<summary>Fenced</summary>',
	'</details>',
	'```',
	'',
	'<a id="downloads-v1-1-0"></a>',
	'Outro line'
].join('\n');

function checkDetailsFolds() {
	const { sandbox, document } = runPage();
	const root = document.createElement('div');
	sandbox.renderMarkdownInto(root, FOLD_BODY, {});
	const folds = byTag(root, 'details');
	const text = root.textContent;

	expect(folds.length === 5, `exact <details> lines must build 5 folds (got ${folds.length})`);
	if (folds.length !== 5) return;
	const [changelog, openFold, nested, scripted, classy] = folds;

	expect(
		Object.keys(changelog.attributes).length === 0,
		'a plain <details> line must build a fold with zero attributes'
	);
	const summary = changelog.children[0];
	expect(
		Boolean(summary) &&
			summary.tagName === 'summary' &&
			Object.keys(summary.attributes).length === 0 &&
			summary.textContent === 'Changelog (click to expand)' &&
			byTag(summary, 'strong').some((s) => s.textContent === 'Changelog'),
		'the <summary> line must become the first child, with <b> rendered as strong'
	);
	expect(
		byTag(changelog, 'li').some((li) => byTag(li, 'strong').some((s) => s.textContent === 'item')),
		'the Markdown inside a fold must render as Markdown'
	);
	expect(
		JSON.stringify(openFold.attributes) === '{"open":""}',
		'<details open> must build an expanded fold and copy nothing else'
	);
	expect(
		byTag(openFold, 'details').includes(nested) && nested.children[0].textContent === 'Nested',
		'a nested fold must close on its own </details>, not on the outer one'
	);
	expect(
		scripted.textContent.includes('<script>window.pwned = 5</script>'),
		'a <script> inside a fold must stay literal text'
	);
	expect(
		byTag(classy, 'summary').length === 0 &&
			classy.textContent === '<summary class="x">Classy</summary>',
		'a <summary> line carrying attributes must stay literal text inside a fold'
	);
	expect(
		text.includes('<details ontoggle="window.pwned=3">') &&
			text.includes('<summary onclick="window.pwned=4">Hostile</summary>'),
		'a <details> or <summary> line carrying attributes must stay literal text'
	);
	expect(
		byTag(root, 'pre').some((pre) =>
			pre.textContent.includes('<details>\n<summary>Fenced</summary>\n</details>')
		),
		'a fold inside a fenced code block must stay code'
	);
	const prose = textOutside(root, 'pre');
	expect(
		!prose.includes('<summary><b>') && !prose.includes('</details>') && !prose.includes('<details>\n'),
		'structural fold lines must not leak as text outside code'
	);
	expect(
		!text.includes('<a id=') && text.includes('Intro line') && text.includes('Outro line'),
		'an empty anchor line is invisible, as on GitHub, and its neighbours survive'
	);
	const all = elements(root);
	expect(
		all.every((node) => !['script', 'img', 'iframe', 'object'].includes(node.tagName)),
		'folds must never create active elements'
	);
	expect(
		all.every((node) => Object.keys(node.attributes).every((name) => !/^on/i.test(name))),
		'no fold may carry an event-handler attribute'
	);
	expect(sandbox.pwned === undefined, 'no fold payload may execute');
}

// A fence inside a fold is code: a </details> line quoted there must not close
// the fold, or the rest of the fold would spill out of it.
const FENCED_FOLD_BODY = [
	'<details>',
	'<summary>Quoted HTML</summary>',
	'',
	'```html',
	'</details>',
	'```',
	'',
	'After the fence.',
	'</details>',
	'',
	'Outside the fold.'
].join('\n');

function checkFenceInsideFold() {
	const { sandbox, document } = runPage();
	const root = document.createElement('div');
	sandbox.renderMarkdownInto(root, FENCED_FOLD_BODY, {});
	const folds = byTag(root, 'details');
	expect(folds.length === 1, `a fold quoting </details> in code must stay one fold (got ${folds.length})`);
	if (folds.length !== 1) return;
	const fold = folds[0];
	expect(
		byTag(fold, 'pre').some((pre) => pre.textContent === '</details>'),
		'a </details> line quoted in a fenced block inside a fold must stay code in that fold'
	);
	expect(
		fold.textContent.includes('After the fence.') && !fold.textContent.includes('Outside the fold.'),
		'the fold must close on its own </details>, after the fenced code'
	);
	expect(
		textOutside(root, 'details').includes('Outside the fold.'),
		'the text after the fold must render outside it'
	);
}

try {
	checkRendering();
} catch (error) {
	expect(false, `the changelog Markdown rendering raised: ${error.message}`);
}

try {
	checkDetailsFolds();
} catch (error) {
	expect(false, `the changelog fold rendering raised: ${error.message}`);
}

try {
	checkFenceInsideFold();
} catch (error) {
	expect(false, `the fenced fold rendering raised: ${error.message}`);
}

console.log(`1..${failures.length === 0 ? 1 : failures.length}`);
if (failures.length === 0) {
	console.log('ok 1 - changelog release notes render as inert, sanitized Markdown');
	process.exit(0);
}
failures.forEach((message, index) => console.log(`not ok ${index + 1} - ${message}`));
process.exit(1);
