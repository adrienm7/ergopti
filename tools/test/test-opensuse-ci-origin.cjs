// tools/test/test-opensuse-ci-origin.cjs

/**
 * Guard openSUSE container preparation against redirector mirror skew.
 * Tumbleweed metadata and its referenced objects must come from the same
 * origin; otherwise a freshly pulled image can resolve a current index through
 * download.opensuse.org and receive a stale mirror whose payload is incomplete.
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const pipeline = require('./ci-pipeline.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
// Each source that installs packages in an openSUSE container. The Linux box is
// read through the loader, which throws when its distro job is missing.
const sources = [
	['.github/workflows/ci-linux.yml (job install-linux-distros)', pipeline.job('install-linux-distros')],
	['.github/workflows/linux-layout.yml', fs.readFileSync(path.join(ROOT, '.github/workflows/linux-layout.yml'), 'utf8')],
];
const originRewrite =
	"sed -i 's|http://download.opensuse.org|https://downloadcontent.opensuse.org|g' " +
	'/etc/zypp/repos.d/*.repo && zypper --non-interactive install';

for (const [workflow, source] of sources) {
	const tumbleweed = source.match(
		/image: opensuse\/tumbleweed:latest\r?\n\s+prep: ([^\r\n]+)/
	);
	assert(tumbleweed, `${workflow} must retain its openSUSE Tumbleweed matrix entry`);
	assert(
		tumbleweed[1].startsWith(originRewrite),
		`${workflow} must bypass download.opensuse.org mirror redirects before zypper install`
	);
}

console.log('[OK] openSUSE CI package installs use the coherent download origin.');
