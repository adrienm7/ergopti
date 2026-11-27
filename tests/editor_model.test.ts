// packages/hotstrings-web/tests/editor_model.test.ts

import { describe, expect, it } from 'vitest';
import {
	DEFAULT_LABELS,
	emptyDraft,
	errorLabel,
	exportToml,
	importToml,
	normalizeDraft,
	parseTags,
	problemLabel,
	removeAt,
	saveDraft,
	validateDraft
} from '../src/editor_model.js';
import type { Hotstring } from '../src/types.js';

const btw: Hotstring = { ...emptyDraft(), trigger: 'btw', output: 'by the way' };

describe('drafts', () => {
	it('starts from the v2 defaults', () => {
		expect(emptyDraft()).toEqual({
			trigger: '',
			output: '',
			expand: 'terminator',
			terminator: 'echo',
			caseSensitive: false,
			wordStart: true
		});
	});

	it('reads comma-separated tags', () => {
		expect(parseTags(' a, ,b ,')).toEqual(['a', 'b']);
		expect(parseTags('')).toEqual([]);
	});

	it('accepts a valid draft and refuses an empty trigger, a duplicate and a missing key', () => {
		expect(validateDraft(btw, [], null)).toEqual([]);
		expect(validateDraft({ ...btw, trigger: '' }, [], null)).toEqual(['trigger-empty']);
		expect(validateDraft({ ...btw, trigger: 'BTW' }, [btw], null)).toEqual(['trigger-duplicate']);
		expect(validateDraft(btw, [btw], 0)).toEqual([]);
		expect(validateDraft({ ...btw, expand: 'immediate' }, [btw], null)).toEqual([]);
		const strict = { ...btw, caseSensitive: true };
		expect(validateDraft({ ...strict, trigger: 'BTW' }, [strict], null)).toEqual([]);
		expect(validateDraft(strict, [strict], null)).toEqual(['trigger-duplicate']);
		expect(validateDraft({ ...btw, expand: 'key' }, [], null)).toEqual(['key-missing']);
	});

	it('labels each problem', () => {
		expect(problemLabel('trigger-empty', DEFAULT_LABELS)).toBe(DEFAULT_LABELS.errorTriggerEmpty);
		expect(problemLabel('trigger-duplicate', DEFAULT_LABELS)).toBe(DEFAULT_LABELS.errorTriggerDuplicate);
		expect(problemLabel('key-missing', DEFAULT_LABELS)).toBe(DEFAULT_LABELS.errorKeyMissing);
	});

	it('drops unused fields and keeps used ones', () => {
		expect(
			normalizeDraft({ ...btw, key: 'F2', conformCase: true, description: '', tags: [] })
		).toEqual(btw);
		const used = { ...btw, expand: 'key' as const, key: 'F2', conformCase: false, description: 'd', tags: ['t'] };
		expect(normalizeDraft(used)).toEqual(used);
		expect(normalizeDraft({ ...btw, caseSensitive: true, conformCase: false })).toEqual({ ...btw, caseSensitive: true });
	});
});

describe('list edits', () => {
	it('appends, replaces and removes', () => {
		const list = saveDraft([], btw, null);
		expect(list).toEqual([btw]);
		const other = { ...btw, trigger: 'omw' };
		expect(saveDraft([btw, btw], other, 1)).toEqual([btw, other]);
		expect(removeAt([btw, other], 0)).toEqual([other]);
	});

	it('imports by appending or replacing, and exports v2', () => {
		const text = exportToml([btw]);
		expect(importToml([btw], text, false).list).toEqual([btw, btw]);
		expect(importToml([btw], text, true)).toEqual({ list: [btw], errors: [] });
		expect(importToml([], 'a = ?', true).errors).toEqual([{ line: 1, message: 'unsupported value' }]);
	});

	it('formats an import error', () => {
		expect(errorLabel({ line: 3, message: 'bad' }, DEFAULT_LABELS)).toBe('Line 3: bad');
	});
});
