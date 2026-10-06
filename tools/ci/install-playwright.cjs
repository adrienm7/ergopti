// tools/ci/install-playwright.cjs
/** Keeps Playwright's pinned native catalogue behind the signed Ubuntu owner. */
'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');

/** Refuses either installed SDK owner when its exact lock binding is missing. */
function pinnedVersion(actual, expected) {
	if (typeof expected !== 'string' || expected.length === 0 || actual !== expected)
		throw new Error('Playwright installed version differs from the lock.');
}

/** Selects canonical prerequisites without a copied package catalogue or OS fallback. */
function prerequisites(platform, official, catalogue, browsers) {
	if (official !== true || !/^ubuntu[\d.]+-(?:x64|arm64)$/.test(platform))
		throw new Error('Playwright dependency acquisition requires a supported Ubuntu host.');
	if (
		!Array.isArray(browsers) ||
		browsers.length === 0 ||
		new Set(browsers).size !== browsers.length ||
		browsers.some((name) => !['chromium', 'webkit'].includes(name))
	)
		throw new Error('Playwright browser selection refused.');
	const selected = catalogue[platform];
	const packages = [];
	for (const name of ['tools', ...browsers]) {
		const group = selected?.[name];
		if (
			!Array.isArray(group) ||
			group.length === 0 ||
			group.some((item) => typeof item !== 'string' || !/^[a-z0-9][a-z0-9+.-]*$/.test(item))
		)
			throw new Error('Playwright native prerequisite catalogue refused.');
		packages.push(...group);
	}
	return [...new Set(packages)];
}

/** A missing terminal result or signal cannot become a successful acquisition. */
function status(result) {
	if (result.error) throw result.error;
	if (result.signal !== null || !Number.isInteger(result.status) || result.status < 0)
		throw new Error('Playwright dependency child has no normal terminal status.');
	return result.status;
}

/** Waits for native dependencies before downloading browsers as the original user. */
function prepare(browsers, ports) {
	const packages = prerequisites(ports.platform, ports.official, ports.catalogue, browsers);
	const acquired = status(
		ports.execute('sudo', [
			'python3',
			path.join(root, 'tools/ci/ubuntu_apt.py'),
			'-y',
			'--no-install-recommends',
			...packages
		])
	);
	if (acquired !== 0) return acquired;
	return status(ports.execute(process.execPath, [ports.cli, 'install', ...browsers]));
}

/** Binds only the installed version from npm ci to its own host and package owners. */
function main(browsers) {
	if (process.platform !== 'linux')
		throw new Error('Native Ubuntu browser preparation requires Linux.');
	const core = path.dirname(require.resolve('playwright-core/package.json'));
	const installed = require(path.join(core, 'package.json'));
	const cliRoot = path.dirname(require.resolve('playwright/package.json'));
	const cliPackage = require(path.join(cliRoot, 'package.json'));
	const pinned = require('../../package-lock.json').packages;
	pinnedVersion(installed.version, pinned['node_modules/playwright-core'].version);
	pinnedVersion(cliPackage.version, pinned['node_modules/playwright'].version);
	const host = require(path.join(core, 'lib/server/utils/hostPlatform.js'));
	const catalogue = require(path.join(core, 'lib/server/registry/nativeDeps.js')).deps;
	return prepare(browsers, {
		platform: host.hostPlatform,
		official: host.isOfficiallySupportedPlatform,
		catalogue,
		cli: path.join(cliRoot, 'cli.js'),
		execute: (executable, arguments_) => spawnSync(executable, arguments_, { stdio: 'inherit' })
	});
}

module.exports = { pinnedVersion, prerequisites, prepare, main };
if (require.main === module) {
	try {
		process.exitCode = main(process.argv.slice(2));
	} catch (failure) {
		console.error(failure.message);
		process.exitCode = 1;
	}
}
