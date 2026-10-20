// tools/test/test-config-template-spacing.cjs
'use strict';

// The generated default config must already carry the house spacing the
// writers render (five blank lines before a top-level header, three before a
// nested one: `toml_codec/codec.lua` and the Windows flat writer). A template
// separated by one blank line makes the first save rewrite every separator,
// and header-only sections then read as runs of blank lines.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const paths = require('../lib/paths.cjs');

const TOP_HEADER_SPACING = 5;
const NESTED_HEADER_SPACING = 3;

/** Return every header with the number of blank lines directly above it. */
function headerSpacings(text) {
	const lines = text.split('\n');
	const found = [];
	for (let index = 0; index < lines.length; index++) {
		const match = /^\[([^\]]+)\]$/.exec(lines[index]);
		if (!match) continue;
		let blanks = 0;
		while (index - blanks - 1 >= 0 && lines[index - blanks - 1] === '') blanks++;
		found.push({ header: match[1], blanks, previous: lines[index - blanks - 1] });
	}
	return found;
}

for (const driver of ['windows', 'macos', 'linux']) {
	const text = fs.readFileSync(
		paths.shared('..', driver, '_generated', 'config_template.toml'),
		'utf8'
	);
	assert(!text.includes('\r'), `${driver} template must be stored with LF`);
	const spacings = headerSpacings(text);
	assert(spacings.length > 20, `${driver} template must expose its real sections`);
	spacings.forEach(({ header, blanks, previous }, position) => {
		if (position === 0) {
			assert(previous.startsWith('#'), `${driver} [${header}] must follow the banner`);
			return;
		}
		const expected = header.includes('.') ? NESTED_HEADER_SPACING : TOP_HEADER_SPACING;
		assert.equal(
			blanks,
			expected,
			`${driver} [${header}] must follow ${expected} blank lines, found ${blanks}; run npm run build:manifest`
		);
	});
	assert(
		text.endsWith('\n') && !text.endsWith('\n\n\n'),
		`${driver} template ends with one newline`
	);
}

console.log('config template spacing: ok');
