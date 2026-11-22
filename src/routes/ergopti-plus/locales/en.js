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
	'Options de menu propres à certains systèmes': 'Platform-specific menu options',
	Option: 'Option',
	'Touches tap-hold par système': 'Tap-hold keys by system',
	'Inventaire des actions configurables': 'Bindable actions inventory',
	Action: 'Action',
	'Trois systèmes, un projet.': 'Three systems, one project.',
	'Les entrées ci-dessous proviennent du manifeste partagé. Une entrée absente peut avoir un équivalent sous un autre nom ; sa présence ne garantit pas son fonctionnement en conditions réelles.':
		'The entries below come from the shared manifest. An absent entry may have an equivalent under another name; its presence does not guarantee real-world operation.',
	'Inventaire des réglages et fonctionnalités': 'Settings and features inventory',
	'Fonctionnalité ou réglage': 'Feature or setting',
	'✓ déclaré pour ce système': '✓ declared for this system',
	'— entrée non déclarée pour ce système': '— entry not declared for this system',
	'Comportements examinés dans le code': 'Behaviors reviewed in the source',
	'Ce catalogue complémentaire couvre les comportements examinés. Il ne constitue pas un inventaire exhaustif ni une garantie de fonctionnement dans chaque application.':
		'This supplementary catalogue covers reviewed behaviors. It is not an exhaustive inventory or a guarantee of operation in every application.',
	// ── Top bar ────────────────────────────────────────────────────────────

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
	'transforme votre frappe en temps réel : expansions de texte, autocorrection, prédictions IA locales, touches à double fonction (tap-holds), gestes trackpad. Pensé pour le français, l’anglais et le code — <strong>gratuit et open-source</strong>.':
		'transforms your typing in real time: text expansions, autocorrection, local AI predictions, dual-function keys (tap-holds), trackpad gestures. Built for French, English and code — <strong>free and open-source</strong>.',
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
	'Afficher les fenêtres au style Linux (daemon Lua, alpha)':
		'Show the windows in Linux style (Lua daemon, alpha)',
	'Découvrir les fonctionnalités': 'Discover the features',

	// ── Promises ─────────────────────────────────────────────────────────────
	'Trois promesses': 'Three promises',
	'Une suite riche, jamais envahissante.': 'A rich suite that never gets in the way.',
	'Utile dès la première heure': 'Useful from the first hour',
	'Apostrophes typographiques, accents, expansions classiques : l’essentiel du gain est livré <strong>par défaut</strong>, sans rien apprendre. Vous tapez normalement, le reste se règle tout seul.':
		'Typographic apostrophes, accents, classic expansions: most of the gain ships <strong>by default</strong>, with nothing to learn. You type normally, the rest takes care of itself.',
	'Progressif, jamais imposé': 'Progressive, never imposed',
	'Chaque fonctionnalité est <strong>activable indépendamment</strong>. Démarrez avec les expansions de texte (hotstrings), ajoutez les touches à double fonction (tap-holds) plus tard, l’IA en bonus. Tout se désactive d’un clic.':
		'Every feature can be <strong>enabled independently</strong>. Start with text expansions (hotstrings), add dual-function keys (tap-holds) later, AI as a bonus. Everything switches off in one click.',
	'Toutes les dispositions': 'Every layout',
	'AZERTY, QWERTY, Bépo, Dvorak… Le logiciel agit sur le <strong>texte produit</strong>, pas sur la touche physique. Gardez votre disposition — ou adoptez Ergopti pour le combo idéal.':
		'AZERTY, QWERTY, Bépo, Dvorak… The software acts on the <strong>text produced</strong>, not the physical key. Keep your layout — or adopt Ergopti for the ideal combo.',

	// ── Personas ─────────────────────────────────────────────────────────────
	'Chacun y gagne, à sa façon.': 'Everyone gains, their own way.',
	'Ergopti+ n’impose pas une manière de travailler — il accélère la vôtre. Quelques exemples.':
		'Ergopti+ doesn’t impose a way of working — it accelerates yours. A few examples.',
	Développeur: 'Developer',
	'Symboles de code en roulements (<code>=></code>, <code>!=</code>), modèles de code tout prêts, ouverture de chemins de fichiers, et une IA locale qui complète sans jamais envoyer votre code ailleurs.':
		'Code symbols as rolls (<code>=></code>, <code>!=</code>), ready-made code templates, opening file paths, and a local AI that completes without ever sending your code anywhere.',
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
	'Pas de compte, pas de pistage, pas de « statistiques anonymes ». Le logiciel ne vous observe pas.':
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
	'Windows, macOS et Linux partagent de nombreuses fonctionnalités. Leur disponibilité, leurs conditions et certains comportements diffèrent selon le système : consultez les inventaires ci-dessous et l’audit de parité du dépôt. Le pilote Linux reste en alpha.':
		'Windows, macOS and Linux share many features. Availability, requirements and some behaviors differ by system: see the inventories below and the repository parity audit. The Linux driver remains in alpha.',

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
	'Sélectionner une démo': 'Choose a demo',
	'Mettre la démo en pause': 'Pause the demo',
	'Relancer la démo': 'Play the demo',
	'{input} → {output}, démo {n} sur {total}': '{input} → {output}, demo {n} of {total}',
	'Sur macOS, aussi avec Homebrew :': 'On macOS, also with Homebrew:',
	'Vous tapez déjà en Ergopti&nbsp;? Installez la disposition pour le combo complet →':
		'Already typing in Ergopti? Install the layout for the full combo →',

	// Section pages of the split Ergopti+ site (2026-11-14).
	'Pages d’Ergopti+': 'Ergopti+ pages',
	'Tout Ergopti+, page par page': 'All of Ergopti+, page by page',
	Aperçu: 'Overview',
	Présentation: 'Introduction',
	Fonctionnalités: 'Features',
	'Configuration — Ergopti+': 'Configuration — Ergopti+',
	'Les réglages d’Ergopti+, ses langues d’interface et le respect de votre vie privée.':
		'Ergopti+ settings, interface languages and respect for your privacy.',
	'FAQ — Ergopti+': 'FAQ — Ergopti+',
	'Les questions fréquentes sur Ergopti+ : vie privée, compatibilité, IA, installation.':
		'Frequently asked questions about Ergopti+: privacy, compatibility, AI, installation.',
	'Fonctionnalités — Ergopti+': 'Features — Ergopti+',
	'Les tap-holds, raccourcis, gestes trackpad et métriques de frappe d’Ergopti+.':
		'Ergopti+ tap-holds, shortcuts, trackpad gestures and typing metrics.',
	'Hotstrings — Ergopti+': 'Hotstrings — Ergopti+',
	'Les hotstrings d’Ergopti+ : expansions, corrections et vos propres hotstrings.':
		'Ergopti+ hotstrings: expansions, corrections and your own hotstrings.',
	'IA — Ergopti+': 'AI — Ergopti+',
	'Les prédictions par IA d’Ergopti+ : modèles locaux ou distants, profils et réglages.':
		'Ergopti+ AI predictions: local or remote models, profiles and settings.',
	'Installation — Ergopti+': 'Installation — Ergopti+',
	'Démarrer avec Ergopti+ et le télécharger pour Windows, macOS ou Linux.':
		'Get started with Ergopti+ and download it for Windows, macOS or Linux.',
	'Présentation — Ergopti+': 'Introduction — Ergopti+',
	'Pour qui est Ergopti+, ce qu’il ajoute à la disposition Ergopti et comment il se compare aux autres outils.':
		'Who Ergopti+ is for, what it adds to the Ergopti layout and how it compares with other tools.',
	'Pour qui, ce qu’il ajoute à la disposition Ergopti et comment il se compare.':
		'Who it is for, what it adds to the Ergopti layout and how it compares.',
	'Expansions, corrections et vos propres hotstrings.':
		'Expansions, corrections and your own hotstrings.',
	'Prédictions par IA locale ou distante, modèles et profils.':
		'Local or remote AI predictions, models and profiles.',
	'Tap-holds, raccourcis, gestes trackpad et métriques de frappe.':
		'Tap-holds, shortcuts, trackpad gestures and typing metrics.',
	'Réglages, langues d’interface et vie privée.': 'Settings, interface languages and privacy.',
	'Démarrer en quelques étapes et télécharger pour Windows, macOS ou Linux.':
		'Get started in a few steps and download for Windows, macOS or Linux.',
	'Les réponses aux questions fréquentes.': 'Answers to frequently asked questions.',
	Prédiction: 'Prediction',
	Correction: 'Correction',
	'Correction + prédiction': 'Correction + prediction',
	'Aucune instruction injectée : le modèle reçoit le contexte brut et continue. Idéal pour le code et les formats stricts.':
		'No instruction injected: the model gets the raw context and continues. Ideal for code and strict formats.',
	'Instruction minimale : continuer le texte entre N et M mots, sans commentaire. Le compromis vitesse/qualité par défaut.':
		'Minimal instruction: continue the text with N to M words, without comment. The default speed/quality trade-off.',
	'Deux lignes en sortie : la fin de phrase corrigée, puis la suite prédite. Bilingue FR/EN, avec exemples intégrés pour les petits modèles.':
		'Two output lines: the corrected end of the sentence, then the predicted continuation. Bilingual FR/EN, with built-in examples for small models.',
	'Le contrat « Avancé », mais N suggestions distinctes en une seule requête — beaucoup plus économique que N appels.':
		'The “Advanced” contract, but N distinct suggestions in a single request — much cheaper than N calls.',
	'Prédictions IA': 'AI predictions',
	'Une IA qui écrit avec vous. Chez vous.': 'An AI that writes with you. On your machine.',
	'Le driver embarque un pont vers un modèle de langage qui tourne <strong>sur votre machine</strong>. Il corrige la fin de votre phrase et propose la suite — validables en une touche, sans que rien ne parte dans le cloud.':
		'The driver ships a bridge to a language model running <strong>on your machine</strong>. It corrects the end of your sentence and suggests what comes next — accepted with one key, with nothing sent to the cloud.',
	'Mode du tooltip IA': 'AI tooltip mode',
	'~/inbox/brouillon.eml': '~/inbox/draft.eml',
	'Bonjour Madame, je vous écris pour': 'Dear Madam, I am writing to',
	'…je vous écris pour': '…I am writing to',
	'vous proposer un rendez-vous mardi prochain.': 'suggest a meeting next Tuesday.',
	'faire suite à notre échange de la semaine dernière.': 'follow up on our conversation last week.',
	'accuser réception de votre dossier complet.': 'acknowledge receipt of your complete file.',
	'Tab = accepter · ↑↓ = naviguer · Échap = ignorer':
		'Tab = accept · ↑↓ = navigate · Esc = dismiss',
	'Llama 3.2 3B · Ollama · Basique — ⏱ 0,18 s': 'Llama 3.2 3B · Ollama · Basic — ⏱ 0.18 s',
	'Je vous remercie de me': 'Thank you for agreeing to',
	recevoire: 'recieve',
	recevoir: 'receive',
	'demain matin.': 'me tomorrow morning.',
	'Tab = accepter': 'Tab = accept',
	'Llama 3.2 3B · Ollama · Avancé — ⏱ 0,21 s': 'Llama 3.2 3B · Ollama · Advanced — ⏱ 0.21 s',
	'Le projet est': 'The project runs',
	paralèle: 'paralel',
	parallèle: 'parallel',
	à: 'to',
	'celui de l’an dernier, avec un budget revu à la hausse.': 'last year’s, with a larger budget.',
	'ceux que nous avons livrés en 2024.': 'the ones we delivered in 2024.',
	'Tab = accepter la correction ET la suite': 'Tab = accept the correction AND the continuation',
	'Mistral 7B · Ollama · Avancé — ⏱ 0,34 s': 'Mistral 7B · Ollama · Advanced — ⏱ 0.34 s',
	'Un seul <kbd>Tab</kbd> insère la correction <strong>et</strong> la suite : 80 caractères pour 1 frappe.':
		'A single <kbd>Tab</kbd> inserts the correction <strong>and</strong> the continuation: 80 characters for 1 keystroke.',
	'{n} suggestions, déclenchées après {ms} ms d’inactivité sur les {chars} derniers caractères — tout est réglable.':
		'{n} suggestions, fired after {ms} ms of inactivity on the last {chars} characters — everything is adjustable.',
	'Choisissez votre moteur — local d’abord': 'Choose your engine — local first',
	'Le plus simple à installer — le driver propose même de le faire pour vous. Catalogue de modèles immense, serveur local en écoute uniquement sur votre machine.':
		'The easiest to install — the driver even offers to do it for you. A huge model catalogue, a local server listening on your machine only.',
	'Inférence accélérée par le GPU des puces Apple. Détecté et sélectionné automatiquement sur les machines compatibles — réponses sous 100 ms sur les petits modèles.':
		'Inference accelerated by the GPU of Apple chips. Detected and selected automatically on compatible machines — answers under 100 ms on small models.',
	'Envie d’un modèle plus puissant ? Branchez une clé API — <strong>{n} fournisseurs</strong> pris en charge, clés chiffrées localement (Trousseau macOS, DPAPI Windows) :':
		'Want a more powerful model? Plug in an API key — <strong>{n} providers</strong> supported, keys encrypted locally (macOS Keychain, Windows DPAPI):',
	'Modèle par défaut : {model}': 'Default model: {model}',
	'Endpoint personnalisé': 'Custom endpoint',
	'Liste générée depuis le fichier de configuration du driver — toujours à jour.':
		'List generated from the driver’s configuration file — always up to date.',
	'Choisissez votre modèle parmi': 'Choose your model among',
	'Un catalogue curé de <strong>{models} modèles open-weights</strong> issus de <strong>{providers} fournisseurs</strong> ({families} familles), du {min} qui répond en 50 ms au {max} ultra-contextuel. Le menu affiche la RAM et l’espace disque requis avant tout téléchargement — et accepte n’importe quel identifiant HuggingFace ou tag Ollama en plus.':
		'A curated catalogue of <strong>{models} open-weights models</strong> from <strong>{providers} providers</strong> ({families} families), from the {min} that answers in 50 ms to the long-context {max}. The menu shows the RAM and disk space required before any download — and accepts any HuggingFace identifier or Ollama tag on top.',
	'{n} modèles': '{n} models',
	'{n} modèle': '{n} model',
	'Et voici la <strong>vraie fenêtre</strong> du navigateur de modèles, alimentée ici avec ce même catalogue — triez, cherchez, comparez :':
		'And here is the <strong>real window</strong> of the model browser, fed here with the same catalogue — sort, search, compare:',
	'Catalogue généré depuis <code>models.json</code> — le même fichier que lit le driver.':
		'Catalogue generated from <code>models.json</code> — the same file the driver reads.',
	'Choisissez (ou écrivez) votre profil de prompt': 'Choose (or write) your prompt profile',
	'L’éditeur de prompts intégré accepte vos propres instructions avec les variables <code>&#123;context&#125;</code>, <code>&#123;min_words&#125;</code>, <code>&#123;max_words&#125;</code> — imposez un ton, une langue, un métier. <em>« Termine mes phrases comme Hemingway »</em> est un profil valide.':
		'The built-in prompt editor accepts your own instructions with the <code>&#123;context&#125;</code>, <code>&#123;min_words&#125;</code>, <code>&#123;max_words&#125;</code> variables — set a tone, a language, a trade. <em>“Finish my sentences like Hemingway”</em> is a valid profile.',
	'Délais par famille': 'Delays per family',
	'Couleurs des tooltips': 'Tooltip colours',
	'Touches et actions des tap-holds': 'Tap-hold keys and actions',
	'Raccourcis clavier': 'Keyboard shortcuts',
	'Apps ignorées': 'Ignored apps',
	'Rechargement à chaud': 'Hot reload',
	'Chemins de config': 'Config paths',
	'Modèle et backend IA': 'AI model and backend',
	'Prompts personnalisés': 'Custom prompts',
	'Sensibilité des gestes': 'Gesture sensitivity',
	'Widget MPM': 'WPM widget',
	'Sélecteur d’actions': 'Action picker',
	Versions: 'Versions',
	Téléchargements: 'Downloads',
	Diagnostic: 'Diagnostics',
	'Éditeur de hotstrings': 'Hotstring editor',
	'Réglages hotstrings': 'Hotstring settings',
	'Temps d’écran': 'Screen time',
	'Statistiques de frappe': 'Typing statistics',
	'Catalogue de modèles': 'Model catalogue',
	'Assistant de démarrage': 'Getting-started assistant',
	'Dossier de config': 'Config folder',
	'Infos personnelles': 'Personal info',
	'Éditeur de prompts': 'Prompt editor',
	'Jeton HuggingFace': 'HuggingFace token',
	'Tout reste chez vous': 'Everything stays with you',
	'Hotstrings, métriques, prédictions IA : chaque calcul est local. Les serveurs d’inférence n’écoutent que sur votre machine. Une fois le modèle téléchargé, tout fonctionne hors-ligne.':
		'Hotstrings, metrics, AI predictions: every computation is local. The inference servers listen on your machine only. Once the model is downloaded, everything works offline.',
	'Open-source, auditable': 'Open source, auditable',
	'Trois drivers, un site, plus de 200 000 lignes de code publiées sur GitHub sous licence libre — et plus de 1 300 fichiers de tests automatisés qui les verrouillent.':
		'Three drivers, a website, more than 200,000 lines of code published on GitHub under a free licence — and more than 1,300 automated test files that lock them down.',
	'Gratuit. Pour de bon.': 'Free. For good.',
	'Pas de freemium, pas de version « Pro », pas de publicité, pas de compte. Le projet est un travail de passion — il est et restera entièrement gratuit.':
		'No freemium, no “Pro” edition, no ads, no account. The project is a labour of love — it is and will remain entirely free.',
	'Zéro télémétrie': 'Zero telemetry',
	'Aucun appel réseau en dehors du backend IA que vous avez choisi et de la vérification de mise à jour. Pas de « données anonymisées », pas de pistage. Rien.':
		'No network call besides the AI backend you chose and the update check. No “anonymised data”, no tracking. Nothing.',
	'Vous gardez la main': 'You stay in control',
	'réglages. Zéro obligation. Zéro code.': 'settings. Zero obligation. Zero code.',
	'Nous livrons de bons défauts — touches, délais, couleurs, raccourcis — mais <strong>tout se change depuis le menu</strong>, sans écrire une ligne de code. Le menu est généré depuis un manifeste unique, pour que les trois drivers exposent exactement les mêmes options.':
		'We ship good defaults — keys, delays, colours, shortcuts — but <strong>everything can be changed from the menu</strong>, without writing a line of code. The menu is generated from a single manifest, so the three drivers expose exactly the same options.',
	'et 300 autres…': 'and 300 more…',
	'🌍 Parle votre langue — {n} au choix': '🌍 Speaks your language — {n} to choose from',
	'Menus, fenêtres, assistants : toute l’interface est traduite. Liste découverte automatiquement depuis les fichiers du driver, dans l’ordre de ses menus :':
		'Menus, windows, assistants: the whole interface is translated. The list is discovered automatically from the driver’s files, in the order of its menus:',
	'⏯ La pause qui rend le PC prêtable': '⏯ The pause that makes your PC lendable',
	'Un raccourci met tout en pause : le clavier redevient <strong>AZERTY</strong>, les raccourcis redeviennent ceux de l’OS — passez votre machine à un collègue sans le dérouter. Réactivez : la disposition Ergopti (si émulée), vos hotstrings et vos raccourcis personnalisés reviennent instantanément.':
		'One shortcut pauses everything: the keyboard goes back to <strong>AZERTY</strong>, the shortcuts go back to the OS’s own — hand your machine to a colleague without confusing them. Turn it back on: the Ergopti layout (if emulated), your hotstrings and your custom shortcuts return instantly.',
	'🔄 Mise à jour depuis l’app': '🔄 Updates from the app',
	'Le driver vérifie les nouvelles versions et se met à jour <strong>depuis le menu</strong> — canal stable ou dev, notes de version intégrées. La fenêtre ci-dessous est la vraie : elle interroge GitHub en direct.':
		'The driver checks for new versions and updates itself <strong>from the menu</strong> — stable or dev channel, release notes built in. The window below is the real one: it queries GitHub live.',
	'Le driver ouvre <strong>{n} fenêtres natives</strong> — réglages, éditeurs, assistants, tableaux de bord. Chacune est une vraie fenêtre de votre système (WebView2 sur Windows, WKWebView sur macOS, WebKitGTK sur Linux). Toutes partagent pourtant <strong>un seul et même code</strong> : même apparence, même comportement sur les trois OS. Liste générée depuis le manifeste du driver :':
		'The driver opens <strong>{n} native windows</strong> — settings, editors, assistants, dashboards. Each one is a real window of your system (WebView2 on Windows, WKWebView on macOS, WebKitGTK on Linux). Yet they all share <strong>one and the same code</strong>: same look, same behaviour on the three OSes. List generated from the driver’s manifest:',
	'Roulements de bigrammes': 'Bigram rolls',
	'Des séquences inconfortables remplacées par des roulements fluides sur doigts adjacents. Vous tapez ce qui est confortable, le mot correct sort.':
		'Awkward sequences replaced by smooth rolls on adjacent fingers. You type what is comfortable, the right word comes out.',
	'Réduction des SFBs': 'SFB reduction',
	'La virgule devient une super touche morte qui neutralise les derniers bigrammes à même doigt. Les touches É/È/Ê s’en chargent côté gauche.':
		'The comma becomes a super dead key that removes the last same-finger bigrams. The É/È/Ê keys handle them on the left side.',
	'Symboles de programmation': 'Programming symbols',
	'Les combinaisons pénibles du code deviennent des roulements vers l’intérieur sur la home-row d’Ergopti.':
		'Tedious code combinations become inward rolls on the Ergopti home row.',
	différent: 'not equal',
	'fermeture HTML': 'HTML closing tag',
	', + voyelle = J': ', + vowel = J',
	'Le <kbd>j</kbd> cède sa place à la touche ★. La séquence <code>,</code>+voyelle — inexistante en français — produit le <code>j</code> : <code>,a</code> → <em>ja</em>, <code>,e</code> → <em>je</em>.':
		'The <kbd>j</kbd> gives its place to the ★ key. The <code>,</code>+vowel sequence — which French never uses — produces the <code>j</code>: <code>,a</code> → <em>ja</em>, <code>,e</code> → <em>je</em>.',
	', + consonne = lettres rares': ', + consonant = rare letters',
	'<code>,è</code> → <em>z</em>, <code>,y</code> → <em>k</em>, <code>,s</code> → <em>q</em>, <code>,c</code> → <em>ç</em>. Les lettres rares restent à une frappe du repos.':
		'<code>,è</code> → <em>z</em>, <code>,y</code> → <em>k</em>, <code>,s</code> → <em>q</em>, <code>,c</code> → <em>ç</em>. The rare letters stay one keystroke from the home position.',
	'Q + voyelle = QU': 'Q + vowel = QU',
	'En français, <kbd>q</kbd> implique presque toujours <kbd>u</kbd> : tapez <code>qe</code>, <code>qoi</code> — le <em>u</em> s’insère tout seul.':
		'In French, <kbd>q</kbd> is almost always followed by <kbd>u</kbd>: type <code>qe</code>, <code>qoi</code> — the <em>u</em> is inserted by itself.',
	'ê = circonflexe direct': 'ê = direct circumflex',
	'Une touche dédiée pour le cas le plus fréquent, et <code>êa</code>, <code>êi</code>, <code>êo</code>, <code>êu</code> pour â, î, ô, û.':
		'A dedicated key for the most frequent case, and <code>êa</code>, <code>êi</code>, <code>êo</code>, <code>êu</code> for â, î, ô, û.',
	'Suffixes en à': 'Suffixes on à',
	'<code>às</code> → <em>ement</em>, <code>àt</code> → <em>ation</em>, <code>àr</code> → <em>eur</em>… Les terminaisons fréquentes en deux frappes au lieu de cinq.':
		'<code>às</code> → <em lang="fr">ement</em>, <code>àt</code> → <em lang="fr">ation</em>, <code>àr</code> → <em lang="fr">eur</em>… Frequent French endings in two keystrokes instead of five.',
	'Apostrophe typographique': 'Typographic apostrophe',
	"Dans du texte, <kbd>'</kbd> produit <em>’</em> ; dans du code, elle reste droite. Aucun réglage.":
		"In text, <kbd>'</kbd> produces <em>’</em>; in code, it stays straight. No setting needed.",
	'⚡ Bonus disposition Ergopti': '⚡ Ergopti layout bonus',
	'L’autre moitié du gain.': 'The other half of the gain.',
	'fonctionne sur n’importe quelle disposition': 'works on any layout',
	'— AZERTY, QWERTY, Bépo… Tout ce qui précède marche sans rien changer à votre clavier. Les fonctionnalités ci-dessous, elles, exploitent les positions exactes des touches de la disposition':
		'— AZERTY, QWERTY, Bépo… Everything above works without changing anything on your keyboard. The features below, however, rely on the exact key positions of the',
	' : adoptez la disposition et Ergopti+ les active automatiquement.':
		' layout: adopt it and Ergopti+ turns them on automatically.',
	'La disposition Ergopti et ses couches — explorez la couche AltGr, la touche magique et les symboles de programmation.':
		'The Ergopti layout and its layers — explore the AltGr layer, the magic key and the programming symbols.',
	Autocorrection: 'Autocorrection',
	'Les fautes les plus fréquentes, balayées à la frappe':
		'The most frequent mistakes, swept away as you type',
	'Apostrophes typographiques, capitalisation des marques, accents oubliés. Ce n’est pas un correcteur après coup : c’est appliqué pendant que vous tapez.':
		'Typographic apostrophes, brand capitalisation, forgotten accents. It is not an after-the-fact checker: it applies while you type.',
	'Touche magique ★': 'Magic key ★',
	'Un suffixe explicite pour les expansions longues': 'An explicit suffix for long expansions',
	'Pour vos snippets fréquents — formules, signatures, identifiants — la touche ★ déclenche l’expansion sans aucune ambiguïté. Aucun risque de collision avec la frappe normale.':
		'For your frequent snippets — phrases, signatures, identifiers — the ★ key fires the expansion without any ambiguity. No risk of clashing with normal typing.',
	'Expansions en temps réel': 'Real-time expansions',
	'corrections et expansions, prêtes à l’emploi.': 'corrections and expansions, ready to use.',
	'Cinq familles livrées avec le driver, chacune avec sa couleur de tooltip et son délai réglable. Ce compteur est <strong>mesuré automatiquement</strong> depuis les fichiers du driver à chaque mise à jour du site.':
		'Five families ship with the driver, each with its own tooltip colour and adjustable delay. This counter is <strong>measured automatically</strong> from the driver’s files at every site update.',
	'Couleurs et délais réels du driver — chaque famille est personnalisable et désactivable depuis le menu.':
		'The driver’s real colours and delays — every family can be customised and turned off from the menu.',
	'Répéteur de lettre': 'Letter repeater',
	'Si aucune abréviation ne correspond, <kbd class="star">★</kbd> double simplement la lettre précédente. <strong>Plus aucun SFB sur les doublons.</strong>':
		'If no abbreviation matches, <kbd class="star">★</kbd> simply doubles the previous letter. <strong>No more SFBs on double letters.</strong>',
	'Déclencheur d’abréviations': 'Abbreviation trigger',
	'Si les lettres précédentes forment une abréviation connue, <kbd class="star">★</kbd> expanse à la place. Les deux modes sont décidés au moment de la frappe — sans configuration.':
		'If the previous letters form a known abbreviation, <kbd class="star">★</kbd> expands it instead. Both modes are decided as you type — no configuration.',
	'Et voici la vraie fenêtre d’édition.': 'And here is the real editing window.',
	'Pas une capture d’écran : c’est la fenêtre d’édition du driver, servie depuis ses propres fichiers et pilotée ici avec des données de démonstration. Sections pliables, recherche, ajout en deux champs — chez vous, avec vos raccourcis.':
		'Not a screenshot: it is the driver’s editing window, served from its own files and driven here with demo data. Collapsible sections, search, adding in two fields — at home, with your shortcuts.',
	Entrée: 'Enter',
	'La touche la plus accessible de la home-row devient validation ET modificateur.':
		'The most reachable key of the home row becomes both Enter AND a modifier.',
	Copier: 'Copy',
	'Copier d’un seul appui sur une touche que votre auriculaire connaît déjà.':
		'Copy with a single press on a key your little finger already knows.',
	Coller: 'Paste',
	'Coller sans quitter la position de repos, sans accord à deux mains.':
		'Paste without leaving the home position, without a two-handed chord.',
	'Retour arrière': 'Backspace',
	'Couche navigation': 'Navigation layer',
	'Backspace sous le pouce ; maintenu, il ouvre le layer de navigation ci-dessous.':
		'Backspace under the thumb; held, it opens the navigation layer below.',
	'Shift one-shot': 'One-shot Shift',
	'Un appui = la prochaine lettre en majuscule. Fini le Shift maintenu pour une seule lettre.':
		'One press = the next letter in upper case. No more holding Shift for a single letter.',
	'Tab au pouce droit — l’indentation et la navigation de formulaires sans étirement.':
		'Tab under the right thumb — indentation and form navigation without stretching.',
	'Alt-Tab (écran)': 'Alt-Tab (screen)',
	'Bascule d’application sur le moniteur courant, en un seul appui.':
		'Switches applications on the current monitor, in a single press.',
	Gauche: 'Left',
	Bas: 'Down',
	Haut: 'Up',
	Droite: 'Right',
	'Page haut': 'Page up',
	'Page bas': 'Page down',
	Début: 'Home',
	Fin: 'End',
	'⌫mot': '⌫word',
	'⌦mot': '⌦word',
	'Effacer mot': 'Delete word',
	'Suppr. mot': 'Delete next word',
	'Téléporter la souris': 'Teleport the mouse',
	'Le curseur saute sur l’écran voisin d’un seul tap — fini de deviner vers quel bord le pousser pour changer de moniteur.':
		'The pointer jumps to the next screen in a single tap — no more guessing which edge to push it to change monitors.',
	'Surbrillance du curseur': 'Pointer highlight',
	'Perdu votre souris sur trois écrans ? Un halo la fait ressortir à l’instant — parfait aussi en présentation.':
		'Lost your mouse across three screens? A halo makes it stand out instantly — perfect for presentations too.',
	'Capture en un tap': 'Screenshot in one tap',
	'Région, fenêtre, plein écran ou OCR — sur la touche à gauche du 1, sans chercher le raccourci système.':
		'Region, window, full screen or OCR — on the key left of 1, without hunting for the system shortcut.',
	'Sélectionner la ligne': 'Select the line',
	'La ligne entière sélectionnée d’un geste, sans viser au pixel ni tripler-cliquer.':
		'The whole line selected in one move, without pixel-perfect aiming or triple-clicking.',
	'Ouvrir lien ou chemin': 'Open link or path',
	'Ouvre l’URL ou le chemin de fichier local sous le curseur — où qu’il se trouve dans le texte.':
		'Opens the URL or local file path under the cursor — wherever it sits in the text.',
	'Changer la casse': 'Change case',
	'Bascule la sélection en MAJUSCULES, minuscules ou Casse De Titre — plus besoin de retaper.':
		'Switches the selection to UPPER CASE, lower case or Title Case — no need to retype.',
	'MAJUSCULES sur le mot en cours uniquement — le shift virtuel se relâche à l’espace. Parfait pour les acronymes (NASA, TODO).':
		'UPPER CASE on the current word only — the virtual Shift releases at the space. Perfect for acronyms (NASA, TODO).',
	'Suppression de mot': 'Word deletion',
	'Un geste efface le mot entier — idéal pour annuler une expansion d’un coup.':
		'One move erases the whole word — ideal to undo an expansion at once.',
	'Encadrer la sélection': 'Wrap the selection',
	'Sélectionnez du texte, tapez <code>"</code>, <code>(</code> ou <code>[</code> : la sélection est encadrée par la paire correspondante.':
		'Select some text, type <code>"</code>, <code>(</code> or <code>[</code>: the selection is wrapped in the matching pair.',
	'Répéteur intelligent': 'Smart repeater',
	'Sans abréviation en attente, ★ double la lettre précédente — les doublons sans SFB.':
		'With no pending abbreviation, ★ doubles the previous letter — double letters without SFBs.',
	'Sept touches à double vie.': 'Seven keys with a double life.',
	'Un appui bref déclenche une action, un maintien conserve le rôle de modificateur. La même logique sur les deux OS : <strong>les mêmes doigts</strong> déclenchent les mêmes gestes, avec le modificateur natif de chaque plateforme — <kbd>Ctrl</kbd> sur Windows, <kbd>⌘</kbd> sur macOS. L’objectif : <strong>une expérience unifiée</strong>, quel que soit l’ordinateur devant vous. Ce sont les défauts livrés ; chaque touche, action et délai se change depuis le menu.':
		'A short press fires an action, a hold keeps the modifier role. The same logic on both OSes: <strong>the same fingers</strong> fire the same moves, with each platform’s native modifier — <kbd>Ctrl</kbd> on Windows, <kbd>⌘</kbd> on macOS. The goal: <strong>one unified experience</strong>, whatever computer is in front of you. These are the shipped defaults; every key, action and delay can be changed from the menu.',
	'Layer navigation': 'Navigation layer',
	'(maintenir <kbd>LAlt</kbd>)': '(hold <kbd>LAlt</kbd>)',
	'Flèches sur HJKL, pages, début/fin de ligne, effacement par mot — la main ne quitte jamais la position de repos.':
		'Arrows on HJKL, pages, line start/end, word deletion — the hand never leaves the home position.',
	'Des actions qui règlent de vraies galères.': 'Actions that fix real daily hassles.',
	'Bien au-delà du copier-coller : voici quelques-unes des actions les plus utiles — chacune assignable à n’importe quelle touche, tap-hold ou geste.':
		'Far beyond copy and paste: here are some of the most useful actions — each one assignable to any key, tap-hold or gesture.',
	'actions à assigner. À n’importe quelle touche ou geste.':
		'actions to assign. To any key or gesture.',
	'Tap-holds, gestes trackpad et raccourcis piochent dans le même catalogue d’actions, défini dans <strong>un seul fichier partagé par les trois drivers</strong>. Mêmes groupes, mêmes sections que dans le sélecteur du driver — filtrés ici pour <strong>{os}</strong> ; changez d’OS en haut de page pour voir la différence.':
		'Tap-holds, trackpad gestures and shortcuts draw from the same action catalogue, defined in <strong>a single file shared by the three drivers</strong>. Same groups, same sections as in the driver’s picker — filtered here for <strong>{os}</strong>; switch OS at the top of the page to see the difference.',
	axe: 'axis',
	Auto: 'Auto',
	Magique: 'Magic',
	Perso: 'Personal',
	'Expansion en temps réel — une vraie phrase, plusieurs familles d’expansions, sans jamais rompre le flux de frappe.':
		'Real-time expansion — a real sentence, several expansion families, without ever breaking the typing flow.',
	'★ Touche magique': '★ Magic key',
	'★ Roulement': '★ Roll',
	'✨ IA — suite acceptée': '✨ AI — continuation accepted',
	'~/courriel/brouillon.txt': '~/mail/draft.txt',
	'Widget MPM en direct': 'Live WPM widget',
	MPM: 'WPM',
	'Les pics correspondent aux hotstrings et aux acceptations d’IA.':
		'The peaks match hotstrings and accepted AI suggestions.',
	'Évolution des MPM': 'WPM over time',
	'Votre vitesse jour après jour, semaine après semaine — avec les records et les moyennes glissantes.':
		'Your speed day after day, week after week — with records and rolling averages.',
	'Impact des hotstrings et de l’IA': 'Impact of hotstrings and AI',
	'Les caractères « + Hotstrings » et « + IA » sont comptés à part : vous voyez exactement combien de frappe vous déléguez.':
		'The “+ Hotstrings” and “+ AI” characters are counted separately: you see exactly how much typing you delegate.',
	'N-grammes — 19 onglets': 'N-grams — 19 tabs',
	'Des caractères aux heptagrammes, mots et raccourcis les plus tapés : la matière première pour créer vos prochains hotstrings.':
		'From characters to heptagrams, most-typed words and shortcuts: the raw material for your next hotstrings.',
	'Heatmaps clavier': 'Keyboard heatmaps',
	'Deux cartes de chaleur montrent quelles touches travaillent le plus — et valident (ou non) votre disposition.':
		'Two heatmaps show which keys work the hardest — and confirm (or not) your layout.',
	'Ergonomie mesurée': 'Measured ergonomics',
	'SFBs, roulements, redirections : les métriques des passionnés de layouts, calculées sur VOTRE frappe réelle.':
		'SFBs, rolls, redirects: the metrics layout enthusiasts love, computed on YOUR real typing.',
	'Temps d’écran par app': 'Screen time per app',
	'Temps par application, bascules entre apps, séries et scores de productivité — dans un second tableau de bord dédié.':
		'Time per application, app switches, streaks and productivity scores — in a second, dedicated dashboard.',
	'On n’améliore que ce que l’on mesure.': 'You only improve what you measure.',
	'Un enregistreur local compte vos frappes, mots et expansions dans une base <strong>SQLite sur votre machine</strong> — rien ne part jamais ailleurs. Deux tableaux de bord complets et un widget flottant en font un vrai coach de frappe.':
		'A local recorder counts your keystrokes, words and expansions in a <strong>SQLite database on your machine</strong> — nothing ever leaves it. Two complete dashboards and a floating widget turn it into a real typing coach.',
	'Vitesse moyenne': 'Average speed',
	'+9 % ce mois-ci': '+9% this month',
	'Frappe déléguée': 'Delegated typing',
	'+ Hotstrings · + IA': '+ Hotstrings · + AI',
	'Activité — 26 semaines': 'Activity — 26 weeks',
	'Aperçu illustratif — les vrais tableaux de bord (<em>Statistiques de frappe</em> et <em>Temps d’écran</em>) sont deux fenêtres du driver, avec vos données réelles.':
		'Illustrative preview — the real dashboards (<em>Typing statistics</em> and <em>Screen time</em>) are two windows of the driver, with your real data.',
	'Les vraies fenêtres, servies depuis le driver.': 'The real windows, served from the driver.',
	'Tableaux de bord': 'Dashboards',
	'Données de démonstration générées pour l’aperçu — chez vous, ces tableaux de bord se remplissent de VOTRE frappe, et rien ne quitte jamais votre machine.':
		'Demo data generated for the preview — at home, these dashboards fill with YOUR typing, and nothing ever leaves your machine.',
	'Le widget MPM, toujours sous les yeux': 'The WPM widget, always in sight',
	'Un petit compteur flottant, toujours au premier plan, affiche votre vitesse en temps réel. Regardez-le <strong>bondir</strong> quand une hotstring ou l’IA tape à votre place — c’est toute la frappe déléguée qui devient visible :':
		'A small floating counter, always on top, shows your speed in real time. Watch it <strong>jump</strong> when a hotstring or the AI types for you — all the delegated typing becomes visible:',
	'Combien de frappe déléguez-vous ?': 'How much typing do you delegate?',
	'À la main': 'By hand',
	'100 frappes': '100 keystrokes',
	'Avec Ergopti+': 'With Ergopti+',
	'60 tapées': '60 typed',
	'40 déléguées': '40 delegated',
	'Hotstrings et IA écrivent le reste — pour le même texte, bien moins de frappes. Proportions illustratives ; les vôtres sont dans le tableau de bord.':
		'Hotstrings and AI write the rest — the same text, far fewer keystrokes. Illustrative proportions; yours are in the dashboard.',
	'🔐 Tout est calculé et stocké <strong>localement</strong>. Les champs de mot de passe sont ignorés, le module entier se désactive d’un clic, et la base SQLite vous appartient.':
		'🔐 Everything is computed and stored <strong>locally</strong>. Password fields are ignored, the whole module turns off in one click, and the SQLite database belongs to you.',
	'Nom complet': 'Full name',
	'E-mail': 'Email',
	Téléphone: 'Phone',
	'Cordialement, {name}': 'Best regards, {name}',
	Signature: 'Signature',
	Adresse: 'Address',
	'Date du jour': 'Today’s date',
	'Date en lettres': 'Date in words',
	'Téléphone configuré': 'Configured phone',
	'Remplissage de formulaire': 'Form filling',
	'Sélectionnez un texte que vous tapez souvent.': 'Select a text you type often.',
	'Ouvrez le menu → Hotstrings personnels.': 'Open the menu → Personal hotstrings.',
	'Choisissez un déclencheur (ex : sig★).': 'Choose a trigger (e.g. sig★).',
	'C’est actif — sans redémarrer le driver.': 'It is active — without restarting the driver.',
	'Vos propres raccourcis': 'Your own shortcuts',
	'Et ceux que <em>vous</em> tapez tous les jours.': 'And the ones <em>you</em> type every day.',
	'Signature, IBAN, formules récurrentes : ajoutez vos hotstrings <strong>en un clic</strong> depuis le menu — stockés dans un simple fichier TOML, rechargés à la volée.':
		'Signature, IBAN, recurring phrases: add your hotstrings <strong>in one click</strong> from the menu — stored in a plain TOML file, reloaded on the fly.',
	'Ajout en 5 secondes': 'Added in 5 seconds',
	'Hotstrings dynamiques': 'Dynamic hotstrings',
	'Certaines valeurs changent tous les jours (la date) ou ne doivent pas être écrites en dur (téléphone, IBAN). Le préfixe <code>@</code> les calcule <strong>au moment précis</strong> du déclenchement, depuis l’éditeur d’informations personnelles.':
		'Some values change every day (the date) or must not be hard-coded (phone, IBAN). The <code>@</code> prefix computes them <strong>at the very moment</strong> the hotstring fires, from the personal information editor.',
	'Nom, e-mail, téléphone, adresse, IBAN : tout est centralisé dans une seule fenêtre — les hotstrings dynamiques s’en servent automatiquement.':
		'Name, email, phone, address, IBAN: everything lives in a single window — the dynamic hotstrings use it automatically.',
	'La fenêtre en question — la vraie. <strong>Modifiez un champ ci-dessous</strong> : les exemples <code>np★</code>, <code>sig★</code>, <code>@np★</code>… au-dessus se réécrivent en direct, exactement comme le feront vos expansions.':
		'The window itself — the real one. <strong>Edit a field below</strong>: the <code>np★</code>, <code>sig★</code>, <code>@np★</code>… examples above rewrite themselves live, exactly as your expansions will.',
	'Trois systèmes': 'Three systems',
	'En bonus sur Windows': 'Bonus on Windows',
	'<strong>Ergopti sans installation.</strong> Le driver peut <em>émuler</em> la disposition Ergopti par-dessus votre layout actuel — aucun installateur, aucun droit admin. Idéal au bureau ou sur un poste verrouillé.':
		'<strong>Ergopti without installing.</strong> The driver can <em>emulate</em> the Ergopti layout on top of your current layout — no installer, no admin rights. Ideal at the office or on a locked-down machine.',
	'<strong>Le meilleur d’Ergopti, même en AZERTY ou Bépo.</strong> Sans changer de disposition, profitez de la couche de symboles AltGr d’Ergopti et des <em>chiffres en accès direct</em> — deux des plus gros gains de la disposition, disponibles partout.':
		'<strong>The best of Ergopti, even on AZERTY or Bépo.</strong> Without changing layout, enjoy Ergopti’s AltGr symbol layer and <em>direct-access digits</em> — two of the layout’s biggest gains, available everywhere.',
	'En bonus sur macOS': 'Bonus on macOS',
	'<strong>Backend MLX (Apple Silicon).</strong> Inférence IA locale accélérée par la puce Apple — des prédictions plus rapides, toujours sans passer par le cloud.':
		'<strong>MLX backend (Apple Silicon).</strong> Local AI inference accelerated by the Apple chip — faster predictions, still without going through the cloud.',
	'<strong>Moteur de gestes intégral.</strong> 36 emplacements de gestes trackpad et 3 axes continus, là où Windows en propose 10.':
		'<strong>Full gesture engine.</strong> 36 trackpad gesture slots and 3 continuous axes, where Windows offers 10.',
	'Applications macOS incluses': 'Bundled macOS applications',
	'Des utilitaires signés Ergopti, livrés directement dans le driver macOS — rien de plus à installer.':
		'Utilities signed by Ergopti, shipped directly inside the macOS driver — nothing more to install.',
	'Applications et descriptions extraites automatiquement des bundles embarqués dans le driver.':
		'Applications and descriptions extracted automatically from the bundles shipped in the driver.',
	'🐧 Vous utilisez Linux ? On vous cherche.': '🐧 On Linux? We are looking for you.',
	'Le driver Linux existe : 16 000 lignes de Lua, tap-holds gérés par le daemon lui-même, hotstrings via le moteur partagé, IA Ollama, métriques SQLite. Mais <strong>personne ne l’a encore fait tourner en conditions réelles</strong> — il lui faut des testeurs avant d’être recommandable. Si vous voulez essuyer les plâtres, <a href="https://github.com/adrienm7/ergopti" target="_blank" rel="noopener">ouvrez une issue sur GitHub</a> : chaque retour fera avancer le support.':
		'The Linux driver exists: 16,000 lines of Lua, tap-holds handled by the daemon itself, hotstrings through the shared engine, Ollama AI, SQLite metrics. But <strong>nobody has run it in real conditions yet</strong> — it needs testers before it can be recommended. If you are willing to be a pioneer, <a href="https://github.com/adrienm7/ergopti" target="_blank" rel="noopener">open an issue on GitHub</a>: every report moves the support forward.',
	Installez: 'Install',
	', lancez-le, tapez <code>ct★</code> — et regardez <samp class="cta-demo" lang="fr">c’était</samp> s’écrire tout seul. Le reste suivra.':
		', start it, type <code>ct★</code> — and watch <samp class="cta-demo" lang="fr">c’était</samp> write itself. The rest will follow.',
	'3 doigts': '3 fingers',
	'4 doigts': '4 fingers',
	'5 doigts': '5 fingers',
	'Définition du mot': 'Word definition',
	'Posez trois doigts sur un mot : sa définition apparaît. Le geste signature.':
		'Rest three fingers on a word: its definition appears. The signature gesture.',
	'Mot précédent / suivant': 'Previous / next word',
	'Avancez mot par mot dans n’importe quel champ texte.':
		'Move word by word through any text field.',
	'Volume + / −': 'Volume + / −',
	'Axe continu : plus le geste est long, plus le volume bouge.':
		'Continuous axis: the longer the gesture, the more the volume moves.',
	'Sélectionnez à deux doigts, copiez à quatre — plus rapide que le raccourci.':
		'Select with two fingers, copy with four — faster than the shortcut.',
	'Onglet précédent / suivant': 'Previous / next tab',
	'Navigation d’onglets sans toucher le clavier.': 'Tab navigation without touching the keyboard.',
	'Toutes vos fenêtres d’un geste.': 'All your windows in one gesture.',
	'Gestes trackpad': 'Trackpad gestures',
	'emplacements de gestes. 3 axes continus.': 'gesture slots. 3 continuous axes.',
	'Le driver intercepte les gestes multi-touch bruts (pas les événements souris) et les associe à l’action de votre choix. Taps et swipes de 2 à 5 doigts, catalogue d’actions intégré, sensibilité réglable par geste.':
		'The driver intercepts raw multi-touch gestures (not mouse events) and binds them to the action of your choice. Taps and swipes with 2 to 5 fingers, a built-in action catalogue, sensitivity adjustable per gesture.',
	'Moteur complet sur <strong>macOS</strong> (36 slots + 3 axes, valeurs par défaut ci-dessus) ; <strong>Windows</strong> expose 10 emplacements assignables (taps et swipes 3-4 doigts). Chaque geste est réassignable depuis le menu, ou désactivable.':
		'Full engine on <strong>macOS</strong> (36 slots + 3 axes, defaults above); <strong>Windows</strong> exposes 10 assignable slots (3- and 4-finger taps and swipes). Every gesture can be reassigned from the menu, or turned off.',
	'Déclaration d’accessibilité — Ergopti': 'Accessibility statement — Ergopti',
	'Accessibilité du site Ergopti, d’Ergopti Studio et d’Ergopti+ : objectif WCAG 2.2 AA, réglages proposés, limites connues et contact':
		'Accessibility of the Ergopti website, Ergopti Studio and Ergopti+: WCAG 2.2 AA target, available settings, known gaps and contact',
	'Déclaration d’accessibilité': 'Accessibility statement',
	Objectif: 'Goal',
	'Le site': 'The',
	', Ergopti Studio et': ' website, Ergopti Studio and',
	'doivent pouvoir être utilisés par tout le monde. Ils doivent fonctionner au clavier seul, avec un lecteur d’écran, avec un zoom important, sans animations ou avec une police adaptée. L’objectif est la conformité au niveau':
		'must be usable by everyone. They must work with the keyboard alone, with a screen reader, at high zoom, without animations or with an adapted font. The goal is conformance to level',
	des: 'of the',
	'(WCAG 2.2), et au niveau AAA quand cela coûte peu.':
		'(WCAG 2.2), and to level AAA where it costs little.',
	'État actuel : partiellement conforme.': 'Current status: partially conformant.',
	'Les travaux ont commencé le 16 novembre 2026 ; les limites connues sont listées plus bas.':
		'The work started on 16 November 2026; the known gaps are listed below.',
	'Comment c’est vérifié': 'How it is checked',
	'Chaque page du site et chaque page d’Ergopti Studio est analysée automatiquement à chaque modification, en thème clair et en thème sombre, avec l’outil':
		'Every page of the website and every page of Ergopti Studio is analysed automatically at every change, in the light and the dark theme, with the',
	'. Le nombre de défauts détectés ne peut que baisser : une modification qui en ajoute un est refusée. Chaque page est aussi relue avec un texte agrandi à 200 % et l’espacement élargi. Aucun texte ne doit y être coupé, en recouvrir un autre ou passer sous l’en-tête. Aucun paragraphe n’est justifié et aucune ligne ne dépasse 80 caractères. L’analyse automatique ne détecte qu’une partie des problèmes : des vérifications manuelles (lecteurs d’écran, navigation au clavier, zoom) la complètent.':
		' tool. The number of detected defects can only go down: a change that adds one is refused. Every page is also reviewed with text enlarged to 200% and wider spacing. No text may be cut off, overlap another or slip under the header. No paragraph is justified and no line exceeds 80 characters. Automated analysis only finds part of the problems: manual checks (screen readers, keyboard navigation, zoom) complete it.',
	'Réglages proposés': 'Available settings',
	'Le bouton d’accessibilité en haut de chaque page':
		'The accessibility button at the top of every page',
	'ouvre les réglages d’accessibilité': 'opens the accessibility settings',
	'. Ils s’appliquent au site et à Ergopti Studio, et ce navigateur les retient :':
		'. They apply to the website and to Ergopti Studio, and this browser remembers them:',
	'réduire les animations et les défilements (le réglage « réduire les animations » du système est aussi respecté) ;':
		'reduce animations and scrolling (the system’s “reduce motion” setting is honoured too);',
	'une police très lisible,': 'a highly legible font,',
	', conçue par le Braille Institute pour les personnes malvoyantes, ou une police pensée pour les personnes dyslexiques,':
		', designed by the Braille Institute for people with low vision, or a font designed for people with dyslexia,',
	' ;': ';',
	'un texte plus grand, jusqu’à 200 % ;': 'larger text, up to 200%;',
	'un espacement élargi des lettres, des mots et des lignes ;':
		'wider spacing of letters, words and lines;',
	'des lignes de texte plus courtes, et tout le texte aligné à gauche ;':
		'shorter lines of text, and all text aligned to the left;',
	'un contraste élevé ;': 'high contrast;',
	'des couleurs que les personnes daltoniennes distinguent, sur les claviers dessinés et les démonstrations.':
		'colours that colour-blind people can tell apart, on the drawn keyboards and the demos.',
	'Toutes les pages ont aussi un lien « Aller au contenu », visible au premier appui sur la touche Tab.':
		'Every page also has a “Skip to content” link, visible at the first press of the Tab key.',
	'Limites connues': 'Known gaps',
	'Les graphiques et cartes de chaleur du Comparer et des benchmarks n’ont pas encore tous leurs chiffres sous forme de tableau.':
		'The charts and heatmaps of the Comparer and the benchmarks do not all have their figures as a table yet.',
	'Les dessins de clavier du site se lisent comme des tableaux, mais ceux d’Ergopti Studio ne nomment pas encore toutes leurs touches pour les lecteurs d’écran.':
		'The website’s keyboard drawings read as tables, but those of Ergopti Studio do not name all their keys for screen readers yet.',
	'La démonstration animée de la page d’': 'The animated demo on the ',
	'défile seule et n’a pas encore de bouton pause ; le réglage « réduire les animations » l’arrête.':
		'page plays by itself and has no pause button yet; the “reduce animations” setting stops it.',
	'Les fenêtres d’': 'The windows of ',
	'(menus, réglages, info-bulles) n’ont pas encore été vérifiées avec les lecteurs d’écran de Windows, macOS et Linux.':
		'(menus, settings, tooltips) have not been checked yet with the screen readers of Windows, macOS and Linux.',
	'Les vidéos de démonstration n’ont pas encore de sous-titres ni de transcription.':
		'The demo videos have no captions or transcript yet.',
	'Signaler un problème': 'Report a problem',
	'Si une partie du site, d’Ergopti Studio ou d’':
		'If a part of the website, of Ergopti Studio or of ',
	'vous est difficile ou impossible à utiliser, merci de le signaler : c’est ce qui permet de le corriger. Décrivez la page, ce que vous cherchiez à faire et, si possible, votre navigateur et votre outil d’assistance.':
		'is hard or impossible for you to use, please report it. That is what lets it be fixed. Describe the page, what you were trying to do and, if possible, your browser and your assistive technology.',
	'en créant une': 'by opening an',
	sur: 'on',
	'la page GitHub du projet': 'the project’s GitHub page',
	'ou sur le': 'or on the',
	'serveur Discord BÉPO | Ergodis': 'BÉPO | Ergodis Discord server',
	', dans le canal d’': ', in the channel of ',
	'.': '.',
	'Police du site': 'Site font',
	'Atkinson Hyperlegible (très lisible)': 'Atkinson Hyperlegible (highly legible)',
	'OpenDyslexic (dyslexie)': 'OpenDyslexic (dyslexia)',
	'Réglages d’accessibilité': 'Accessibility settings',
	'Ces réglages s’appliquent à tout le site et à Ergopti Studio, et sont retenus par ce navigateur.':
		'These settings apply to the whole website and to Ergopti Studio, and this browser remembers them.',
	'Réduire les animations et les défilements': 'Reduce animations and scrolling',
	Police: 'Font',
	'Taille du texte': 'Text size',
	'Espacer les lettres, les mots et les lignes': 'Space out letters, words and lines',
	'Raccourcir les lignes de texte': 'Shorten lines of text',
	'Aligner tout le texte à gauche': 'Align all text to the left',
	'Contraste élevé': 'High contrast',
	'Couleurs adaptées au daltonisme': 'Colour-blind friendly colours',
	'Ce navigateur refuse l’enregistrement : les réglages valent pour cette page seulement.':
		'This browser refuses storage: the settings apply to this page only.',
	Réinitialiser: 'Reset',
	Fermer: 'Close',
	'Code couleur réel du driver :': 'The driver’s real colour code:',
	contexte: 'context',
	correction: 'correction',
	prédiction: 'prediction',
	'✨ ligne active': '✨ active line',
	'Style des fenêtres': 'Window style'
};
