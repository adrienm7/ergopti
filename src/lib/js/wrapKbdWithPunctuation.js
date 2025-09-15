// wrapKbdWithPunctuation.js

/**
 * Finds all <kbd>, <kbd-output> and <kbd-non> elements
 * and wraps the element + surrounding punctuation/parentheses
 * into a <span class="nowrap">.
 */
export function wrapKbdWithPunctuation(root = document) {
	const selector = 'kbd, kbd-output, kbd-non';

	function wrap(el, extraBefore = null, extraAfter = null) {
		const span = document.createElement('span');
		span.className = 'nowrap';
		el.parentNode.insertBefore(span, el);

		if (extraBefore) span.appendChild(extraBefore);
		span.appendChild(el);
		if (extraAfter) span.appendChild(extraAfter);
	}

	function wrapIfNeeded(el) {
		if (!el || !el.parentNode) return;
		if (el.parentNode.classList?.contains('nowrap')) return;

		const prev = el.previousSibling;
		const next = el.nextSibling;

		// check previous sibling for "("
		if (prev && prev.nodeType === Node.TEXT_NODE) {
			const m = prev.nodeValue.match(/(\(\s*)$/);
			if (m) {
				const prefix = m[1];
				const beforeNode = document.createTextNode(prefix);
				wrap(el, beforeNode, null);
				prev.nodeValue = prev.nodeValue.slice(0, -prefix.length);
				if (!prev.nodeValue.length) prev.remove();
				return;
			}
		}

		// check next sibling for punctuation or ")"
		if (next && next.nodeType === Node.TEXT_NODE) {
			const m = next.nodeValue.match(/^(\s*[.,;:!?…)]+)/);
			if (m) {
				const suffix = m[1];
				const afterNode = document.createTextNode(suffix);
				wrap(el, null, afterNode);
				next.nodeValue = next.nodeValue.slice(suffix.length);
				if (!next.nodeValue.length) next.remove();
				return;
			}
		}

		if (next && next.nodeType === Node.ELEMENT_NODE) {
			const text = next.textContent || '';
			if (/^\s*[.,;:!?…)]$/.test(text)) {
				wrap(el, null, next);
				return;
			}
			const fc = next.firstChild;
			if (fc?.nodeType === Node.TEXT_NODE) {
				const m2 = fc.nodeValue.match(/^(\s*[.,;:!?…)]+)/);
				if (m2) {
					const suffix = m2[1];
					const afterNode = document.createTextNode(suffix);
					wrap(el, null, afterNode);
					fc.nodeValue = fc.nodeValue.slice(suffix.length);
					if (!fc.nodeValue.length) next.removeChild(fc);
				}
			}
		}
	}

	root.querySelectorAll(selector).forEach(wrapIfNeeded);
}
