// tools/test/test-bootstrap-retry-projection.cjs
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const generator = require('../codegen/codegen-bootstrap-retry.cjs');
const raw = fs.readFileSync(path.join(root, generator.SOURCE), 'utf8');
const shell = fs.readFileSync(path.join(root, generator.SHELL), 'utf8');
const frozen = {
	schema_version: 1,
	admission_seconds: 30,
	idle_seconds: 60,
	retirement_seconds: 600
};
assert.deepEqual(JSON.parse(raw), frozen);
const rendered = generator.render(raw, shell);
assert.equal(rendered[generator.SHELL], shell);
assert.match(rendered[generator.LUA], /admission_seconds = 30/);
for (const field of ['admission_seconds', 'idle_seconds', 'retirement_seconds']) {
	const changed = { ...frozen, [field]: true };
	assert.throws(() => generator.render(JSON.stringify(changed, null, '\t') + '\n', shell));
}
assert.throws(() =>
	generator.render(
		raw.replace('"schema_version": 1,', '"schema_version": 1, "schema_version": 1,'),
		shell
	)
);
assert.throws(() => generator.render(raw, shell + '\nCURL_STALL_SEC=60\n'));
const changed = { ...frozen, admission_seconds: 31 };
const successor = generator.render(JSON.stringify(changed, null, '\t') + '\n', shell);
assert.equal(
	successor[generator.SHELL].replace('CURL_CONNECT_TIMEOUT_SEC=31', 'CURL_CONNECT_TIMEOUT_SEC=30'),
	shell
);
generator.generate(root, { check: true });
console.log(
	'PASS original 30/60/600, full shell preservation, three bool refusals, duplicate JSON/shell, narrow mutation, drift check'
);
