// tools/test/test-issue-link-vectors.cjs

/**
 * ==============================================================================
 * MODULE: Issue Link Vectors (JS)
 * DESCRIPTION:
 * Replays _shared/tests/corpus/diagnostics/issue_link_vectors.json through the
 * shared page builder _shared/ui/issue_link.js: RFC 3986 percent-encoding of
 * UTF-8 and the byte-bounded prefilled GitHub issue URL. The Lua and AHK ports
 * replay the same file in their suites, so the three agree byte for byte.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
// The builder is a page script (it defines window.ErgoptiIssueLink), so it runs
// in a sandbox exactly as the pages load it
const IssueLink = (() => {
	const file = path.join(SHARED, 'ui', 'issue_link.js');
	const sandbox = { window: {} };
	vm.runInNewContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
	if (!sandbox.window.ErgoptiIssueLink) throw new Error('issue_link.js did not define window.ErgoptiIssueLink');
	return sandbox.window.ErgoptiIssueLink;
})();
const corpus = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'tests', 'corpus', 'diagnostics', 'issue_link_vectors.json'), 'utf8')
);

const failures = [];

// Floors: a corpus that parsed to nothing would pass every loop below
if (!Array.isArray(corpus.encode_vectors) || corpus.encode_vectors.length < 5) {
	failures.push('the corpus holds fewer than 5 encoding vectors');
}
if (!Array.isArray(corpus.url_vectors) || corpus.url_vectors.length < 5) {
	failures.push('the corpus holds fewer than 5 URL vectors');
}

for (const vector of corpus.encode_vectors || []) {
	const got = IssueLink.percentEncode(vector.input);
	if (got !== vector.expected) failures.push(`encode ${vector.id}: got ${got}, expected ${vector.expected}`);
}

for (const vector of corpus.url_vectors || []) {
	const templates = Object.assign({}, corpus.templates, { max_url_bytes: vector.max_url_bytes });
	let got;
	let error = null;
	try {
		got = IssueLink.buildIssueUrl(templates, corpus.repository, vector.template, vector.values);
	} catch (caught) {
		error = caught;
	}
	if (vector.expect_error) {
		if (!error) failures.push(`url ${vector.id}: built ${got} where an error was expected`);
		continue;
	}
	if (error) failures.push(`url ${vector.id}: threw ${error.message}`);
	else if (got !== vector.expected) failures.push(`url ${vector.id}: got ${got}, expected ${vector.expected}`);
	else if (got.length > vector.max_url_bytes) failures.push(`url ${vector.id}: over its budget`);
}

// A lone surrogate has no UTF-8 form: it is encoded as U+FFFD, as the AHK port
// does. JSON cannot carry one to the Lua port, so it is pinned here only.
const lone = IssueLink.percentEncode('a\ud800b');
if (lone !== 'a%EF%BF%BDb') failures.push(`a lone surrogate encoded as ${lone}, expected a%EF%BF%BDb`);

if (failures.length > 0) {
	console.error(`[FAIL] issue link vectors: ${failures.length} failure(s)`);
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log(
	`[OK] issue link vectors: ${corpus.encode_vectors.length} encoding and ${corpus.url_vectors.length} URL vector(s) match.`
);
