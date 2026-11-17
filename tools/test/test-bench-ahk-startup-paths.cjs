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
 *
 * The first boot of a fresh private code copy rebuilds the hotstring and locale
 * caches that an installed driver reuses (about 1 s on the maintainer's PC), so
 * one warm-up boot runs by default and stays out of the summary.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const AppDirs = require('./lib/app-dirs.cjs');
const {
	benchmarkFixturePaths,
	parseArgs,
	summarizeSamples
} = require('../dev/bench-ahk-startup.cjs');

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

// perf-bench-warm-caches-2026-11-17: the cold first boot of a private copy is
// not the boot an installed driver makes; it is a warm-up, not a sample.
assert.equal(parseArgs(['--config-dir=x']).warmup, 1, 'one warm-up boot by default');
assert.equal(parseArgs(['--config-dir=x', '--warmup=0']).warmup, 0, 'a cold boot stays measurable');
assert.throws(() => parseArgs(['--config-dir=x', '--warmup=-1']), /--warmup/);
assert.throws(() => parseArgs(['--config-dir=x', '--warm']), /Usage/);
const summary = summarizeSamples([
	{ elapsed_ms: 20000, warmup: true },
	{ elapsed_ms: 9000, warmup: false },
	{ elapsed_ms: 11000, warmup: false },
	{ elapsed_ms: 10000, warmup: false }
]);
assert.deepEqual(
	summary,
	{ samples: 3, warmup: 1, median_ms: 10000, max_ms: 11000, min_ms: 9000 },
	'the warm-up boot is printed but never summarized'
);
assert.throws(() => summarizeSamples([{ elapsed_ms: 1, warmup: true }]), /No measured sample/);
console.log('[OK] startup benchmark warm-up boots stay out of the summary.');
