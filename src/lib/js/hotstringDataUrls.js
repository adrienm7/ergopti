// src/lib/js/hotstringDataUrls.js

const hotstringsRoot = '/ergopti_plus/_shared/modules/hotstrings';

/** Return the shared symbols and French demo catalogues in their source order. */
export function getMagicKeyUrls(base) {
	return [`${base}${hotstringsRoot}/magickey.toml`, getFrenchMagicKeyUrl(base)];
}

/** Return the French abbreviation source relative to the configured Svelte base. */
export function getFrenchMagicKeyUrl(base) {
	return `${base}${hotstringsRoot}/french/magickey.toml`;
}
