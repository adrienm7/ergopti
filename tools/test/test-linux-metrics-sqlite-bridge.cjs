// tools/test/test-linux-metrics-sqlite-bridge.cjs
// Regression contract: the Linux dashboard must read persisted SQLite data and
// refresh the selected range through its native WebKit bridge.

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '../..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
const reader = read('static/ergopti_plus/linux/modules/keylogger/sqlite_reader.lua');
const bridge = read('static/ergopti_plus/linux/ui/metrics_typing/bridge.lua');
const data = read('static/ergopti_plus/_shared/ui/metrics_typing/data.js');
const html = read('static/ergopti_plus/_shared/ui/metrics_typing/index.html');

// The sqlite3 invocation is composed by modules/keylogger/sqlite_command.lua
// now, so the SQL script travels on stdin instead of through a file staged in
// the world-writable /tmp. The assertion follows the mechanism rather than the
// literal command: the reader must still ask sqlite3 for JSON, and must still
// go through the audited builder to do it.
assert.match(reader, /SqliteCommand\.build/);
assert.match(reader, /flags = \{ "-json" \}/);
assert.match(reader, /FROM agg_app_day/);
// The reader reaches its nine n-gram tables through a code-to-table map now,
// so the contract is the map's coverage rather than one literal FROM clause.
// Eight of these nine were handed to the dashboard as permanently empty maps
// while the writer was filling them, and a blank panel looks identical whether
// the rows were never written or never read.
for (const table of [
	'ngram_chars', 'ngram_bigrams', 'ngram_trigrams', 'ngram_quadgrams',
	'ngram_pentagrams', 'ngram_hexagrams', 'ngram_heptagrams',
	'ngram_words', 'ngram_word_bigrams',
]) {
	assert.ok(reader.includes(table), `reader must project ${table}`);
}
assert.match(bridge, /action == "range"/);
assert.match(bridge, /get_range_payload/);
assert.match(data, /window\.webkit\.messageHandlers\.metrics_typing_bridge\.postMessage\(\{ action: 'range', \.\.\.req \}\)/);
assert.match(html, /metrics_typing_bridge\.postMessage\(\{ action: 'ready' \}\)/);

console.log('PASS test-linux-metrics-sqlite-bridge');
