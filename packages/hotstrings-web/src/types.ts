// packages/hotstrings-web/src/types.ts

/**
 * The shared data model of the hotstring engine.
 *
 * A hotstring replaces a typed trigger with an output. The fields mirror the
 * Ergopti domain contract (static/ergopti_plus/_shared/tests/corpus/hotstrings/
 * vectors.json): `wordStart` is the corpus `is_word`, `expand: 'immediate'` is
 * `auto_expand`, `caseSensitive` is `is_case_sensitive_strict`, and
 * `conformCase: false` is the literal registration (`is_case_sensitive`
 * without strict).
 */

/** When a hotstring fires. */
export type ExpandMode = 'terminator' | 'immediate' | 'enter' | 'tab' | 'key';

/** What happens to the key that fired a hotstring. */
export type TerminatorMode = 'consume' | 'echo';

/** One hotstring. */
export interface Hotstring {
	/** The text typed to fire the hotstring. */
	trigger: string;
	/** The replacement text; may hold placeholders (see placeholders.ts). */
	output: string;
	/**
	 * `terminator`: on a terminator typed after the trigger (space, punctuation,
	 * Tab, Enter). `immediate`: as soon as the trigger's last character is
	 * typed. `enter` / `tab`: only on that key. `key`: only on `key`.
	 */
	expand: ExpandMode;
	/** The key that fires an `expand: 'key'` hotstring (a character or a key name). */
	key?: string;
	/** Whether the firing key is typed after the output (`echo`) or swallowed. */
	terminator: TerminatorMode;
	/** True: only the casing written in `trigger` fires, and the output is verbatim. */
	caseSensitive: boolean;
	/**
	 * Only read when `caseSensitive` is false. True (the default): the trigger
	 * fires typed in lower, Title or UPPER case and the output follows that
	 * casing; any other casing fires nothing. False: any casing fires and the
	 * output is verbatim (Ergopti's literal registration, used for acronyms).
	 */
	conformCase?: boolean;
	/** True: the trigger fires only at the start of a word. */
	wordStart: boolean;
	/** Collision rank among triggers of the same length; higher wins (default 0). */
	priority?: number;
	/** Free text shown by editors. */
	description?: string;
	/** Free labels; a v1 file's section names become tags. */
	tags?: string[];
}

/** The edit a matcher asks its caller to make. */
export interface Expansion {
	/** The hotstring that fired. */
	hotstring: Hotstring;
	/** UTF-16 code units of `before` to remove, ending at the cursor. */
	deleteCount: number;
	/** Text to insert in their place: the output, then the terminator when echoed. */
	insert: string;
	/** True when the typed key must not be inserted by the caller. */
	consumedKey: boolean;
	/**
	 * What a Backspace undo gives back (see undo.ts): the trigger as typed,
	 * without a final magic key, then the echoed terminator.
	 */
	restore: string;
}
