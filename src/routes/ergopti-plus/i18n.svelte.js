// src/routes/ergopti-plus/i18n.svelte.js

/**
 * ==============================================================================
 * MODULE: Ergopti+ Page — Extensible gettext-style i18n
 * DESCRIPTION:
 * A tiny, reactive translation layer designed so that adding languages later is
 * trivial and so that changing the (French) source text can never leave a stale
 * translation on screen.
 *
 * HOW IT WORKS (gettext model):
 *   - The KEY is the French source string itself: `t('Bonjour')`.
 *   - French is implicit — `t()` returns the key verbatim when lang === 'fr'.
 *   - Other languages live in per-language dictionaries mapping the French
 *     source → the translation (see ./locales/en.js).
 *   - A missing key falls back to French. So if the French wording is edited,
 *     the old translation stops matching and the (new) French shows instead —
 *     no stale text, ever. Re-translate at leisure by adding the new key.
 *
 * ADDING A LANGUAGE (e.g. German):
 *   1. Create ./locales/de.js exporting `{ 'source FR': 'Übersetzung', … }`.
 *   2. Register it in TRANSLATIONS and AVAILABLE_LANGS below.
 *   Nothing at any call site changes; the selector and auto-detection pick it
 *   up automatically.
 *
 * INTERPOLATION:
 *   Use `{name}` placeholders and pass values: `t('Salut {name}', {name})`.
 *   The placeholder survives translation, so the same call works in every
 *   language.
 * ==============================================================================
 */

import en from './locales/en.js';

/** Storage key for the persisted language choice. */
const LANG_STORAGE_KEY = 'ergoptiplus.lang';

// Non-French dictionaries, keyed by the French source string. Add a language
// here (and to AVAILABLE_LANGS) — call sites never change.
const TRANSLATIONS = { en };

/**
 * Languages offered by the selector, in display order. French is always the
 * source. Extend this list to expose a new language.
 * @type {Array<{code: string, label: string}>}
 */
export const AVAILABLE_LANGS = [
	{ code: 'fr', label: 'FR' },
	{ code: 'en', label: 'EN' }
];

/** Reactive UI language for the whole Ergopti+ page. */
export const i18n = $state({
	/** @type {string} A code present in AVAILABLE_LANGS. */
	lang: 'fr'
});

/**
 * Translate a French source string, with optional `{placeholder}` values.
 * @param {string} fr The French source string (also the translation key).
 * @param {Record<string, string|number>} [vars] Values for `{name}` placeholders.
 * @returns {string}
 */
export function t(fr, vars) {
	let out = i18n.lang === 'fr' ? fr : (TRANSLATIONS[i18n.lang]?.[fr] ?? fr);
	if (vars) {
		for (const key of Object.keys(vars)) {
			out = out.replaceAll('{' + key + '}', String(vars[key]));
		}
	}
	return out;
}

/**
 * Set the active language and persist the explicit choice.
 * @param {string} next A code present in AVAILABLE_LANGS.
 */
export function setLang(next) {
	i18n.lang = AVAILABLE_LANGS.some((l) => l.code === next) ? next : 'fr';
	try {
		localStorage.setItem(LANG_STORAGE_KEY, i18n.lang);
	} catch (_) {
		/* localStorage may be unavailable — the choice just won't persist. */
	}
}

/**
 * Restore the persisted language if any, otherwise detect it from the browser
 * (its two-letter code), defaulting to French. Called once from onMount.
 */
export function restoreLang() {
	let stored = null;
	try {
		stored = localStorage.getItem(LANG_STORAGE_KEY);
	} catch (_) {
		/* ignore */
	}
	if (AVAILABLE_LANGS.some((l) => l.code === stored)) {
		i18n.lang = stored;
		return;
	}
	const code = typeof navigator !== 'undefined' ? (navigator.language || '').slice(0, 2).toLowerCase() : '';
	i18n.lang = AVAILABLE_LANGS.some((l) => l.code === code) ? code : 'fr';
}
