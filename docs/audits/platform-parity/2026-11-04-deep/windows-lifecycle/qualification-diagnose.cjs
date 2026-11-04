'use strict';
// Load the unmodified baseline test with one observational print in memory.
// Assertions, production modules, fixtures and their digests stay unchanged.
const fs = require('node:fs');
const Module = require('node:module');
const file = '/workspace/ergopti/tools/test/test-windows-updater-original-source.cjs';
const original = fs.readFileSync(file, 'utf8');
const needle = 'assert.equal(modeled.calls.length, 3);';
if (original.split(needle).length !== 2) throw new Error('Observation anchor is not unique');
const observed = original.replace(
	needle,
	`process.stderr.write('MODEL_DIAGNOSTIC ' + JSON.stringify({calls: modeled.calls.length, errors: modeled.receipt.errors, status: modeled.receipt.status, sdk: modeled.receipt.sdk_before, stderr: modeled.stderr, exits: modeled.exits}) + '\\n');\n${needle}`
);
const subject = new Module(file, module);
subject.filename = file;
subject.paths = Module._nodeModulePaths('/workspace/ergopti/tools/test');
subject._compile(observed, file);
