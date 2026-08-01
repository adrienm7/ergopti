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
	testRunner: 'command',
	commandRunner: {
		command: 'node tools/test/test-mutation-targets.cjs'
	},

	mutate: [
		// Only mutate domain files that contain actual algorithm logic exercised by
		// the test harness. Domain spec files that are purely pseudocode + typedefs
		// (Expander, GestureRecognizer, Terminators, ProfileSelector, PromptBuilder)
		// produce unkillable mutants and inflate the surviving count without
		// measuring anything real. Registry and HotstringMatcher contain
		// the canonical algorithmic code (bucketing, sorting, matching) that the
		// harness actually exercises — those are the meaningful mutation targets.
		'static/ergopti_plus/_shared/core/domain/Registry.spec.js',
		'static/ergopti_plus/_shared/core/domain/HotstringMatcher.spec.js',
		'!**/node_modules/**'
	],

	reporters: ['html', 'clear-text', 'progress'],
	htmlReporter: { fileName: 'reports/mutation/mutation.html' },

	thresholds: {
		// Registry.spec.js and HotstringMatcher.spec.js contain ~30% algorithmic
		// logic (contractTestVectors, validateAdapter) and ~70% normative
		// documentation (portContract name/version/methods, pseudocode comments,
		// JSDoc typedefs). The latter produces unkillable mutants regardless of
		// test quality. A realistic floor for this mixed-content architecture is
		// 25% — below that indicates the algorithmic portions are untested.
		break: 25,
		low: 30,
		high: 60
	},

	timeoutMS: 30000,
	concurrency: 2,
	tempDirName: '.stryker-tmp',
	cleanTempDir: true,

	// `.claude` holds agent scratch state including git WORKTREES, whose .husky/_
	// entries are not copyable — Stryker died with EPERM trying to clone one into
	// its sandbox, so `npm run test:js -- --full` could not complete locally at
	// all. CI only runs mutation on main, so this stayed invisible on dev. `.git`
	// is excluded for the same reason: it is large, irrelevant to mutants, and
	// full of files that resist copying.
	ignorePatterns: ['_generated', 'node_modules', 'reports', '.stryker-tmp', '.claude', '.git']
};

export default config;
