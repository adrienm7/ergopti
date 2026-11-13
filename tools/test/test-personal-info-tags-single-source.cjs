// tools/test/test-personal-info-tags-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Personal-Info Named Tags Single Source
 * DESCRIPTION:
 * The @-tags that name one personal_info field (@iban, @tel, …) live in
 * _shared/hotstrings/engine/personal_info/tags.lua, read by macOS and Linux.
 * Windows registers its own AutoHotkey map (PERSONAL_INFO_TAGS and its
 * registration order, infra/personal_info_preview.ahk). This gate holds the
 * three to one set of tags and one field per tag: a tag missing on one OS
 * there read letter by letter and typed more personal data than asked
 * (HCD-3).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..', '..');
const plus = path.join(root, 'static', 'ergopti_plus');
const read = (...parts) => fs.readFileSync(path.join(plus, ...parts), 'utf8');

/** The Lua FIELDS table, as tag → field. */
function sharedTags() {
	const source = read('_shared', 'hotstrings', 'engine', 'personal_info', 'tags.lua');
	const body = /M\.FIELDS = \{([\s\S]*?)\n\}/.exec(source);
	assert.ok(body, 'tags.lua declares M.FIELDS');
	const tags = {};
	for (const match of body[1].matchAll(
		/^\s*(?:\["([^"]+)"\]|([a-z]+))\s*=\s*"([a-z_]+)",?\s*$/gm
	)) {
		tags[match[1] ?? match[2]] = match[3];
	}
	assert.ok(Object.keys(tags).length > 0, 'M.FIELDS lists tags');
	return tags;
}

/** The Windows map and its registration order. */
function windowsTags() {
	const source = read('windows', 'infra', 'personal_info_preview.ahk');
	const body = /global PERSONAL_INFO_TAGS := Map\(([\s\S]*?)\n\)/.exec(source);
	assert.ok(body, 'personal_info_preview.ahk declares PERSONAL_INFO_TAGS');
	const tags = {};
	for (const match of body[1].matchAll(/"([^"]+)",\s*"([a-z_]+)"/g)) tags[match[1]] = match[2];
	const order = /global PERSONAL_INFO_TAG_ORDER := \[([^\]]*)\]/.exec(source);
	assert.ok(order, 'personal_info_preview.ahk declares PERSONAL_INFO_TAG_ORDER');
	return { tags, order: [...order[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]) };
}

const shared = sharedTags();
const windows = windowsTags();
assert.deepEqual(windows.tags, shared, 'the Windows map names the shared tags and fields');
assert.deepEqual(
	[...windows.order].sort(),
	Object.keys(shared).sort(),
	'the Windows registration order lists every shared tag once'
);
console.log(
	`[OK] ${Object.keys(shared).length} personal-info named tags agree on Windows, macOS and Linux.`
);
