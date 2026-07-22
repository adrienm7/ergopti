// src/routes/ergopti-plus/countup.js

/**
 * ==============================================================================
 * MODULE: Ergopti+ Page — Count-Up Action
 * DESCRIPTION:
 * Svelte action that animates a headline number from 0 to its value the first
 * time it scrolls into view — the same keynote effect as the KPI strip, made
 * reusable for the big inline numbers (hotstring total, gesture slots, model
 * count…). The node is prerendered with its final text, so without JS (or with
 * reduced motion) the correct number is simply already there.
 *
 * FEATURES & RATIONALE:
 * 1. One shared IntersectionObserver for every counted number on the page.
 * 2. Reactive: when the bound value changes after reveal (e.g. the action
 *    count re-filtered by the OS toggle), the number quickly re-counts from
 *    its previous value instead of snapping.
 * ==============================================================================
 */

/** Duration of the first count-up when the number enters the viewport. */
const FIRST_RUN_MS = 1300;

/** Duration of the quick re-count when an already-visible value changes. */
const UPDATE_MS = 450;

/** Fraction of the element that must be visible before counting starts. */
const COUNT_THRESHOLD = 0.6;

/** @type {IntersectionObserver | null} */
let observer = null;

/** @type {WeakMap<Element, {value: number, revealed: boolean, active: boolean}>} */
const states = new WeakMap();

/**
 * Format a value like every other counter on the page (fr-FR thousands).
 * @param {number} n
 * @returns {string}
 */
function fmt(n) {
	return Math.round(n).toLocaleString('fr-FR');
}

/**
 * Ease-out count animation on a node's text content.
 * @param {HTMLElement} node
 * @param {{active: boolean}} st Liveness guard — stops after destroy.
 * @param {number} from
 * @param {number} to
 * @param {number} duration
 */
function animate(node, st, from, to, duration) {
	const start = performance.now();
	/** @param {number} now */
	function tick(now) {
		if (!st.active) return;
		const t = Math.min(1, (now - start) / duration);
		const eased = 1 - Math.pow(1 - t, 3);
		node.textContent = fmt(from + (to - from) * eased);
		if (t < 1) requestAnimationFrame(tick);
	}
	requestAnimationFrame(tick);
}

/**
 * Lazily create the shared observer (client only).
 * @returns {IntersectionObserver}
 */
function getObserver() {
	if (!observer) {
		observer = new IntersectionObserver(
			(entries) => {
				for (const entry of entries) {
					if (!entry.isIntersecting) continue;
					const st = states.get(entry.target);
					if (!st || st.revealed) continue;
					st.revealed = true;
					observer?.unobserve(entry.target);
					animate(/** @type {HTMLElement} */ (entry.target), st, 0, st.value, FIRST_RUN_MS);
				}
			},
			{ threshold: COUNT_THRESHOLD }
		);
	}
	return observer;
}

/**
 * Svelte action — counts the node's number up from 0 on first sight.
 * Usage: `<span use:countup={total}>{fmt(total)}</span>`.
 * @param {HTMLElement} node
 * @param {number} value
 * @returns {{update: (next: number) => void, destroy: () => void}}
 */
export function countup(node, value) {
	const reduced =
		typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion: reduce)').matches;
	const st = { value: Number(value) || 0, revealed: false, active: true };
	states.set(node, st);
	if (reduced) {
		// No animation: keep (or set) the final value and never observe.
		st.revealed = true;
		node.textContent = fmt(st.value);
	} else {
		getObserver().observe(node);
	}

	return {
		update(next) {
			const v = Number(next) || 0;
			const prev = st.value;
			st.value = v;
			if (!st.revealed) return;
			if (reduced || prev === v) {
				node.textContent = fmt(v);
				return;
			}
			animate(node, st, prev, v, UPDATE_MS);
		},
		destroy() {
			st.active = false;
			observer?.unobserve(node);
		}
	};
}
