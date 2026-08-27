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

const ROOT = path.resolve(__dirname, '..', '..');
const workflows = [
	'.github/workflows/ci.yml',
	'.github/workflows/linux-layout.yml',
];
const originRewrite =
	"sed -i 's|http://download.opensuse.org|https://downloadcontent.opensuse.org|g' " +
	'/etc/zypp/repos.d/*.repo && zypper --non-interactive install';

for (const workflow of workflows) {
	const source = fs.readFileSync(path.join(ROOT, workflow), 'utf8');
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
