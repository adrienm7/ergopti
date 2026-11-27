// packages/hotstrings-web/src/editor_model.ts

/**
 * The editing rules behind HotstringEditor.svelte, kept out of the component
 * so any UI (Svelte, plain DOM, BookTool) shares them: drafts, validation,
 * list edits, TOML import and export. Every function returns a new list.
 */

import { lowerCase } from './matcher.js';
import { parseHotstrings, serializeHotstrings, type HotstringFileError } from './toml.js';
import type { Hotstring } from './types.js';

/** The texts of the editor; callers translate them. */
export interface EditorLabels {
	title: string;
	empty: string;
	trigger: string;
	output: string;
	expand: string;
	expandTerminator: string;
	expandImmediate: string;
	expandEnter: string;
	expandTab: string;
	expandKey: string;
	key: string;
	terminator: string;
	terminatorEcho: string;
	terminatorConsume: string;
	caseSensitive: string;
	conformCase: string;
	wordStart: string;
	description: string;
	tags: string;
	add: string;
	edit: string;
	remove: string;
	save: string;
	cancel: string;
	importToml: string;
	exportToml: string;
	importReplace: string;
	errorTriggerEmpty: string;
	errorTriggerDuplicate: string;
	errorKeyMissing: string;
	errorLine: string;
}

/** English defaults. `errorLine` takes `{line}` and `{message}`. */
export const DEFAULT_LABELS: EditorLabels = {
	title: 'Hotstrings',
	empty: 'No hotstring yet.',
	trigger: 'Trigger',
	output: 'Output',
	expand: 'Expands',
	expandTerminator: 'On a terminator (space, punctuation)',
	expandImmediate: 'At once',
	expandEnter: 'On Enter',
	expandTab: 'On Tab',
	expandKey: 'On a custom key',
	key: 'Key',
	terminator: 'Terminator',
	terminatorEcho: 'Typed after the output',
	terminatorConsume: 'Swallowed',
	caseSensitive: 'Case sensitive',
	conformCase: 'Output follows the typed casing',
	wordStart: 'Only at the start of a word',
	description: 'Description',
	tags: 'Tags (comma separated)',
	add: 'New hotstring',
	edit: 'Edit',
	remove: 'Delete',
	save: 'Save',
	cancel: 'Cancel',
	importToml: 'Import TOML',
	exportToml: 'Export TOML',
	importReplace: 'Replace the list on import',
	errorTriggerEmpty: 'The trigger is empty.',
	errorTriggerDuplicate: 'Another hotstring has this trigger.',
	errorKeyMissing: 'Choose the key.',
	errorLine: 'Line {line}: {message}'
};

/** A problem with a draft. */
export type DraftProblem = 'trigger-empty' | 'trigger-duplicate' | 'key-missing';

/** A new, empty hotstring with the v2 defaults. */
export function emptyDraft(): Hotstring {
	return {
		trigger: '',
		output: '',
		expand: 'terminator',
		terminator: 'echo',
		caseSensitive: false,
		wordStart: true
	};
}

/** Reads a comma-separated tag field. */
export function parseTags(text: string): string[] {
	return text
		.split(',')
		.map((tag) => tag.trim())
		.filter((tag) => tag !== '');
}

/** Whether two hotstrings would answer the same typed trigger in the same way. */
function sameTrigger(a: Hotstring, b: Hotstring): boolean {
	if (a.expand !== b.expand) return false;
	if (a.caseSensitive && b.caseSensitive) return a.trigger === b.trigger;
	return lowerCase(a.trigger) === lowerCase(b.trigger);
}

/**
 * Checks a draft against the list.
 * @param draft The edited hotstring.
 * @param list The current list.
 * @param index The index being edited, or null for a new hotstring.
 * @returns The problems, empty when the draft can be saved.
 */
export function validateDraft(draft: Hotstring, list: Hotstring[], index: number | null): DraftProblem[] {
	const problems: DraftProblem[] = [];
	if (draft.trigger === '') problems.push('trigger-empty');
	else if (list.some((other, i) => i !== index && sameTrigger(other, draft))) {
		problems.push('trigger-duplicate');
	}
	if (draft.expand === 'key' && !draft.key) problems.push('key-missing');
	return problems;
}

/** The label of a draft problem. */
export function problemLabel(problem: DraftProblem, labels: EditorLabels): string {
	if (problem === 'trigger-empty') return labels.errorTriggerEmpty;
	if (problem === 'trigger-duplicate') return labels.errorTriggerDuplicate;
	return labels.errorKeyMissing;
}

/** Drops the fields a draft does not use, so the saved hotstring is minimal. */
export function normalizeDraft(draft: Hotstring): Hotstring {
	const out: Hotstring = { ...draft };
	if (out.expand !== 'key') delete out.key;
	if (out.caseSensitive || out.conformCase !== false) delete out.conformCase;
	if (out.description === '') delete out.description;
	if (out.tags !== undefined && out.tags.length === 0) delete out.tags;
	return out;
}

/** Saves a draft: replaces `index`, or appends when `index` is null. */
export function saveDraft(list: Hotstring[], draft: Hotstring, index: number | null): Hotstring[] {
	const saved = normalizeDraft(draft);
	if (index === null) return [...list, saved];
	return list.map((hotstring, i) => (i === index ? saved : hotstring));
}

/** Removes the hotstring at `index`. */
export function removeAt(list: Hotstring[], index: number): Hotstring[] {
	return list.filter((_, i) => i !== index);
}

/** The result of an import. */
export interface ImportResult {
	list: Hotstring[];
	errors: HotstringFileError[];
}

/** Imports a TOML file (v1 or v2), replacing the list or appending to it. */
export function importToml(list: Hotstring[], text: string, replace: boolean): ImportResult {
	const parsed = parseHotstrings(text);
	return { list: replace ? parsed.hotstrings : [...list, ...parsed.hotstrings], errors: parsed.errors };
}

/** Exports the list as TOML v2. */
export function exportToml(list: Hotstring[]): string {
	return serializeHotstrings(list);
}

/** Formats an import error with the `errorLine` label. */
export function errorLabel(error: HotstringFileError, labels: EditorLabels): string {
	return labels.errorLine.replace('{line}', String(error.line)).replace('{message}', error.message);
}
