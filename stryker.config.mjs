// stryker.config.mjs

/**
 * ==============================================================================
 * MODULE: Stryker Mutation Testing Configuration
 * DESCRIPTION:
 * Configures Stryker to run mutation testing against the JS domain layer.
 * Targets the reference implementations in test-mutation-targets.cjs, which
 * exercise the Registry tail-char bucketing, HotstringMatcher algorithm, and
 * Expander decide/cycle logic.
 *
 * FEATURES & RATIONALE:
 * 1. Command runner: no test framework adapter needed — scripts run via Node
 *    directly, so the built-in "command" runner handles execution.
 * 2. Focused mutants: only domain and port spec files are mutated; generated
 *    code and node_modules are excluded to avoid noise.
 * 3. Thresholds: break=50, low=65, high=80 — a score below 50% fails the run,
 *    signalling that the test suite does not adequately guard the domain logic.
 * ==============================================================================
 */

/** @type {import('@stryker-mutator/core').PartialStrykerOptions} */
const config = {
	testRunner:  "command",
	commandRunner: {
		command: "node tools/test/test-mutation-targets.cjs",
	},

	mutate: [
		"static/ergopti_plus/shared/domain/**/*.js",
		"static/ergopti_plus/shared/ports/**/*.spec.js",
		"!static/ergopti_plus/shared/**/_generated/**",
		"!**/node_modules/**",
	],

	reporters:    ["html", "clear-text", "progress"],
	htmlReporter: { fileName: "reports/mutation/mutation.html" },

	thresholds: {
		break: 50,
		low:   65,
		high:  80,
	},

	timeoutMS:     30000,
	concurrency:   2,
	tempDirName:   ".stryker-tmp",
	cleanTempDir:  true,

	ignorePatterns: [
		"_generated",
		"node_modules",
		"reports",
		".stryker-tmp",
	],
};

export default config;
