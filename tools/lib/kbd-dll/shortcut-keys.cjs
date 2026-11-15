// tools/lib/kbd-dll/shortcut-keys.cjs

/**
 * ==============================================================================
 * MODULE: Windows Shortcut Keys (Virtual-Key Exchange)
 * DESCRIPTION:
 * Carries a layout source's `keys.<physical>.shortcut_key` into a Windows
 * keyboard layout: Windows matches Ctrl, Alt and Win shortcuts on the virtual
 * key a physical key sends, so the key takes the virtual key of the key it
 * names. The KLC generator (tools/codegen/lib/windows-keyboard-layout.cjs) and
 * the DLL tables (source.cjs) both apply this one rule.
 *
 * FEATURES & RATIONALE:
 * 1. An exchange, never a share: kbd.h keys every character table by virtual
 *    key, so two physical keys of one virtual key would type the same
 *    characters. The named key takes a virtual key a claiming key frees; when
 *    the two keys name each other the exchange is exact, otherwise the named
 *    key's own shortcuts move, which the result lists as `displaced`.
 * 2. Fail fast and say it: a pair whose key or named key types no character
 *    (no row of its own), or whose named key another pair already took, is
 *    refused with a stable reason instead of being approximated.
 * 3. Pure and dependency-free: the layout editor page loads it in both bundles.
 * ==============================================================================
 */

'use strict';

/**
 * The virtual key of every key once the shortcut keys are carried.
 * @param {{code: string, vk: *}[]} keys - The character keys in row order, each
 *   with the virtual key the layout gives it; every vk is distinct.
 * @param {{key: string, shortcut_key: string}[]} pairs - The source's shortcut keys.
 * @returns {{vks: Map<string, *>, carried: object[], displaced: object[], refused: object[]}}
 *   vks: code -> virtual key; carried: {key, shortcut_key, vk}; displaced: {key, vk, by}
 *   (a named key that now sends another virtual key); refused: {key, shortcut_key, reason}.
 */
function exchangeVirtualKeys(keys, pairs) {
	const vks = new Map(keys.map((key) => [key.code, key.vk]));
	if (vks.size !== keys.length) throw new Error('a character key is listed twice');
	if (new Set(vks.values()).size !== keys.length)
		throw new Error('two character keys share a virtual key');
	const carried = [];
	const refused = [];
	const claimedVk = new Map();
	for (const pair of pairs) {
		if (!vks.has(pair.key) || !vks.has(pair.shortcut_key)) {
			refused.push(Object.assign({}, pair, { reason: 'shortcut_key_not_a_character_key' }));
			continue;
		}
		const vk = vks.get(pair.shortcut_key);
		if (claimedVk.has(vk)) {
			refused.push(Object.assign({}, pair, { reason: 'shortcut_key_virtual_key_taken' }));
			continue;
		}
		claimedVk.set(vk, pair.key);
		carried.push({ key: pair.key, shortcut_key: pair.shortcut_key, vk });
	}
	const claimers = new Set(carried.map((entry) => entry.key));
	// The virtual keys claimers free, in row order, go to the keys that lost theirs.
	const freed = keys.filter((key) => claimers.has(key.code) && !claimedVk.has(key.vk));
	const losers = keys.filter((key) => !claimers.has(key.code) && claimedVk.has(key.vk));
	const displaced = losers.map((key, index) => ({
		key: key.code,
		vk: freed[index].vk,
		by: claimedVk.get(key.vk)
	}));
	for (const entry of carried) vks.set(entry.key, entry.vk);
	for (const entry of displaced) vks.set(entry.key, entry.vk);
	return { vks, carried, displaced, refused };
}

/**
 * The shortcut-key pairs of a validated layout source, in key order.
 * @param {object} source - A validated structured source.
 * @returns {{key: string, shortcut_key: string}[]}
 */
function shortcutPairs(source) {
	return Object.entries(source.keys || {})
		.filter(([, fields]) => typeof fields.shortcut_key === 'string')
		.map(([key, fields]) => ({ key, shortcut_key: fields.shortcut_key }));
}

module.exports = { exchangeVirtualKeys, shortcutPairs };
