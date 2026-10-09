// _shared/core/domain/Terminators.spec.js

/**
 * ==============================================================================
 * DOMAIN: Terminators
 * DESCRIPTION:
 * Contract and data model for the terminator catalogue. A "terminator" is a
 * character or set of characters whose input signals the end of a hotstring
 * trigger and triggers the expansion check. The catalogue ships with a default
 * set of terminators (space, punctuation, magic key, …) and supports runtime
 * enable/disable and custom user-defined terminators.
 *
 * FEATURES & RATIONALE:
 * 1. O(1) character lookup: enabled terminator characters are stored in a flat
 *    Set. Checking whether a character is a terminator is O(1) regardless of
 *    catalogue size. The Set is rebuilt lazily when the catalogue is mutated.
 * 2. Consume flag: some terminators are "consumed" (not re-typed after
 *    expansion, e.g. the magic key ★). Others are echoed (e.g. space). The
 *    is_consumed(char) method encapsulates this flag.
 * 3. Default catalogue: the TERMINATOR_DEFS constant exports the built-in
 *    catalogue so both the JS reference, the AHK adapter, and the HS adapter
 *    start from the same ground truth.
 * 4. Magic key rename: the magic key terminator can be reassigned to a
 *    different character at runtime (user config). updateMagicKey(char)
 *    handles the swap atomically.
 * ==============================================================================
 */

'use strict';

// ==================================================
// ==================================================
// ======= 1/ Default Terminator Catalogue =======
// ==================================================
// ==================================================

/**
 * Built-in terminator definitions.
 * Adapters MUST start from this catalogue (or a faithful translation of it)
 * before applying user configuration.
 *
 * @typedef {object} TerminatorDef
 * @property {string}   key             Stable identifier (snake_case).
 * @property {string[]} chars           UTF-8 characters that belong to this slot.
 * @property {string}   label           Human-readable UI label (French).
 * @property {boolean}  default_enabled True = active out of the box.
 * @property {boolean}  consume         True = the char is swallowed, not echoed.
 *
 * Conventions:
 * - The list ORDER is the menu order; both drivers (AHK tray + macOS) render the
 *   catalogue in this exact sequence, separators included.
 * - One character per slot (do not bundle several toggleable chars into one
 *   entry); the lone exception is "enter" (CR+LF are one logical key).
 * - Only CLOSING delimiters terminate a word — the opening "(", "[", "{", "<"
 *   never end a word, so only ")", "]", "}", ">" are listed.
 * - Insert a bare { type: "separator" } entry to render a "-" divider between
 *   groups in the menus (it carries no characters and is never enabled).
 * - The magic key lives under the key "star" (historical, shared with the macOS
 *   registry's update_trigger_char sync) and is the only consumed slot.
 * - Labels are static French strings. The macOS shim re-resolves a handful of
 *   keys (nbsp, nnbsp, enter, parenright, equal) through i18n at load time;
 *   every other label is shown verbatim on both drivers.
 * - Defaults are deliberately conservative: only the BASIC word-terminators
 *   fire out of the box — whitespace (space, tab, enter), the sentence
 *   punctuation (. , ; : ! ?) and the magic key. Everything else (the
 *   non-breaking spaces, dashes, ellipsis, apostrophes, double quote, closing
 *   delimiters, slashes, equals) ships disabled-but-toggleable: the catalogue
 *   offers plenty of options, but only the obvious ones are on. Both drivers
 *   derive their defaults from this single list, so they behave identically.
 */
