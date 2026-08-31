// tools/test/test-node-runtime-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Node Runtime Single-Source Guard
 * DESCRIPTION:
 * Keeps every GitHub workflow on the exact Node runtime used by generators.
 * A floating major upgraded CI's Unicode database while local generation still
 * used the reviewed version, so drift checks failed before any driver job ran.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const WORKFLOWS = path.join(ROOT, '.github', 'workflows');
const VERSION_FILE = path.join(ROOT, '.node-version');
const UNICODE_GENERATOR = path.join(ROOT, 'tools', 'codegen', 'codegen-unicode-case-linux.cjs');
const errors = [];

const pinnedVersion = fs.readFileSync(VERSION_FILE, 'utf8').trim();
if (!/^\d+\.\d+\.\d+$/.test(pinnedVersion)) {
	errors.push(`.node-version must contain one exact semantic version, got '${pinnedVersion}'`);
}

const workflowFiles = fs.readdirSync(WORKFLOWS)
	.filter((name) => /\.ya?ml$/.test(name))
	.map((name) => path.join(WORKFLOWS, name));
let setupCount = 0;
let filePinCount = 0;
let inlineVersionCount = 0;
for (const workflowFile of workflowFiles) {
	const source = fs.readFileSync(workflowFile, 'utf8');
	setupCount += (source.match(/uses:\s*actions\/setup-node@/g) ?? []).length;
	filePinCount += (source.match(/node-version-file:\s*['"]\.node-version['"]/g) ?? []).length;
	inlineVersionCount += (source.match(/node-version:\s*/g) ?? []).length;
}

if (setupCount < 10) {
	errors.push(`only ${setupCount} setup-node steps were found; the workflow scan is incomplete`);
}
if (filePinCount !== setupCount || inlineVersionCount !== 0) {
	errors.push(
		`all ${setupCount} setup-node steps must read .node-version; found ${filePinCount} file pins and ` +
		`${inlineVersionCount} inline versions`
	);
}

const generatorSource = fs.readFileSync(UNICODE_GENERATOR, 'utf8');
const expectedUnicode =
	(generatorSource.match(/EXPECTED_UNICODE_VERSION\s*=\s*['"]([^'"]+)['"]/) ?? [])[1] ?? '';
if (!expectedUnicode) {
	errors.push('the Linux Unicode generator no longer declares its reviewed Unicode version');
}
if (process.version !== `v${pinnedVersion}`) {
	errors.push(`the active Node ${process.version} does not match the repository pin v${pinnedVersion}`);
}
if (expectedUnicode && process.versions.unicode !== expectedUnicode) {
	errors.push(
		`pinned Node ${pinnedVersion} exposes Unicode ${process.versions.unicode}, but the generator requires ` +
		`${expectedUnicode}`
	);
}

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}

console.log(
	`[OK] ${setupCount} setup-node steps read Node ${pinnedVersion} from .node-version ` +
		`(Unicode ${expectedUnicode}).`
);
