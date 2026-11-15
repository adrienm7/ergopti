// src/lib/keyboard/keyLegend.js

/**
 * ==============================================================================
 * MODULE: Key Legend Formatter
 * DESCRIPTION:
 * The one place that turns a key's character into the legend a keyboard shows:
 * the site's keyboards, and through its generated classic-script copy
 * (static/ergopti_plus/_shared/ui/_generated/key_legend.js, npm run
 * codegen:key-legend:js) the layout editor's board and magnifier and the
 * Comparer's boards.
 *
 * FEATURES & RATIONALE:
 * 1. A dead key reads as its bare accent (« ^ », « ¨ »), centred like any
 *    character, never as a combining mark on a dotted circle, which sits off
 *    centre and reads as a broken glyph (maintainer, 2026-11-15). The legend
 *    element carries DEAD_KEY_CLASS so every board marks it the same way.
 * 2. A control or invisible character gets a visible stand-in (␣, ∅, the
 *    control pictures); a lone combining mark typed as text keeps its dotted
 *    circle, since it is a character the key types, not an accent to come.
 * 3. Pure: no DOM except applyLegend, no imports, so the codegen can wrap it as
 *    a classic script for pages the hosts inline.
 * ==============================================================================
 */

/** The class of a legend element that shows a dead key. */
export const DEAD_KEY_CLASS = 'key-legend-dead';

const DOTTED_CIRCLE = '◌';

// Combining marks and the spacing accent a dead key shows for each.
const SPACING_ACCENTS = Object.freeze({
	0x300: '`',
	0x301: '´',
	0x302: '^',
	0x303: '~',
	0x304: '¯',
	0x306: '˘',
	0x307: '˙',
	0x308: '¨',
	0x30a: '˚',
	0x30b: '˝',
	0x30c: 'ˇ',
	0x327: '¸',
	0x328: '˛'
});

/**
 * Whether a code point is a combining diacritical mark.
 * @param {number} code A code point.
 * @returns {boolean} True for U+0300 to U+036F.
 */
function isCombining(code) {
	return code >= 0x300 && code <= 0x36f;
}

/**
 * The visible form of a character a key types.
 * @param {string} text The characters.
 * @returns {string} The text with stand-ins for empty, space, control
 *   characters and lone combining marks.
 */
export function visibleText(text) {
	if (text === '') return '∅';
	if (text === ' ') return '␣';
	return Array.from(text)
		.map((char) => {
			const code = char.codePointAt(0);
			if (code < 0x20) return String.fromCodePoint(0x2400 + code);
			if (isCombining(code)) return DOTTED_CIRCLE + char;
			return char;
		})
		.join('');
}

/**
 * The bare accent a dead key shows.
 * @param {string} text What the dead key types alone (its terminator), or a
 *   legend spelled as a combining mark on a dotted circle (« ◌̂ »).
 * @returns {string} The spacing accent (« ^ »), or the text itself when it is
 *   not an accent (« µ », « ¤ »); empty for an empty text.
 */
export function deadKeyText(text) {
	return Array.from(String(text))
		.filter((char) => char !== DOTTED_CIRCLE)
		.map((char) => {
			const code = char.codePointAt(0);
			if (isCombining(code)) return SPACING_ACCENTS[code] || char;
			if (code < 0x20) return String.fromCodePoint(0x2400 + code);
			return char;
		})
		.join('');
}

/**
 * Writes a legend into its element and marks a dead key.
 * @param {Element} node The legend element.
 * @param {string} text The legend, already formatted.
 * @param {boolean} dead Whether the key is a dead key.
 */
export function applyLegend(node, text, dead) {
	node.textContent = text;
	node.classList.toggle(DEAD_KEY_CLASS, dead);
}
