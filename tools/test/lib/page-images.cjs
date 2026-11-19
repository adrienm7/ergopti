// tools/test/lib/page-images.cjs

/**
 * ==============================================================================
 * MODULE: Page Images
 * DESCRIPTION:
 * Every image a rendered page shows is either hidden as decoration or named
 * as an image (WCAG 1.1.1; maintainer request of 2026-11-19: decorative icons
 * aria-hidden, meaningful SVGs role="img" with a name). The site's gate reads
 * its Svelte sources (test-site-image-alternatives.cjs); the Studio builds
 * most of its icons and charts in script, so its walk reads the DOM instead:
 * collectImages runs in the page, imageProblems is pure and
 * tools/test/test-page-images.cjs proves it refuses each failure.
 * studio-keyboard.playwright.cjs feeds it every Studio page and tab.
 * ==============================================================================
 */

'use strict';

/**
 * One image of the page.
 * @typedef {object} Picture
 * @property {string} id
 * @property {string} tag - 'img', 'svg', or the tag of an element with role img.
 * @property {boolean} hidden - Out of the accessibility tree (aria-hidden on it or above, or not rendered).
 * @property {boolean} hasAlt - An img's alt attribute is present (empty means decorative).
 * @property {string} role
 * @property {string} name - Its accessible name as far as markup tells: aria-label, aria-labelledby text, title.
 * @property {boolean} insideNamedImage - It lies inside an element with role img that is named.
 */

/**
 * In-page: every img, svg and role="img" element of the page.
 * @returns {Picture[]}
 */
function collectImages() {
	const found = [];
	const places = new Map(Array.from(document.querySelectorAll('*')).map((node, at) => [node, at]));
	const nodes = Array.from(document.querySelectorAll('img, svg, [role="img"]'));
	for (const node of nodes) {
		// An svg inside an svg is part of its drawing.
		if (
			node.tagName.toLowerCase() === 'svg' &&
			node.parentElement &&
			node.parentElement.closest('svg')
		)
			continue;
		const hidden =
			Boolean(node.closest('[aria-hidden="true"]')) ||
			!node.checkVisibility({ contentVisibilityAuto: true, visibilityProperty: true });
		const labelled = (node.getAttribute('aria-labelledby') || '')
			.split(/\s+/)
			.filter(Boolean)
			.map((id) => (document.getElementById(id) || {}).textContent || '')
			.join(' ');
		const title = node.querySelector(':scope > title');
		const name = (
			node.getAttribute('aria-label') ||
			labelled ||
			(title ? title.textContent : '') ||
			node.getAttribute('title') ||
			''
		).trim();
		const outer = node.parentElement && node.parentElement.closest('[role="img"]');
		const hook = node.id ? '#' + node.id : node.classList[0] ? '.' + node.classList[0] : '';
		found.push({
			id: `${node.tagName.toLowerCase()}${hook}@${places.get(node)}`,
			tag: node.tagName.toLowerCase(),
			hidden,
			hasAlt: node.hasAttribute('alt'),
			role: (node.getAttribute('role') || '').toLowerCase(),
			name,
			insideNamedImage: Boolean(
				outer && (outer.getAttribute('aria-label') || outer.getAttribute('aria-labelledby'))
			)
		});
	}
	return found;
}

/**
 * The problems of a page's images: an img without alt, a shown svg that is
 * neither aria-hidden nor a named image, an element with role img and no name.
 * @param {Picture[]} pictures
 * @returns {string[]}
 */
function imageProblems(pictures) {
	const problems = [];
	for (const picture of pictures) {
		if (picture.tag === 'img' && !picture.hasAlt)
			problems.push(`${picture.id}: an img without alt`);
		if (picture.hidden || picture.insideNamedImage) continue;
		if (picture.role === 'img' && !picture.name)
			problems.push(`${picture.id}: an image (role img) without a name`);
		else if (picture.tag === 'svg' && picture.role !== 'img')
			problems.push(
				`${picture.id}: an svg neither hidden as decoration (aria-hidden) nor named (role img and a name)`
			);
	}
	return problems;
}

module.exports = { collectImages, imageProblems };
