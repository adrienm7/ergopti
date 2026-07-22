// src/routes/ergopti-plus/locales/en.js

/**
 * ==============================================================================
 * MODULE: Ergopti+ Page — English dictionary
 * DESCRIPTION:
 * Maps each French source string (the key used in `t('…')` calls) to its
 * English translation. A key that is absent here falls back to French, so this
 * file can grow incrementally and a changed French source simply reverts to
 * French until re-translated — no stale text.
 *
 * Keep keys byte-identical to the French in the components (including the
 * typographic apostrophe ’). Placeholders like `{n}` must be preserved.
 * ==============================================================================
 */

export default {
	// ── Top bar ────────────────────────────────────────────────────────────
	'Ancienne version de cette page →': 'Previous version of this page →',

	// ── <head> ─────────────────────────────────────────────────────────────
	'Ergopti+ — la frappe augmentée, gratuite et locale':
		'Ergopti+ — augmented typing, free and local',
	'Ergopti+ transforme votre frappe en temps réel : {n} expansions et corrections, prédictions IA 100 % locales ({m} modèles), tap-holds, gestes trackpad, métriques de frappe. Gratuit et open-source, sur Windows et macOS (Linux en alpha).':
		'Ergopti+ transforms your typing in real time: {n} expansions and corrections, 100% local AI predictions ({m} models), tap-holds, trackpad gestures, typing metrics. Free and open-source, on Windows and macOS (Linux in alpha).',

	// ── Navigation ───────────────────────────────────────────────────────────
	'Pour qui ?': 'Who for?',
	IA: 'AI',
	Raccourcis: 'Shortcuts',
	Métriques: 'Metrics',
	'Vie privée': 'Privacy',
	Réglages: 'Settings',
	'Déjà en Ergopti ?': 'Already on Ergopti?',
	Comparatif: 'Compare',
	Télécharger: 'Download',

	// ── KPI strip ──────────────────────────────────────────────────────────
	'hotstrings prêts à l’emploi': 'ready-to-use hotstrings',
	'modèles d’IA locale au catalogue': 'local AI models in the catalogue',
	'réglages, tous optionnels': 'settings, all optional',
	'langues d’interface': 'interface languages',

	// ── Hero ─────────────────────────────────────────────────────────────────
	'Frappe augmentée': 'Augmented typing',
	'100 % local': '100% local',
	'Tapez moins.': 'Type less.',
	'Écrivez plus.': 'Write more.',
	'transforme votre frappe en temps réel : expansions de texte, autocorrection, prédictions IA locales, tap-holds, gestes trackpad. Pensé pour le français, l’anglais et le code — <strong>gratuit et open-source</strong>.':
		'transforms your typing in real time: text expansions, autocorrection, local AI predictions, tap-holds, trackpad gestures. Built for French, English and code — <strong>free and open-source</strong>.',
	'En bref': 'In brief',
	'Toute disposition': 'Any layout',
	'Installation & comparatif ↓': 'Setup & comparison ↓',
	'Gratuit · Open-source · Aucun compte, aucune télémétrie':
		'Free · Open-source · No account, no telemetry',
	'Télécharger pour macOS': 'Download for macOS',
	'Télécharger pour Linux (alpha)': 'Download for Linux (alpha)',
	'Télécharger pour Windows': 'Download for Windows',
	'Afficher les fenêtres au style Windows (AutoHotkey)':
		'Show the windows in Windows style (AutoHotkey)',
	'Afficher les fenêtres au style macOS (Hammerspoon)':
		'Show the windows in macOS style (Hammerspoon)',
	'Afficher les fenêtres au style Linux (kanata + daemon Lua, alpha)':
		'Show the windows in Linux style (kanata + Lua daemon, alpha)'
};

