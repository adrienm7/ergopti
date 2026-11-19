// tools/test/lib/heading-landmarks.cjs

/**
 * ==============================================================================
 * MODULE: Heading Order and Landmarks
 * DESCRIPTION:
 * Judges a page's outline as a screen reader user moves through it (WCAG
 * 1.3.1 info and relationships, 2.4.1 bypass blocks, 2.4.6 headings and
 * labels): one h1, no skipped heading level, one main landmark, and every
 * navigation, region, complementary, search or form landmark named, two of
 * one kind never under the same name. collectOutline runs in the page and
 * reads what assistive technology is given (hidden and unrendered parts left
 * out); outlineProblems is pure, so tools/test/test-heading-landmarks.cjs
 * proves without a browser that each failure is caught. The Studio walk
 * (studio-keyboard.playwright.cjs) and the app windows' scan
 * (app-windows-accessibility.playwright.cjs) feed it their pages.
 * ==============================================================================
 */

'use strict';

/**
 * One heading or landmark, as the page reports it.
 * @typedef {object} Outline
 * @property {{level: number, text: string}[]} headings - In document order.
 * @property {{role: string, name: string, id: string}[]} landmarks - In document order.
 */

// The landmarks a reader lists by name; banner, contentinfo and main are one of a kind.
const NAMED_ROLES = Object.freeze(['navigation', 'region', 'complementary', 'search', 'form']);

/**
 * Reads the page's headings and landmarks. Runs in the page (page.evaluate),
 * so it uses nothing from this module's scope.
 * @returns {Outline}
 */
function collectOutline() {
	const exposed = (node) =>
		!node.closest('[hidden], [aria-hidden="true"], [inert]') &&
		node.checkVisibility({ visibilityProperty: true });
	const textOf = (node) => (node ? node.textContent.replace(/\s+/g, ' ').trim() : '');
	const nameOf = (node) => {
		const ids = (node.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean);
		const labelled = ids
			.map((id) => textOf(document.getElementById(id)))
			.join(' ')
			.trim();
		if (labelled) return labelled;
		const label = (node.getAttribute('aria-label') || '').trim();
		return label || (node.getAttribute('title') || '').trim();
	};
	const describe = (node) =>
		node.tagName.toLowerCase() +
		(node.id ? '#' + node.id : '') +
		(node.classList.length ? '.' + node.classList[0] : '');
	// A header or footer is a page landmark only outside sectioning content.
	const sectioned = (node) =>
		Boolean(node.parentElement.closest('article, aside, main, nav, section'));
	const IMPLICIT = {
		MAIN: () => 'main',
		NAV: () => 'navigation',
		ASIDE: () => 'complementary',
		SEARCH: () => 'search',
		HEADER: (node) => (sectioned(node) ? '' : 'banner'),
		FOOTER: (node) => (sectioned(node) ? '' : 'contentinfo'),
		SECTION: (node) => (nameOf(node) ? 'region' : ''),
		FORM: (node) => (nameOf(node) ? 'form' : '')
	};
	const LANDMARKS = new Set([
		'main',
		'navigation',
		'complementary',
		'search',
		'banner',
		'contentinfo',
		'region',
		'form'
	]);
	const headings = [];
	for (const node of document.querySelectorAll('h1, h2, h3, h4, h5, h6, [role="heading"]')) {
		if (!exposed(node)) continue;
		const role = (node.getAttribute('role') || '').trim();
		if (role && role !== 'heading') continue;
		const aria = Number(node.getAttribute('aria-level'));
		const tag = /^H([1-6])$/.exec(node.tagName);
		const level = aria >= 1 ? aria : tag ? Number(tag[1]) : 2;
		headings.push({ level, text: textOf(node).slice(0, 60) || describe(node) });
	}
	const landmarks = [];
	for (const node of document.body.querySelectorAll('*')) {
		const explicit = (node.getAttribute('role') || '').trim().split(/\s+/)[0];
		const role = explicit || (IMPLICIT[node.tagName] ? IMPLICIT[node.tagName](node) : '');
		if (!LANDMARKS.has(role) || !exposed(node)) continue;
		landmarks.push({ role, name: nameOf(node), id: describe(node) });
	}
	return { headings, landmarks };
}

/**
 * The problems of an outline, in words a failing assertion can print.
 * @param {Outline} outline
 * @returns {string[]} Empty when the outline passes.
 */
function outlineProblems(outline) {
	const problems = [];
	const { headings, landmarks } = outline;
	const firsts = headings.filter((heading) => heading.level === 1);
	if (firsts.length === 0) problems.push('no h1');
	if (firsts.length > 1)
		problems.push(`${firsts.length} h1: ${firsts.map((heading) => heading.text).join(' | ')}`);
	let previous = 0;
	for (const heading of headings) {
		if (heading.level > previous + 1)
			problems.push(
				previous === 0
					? `the first heading is h${heading.level} (${heading.text})`
					: `h${previous} then h${heading.level} skips a level (${heading.text})`
			);
		previous = heading.level;
	}
	const mains = landmarks.filter((landmark) => landmark.role === 'main');
	if (mains.length !== 1) problems.push(`${mains.length} main landmarks`);
	const seen = new Map();
	for (const landmark of landmarks) {
		if (!NAMED_ROLES.includes(landmark.role)) continue;
		if (!landmark.name) {
			problems.push(`${landmark.role} landmark ${landmark.id} has no name`);
			continue;
		}
		const key = `${landmark.role}\u0000${landmark.name}`;
		if (seen.has(key))
			problems.push(
				`two ${landmark.role} landmarks are named « ${landmark.name} » (${seen.get(key)}, ${landmark.id})`
			);
		else seen.set(key, landmark.id);
	}
	return problems;
}

module.exports = { collectOutline, outlineProblems, NAMED_ROLES };
