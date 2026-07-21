// src/routes/ergopti-plus/reveal.js

/**
 * ==============================================================================
 * MODULE: Ergopti+ Page — Scroll Reveal Action
 * DESCRIPTION:
 * Minimal IntersectionObserver-based reveal for the marketing page. The
 * layout stamps AOS (mirror mode) on every h2/h3 site-wide, which fights a
 * calm Apple/Linear-style presentation — the page neutralizes AOS in CSS and
 * uses this action instead: reveal once, subtle rise, optional stagger.
 *
 * FEATURES & RATIONALE:
 * 1. One Shared Observer: dozens of revealed nodes reuse a single
 *    IntersectionObserver instead of one observer per node.
 * 2. Reveal Once: elements stay visible once shown (no mirror flicker).
 * ==============================================================================
 */

/** Fraction of the element that must be visible before it reveals. */
const REVEAL_THRESHOLD = 0.15;

/** Pre-trigger margin so elements start animating slightly before entering. */
const REVEAL_ROOT_MARGIN = '0px 0px -40px 0px';

/** @type {IntersectionObserver | null} */
let observer = null;

/**
 * Lazily create the shared observer (client only).
 * @returns {IntersectionObserver}
 */
function getObserver() {
	if (!observer) {
		observer = new IntersectionObserver(
			(entries) => {
				for (const entry of entries) {
					if (entry.isIntersecting) {
						entry.target.classList.add('is-visible');
						observer?.unobserve(entry.target);
					}
				}
			},
			{ threshold: REVEAL_THRESHOLD, rootMargin: REVEAL_ROOT_MARGIN }
		);
	}
	return observer;
}

/**
 * Svelte action — adds the .reveal class, then .is-visible when the element
 * scrolls into view. Pass a delay in ms to stagger grids.
 * @param {HTMLElement} node
 * @param {{delay?: number} | undefined} params
 * @returns {{destroy: () => void}}
 */
export function reveal(node, params = {}) {
	node.classList.add('reveal');
	if (params.delay) node.style.setProperty('--reveal-delay', `${params.delay}ms`);
	getObserver().observe(node);

	return {
		destroy() {
			observer?.unobserve(node);
		}
	};
}
