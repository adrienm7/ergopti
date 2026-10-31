// tools/test/lib/git-safe-directory.cjs

/**
 * ==============================================================================
 * MODULE: Checkout Trust for Child Git Calls
 * DESCRIPTION:
 * A gate run by a user who does not own the checkout (a cloud container that
 * clones as root and tests as a normal user) sees every child `git` refuse the
 * repository as "dubious ownership". The gate then stops on a Git error that
 * says nothing about the code it tests.
 *
 * FEATURES & RATIONALE:
 * 1. One repository, one gate. The entry trusts only the given checkout, and
 *    only for the gate's own process and its children: nothing is written to
 *    the user's Git configuration.
 * 2. Command scope. Git reads safe.directory only from protected configuration;
 *    GIT_CONFIG_COUNT entries are command-line configuration, so they count,
 *    and every child that inherits the environment gets them.
 * 3. Existing entries are kept. A caller's own GIT_CONFIG_KEY_n / VALUE_n
 *    survive; the new entry takes the next index.
 * ==============================================================================
 */

'use strict';

/**
 * Returns the environment variables that trust one checkout for child Git calls.
 * @param {Object<string, string|undefined>} environment The current environment.
 * @param {string} checkout Absolute path of the repository root.
 * @returns {Object<string, string>} The variables to add to the environment.
 */
function trustCheckout(environment, checkout) {
	if (
		typeof checkout !== 'string' ||
		(!checkout.startsWith('/') && !/^[A-Za-z]:[\\/]/.test(checkout))
	)
		throw new Error('trustCheckout needs the absolute path of the checkout');
	const raw = environment.GIT_CONFIG_COUNT;
	const count = raw === undefined || raw === '' ? 0 : Number(raw);
	if (!Number.isInteger(count) || count < 0)
		throw new Error(`GIT_CONFIG_COUNT is not a count: ${JSON.stringify(raw)}`);
	return {
		GIT_CONFIG_COUNT: String(count + 1),
		[`GIT_CONFIG_KEY_${count}`]: 'safe.directory',
		[`GIT_CONFIG_VALUE_${count}`]: checkout
	};
}

module.exports = { trustCheckout };
