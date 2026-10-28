// tools/test/lib/app-cloner-native-stat-port.cjs

/** Shared fixture for the App Cloner's native BSD stat command boundary. */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function resolvePython() {
	for (const candidate of ['python3', 'python']) {
		const result = spawnSync(candidate, ['--version'], { encoding: 'utf8' });
		if (!result.error && result.status === 0) return candidate;
	}
	throw new Error('Required Python interpreter unavailable for the native stat fixture');
}

function resolvePythonForBash(bash, python) {
	const result = spawnSync(bash, ['-c', 'command -v "$1"', 'python-runtime', python], {
		encoding: 'utf8'
	});
	if (result.status !== 0 || !result.stdout.trim()) {
		throw new Error(`Required Python unavailable in Bash: ${result.stderr}`);
	}
	return result;
}

function createNativeStatResources({ resources, fixtureRoot, toBashPath }) {
	const portResources = path.join(fixtureRoot, 'native-stat-port-resources');
	fs.mkdirSync(portResources);
	for (const name of [
		'clone_app.sh',
		'make_shortcut.sh',
		'reserve_bundle.sh',
		'quote_launcher_values.py'
	]) {
		fs.copyFileSync(path.join(resources, name), path.join(portResources, name));
	}
	const statQuery = path.join(fixtureRoot, 'native-stat-query.py');
	fs.writeFileSync(
		statQuery,
		`import os, sys
if len(sys.argv) != 4 or sys.argv[1:3] != ['-f', '%d:%i']:
    sys.exit('Invalid native stat boundary arguments')
if os.environ.get('OWNED_STAT_FAULT') == 'capture':
    sys.exit('owned-identity-capture-failure')
entry = os.lstat(sys.argv[3])
print(f'{entry.st_dev}:{entry.st_ino}')
`
	);
	const statPort = path.join(fixtureRoot, 'native-stat-port');
	fs.writeFileSync(statPort, '#!/bin/sh\nexec "$REAL_PYTHON" "$OWNED_STAT_QUERY" "$@"\n');
	fs.chmodSync(statPort, 0o755);
	const source = fs.readFileSync(path.join(resources, 'reserve_bundle.sh'), 'utf8');
	// Port only the command: real filesystem identity, guards and cleanup stay
	// owned by the shipped source. Unexpected flags fail instead of falling back.
	fs.writeFileSync(
		path.join(portResources, 'reserve_bundle.sh'),
		source.replaceAll('/usr/bin/stat', `'${toBashPath(statPort).replaceAll("'", "'\\''")}'`)
	);
	return {
		statQuery,
		portedCloneScript: path.join(portResources, 'clone_app.sh'),
		portedShortcutScript: path.join(portResources, 'make_shortcut.sh')
	};
}

module.exports = { resolvePython, resolvePythonForBash, createNativeStatResources };
