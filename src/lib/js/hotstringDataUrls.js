// src/lib/js/hotstringDataUrls.js

const hotstringsRoot = 'ergopti_plus/_shared/modules/hotstrings';

/**
 * Return the shared symbols and French demo catalogues in their source order.
 * @param {(file: string) => string} asset - The $app/paths static-file resolver.
 * @returns {string[]}
 */
export function getMagicKeyUrls(asset) {
	return [asset(`${hotstringsRoot}/magickey.toml`), getFrenchMagicKeyUrl(asset)];
}

/**
 * Return the French abbreviation source under the configured Svelte base.
 * @param {(file: string) => string} asset - The $app/paths static-file resolver.
 * @returns {string}
 */
export function getFrenchMagicKeyUrl(asset) {
	return asset(`${hotstringsRoot}/french/magickey.toml`);
}
