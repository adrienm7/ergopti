// tools/test/test-bench-ahk-startup-paths.cjs

/**
 * ==============================================================================
 * MODULE: Startup Benchmark Fixture Paths Tests
 * DESCRIPTION:
 * tools/dev/bench-ahk-startup.cjs boots the driver with LOCALAPPDATA set to a
 * private fixture. It wrote paths.toml at the fixture root and read the logs
 * from <fixture>\ergopti_plus\logs, the layout before the one-folder rename:
 * the driver then ignored the copied configuration and the benchmark failed on
 * a missing logs folder after a successful boot. Both paths now come from
 * app_dirs.toml, the declaration the driver and the startup smoke read.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const AppDirs = require('./lib/app-dirs.cjs');
const { benchmarkFixturePaths } = require('../dev/bench-ahk-startup.cjs');

const fixture = path.join('C:', 'private', 'fixture');
const { pathsFile, logDir } = benchmarkFixturePaths(fixture);

assert.equal(
	pathsFile,
	path.join(fixture, ...AppDirs.segments('config.windows', 'windows', 'paths_file')),
	'paths.toml is where the driver looks for it below %LOCALAPPDATA%'
);
assert.equal(
	logDir,
	path.join(fixture, ...AppDirs.segments('logs.windows', 'windows')),
	'the logs folder is the one the driver writes below %LOCALAPPDATA%'
);
assert.notEqual(path.dirname(pathsFile), fixture, 'paths.toml is inside the application folder');
console.log('[OK] startup benchmark fixture paths follow app_dirs.toml.');
