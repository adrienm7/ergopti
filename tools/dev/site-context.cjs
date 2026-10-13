// tools/dev/site-context.cjs

/** Resolve an attached local branch or an explicit site target bound to the actual Git commit. */
'use strict';

const SITE_LOTS = Object.freeze({
	'Stable site': Object.freeze({ target: 'main', base_path: '' }),
	'Development site': Object.freeze({ target: 'dev', base_path: '/dev' })
});

/** Return the complete authored target map; matrix cells contain only its human keys. */
function siteLots() {
	return structuredClone(SITE_LOTS);
}

/** Resolve a deployment identity to its unique human-readable matrix lot. */
function siteLot(target) {
	const lot = Object.keys(SITE_LOTS).find((key) => SITE_LOTS[key].target === target);
	requireContext(lot !== undefined, 'the target must be main or dev.');
	return lot;
}

/** Refuse altered or incomplete predecessor metadata before using its selected row. */
function selectSiteLot(lot, metadata) {
	requireContext(
		metadata === JSON.stringify(SITE_LOTS),
		'the complete site lot metadata must match its authored source.'
	);
	requireContext(typeof lot === 'string' && Object.hasOwn(SITE_LOTS, lot), 'unknown site lot.');
	return structuredClone(SITE_LOTS[lot]);
}

function requireContext(condition, message) {
	if (!condition) throw new Error('Site build context refused: ' + message);
}

/** Validate the two actual site deployment targets without confusing them with a Git ref. */
function resolveSiteTarget(branch, base) {
	const expected = SITE_LOTS[siteLot(branch)];
	requireContext(base === expected.base_path, 'the target and BASE_PATH must agree explicitly.');
	return { branch, base_path: base };
}

/**
 * Keep the deployment target separate from the source commit, including matrix builds.
 * @param {Record<string, string|undefined>} env Explicit process environment.
 * @param {(args: string[]) => string} git Checked Git command reader.
 * @returns {{branch: string, base_path?: string, source_sha?: string}}
 */
function resolveSiteContext(env, git) {
	const explicit = ['ERGOPTI_SITE_TARGET', 'ERGOPTI_SITE_SOURCE_SHA'].some((key) =>
		Object.hasOwn(env, key)
	);
	if (!explicit) {
		requireContext(env.GITHUB_ACTIONS !== 'true', 'GitHub builds require an explicit site target.');
		const branch = git(['symbolic-ref', '--quiet', '--short', 'HEAD']).trim();
		requireContext(
			branch !== '' && branch !== 'HEAD' && !/[\s\x00-\x1f\x7f]/.test(branch),
			'an attached branch is required for ordinary local use.'
		);
		return { branch };
	}
	requireContext(Object.hasOwn(env, 'BASE_PATH'), 'BASE_PATH must be explicit.');
	const { branch, base_path: base } = resolveSiteTarget(env.ERGOPTI_SITE_TARGET, env.BASE_PATH);
	const source = env.ERGOPTI_SITE_SOURCE_SHA;
	requireContext(
		typeof source === 'string' && /^[a-f0-9]{40}$/.test(source),
		'invalid source SHA.'
	);
	if (env.GITHUB_ACTIONS === 'true' || Object.hasOwn(env, 'GITHUB_SHA'))
		requireContext(env.GITHUB_SHA === source, 'the declared source differs from GitHub context.');
	const actual = git(['rev-parse', '--verify', 'HEAD^{commit}']).trim();
	requireContext(actual === source, 'the declared source differs from the checked-out commit.');
	return { branch, base_path: base, source_sha: actual };
}

module.exports = { resolveSiteContext, resolveSiteTarget, siteLots, siteLot, selectSiteLot };
