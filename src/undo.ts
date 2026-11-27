// packages/hotstrings-web/src/undo.ts

/**
 * The Backspace undo of an expansion, after Ergopti's shared rule
 * (static/ergopti_plus/_shared/hotstrings/engine/backspace_restore.lua and
 * _shared/tests/corpus/hotstrings/backspace_restore_vectors.json):
 * 1. A Backspace within the window after an expansion removes the inserted
 *    text and gives back what the user typed: the trigger as typed (its casing
 *    included) without a final magic key, then the terminator when it was
 *    echoed. A consumed terminator was never typed and does not come back.
 *    `Expansion.restore` from the matcher is exactly that text.
 * 2. The window is inclusive: a Backspace exactly at its end still undoes.
 * 3. Past the window, after an undo, or after `clear()` (call it on any other
 *    key), `backspace` answers null and the caller deletes one character.
 */

/** Ergopti's default window, hotstrings.backspace_restore_window_ms. */
export const DEFAULT_UNDO_WINDOW_MS = 500;

/** One expansion an undo can revert. */
export interface UndoRecord {
	/** The text given back: `Expansion.restore`. */
	trigger: string;
	/** The text the expansion inserted, ending at the caret. */
	insert: string;
	/** When the expansion was applied, in milliseconds. */
	at: number;
}

/** The edit an undo makes at the caret. */
export interface UndoEdit {
	/** UTF-16 code units before the caret to remove (the inserted text). */
	deleteCount: number;
	/** The text to insert in their place. */
	insert: string;
}

/** Remembers the last expansion and reverts it on a prompt Backspace. */
export class ExpansionUndo {
	private readonly windowMs: number;
	private last: UndoRecord | null = null;

	/**
	 * @param windowMs How long after an expansion a Backspace undoes it; a whole number of milliseconds, at least 1.
	 */
	constructor(windowMs: number = DEFAULT_UNDO_WINDOW_MS) {
		if (!Number.isInteger(windowMs) || windowMs < 1) {
			throw new RangeError('the undo window must be a whole positive number of milliseconds');
		}
		this.windowMs = windowMs;
	}

	/** Records the expansion just applied; it replaces any earlier record. */
	record(entry: UndoRecord): void {
		this.last = { ...entry };
	}

	/** Forgets the last expansion: call it on any key other than Backspace. */
	clear(): void {
		this.last = null;
	}

	/**
	 * Answers a Backspace.
	 * @param now The time of the Backspace, in the clock `record` used.
	 * @returns The undo edit, or null when the Backspace deletes one character.
	 */
	backspace(now: number): UndoEdit | null {
		const last = this.last;
		this.last = null;
		if (last === null) return null;
		const elapsed = now - last.at;
		if (elapsed < 0 || elapsed > this.windowMs) return null;
		return { deleteCount: last.insert.length, insert: last.trigger };
	}
}
