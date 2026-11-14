// tools/test/test-ahk-os-purity-platform.cjs

/**
 * ==============================================================================
 * MODULE: Windows OS-Purity Ratchet Platform Domains
 * DESCRIPTION:
 * The structure plan homes a driver's OS bindings in platform/<domain>/, which
 * has no adapters/ role folder (S14 to S17 move Windows adapters there). The
 * OS-purity ratchets exempt adapters/ by folder, so without a rule those
 * bindings would count as modules+lib code and raise the ratchet at every
 * platform step. The ratchet treats the plan's platform domains as the same
 * isolation layer (decided by the coordinator on 2026-11-14, to review by the
 * maintainer). Its domain list must stay the plan's, and its file walk must
 * apply it.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const Rules = require('../audit/structure/rules.cjs');

const ROOT = path.resolve(__dirname, '..', '..');

function ratchetSource() {
	const tracked = execFileSync('git', ['ls-files', 'static/ergopti_plus/windows/tests'], {
		cwd: ROOT,
		encoding: 'utf8'
	})
		.split('\n')
		.filter((f) => f.endsWith('/test_ahk_os_purity_ratchet.ahk'));
	assert.equal(tracked.length, 1, 'one OS-purity ratchet source');
	return fs.readFileSync(path.join(ROOT, tracked[0]), 'utf8');
}

function run() {
	const source = ratchetSource();
	const declared = source.match(/^_AOPR_PLATFORM_DOMAINS := \[([^\]]*)\]$/m);
	assert.ok(declared, 'the ratchet declares its platform domains');
	const domains = [...declared[1].matchAll(/"([a-z_]+)"/g)].map((m) => m[1]);
	assert.deepEqual(domains, Rules.PLATFORM_DOMAINS, "the ratchet's domains are the plan's");
	const walk = source.match(/^_AOPR_FilesIn\(SubDirs\) \{[\s\S]*?^\}/m);
	assert.ok(walk, 'the ratchet walks its trees in _AOPR_FilesIn');
	assert.match(
		walk[0],
		/_AOPR_IsPlatformAdapter\(A_LoopFilePath\)/,
		'the walk skips platform domains'
	);
	console.log('[OK] the OS-purity ratchet exempts the plan platform domains as adapters/.');
}

run();
