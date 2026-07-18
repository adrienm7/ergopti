// tools/test/test-metrics-speed-source-filters.cjs
// Regression contract for the typing-speed source toggles shared by every OS.

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const sourcePath = path.join(
	__dirname,
	'../../static/ergopti_plus/_shared/ui/metrics_typing/data.js'
);
const source = fs.readFileSync(sourcePath, 'utf8');

function expect(pattern, message) {
	assert.match(source, pattern, message);
}

expect(
	/const net_hs_chars = Math\.max\(0, hs_chars_raw - hs_input_raw\);/,
	'Hotstring output must be converted from gross output to net added characters.'
);
expect(
	/const net_llm_chars = Math\.max\(0, llm_chars_raw - llm_input_raw\);/,
	'LLM output must be converted from gross output to net added characters.'
);
expect(
	/\(show_hs \? Math\.max\(0, hs_c - \(app\.hs_input_chars \|\| 0\)\) : 0\)/,
	'The historical fallback must use the hotstring net gain only when enabled.'
);
expect(
	/\(show_llm \? Math\.max\(0, llm_c - \(app\.llm_input_chars \|\| 0\)\) : 0\)/,
	'The historical fallback must use the LLM net gain only when enabled.'
);
expect(
	/\(show_hs \? totals\.trig_hs_time_ms : 0\) \+ \(show_llm \? totals\.trig_llm_time_ms : 0\)/,
	'Only enabled generated sources may replace their trigger timing.'
);
assert.doesNotMatch(
	source,
	/const trig_time_ms = totals\.trig_hs_time_ms \+ totals\.trig_llm_time_ms;/,
	'Hidden sources must not silently remove their trigger time from the manual baseline.'
);

console.log('PASS test-metrics-speed-source-filters');
