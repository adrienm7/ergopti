// tools/test/test-site-image-alternatives.cjs

/**
 * ==============================================================================
 * MODULE: Site Image Alternatives Gate
 * DESCRIPTION:
 * Every image of the site has the right text alternative (WCAG 1.1.1,
 * maintainer request of 2026-11-19). axe checks the pages it opens; this gate
 * reads every Svelte file, so a page, a block or a state axe never renders is
 * held too.
 *
 * WHAT IS CHECKED, in every Svelte file under src/:
 * 1. Each <img> and <enhanced:img> has an alt attribute: a description, or
 *    alt="" for a decoration. An image hidden with aria-hidden="true" has
 *    alt="", so the two ways of hiding agree.
 * 2. Each inline <svg> is either hidden (aria-hidden="true": a decoration, or
 *    an icon beside its text label) or an image with a name (role="img" with
 *    aria-label, aria-labelledby or a <title> child).
 * 3. Each icon-font glyph (<i class="icon-…">) is hidden (aria-hidden="true")
 *    or an image with a name (role="img" and aria-label): its private-use
 *    character means nothing to a screen reader.
 * 4. Each <input type="image"> and <area> has an alt.
 * 5. The checker refuses each failure on a sample and accepts the right
 *    markup, so it cannot pass vacuously.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const markup = require('./lib/svelte-markup.cjs');

/** Whether aria-hidden is statically "true". */
function hidden(element) {
	return markup.staticValue(element, 'aria-hidden') === 'true';
}

/** Whether the element has a non-empty accessible name of its own (static or computed). */
function named(element) {
	for (const name of ['aria-label', 'aria-labelledby']) {
		if (!markup.hasAttribute(element, name)) continue;
		const value = markup.staticValue(element, name);
		if (value === null || value.trim()) return true;
	}
	return false;
}

function hasTitleChild(element) {
	return element.children.some(
		(child) => child.type === 'RegularElement' && child.name === 'title'
	);
}

/** The image problems of one source file. */
function imageProblems(source, file) {
	const problems = [];
	for (const element of markup.elementsOf(source, file)) {
		const where = `${file}:${element.line} <${element.name}>`;
		// Elements inside a hidden svg or an aria-hidden ancestor are judged by that ancestor.
		if (element.ancestors.includes('svg')) continue;
		if (element.name === 'img' || element.name === 'enhanced:img') {
			if (!markup.hasAttribute(element, 'alt'))
				problems.push(`${where} has no alt: describe it, or alt="" for a decoration`);
			else if (hidden(element) && markup.staticValue(element, 'alt') !== '')
				problems.push(`${where} is aria-hidden but has a non-empty alt`);
		} else if (element.name === 'svg') {
			const role = markup.staticValue(element, 'role');
			if (hidden(element)) continue;
			if (role === 'img' && (named(element) || hasTitleChild(element))) continue;
			problems.push(
				`${where} is neither aria-hidden="true" nor role="img" with a name or a <title>`
			);
		} else if (
			element.name === 'i' &&
			markup.staticClasses(element).some((c) => c.startsWith('icon-'))
		) {
			if (hidden(element)) continue;
			if (markup.staticValue(element, 'role') === 'img' && named(element)) continue;
			problems.push(
				`${where} icon glyph is neither aria-hidden="true" nor role="img" with aria-label`
			);
		} else if (
			(element.name === 'input' && markup.staticValue(element, 'type') === 'image') ||
			element.name === 'area'
		) {
			if (!markup.hasAttribute(element, 'alt')) problems.push(`${where} has no alt`);
		}
	}
	return problems;
}

/** The checker refuses each failure it exists for and accepts the right markup. */
function checkTheChecker() {
	const of = (body) => imageProblems(body, 'sample.svelte');
	assert.match(of('<img src="a.png">')[0], /no alt/);
	assert.match(of('<enhanced:img src="./a.png" />')[0], /no alt/);
	assert.match(of('<img src="a.png" alt="Logo" aria-hidden="true">')[0], /non-empty alt/);
	assert.match(of('<svg viewBox="0 0 1 1"><path d="M0 0" /></svg>')[0], /neither/);
	assert.match(of('<svg role="img"><path d="M0 0" /></svg>')[0], /neither/);
	assert.match(of('<i class="icon-github"></i>')[0], /icon glyph/);
	assert.match(of('<input type="image" src="go.png">')[0], /no alt/);
	assert.deepEqual(
		of(
			[
				'<img src="a.png" alt="">',
				'<img src="b.png" alt={description}>',
				'<svg aria-hidden="true"><path d="M0 0" /></svg>',
				'<svg role="img" aria-label="Graphique"><path d="M0 0" /></svg>',
				'<svg role="img"><title>Graphique</title><path d="M0 0" /></svg>',
				'<i class="icon-github" aria-hidden="true"></i>',
				'<i class="icon-x" role="img" aria-label="Fermer"></i>',
				'{#if a}<i class="glow">+</i>{/if}'
			].join('\n')
		),
		[]
	);
}

function main() {
	checkTheChecker();
	const problems = [];
	let files = 0;
	for (const file of markup.svelteFiles()) {
		files++;
		problems.push(...imageProblems(fs.readFileSync(path.join(markup.ROOT, file), 'utf8'), file));
	}
	if (problems.length) {
		for (const problem of problems) console.error('  ' + problem);
		throw new Error(problems.length + ' image(s) without the right text alternative');
	}
	console.log(`Site image alternatives: ${files} Svelte files, every img, svg and icon glyph`);
}

if (require.main === module) main();

module.exports = { imageProblems };
