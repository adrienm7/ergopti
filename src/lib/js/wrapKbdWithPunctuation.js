// wrapKbdWithPunctuation.js

/**
 * Finds all <kbd>, <kbd-output> and <kbd-non> elements
 * and wraps the element + following punctuation into a <span class="nowrap">
 */
export function wrapKbdWithPunctuation(root = document) {
	const selector = 'kbd, kbd-output, kbd-non';

	function wrapIfPunctuationAfter(el) {
		if (!el || !el.parentNode) return;
		if (el.parentNode.classList?.contains('nowrap')) return;

		const next = el.nextSibling;
		if (!next) return;

		// case: plain text node right after
		if (next.nodeType === Node.TEXT_NODE) {
			const m = next.nodeValue.match(/^(\s*[.,;:!?…]+)/);
			if (m) {
				const prefix = m[1];
				const span = document.createElement('span');
				span.className = 'nowrap';
				el.parentNode.insertBefore(span, el);
				span.appendChild(el);
				span.appendChild(document.createTextNode(prefix));
				const rest = next.nodeValue.slice(prefix.length);
				if (rest.length) next.nodeValue = rest;
				else next.remove();
			}
			return;
		}

		// case: following element contains only punctuation
		if (next.nodeType === Node.ELEMENT_NODE) {
			const text = next.textContent || '';
			if (/^\s*[.,;:!?…]+$/.test(text)) {
				const span = document.createElement('span');
				span.className = 'nowrap';
				el.parentNode.insertBefore(span, el);
				span.appendChild(el);
				span.appendChild(next);
				return;
			}

			// case: first child text node of next element starts with punctuation
			const fc = next.firstChild;
			if (fc?.nodeType === Node.TEXT_NODE) {
				const m2 = fc.nodeValue.match(/^(\s*[.,;:!?…]+)/);
				if (m2) {
					const prefix = m2[1];
					const span = document.createElement('span');
					span.className = 'nowrap';
					el.parentNode.insertBefore(span, el);
					span.appendChild(el);
					span.appendChild(document.createTextNode(prefix));
					fc.nodeValue = fc.nodeValue.slice(prefix.length);
					if (!fc.nodeValue.length) next.removeChild(fc);
				}
			}
		}
	}

	root.querySelectorAll(selector).forEach(wrapIfPunctuationAfter);
}