const TERMINATOR_DEFS = [
	// Whitespace & dashes
	{ key: 'space', chars: [' '], label: '␣ : Espace', default_enabled: true, consume: false },
	{
		key: 'nbsp',
		chars: [' '],
		label: '⍽ : Espace insécable',
		default_enabled: false,
		consume: false
	},
	{
		key: 'nnbsp',
		chars: [' '],
		label: '⍽ : Espace fine insécable',
		default_enabled: false,
		consume: false
	},
	{ key: 'minus', chars: ['-'], label: '- : Tiret', default_enabled: false, consume: false },
	{
		key: 'underscore',
		chars: ['_'],
		label: '_ : Tiret bas',
		default_enabled: false,
		consume: false
	},
	{ type: 'separator' },
	// Tab / Entrée / magic key
	{ key: 'tab', chars: ['\t'], label: '⇥ : Tabulation', default_enabled: true, consume: false },
	{ key: 'enter', chars: ['\r', '\n'], label: '⏎ : Entrée', default_enabled: true, consume: false },
	{ key: 'star', chars: ['★'], label: '★ : Touche magique', default_enabled: true, consume: true },
	{ type: 'separator' },
	// Sentence punctuation
	{ key: 'comma', chars: [','], label: ', : Virgule', default_enabled: true, consume: false },
	{
		key: 'semicolon',
		chars: [';'],
		label: '; : Point-virgule',
		default_enabled: true,
		consume: false
	},
	{ key: 'period', chars: ['.'], label: '. : Point', default_enabled: true, consume: false },
	{
		key: 'ellipsis',
		chars: ['…'],
		label: '… : Points de suspension',
		default_enabled: false,
		consume: false
	},
	{
		key: 'exclam',
		chars: ['!'],
		label: "! : Point d'exclamation",
		default_enabled: true,
		consume: false
	},
	{
		key: 'question',
		chars: ['?'],
		label: "? : Point d'interrogation",
		default_enabled: true,
		consume: false
	},
	{ key: 'colon', chars: [':'], label: ': : Deux-points', default_enabled: true, consume: false },
	{ type: 'separator' },
	// Closing delimiters only (the opening ( [ { < never end a word)
	{
		key: 'parenright',
		chars: [')'],
		label: ') : Parenthèse fermante',
		default_enabled: false,
		consume: false
	},
	{
		key: 'braceright',
		chars: ['}'],
		label: '} : Accolade fermante',
		default_enabled: false,
		consume: false
	},
	{
		key: 'bracketright',
		chars: [']'],
		label: '] : Crochet fermant',
		default_enabled: false,
		consume: false
	},
	{
		key: 'anglebracketright',
		chars: ['>'],
		label: '> : Guillemet fermant',
		default_enabled: false,
		consume: false
	},
	{ type: 'separator' },
	// Apostrophes, quote & symbols
	{
		key: 'apostrophe_typo',
		chars: ['’'],
		label: '’ : Apostrophe typographique',
		default_enabled: false,
		consume: false
	},
	{
		key: 'apostrophe_straight',
		chars: ["'"],
		label: "' : Apostrophe droite",
		default_enabled: false,
		consume: false
	},
	{
		key: 'quote',
		chars: ['"'],
		label: '" : Guillemet double',
		default_enabled: false,
		consume: false
	},
	{ key: 'equal', chars: ['='], label: '= : Égal', default_enabled: false, consume: false },
	{ key: 'slash', chars: ['/'], label: '/ : Slash', default_enabled: false, consume: false },
	{
		key: 'backslash',
		chars: ['\\'],
		label: '\\ : Backslash',
		default_enabled: false,
		consume: false
	}
];

// ==================================================
// ==================================================
// ======= 2/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The Terminators domain contract.
 * @type {object}
 */
const portContract = {
	name: 'Terminators',
	version: '1.0.0',

	/**
	 * isTerminator(char) — True if char belongs to any enabled terminator slot.
	 *   @param {string} char  A single UTF-8 codepoint.
	 *   @returns {boolean}
	 *
	 * isConsumed(char) — True if the enabled terminator for char is consumed.
	 *   @param {string} char  A single UTF-8 codepoint.
	 *   @returns {boolean}
	 *
	 * setEnabled(key, enabled) — Enable or disable a terminator slot.
	 *   @param {string}  key     The terminator's key from TERMINATOR_DEFS.
	 *   @param {boolean} enabled
	 *   @returns {void}
	 *   @error_behavior "log_and_return" on unknown key.
	 *
	 * isEnabled(key) — Query the enabled state of a slot.
	 *   @param {string} key
	 *   @returns {boolean}
	 *
	 * updateMagicKey(char) — Reassign the magic_key slot to a new character.
	 *   Replaces the chars array of the magic_key slot and rebuilds the Set.
	 *   @param {string} char  A single UTF-8 codepoint.
	 *   @returns {void}
	 *
	 * addCustom(key, chars, label, consumed) — Add a user-defined terminator.
	 *   @param {string}   key     Unique identifier (must not collide with TERMINATOR_DEFS keys).
	 *   @param {string[]} chars   Characters for this slot (must not collide with any existing slot).
	 *   @param {string}   label   Display label.
	 *   @param {boolean}  consumed
	 *   @returns {boolean} True only when the slot is committed.
	 *   @error_behavior "log_and_return_false" on key or character collision.
	 *
	 * all() — Return a copy of the full catalogue (enabled + disabled).
	 *   @returns {TerminatorDef[]}
	 */
	methods: {
		isTerminator: { arity: 1, required: true },
		isConsumed: { arity: 1, required: true },
		setEnabled: { arity: 2, required: true },
		isEnabled: { arity: 1, required: true },
		updateMagicKey: { arity: 1, required: true },
		addCustom: { arity: 4, required: true },
		all: { arity: 0, required: true }
	},

	/** Exported so adapters initialize from the same source. */
	TERMINATOR_DEFS
};

