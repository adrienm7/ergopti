// _shared/ui/layout_composer/reference_layouts.js

/**
 * ==============================================================================
 * MODULE: Layout Composer Reference Layouts
 * DESCRIPTION:
 * The two layouts every composition can start from although the registry does
 * not hold them: US QWERTY and French AZERTY. They are plain data, one row per
 * physical key (W3C KeyboardEvent.code) with the text it types on the base,
 * Shift, AltGr and Shift+AltGr layers, so the composer model reads them like a
 * parsed registry layout. They are facts about the keyboards, not a copy of any
 * vendor's layout file.
 *
 * FEATURES & RATIONALE:
 * 1. Dead keys are declared once (`dead`) with the characters they compose;
 *    the model turns them into the same state machine a .keylayout carries.
 * 2. A null cell types nothing on that layer.
 * 3. The ids share the registry's namespace; the registry may not use them
 *    (tools/test/test-layout-composer-model.cjs pins it).
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm context).
var LAYOUT_COMPOSER_REFERENCE = (function () {
	'use strict';

	// Dead keys: the character they type alone and what they make of a letter.
	const DEAD = {
		circumflex: {
			terminator: '^',
			compose: {
				a: 'â',
				e: 'ê',
				i: 'î',
				o: 'ô',
				u: 'û',
				A: 'Â',
				E: 'Ê',
				I: 'Î',
				O: 'Ô',
				U: 'Û',
				' ': '^'
			}
		},
		diaeresis: {
			terminator: '¨',
			compose: {
				a: 'ä',
				e: 'ë',
				i: 'ï',
				o: 'ö',
				u: 'ü',
				y: 'ÿ',
				A: 'Ä',
				E: 'Ë',
				I: 'Ï',
				O: 'Ö',
				U: 'Ü',
				' ': '¨'
			}
		}
	};

	// [base, Shift, AltGr, Shift+AltGr] per physical key; {dead: name} is a dead key.
	const QWERTY = {
		Space: [' ', ' ', null, null],
		Backquote: ['`', '~', null, null],
		Digit1: ['1', '!', null, null],
		Digit2: ['2', '@', null, null],
		Digit3: ['3', '#', null, null],
		Digit4: ['4', '$', null, null],
		Digit5: ['5', '%', null, null],
		Digit6: ['6', '^', null, null],
		Digit7: ['7', '&', null, null],
		Digit8: ['8', '*', null, null],
		Digit9: ['9', '(', null, null],
		Digit0: ['0', ')', null, null],
		Minus: ['-', '_', null, null],
		Equal: ['=', '+', null, null],
		KeyQ: ['q', 'Q', null, null],
		KeyW: ['w', 'W', null, null],
		KeyE: ['e', 'E', null, null],
		KeyR: ['r', 'R', null, null],
		KeyT: ['t', 'T', null, null],
		KeyY: ['y', 'Y', null, null],
		KeyU: ['u', 'U', null, null],
		KeyI: ['i', 'I', null, null],
		KeyO: ['o', 'O', null, null],
		KeyP: ['p', 'P', null, null],
		BracketLeft: ['[', '{', null, null],
		BracketRight: [']', '}', null, null],
		KeyA: ['a', 'A', null, null],
		KeyS: ['s', 'S', null, null],
		KeyD: ['d', 'D', null, null],
		KeyF: ['f', 'F', null, null],
		KeyG: ['g', 'G', null, null],
		KeyH: ['h', 'H', null, null],
		KeyJ: ['j', 'J', null, null],
		KeyK: ['k', 'K', null, null],
		KeyL: ['l', 'L', null, null],
		Semicolon: [';', ':', null, null],
		Quote: ["'", '"', null, null],
		Backslash: ['\\', '|', null, null],
		IntlBackslash: ['\\', '|', null, null],
		KeyZ: ['z', 'Z', null, null],
		KeyX: ['x', 'X', null, null],
		KeyC: ['c', 'C', null, null],
		KeyV: ['v', 'V', null, null],
		KeyB: ['b', 'B', null, null],
		KeyN: ['n', 'N', null, null],
		KeyM: ['m', 'M', null, null],
		Comma: [',', '<', null, null],
		Period: ['.', '>', null, null],
		Slash: ['/', '?', null, null]
	};

	const AZERTY = {
		Space: [' ', ' ', null, null],
		Backquote: ['²', null, null, null],
		Digit1: ['&', '1', null, null],
		Digit2: ['é', '2', '~', null],
		Digit3: ['"', '3', '#', null],
		Digit4: ["'", '4', '{', null],
		Digit5: ['(', '5', '[', null],
		Digit6: ['-', '6', '|', null],
		Digit7: ['è', '7', '`', null],
		Digit8: ['_', '8', '\\', null],
		Digit9: ['ç', '9', '^', null],
		Digit0: ['à', '0', '@', null],
		Minus: [')', '°', ']', null],
		Equal: ['=', '+', '}', null],
		KeyQ: ['a', 'A', null, null],
		KeyW: ['z', 'Z', null, null],
		KeyE: ['e', 'E', '€', null],
		KeyR: ['r', 'R', null, null],
		KeyT: ['t', 'T', null, null],
		KeyY: ['y', 'Y', null, null],
		KeyU: ['u', 'U', null, null],
		KeyI: ['i', 'I', null, null],
		KeyO: ['o', 'O', null, null],
		KeyP: ['p', 'P', null, null],
		BracketLeft: [{ dead: 'circumflex' }, { dead: 'diaeresis' }, null, null],
		BracketRight: ['$', '£', '¤', null],
		KeyA: ['q', 'Q', null, null],
		KeyS: ['s', 'S', null, null],
		KeyD: ['d', 'D', null, null],
		KeyF: ['f', 'F', null, null],
		KeyG: ['g', 'G', null, null],
		KeyH: ['h', 'H', null, null],
		KeyJ: ['j', 'J', null, null],
		KeyK: ['k', 'K', null, null],
		KeyL: ['l', 'L', null, null],
		Semicolon: ['m', 'M', null, null],
		Quote: ['ù', '%', null, null],
		Backslash: ['*', 'µ', null, null],
		IntlBackslash: ['<', '>', null, null],
		KeyZ: ['w', 'W', null, null],
		KeyX: ['x', 'X', null, null],
		KeyC: ['c', 'C', null, null],
		KeyV: ['v', 'V', null, null],
		KeyB: ['b', 'B', null, null],
		KeyN: ['n', 'N', null, null],
		KeyM: [',', '?', null, null],
		Comma: [';', '.', null, null],
		Period: [':', '/', null, null],
		Slash: ['!', '§', null, null]
	};

	return {
		qwerty: { name: 'QWERTY (US)', rows: QWERTY, dead: {} },
		azerty: { name: 'AZERTY (FR)', rows: AZERTY, dead: DEAD }
	};
})();
