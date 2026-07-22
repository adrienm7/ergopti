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
		'Show the windows in Linux style (kanata + Lua daemon, alpha)',
	'Découvrir les fonctionnalités': 'Discover the features',

	// ── Promises ─────────────────────────────────────────────────────────────
	'Trois promesses': 'Three promises',
	'Une suite riche, jamais envahissante.': 'A rich suite that never gets in the way.',
	'Utile dès la première heure': 'Useful from the first hour',
	'Apostrophes typographiques, accents, expansions classiques : l’essentiel du gain est livré <strong>par défaut</strong>, sans rien apprendre. Vous tapez normalement, le reste se règle tout seul.':
		'Typographic apostrophes, accents, classic expansions: most of the gain ships <strong>by default</strong>, with nothing to learn. You type normally, the rest takes care of itself.',
	'Progressif, jamais imposé': 'Progressive, never imposed',
	'Chaque fonctionnalité est <strong>activable indépendamment</strong>. Démarrez avec les hotstrings, ajoutez les tap-holds plus tard, l’IA en bonus. Tout se désactive d’un clic.':
		'Every feature can be <strong>enabled independently</strong>. Start with hotstrings, add tap-holds later, AI as a bonus. Everything switches off in one click.',
	'Toutes les dispositions': 'Every layout',
	'AZERTY, QWERTY, Bépo, Dvorak… Le driver agit sur le <strong>texte produit</strong>, pas sur la touche physique. Gardez votre layout — ou adoptez Ergopti pour le combo idéal.':
		'AZERTY, QWERTY, Bépo, Dvorak… The driver acts on the <strong>text produced</strong>, not the physical key. Keep your layout — or adopt Ergopti for the ideal combo.',

	// ── Personas ─────────────────────────────────────────────────────────────
	'Chacun y gagne, à sa façon.': 'Everyone gains, their own way.',
	'Ergopti+ n’impose pas une manière de travailler — il accélère la vôtre. Quelques exemples.':
		'Ergopti+ doesn’t impose a way of working — it accelerates yours. A few examples.',
	Développeur: 'Developer',
	'Symboles de code en roulements (<code>=></code>, <code>!=</code>), snippets de boilerplate, ouverture de chemins de fichiers, et une IA locale qui complète sans jamais envoyer votre code ailleurs.':
		'Code symbols as rolls (<code>=></code>, <code>!=</code>), boilerplate snippets, opening file paths, and a local AI that completes without ever sending your code anywhere.',
	Rédacteur: 'Writer',
	'Autocorrection en continu, signatures et formules en une abréviation, apostrophes typographiques automatiques, et des prédictions qui terminent vos phrases.':
		'Continuous autocorrection, signatures and set phrases in one abbreviation, automatic typographic apostrophes, and predictions that finish your sentences.',
	Multilingue: 'Multilingual',
	'FR/EN et bien plus : corrections et prédictions bilingues, symboles et accents à portée de doigt, interface en 21 langues.':
		'FR/EN and beyond: bilingual corrections and predictions, symbols and accents at your fingertips, interface in 21 languages.',
	'Ergonomie & confort': 'Ergonomics & comfort',
	'Tap-holds pour garder les mains au repos, layer de navigation sans flèches, gestes trackpad, et des métriques pour voir vos progrès.':
		'Tap-holds to keep your hands at rest, a navigation layer without arrow keys, trackpad gestures, and metrics to watch your progress.',

	// ── Getting started ──────────────────────────────────────────────────────
	'Prise en main': 'Getting started',
	'Opérationnel en trois minutes.': 'Up and running in three minutes.',
	'Pas de configuration obligatoire, pas de courbe d’apprentissage : ça marche dès le lancement, et ça grandit avec vous.':
		'No mandatory configuration, no learning curve: it works from launch, and grows with you.',
	'Téléchargez et lancez': 'Download and launch',
	'Un exécutable pour Windows, une app pour macOS. Aucun compte, aucun droit administrateur nécessaire dans la plupart des cas.':
		'One executable for Windows, one app for macOS. No account, no administrator rights needed in most cases.',
	'Tapez comme d’habitude': 'Type as usual',
	'Rien à réapprendre. Vos hotstrings, corrections et prédictions sont actifs immédiatement, sur votre disposition actuelle.':
		'Nothing to relearn. Your hotstrings, corrections and predictions are active immediately, on your current layout.',
	'Ajustez à votre rythme': 'Tune at your own pace',
	'Activez une fonctionnalité à la fois depuis le menu — tap-holds, gestes, IA. Rien n’est imposé, tout est optionnel.':
		'Enable one feature at a time from the menu — tap-holds, gestures, AI. Nothing is imposed, everything is optional.',

	// ── Privacy ──────────────────────────────────────────────────────────────
	'Puissant parce que local. Pas malgré ça.': 'Powerful because it’s local. Not in spite of it.',
	'Le pari d’Ergopti+ : tout ce qui rend la frappe plus intelligente tourne chez vous. Aucune donnée n’a besoin d’en sortir — et aucune n’en sort.':
		'Ergopti+’s bet: everything that makes typing smarter runs on your machine. No data needs to leave it — and none does.',
	'Frappe, hotstrings, prédictions, métriques : tout est calculé et stocké sur votre machine. Aucun serveur, aucun cloud par défaut.':
		'Keystrokes, hotstrings, predictions, metrics: everything is computed and stored on your machine. No server, no cloud by default.',
	'Aucune télémétrie': 'No telemetry',
	'Pas de compte, pas de tracking, pas de « statistiques anonymes ». Le logiciel ne vous observe pas.':
		'No account, no tracking, no “anonymous statistics”. The software does not watch you.',
	'Mots de passe ignorés': 'Passwords ignored',
	'Les champs de saisie sécurisés sont exclus de toute capture et de tout enregistrement de frappe.':
		'Secure input fields are excluded from any capture and any keystroke logging.',
	'Clés d’API chiffrées': 'Encrypted API keys',
	'Si vous utilisez un modèle distant (optionnel), la clé est chiffrée localement (Trousseau macOS, DPAPI Windows) — jamais en clair.':
		'If you use a remote model (optional), the key is encrypted locally (macOS Keychain, Windows DPAPI) — never in plain text.',
	'Vos données vous appartiennent': 'Your data is yours',
	'Les métriques vivent dans une base SQLite locale que vous pouvez lire, exporter ou supprimer à tout moment.':
		'Metrics live in a local SQLite database you can read, export or delete at any time.',
	'Le code est open-source et public. N’importe qui peut vérifier ce que fait réellement le driver.':
		'The code is open-source and public. Anyone can verify what the driver actually does.',

	// ── FAQ ──────────────────────────────────────────────────────────────────
	'Questions fréquentes': 'Frequently asked questions',
	'Tout ce qu’on se demande avant d’installer.': 'Everything you wonder before installing.',
	'Confidentialité, performance, compatibilité — les réponses courtes, sans détour.':
		'Privacy, performance, compatibility — short answers, straight up.',
	'Est-ce que quelque chose part sur Internet ?': 'Does anything leave for the Internet?',
	'Non. Tout — hotstrings, prédictions IA, métriques — est calculé et stocké <strong>sur votre machine</strong>. Les modèles d’IA tournent en local ; si vous branchez une clé d’API distante (optionnel), elle est chiffrée dans le Trousseau macOS ou via DPAPI sur Windows, et vous choisissez explicitement quand l’utiliser.':
		'No. Everything — hotstrings, AI predictions, metrics — is computed and stored <strong>on your machine</strong>. The AI models run locally; if you plug in a remote API key (optional), it is encrypted in the macOS Keychain or via DPAPI on Windows, and you explicitly choose when to use it.',
	'Est-ce que ça ralentit ma frappe ?': 'Does it slow my typing down?',
	'Non perceptiblement. Les expansions sont synchrones et instantanées ; les prédictions IA sont asynchrones et n’interrompent jamais la frappe — une suggestion s’affiche quand elle est prête, et vous l’ignorez ou l’acceptez d’une touche.':
		'Not perceptibly. Expansions are synchronous and instantaneous; AI predictions are asynchronous and never interrupt typing — a suggestion appears when ready, and you ignore it or accept it with one key.',
	'Quelle différence entre Ergopti et Ergopti+ ?':
		'What’s the difference between Ergopti and Ergopti+?',
	'<strong>Ergopti</strong> est la disposition clavier — l’agencement des lettres. <strong>Ergopti+</strong> est le logiciel compagnon : hotstrings, IA, tap-holds, gestes, métriques, qui fonctionne sur n’importe quelle disposition. Utilisez l’un sans l’autre, ou les deux ensemble pour le gain maximal.':
		'<strong>Ergopti</strong> is the keyboard layout — the arrangement of the letters. <strong>Ergopti+</strong> is the companion software: hotstrings, AI, tap-holds, gestures, metrics, working on any layout. Use either without the other, or both together for the maximum gain.',
	'Ça marche dans toutes mes applications ?': 'Does it work in all my applications?',
	'Oui, le driver agit au niveau du système : navigateur, éditeur de code, messagerie, traitement de texte… Les champs de mot de passe sont volontairement <strong>ignorés</strong>. Quelques applications très verrouillées (certains jeux anti-triche) peuvent bloquer l’injection de touches.':
		'Yes — the driver acts at the system level: browser, code editor, mail, word processing… Password fields are deliberately <strong>ignored</strong>. A few heavily locked-down applications (some anti-cheat games) may block key injection.',
	'Faut-il utiliser la disposition Ergopti ?': 'Do I need the Ergopti layout?',
	'Non. <strong>Tout fonctionne sur n’importe quelle disposition</strong> (AZERTY, QWERTY, Bépo…). La disposition Ergopti débloque des bonus supplémentaires (roulements, super-touches), mais elle est totalement optionnelle.':
		'No. <strong>Everything works on any layout</strong> (AZERTY, QWERTY, Bépo…). The Ergopti layout unlocks extra bonuses (rolls, super keys), but it is entirely optional.',
	'C’est vraiment gratuit ?': 'Is it really free?',
	'Oui : gratuit, open-source, sans compte et sans télémétrie. Le code est auditable publiquement sur GitHub.':
		'Yes: free, open-source, no account and no telemetry. The code is publicly auditable on GitHub.',
	'Comment on désinstalle ?': 'How do I uninstall?',
	'Chaque fonctionnalité se désactive d’un clic dans le menu, et l’application se retire comme n’importe quelle autre. Vos données (base SQLite locale) vous appartiennent et partent avec.':
		'Every feature switches off with one click in the menu, and the application removes like any other. Your data (a local SQLite database) is yours and leaves with it.',
	'Windows, macOS ou Linux ?': 'Windows, macOS or Linux?',
	'Windows (AutoHotkey) et macOS (Hammerspoon) sont à parité et prêts à l’emploi. Le driver Linux (kanata + daemon Lua) est complet mais en alpha — il cherche ses premiers testeurs.':
		'Windows (AutoHotkey) and macOS (Hammerspoon) are at parity and ready to use. The Linux driver (kanata + Lua daemon) is complete but in alpha — looking for its first testers.',

	// ── Comparison ───────────────────────────────────────────────────────────
	'Autocorr. native': 'Native autocorrect',
	'Tout au même endroit, gratuitement.': 'Everything in one place, for free.',
	'Les outils ci-dessous sont excellents —': 'The tools below are excellent —',
	's’appuie d’ailleurs sur AutoHotkey et Hammerspoon. La différence : une <strong>suite complète, locale et unifiée</strong> sur les trois OS, sans rien scripter.':
		'is in fact built on AutoHotkey and Hammerspoon. The difference: a <strong>complete, local, unified suite</strong> across all three OSes, with nothing to script.',
	Fonctionnalité: 'Feature',
	Gratuit: 'Free',
	'100 % local, sans compte': '100% local, no account',
	'Hotstrings + autocorrection': 'Hotstrings + autocorrect',
	'IA locale intégrée': 'Built-in local AI',
	'Tap-holds + gestes trackpad': 'Tap-holds + trackpad gestures',
	'Métriques de frappe': 'Typing metrics',
	'Config sans écrire de code': 'Config without writing code',
	basique: 'basic',
	variable: 'varies',
	'Comparatif indicatif des offres par défaut, dressé de bonne foi — chaque outil a ses forces.':
		'An indicative, good-faith comparison of default offerings — every tool has its strengths.',

	// ── Final CTA ────────────────────────────────────────────────────────────
	'Vos doigts vous diront merci.': 'Your fingers will thank you.',
	'★ {n} sur GitHub': '★ {n} on GitHub',
	'Vous tapez déjà en Ergopti&nbsp;? Installez la disposition pour le combo complet →':
		'Already typing in Ergopti? Install the layout for the full combo →'
};