// ==================================================
// ==================================================
// ======= 3/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a Terminators adapter.
 * @param {object} adapter
 * @returns {string[]} Violations. Empty = compliant.
 */
function validateAdapter(adapter) {
	const violations = [];
	if (!adapter || typeof adapter !== 'object') {
		return ['adapter must be a non-null object'];
	}
	for (const [name, spec] of Object.entries(portContract.methods)) {
		if (!spec.required) continue;
		if (typeof adapter[name] !== 'function') {
			violations.push(`missing method: ${name}`);
		} else if (adapter[name].length !== spec.arity) {
			violations.push(`method ${name}: expected arity ${spec.arity}, got ${adapter[name].length}`);
		}
	}
	return violations;
}

// ==================================================
// ==================================================
// ======= 4/ Compliance Test Vectors =======
// ==================================================
// ==================================================

/**
 * Returns test vectors for Terminators compliance.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: 'space_is_terminator',
			description: 'Space is a terminator by default.',
			input: { char: ' ' },
			assert: { isTerminator: true, isConsumed: false }
		},
		{
			id: 'magic_key_consumed',
			description: 'The magic key terminator is consumed (not echoed).',
			input: { char: '★' },
			assert: { isTerminator: true, isConsumed: true }
		},
		{
			id: 'letter_not_terminator',
			description: 'An ordinary letter is not a terminator.',
			input: { char: 'a' },
			assert: { isTerminator: false }
		},
		{
			id: 'disable_then_not_terminator',
			description: "After setEnabled('space', false), space is not a terminator.",
			steps: [
				{ call: 'setEnabled', args: ['space', false] },
				{ assert: { call: 'isTerminator', args: [' '], expected: false } },
				{ call: 'setEnabled', args: ['space', true] } // restore
			]
		},
		{
			id: 'update_magic_key',
			description: "updateMagicKey('§') makes § a consumed terminator and ★ is no longer one.",
			steps: [
				{ call: 'updateMagicKey', args: ['§'] },
				{ assert: { call: 'isTerminator', args: ['§'], expected: true } },
				{ assert: { call: 'isConsumed', args: ['§'], expected: true } },
				{ assert: { call: 'isTerminator', args: ['★'], expected: false } }
			]
		},
		{
			id: 'add_custom_terminator',
			description: 'addCustom adds a new slot that isTerminator recognizes.',
			steps: [
				{ call: 'addCustom', args: ['pipe', ['|'], 'Pipe', false] },
				{ assert: { call: 'isTerminator', args: ['|'], expected: true } },
				{ assert: { call: 'isConsumed', args: ['|'], expected: false } },
				{ assert: { call: 'isEnabled', args: ['pipe'], expected: true } }
			]
		},
		{
			id: 'all_returns_catalogue',
			description: 'all() returns at least the built-in TERMINATOR_DEFS slots.',
			steps: [
				{
					assert_min_length: {
						call: 'all',
						args: [],
						min: TERMINATOR_DEFS.length
					}
				}
			]
		}
	];
}

module.exports = { portContract, validateAdapter, contractTestVectors, TERMINATOR_DEFS };
