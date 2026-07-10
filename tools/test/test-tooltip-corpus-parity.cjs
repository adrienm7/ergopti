/**
 * ==============================================================================
 * ESCROW: Tooltip corpus structural validation gate
 * DESCRIPTION:
 * Validates that the shared JSON corpus files
 * (_shared/tests/corpus/tooltip/layout_vectors.json and dequeue_vectors.json)
 * exist, parse correctly, and have the expected vector count and structure.
 *
 * The JS source-of-truth functions (layoutTestVectors / dequeueTestVectors in
 * _shared/modules/tooltip/) export 6 layout vectors and 3 dequeue vectors.
 * The JSON corpus is the frozen canonical form consumed by the macOS and AHK
 * test suites — this gate ensures it stays present and well-formed.
 *
 * ROOT CAUSE ENCODED:
 * The layoutTestVectors() and dequeueTestVectors() JS sinks were consumed by
 * zero cross-driver tests — only the macOS dequeue contract consumed
 * hardcoded copies. This gate ensures the shared JSON corpus files exist and
 * have the right shape so both drivers load from the same source.
 * ==============================================================================
 */

const assert     = require("node:assert").strict;
const { readFileSync } = require("node:fs");
const path       = require("node:path");

const root = path.resolve(__dirname, "../../static/ergopti_plus");

// ── Layout corpus ──
const layoutPath = path.resolve(root, "_shared/tests/corpus/tooltip/layout_vectors.json");
const layoutCorpus = JSON.parse(readFileSync(layoutPath, "utf-8"));

assert.ok(typeof layoutCorpus.description === "string" && layoutCorpus.description.length > 0,
	"layout corpus must have a description");
assert.ok(Array.isArray(layoutCorpus.vectors),
	"layout corpus must have a vectors array");
assert.strictEqual(layoutCorpus.vectors.length, 6,
	"layout corpus must have exactly 6 vectors (matching layoutTestVectors())");

for (let i = 0; i < layoutCorpus.vectors.length; i++) {
	const v = layoutCorpus.vectors[i];
	assert.ok(typeof v.id === "string" && v.id.length > 0,
		`layout vector[${i}] must have a string id`);
	assert.ok(typeof v.description === "string",
		`layout vector[${i}] must have a description`);
	assert.ok(typeof v.expected === "object" && typeof v.expected.x === "number" && typeof v.expected.y === "number",
		`layout vector[${i}] (${v.id}) must have expected {x, y}`);
	assert.ok(typeof v.canvasSize === "object" && typeof v.canvasSize.w === "number" && typeof v.canvasSize.h === "number",
		`layout vector[${i}] (${v.id}) must have canvasSize {w, h}`);
	assert.ok(typeof v.screenFrame === "object" && typeof v.screenFrame.w === "number" && typeof v.screenFrame.h === "number",
		`layout vector[${i}] (${v.id}) must have screenFrame {x, y, w, h}`);
}

// ── Dequeue corpus ──
const dequeuePath = path.resolve(root, "_shared/tests/corpus/tooltip/dequeue_vectors.json");
const dequeueCorpus = JSON.parse(readFileSync(dequeuePath, "utf-8"));

assert.ok(typeof dequeueCorpus.description === "string" && dequeueCorpus.description.length > 0,
	"dequeue corpus must have a description");
assert.ok(Array.isArray(dequeueCorpus.vectors),
	"dequeue corpus must have a vectors array");
assert.strictEqual(dequeueCorpus.vectors.length, 3,
	"dequeue corpus must have exactly 3 vectors (matching dequeueTestVectors())");

for (let i = 0; i < dequeueCorpus.vectors.length; i++) {
	const v = dequeueCorpus.vectors[i];
	assert.ok(typeof v.id === "string" && v.id.length > 0,
		`dequeue vector[${i}] must have a string id`);
	assert.ok(typeof v.description === "string",
		`dequeue vector[${i}] must have a description`);
	assert.ok(Array.isArray(v.rows) && v.rows.length > 0,
		`dequeue vector[${i}] (${v.id}) must have a non-empty rows array`);
	assert.ok(typeof v.expectDequeue === "boolean",
		`dequeue vector[${i}] (${v.id}) must have expectDequeue boolean`);
	if (v.steps) {
		assert.ok(Array.isArray(v.steps),
			`dequeue vector[${i}] (${v.id}) steps must be an array`);
		for (const step of v.steps) {
			assert.ok(typeof step.action === "string",
				`step in ${v.id} must have action string`);
		}
	}
}
