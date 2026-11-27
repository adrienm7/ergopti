// packages/hotstrings-web/src/index.ts

/**
 * The public entry of @ergopti/hotstrings-web: types, TOML files,
 * placeholders, matcher, Backspace undo and the editor model.
 */

export type { ExpandMode, Expansion, Hotstring, TerminatorMode } from './types.js';
export {
	FORMAT_V2,
	parseHotstrings,
	quoteTomlString,
	serializeHotstrings,
	type HotstringFileError,
	type ParsedHotstrings
} from './toml.js';
export {
	expandOutput,
	formatDate,
	type ExpandedOutput,
	type PlaceholderContext
} from './placeholders.js';
export {
	DEFAULT_MAGIC_KEY,
	DEFAULT_TERMINATORS,
	HotstringMatcher,
	foldCase,
	isWordChar,
	lowerCase,
	type MatcherOptions
} from './matcher.js';
export {
	DEFAULT_UNDO_WINDOW_MS,
	ExpansionUndo,
	type UndoEdit,
	type UndoRecord
} from './undo.js';
