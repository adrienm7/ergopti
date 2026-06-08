<script>
	import { onMount } from 'svelte';
	import { fly } from 'svelte/transition';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import { getRelease, getRawUrl } from '$lib/js/getGitHubRelease.js';

	// `data` is populated at build time by +page.server.js, which reads
	// the Hammerspoon LLM catalog (static/ergopti_plus/macos/data/llm_models.json)
	// and returns a compact per-provider summary. Adding a model to the
	// driver's JSON automatically refreshes this page on the next deploy.
	let { data } = $props();

	/** @type {Awaited<ReturnType<typeof getRelease>>} */
	let release = $state(null);
	let urlAhkExe = $derived(release?.url('ErgoptiPlus.exe') ?? '#');
	let urlMacosApp = $derived(release?.url('ErgoptiPlus.app.zip') ?? '#');
	let urlKanata = $derived(release?.url('kanata.kbd') ?? '#');
	const { aiProviders, aiTotalProviders, aiTotalModels, aiTotalFamilies } = data;

	// Live typing demo — cycle through real expansions from the hotstring TOMLs.
	// Each entry has the typed prefix, the expanded result, the group label and
	// the same hex colour used in the tooltip (rouge magic / vert auto / etc.).
	const demos = [
		{ input: 'ct★', output: 'c’était', group: 'Magic Key', color: '#e53935' },
		{ input: 'qa', output: 'qua', group: 'Roulements', color: '#fb8c00' },
		{ input: 'taiwan', output: 'Taïwan', group: 'Autocorrection', color: '#43a047' },
		{ input: 'np★', output: 'Adrien Moyaux', group: 'Personal Info', color: '#1e88e5' },
		{ input: ',t', output: 'pt', group: 'Réduction SFBs', color: '#fb8c00' },
		{ input: 'jusqu', output: 'jusqu’', group: 'Autocorrection', color: '#43a047' },
		{ input: 'pex★', output: 'par exemple', group: 'Magic Key', color: '#e53935' },
		{ input: 'sx', output: 'sk', group: 'Roulements', color: '#fb8c00' }
	];

	let demoIndex = $state(0);
	let typed = $state('');
	let phase = $state('typing');
	let demoStepTimer;
	// Generation counter — incremented on every runCycle / goToDemo call so a
	// pending setTimeout from the previous cycle bails out the moment it fires.
	// Without this, a fast click on the pager could land its callback on top of
	// the new cycle and trample its state.
	let cycleGen = 0;

	// ─── OS detection + manual override ─────────────────────────
	// SSR default is 'windows' so the prerendered HTML already renders
	// with a Windows chrome (matching the most common audience).  On the
	// client we sniff navigator.userAgent and also honour an explicit
	// user choice persisted in localStorage so the toggle "sticks".
	let osStyle = $state('windows');

	function detectOS() {
		if (typeof navigator === 'undefined') return 'windows';
		const ua = navigator.userAgent || '';
		if (/mac/i.test(ua) && !/windows/i.test(ua)) return 'macos';
		return 'windows';
	}

	function setOS(next) {
		osStyle = next;
		try {
			localStorage.setItem('ergoptiplus.osStyle', next);
		} catch (_) {
			/* localStorage might be unavailable — silently fall back. */
		}
	}

	function runDemoStep(d, i, gen) {
		if (gen !== cycleGen) return;
		if (i < d.input.length) {
			typed = d.input.slice(0, i + 1);
			demoStepTimer = setTimeout(() => runDemoStep(d, i + 1, gen), 110);
			return;
		}
		// Finished typing the prefix. Show the tooltip preview, then "fire".
		phase = 'tooltip';
		demoStepTimer = setTimeout(() => {
			if (gen !== cycleGen) return;
			phase = 'expanded';
			typed = d.output;
			demoStepTimer = setTimeout(() => {
				if (gen !== cycleGen) return;
				demoIndex = (demoIndex + 1) % demos.length;
				runCycle();
			}, 1600);
		}, 900);
	}

	function runCycle() {
		cycleGen++;
		const gen = cycleGen;
		typed = '';
		phase = 'typing';
		demoStepTimer = setTimeout(() => runDemoStep(demos[demoIndex], 0, gen), 50);
	}

	function goToDemo(i) {
		clearTimeout(demoStepTimer);
		demoIndex = i;
		runCycle();
	}

	// Animated counters for the KPI strip — easeOut over 1.4s.
	const kpis = [
		{ value: 3000, suffix: '+', label: 'hotstrings prêts à l’emploi' },
		{ value: 6, suffix: '', label: 'catégories paramétrables' },
		{ value: 10, suffix: '', label: 'gestes trackpad' },
		{ value: 2, suffix: '', label: 'drivers natifs (macOS + Win)' }
	];
	let counters = $state(kpis.map(() => 0));
	let counterRaf;

	function animateCounters() {
		const start = performance.now();
		const duration = 1600;
		function tick(now) {
			const t = Math.min(1, (now - start) / duration);
			const eased = 1 - Math.pow(1 - t, 3);
			counters = kpis.map((k) => Math.round(k.value * eased));
			if (t < 1) counterRaf = requestAnimationFrame(tick);
		}
		counterRaf = requestAnimationFrame(tick);
	}

	// ─── Real-world session ─────────────────────────────────────────
	// Pre-recorded "session" demonstrating multiple expansions firing in a
	// single sentence. Each token is either a literal string ('lit') typed
	// verbatim, or a hotstring ('hot') with a `pre` (the user's keystrokes)
	// and a `post` (the expansion result). The animation streams character
	// by character; on a hotstring token it pauses, shows a brief tooltip,
	// then swaps the typed prefix for the expansion.
	const session = [
		{ type: 'lit', text: 'Bonjour, ' },
		{ type: 'hot', pre: 'jusqu', post: 'jusqu’', color: '#43a047', group: 'Auto' },
		{ type: 'lit', text: 'à hier ' },
		{ type: 'hot', pre: 'pex★', post: 'par exemple', color: '#e53935', group: 'Magic' },
		{ type: 'lit', text: ', je signais encore mes mails “' },
		{ type: 'hot', pre: 'np★', post: 'Adrien Moyaux', color: '#1e88e5', group: 'Perso' },
		{ type: 'lit', text: '” à la main. ' },
		{ type: 'hot', pre: 'ct★', post: 'c’était', color: '#e53935', group: 'Magic' },
		{ type: 'lit', text: ' fastidieux et ' },
		{ type: 'hot', pre: ',t', post: 'pt', color: '#fb8c00', group: 'SFB' },
		{ type: 'lit', text: 'imal pour les doigts.' }
	];

	let sessionText = $state('');
	let sessionTooltip = $state(null);
	let sessionTimer;

	function runSession() {
		sessionText = '';
		sessionTooltip = null;
		let tIdx = 0;
		let cIdx = 0;
		let pendingTooltip = false;

		function step() {
			if (tIdx >= session.length) {
				sessionTimer = setTimeout(runSession, 4000);
				return;
			}
			const tok = session[tIdx];
			if (tok.type === 'lit') {
				if (cIdx < tok.text.length) {
					sessionText += tok.text[cIdx];
					cIdx++;
					sessionTimer = setTimeout(step, 28 + Math.random() * 30);
				} else {
					tIdx++;
					cIdx = 0;
					sessionTimer = setTimeout(step, 60);
				}
			} else {
				if (cIdx < tok.pre.length) {
					sessionText += tok.pre[cIdx];
					cIdx++;
					sessionTimer = setTimeout(step, 50);
					return;
				}
				if (!pendingTooltip) {
					pendingTooltip = true;
					sessionTooltip = { text: tok.post, color: tok.color, group: tok.group };
					sessionTimer = setTimeout(step, 600);
					return;
				}
				// Swap the typed prefix for the expansion in-place.
				sessionText = sessionText.slice(0, sessionText.length - tok.pre.length) + tok.post;
				sessionTooltip = null;
				pendingTooltip = false;
				tIdx++;
				cIdx = 0;
				sessionTimer = setTimeout(step, 250);
			}
		}
		step();
	}

	onMount(async () => {
		// Fetch the GitHub release for driver download buttons.
		release = await getRelease();

		// Restore persisted choice if any, otherwise sniff the user agent.
		let stored = null;
		try {
			stored = localStorage.getItem('ergoptiplus.osStyle');
		} catch (_) {
			/* ignore */
		}
		osStyle = stored === 'macos' || stored === 'windows' ? stored : detectOS();

		// Hero typing demo cycles immediately so the page feels alive.
		runCycle();
		// 600 ms delay before the counters start animating so the user has
		// time to see the hero before the eye is pulled to the numbers.
		const kpiTimer = setTimeout(animateCounters, 600);
		runSession();
		return () => {
			clearTimeout(demoStepTimer);
			clearTimeout(kpiTimer);
			clearTimeout(sessionTimer);
			if (counterRaf) cancelAnimationFrame(counterRaf);
		};
	});

	const features = [
		{
			icon: '★',
			color: '#e53935',
			title: 'Touche magique',
			body: 'Une touche dédiée pour expanser des centaines d’abréviations : <code>ct★</code> devient <em>c’était</em>, <code>pex★</code> devient <em>par exemple</em>.'
		},
		{
			icon: '✓',
			color: '#43a047',
			title: 'Autocorrection',
			body: 'Apostrophes typographiques, majuscules sur les noms propres, accents oubliés — les fautes les plus fréquentes sont rattrapées au vol.'
		},
		{
			icon: '⟶',
			color: '#fb8c00',
			title: 'Roulements',
			body: 'Des bigrammes inconfortables réécrits à la volée : <code>hc</code> → <em>wh</em>, <code>qa</code> → <em>qua</em>, <code>(#</code> → <em>("</em>.'
		},
		{
			icon: '⌨',
			color: '#1e88e5',
			title: 'Hotstrings personnels',
			body: 'Vos snippets, signatures, IBAN, numéros récurrents — édités depuis un fichier TOML ou directement depuis le menu.'
		},
		{
			icon: '✥',
			color: '#8e44ad',
			title: 'Tap-holds',
			body: '<kbd>CapsLock</kbd> en <em>Entrée</em> en tap, <em>Cmd/Ctrl</em> en hold. <kbd>LShift</kbd> = Copier. <kbd>LCtrl</kbd> = Coller. Pas de touche perdue.'
		},
		{
			icon: '◐',
			color: '#00838f',
			title: 'Gestes trackpad',
			body: '10 slots de gestes (taps et swipes à 3 ou 4 doigts) configurables, mappés à n’importe quelle action système ou personnalisée.'
		},
		{
			icon: '◇',
			color: '#fdd835',
			title: 'Tooltip temps réel',
			body: 'Aperçu visuel coloré pendant la saisie : vous voyez l’expansion <em>avant</em> qu’elle ne se déclenche.'
		},
		{
			icon: '⌬',
			color: '#ec407a',
			title: 'Prédictions IA',
			body: 'Bridge LLM intégré côté Hammerspoon : suggestions contextuelles à la frappe, validables avec la touche magique.'
		}
	];

	// ─── Hotstrings deep dive ─────────────────────────────────────
	// Each category is shown WITH ITS REAL ENVIRONMENT — no isolated
	// "sx → sk" but "sx" written in the middle of typing "ask" so the user
	// sees how the roll actually saves them keystrokes in normal prose.
	// The examples preserve the original casing from the TOMLs so the
	// reader notices that uppercase entries (OUi → Oui, chatgpt → ChatGPT)
	// also work — these features ARE case-sensitive.
	// Universal hotstring categories — these work the same on AZERTY,
	// QWERTY, Bépo, etc. They operate on the produced TEXT, not on the
	// physical key, so they're cross-layout by construction.
	const hotstringDetails = [
		{
			title: 'Autocorrection',
			color: '#43a047',
			tag: 'Les fautes les plus fréquentes, balayées',
			lead: 'Apostrophes typographiques, capitalisation des marques, accents oubliés sur les noms propres et expressions courantes. Ce n’est pas du correcteur post-coup : c’est appliqué à la frappe.',
			rows: [
				{ trig: 'chatgpt', out: 'ChatGPT', words: ['ChatGPT m’a aidé sur…'] },
				{ trig: 'alexei', out: 'Alexeï', words: ['Alexeï Navalny'] },
				{ trig: 'OUi', out: 'Oui', words: ['Oui, je viens.'] },
				{ trig: 'jusqu', out: 'jusqu’', words: ['jusqu’à demain', 'jusqu’ici'] }
			]
		},
		{
			title: 'Touche magique ★',
			color: '#e53935',
			tag: 'Un suffixe explicite pour les expansions longues',
			lead: 'Pour vos snippets fréquents — formules de politesse, signatures, identifiants — la touche ★ déclenche l’expansion de manière non ambiguë. Aucun risque de collision avec la frappe normale.',
			rows: [
				{ trig: 'ct★', out: 'c’était', words: ['ct★ génial', '→ c’était génial'] },
				{ trig: 'pex★', out: 'par exemple', words: ['pex★ ce matin', '→ par exemple ce matin'] },
				{ trig: 'np★', out: 'Adrien Moyaux', words: ['Cordialement,\nnp★', '→ …\nAdrien Moyaux'] },
				{ trig: 'dt★', out: '07/05/2026', words: ['Le dt★ à 14h', '→ Le 07/05/2026 à 14h'] }
			]
		}
	];

	// Ergopti-specific text replacements. These ONLY make sense on the
	// Ergopti layout because they target precise key positions (e.g. the
	// SFB on c+t, the unused ,+letter sequences, the comfortable hc roll).
	// Grouped under their own h2 banner with a clear disclaimer.
	const ergoptiBigrams = [
		{
			title: 'Roulements de bigrammes',
			color: '#fb8c00',
			tag: 'Des combinaisons inconfortables remplacées par des roulements',
			lead: 'Quelques bigrammes naturellement inconfortables sur Ergopti sont remappés vers des séquences fluides qui glissent sur des doigts adjacents. Vous tapez ce qui est confortable, le mot correct sort.',
			rows: [
				{ trig: "p'", out: 'ct', words: ['acteur', 'docteur', 'docteurs'] },
				{ trig: 'sx', out: 'sk', words: ['ask', 'task', 'desk', 'risk'] },
				{ trig: 'cx', out: 'ck', words: ['back', 'check', 'dock'] },
				{ trig: 'hc', out: 'wh', words: ['what', 'when', 'where', 'while'] }
			]
		},
		{
			title: 'Réduction des SFBs',
			color: '#e53935',
			tag: 'Les Same-Finger Bigrams d’Ergopti, neutralisés',
			lead: 'La , devient une super touche morte qui supprime les derniers SFBs résiduels. Les touches É/È/Ê s’en chargent côté main gauche.',
			rows: [
				{ trig: ',t', out: 'pt', words: ['ap,tement → aptement'] },
				{ trig: 'éà', out: 'ié', words: ['c-éà-l → ciel'] },
				{ trig: 'àé', out: 'éi', words: ['ant-àé-r → antérieur'] },
				{ trig: 'êe', out: 'œ', words: ['s-êe-ur → sœur'] }
			]
		},
		{
			title: 'Hotstrings via touche magique ★',
			color: '#8e44ad',
			tag: 'Doublons et SFBs neutralisés via ★',
			lead: 'La touche ★ a deux comportements : répéter la dernière lettre, ou déclencher une expansion. Quelques expansions exclusivement Ergopti tirent profit de la position de ★ sous l’index gauche.',
			rows: [
				{ trig: 'à★', out: 'bu', words: ['dé-à★-t → début'] },
				{ trig: 'àu', out: 'ub', words: ['t-àu-e → tube'] },
				{ trig: '★ê', out: 'u', words: ['con★ê → connu', 'bat★ê → battu'] }
			]
		}
	];

	// ─── Power features ──────────────────────────────────────────
	// CapsWord, word deletion, easy personal-hotstrings authoring — short
	// cards highlighting little-known but high-impact niceties.
	const powerMoves = [
		{
			icon: '⇪',
			title: 'CapsWord',
			body: 'Tapez en MAJUSCULES uniquement le mot en cours. Dès que vous appuyez sur espace ou ponctuation, le shift virtuel se relâche. Idéal pour les acronymes (USA, NASA, TODO).'
		},
		{
			icon: '⌫',
			title: 'Suppression de mot',
			body: '<kbd>LAlt</kbd> + <kbd>Backspace</kbd> efface le mot entier au lieu d’un caractère. Pour annuler une expansion ratée d’un seul geste.'
		},
		{
			icon: '✎',
			title: 'Hotstrings perso 1-clic',
			body: 'Sélectionnez du texte, ouvrez le menu, donnez un trigger : votre nouveau hotstring est ajouté à <code>personal_hotstrings.toml</code> et chargé sans recharger le driver.'
		},
		{
			icon: '★',
			title: 'Touche magique = répéteur',
			body: 'Pas d’expansion à valider ? La touche magique répète simplement le caractère précédent — utile pour les <em>aaaaa</em> ou les <em>...</em>.'
		}
	];

	// ─── Navigation layer ────────────────────────────────────────
	// Mappings activated when LAlt is held. Real layout from the AHK driver
	// so the visual matches what the user actually gets after install.
	const navLayer = [
		{ keys: ['j'], label: '←', desc: 'Gauche' },
		{ keys: ['k'], label: '↓', desc: 'Bas' },
		{ keys: ['l'], label: '↑', desc: 'Haut' },
		{ keys: ['m'], label: '→', desc: 'Droite' },
		{ keys: ['u'], label: '⇱', desc: 'Début ligne' },
		{ keys: [','], label: '⇲', desc: 'Fin ligne' },
		{ keys: ['i'], label: '⇞', desc: 'Page haut' },
		{ keys: ['o'], label: '⇟', desc: 'Page bas' },
		{ keys: ['h'], label: '⌫', desc: 'Effacer mot' },
		{ keys: [';'], label: '⌦', desc: 'Suppr droite' }
	];

	// ─── AI predictions ──────────────────────────────────────────
	const aiContext = 'Bonjour Madame, je vous écris pour ';
	const aiSuggestions = [
		'vous proposer un rendez-vous mardi prochain.',
		'faire suite à notre échange de la semaine dernière.',
		'accuser réception de votre dossier complet.'
	];

	// ─── Typing metrics ──────────────────────────────────────────
	const metrics = [
		{ label: 'Mots tapés cette semaine', value: '34 218', accent: '#1e88e5', delta: '+12 %' },
		{ label: 'Vitesse moyenne', value: '78 wpm', accent: '#43a047', delta: '+4 wpm' },
		{ label: 'Précision', value: '97,8 %', accent: '#fb8c00', delta: '+0,3 pt' },
		{ label: 'SFBs évités', value: '1 247', accent: '#e53935', delta: 'roulements' },
		{ label: 'Hotstrings déclenchés', value: '892', accent: '#8e44ad', delta: '147 uniques' },
		{ label: 'Doigts dominants', value: 'I-D 51 / 49', accent: '#00838f', delta: 'équilibré' }
	];

	// Tap-hold showcase — these mappings turn three modifier keys into double
	// agents and recover one of the most underused real-estate areas of any
	// keyboard. Each card pairs a "tap" action (short press) with a "hold"
	// behaviour, illustrating how a single key now serves two purposes.
	const tapHolds = [
		{
			key: 'CapsLock',
			tap: { label: 'Entrée', icon: '↩' },
			hold: { label: 'Cmd / Ctrl', icon: '⌘' },
			color: '#e53935',
			note: 'La touche la plus à plat de la maison-row devient à la fois validation et modificateur d’OS.'
		},
		{
			key: 'LShift',
			tap: { label: 'Copier', icon: '⧉' },
			hold: { label: 'Shift', icon: '⇧' },
			color: '#1e88e5',
			note: 'Plus besoin d’aller chercher Ctrl/Cmd + C : un simple appui sur la touche que vous tenez déjà.'
		},
		{
			key: 'LCtrl',
			tap: { label: 'Coller', icon: '↧' },
			hold: { label: 'Ctrl', icon: '⌃' },
			color: '#43a047',
			note: 'Coller au pouce gauche, sans changer la position de la main droite ni interrompre le flux.'
		},
		{
			key: 'LAlt',
			tap: { label: 'Retour arrière', icon: '⌫' },
			hold: { label: 'Layer navigation', icon: '☷' },
			color: '#fb8c00',
			note: 'Backspace devient un voisin direct du repos des doigts ; en hold, un layer de flèches et navigation.'
		}
	];

	// ─── Reassurance promises ────────────────────────────────────
	// Three short cards placed near the top to defuse the fear of complexity.
	// Each one is phrased as a benefit from the user's perspective ("you
	// gain X"), not as a feature ("we offer X"). Adoption is progressive —
	// you don't have to learn everything at once.
	const promises = [
		{
			icon: '⏱',
			title: 'Vous gagnez du temps dès la 1ʳᵉ heure',
			body: 'Apostrophes, accents, expansions classiques : 80 % du gain est livré <strong>par défaut</strong>, sans rien apprendre. Vous tapez normalement, le reste se règle tout seul.'
		},
		{
			icon: '🌱',
			title: 'Apprentissage progressif, jamais imposé',
			body: 'Chaque fonctionnalité est <strong>activable indépendamment</strong>. Démarrez avec les hotstrings, ajoutez les tap-holds quand vous êtes prêt, l’IA en bonus. Aucune obligation.'
		},
		{
			icon: '🌐',
			title: 'Fonctionne sur <strong>toutes</strong> les dispositions',
			body: 'AZERTY, QWERTY, Bépo, Dvorak, Colemak… Le driver agit sur le texte, pas sur la touche physique. Restez sur votre layout actuel — ou adoptez Ergopti pour le combo idéal.'
		}
	];

	// ─── AI / LLM block — backends, models, prompt profiles ─────
	// The user can pick the backend that matches their machine, then
	// pick a model from a maintained list, then pick a prompt profile.
	// Custom prompts are also possible via a TOML file. All inference
	// happens locally — nothing leaves the machine.
	const aiBackends = [
		{
			name: 'Ollama',
			icon: '🦙',
			audience: 'Mac Intel & Apple Silicon',
			port: '11434',
			pro: 'Le plus simple à installer (brew install ollama). Catalogue de modèles immense.'
		},
		{
			name: 'MLX',
			icon: '⚡',
			audience: 'Apple Silicon (M1, M2, M3, M4)',
			port: '8080',
			pro: 'Inference accélérée par le Neural Engine. Sub-100 ms sur les petits modèles.'
		}
	];

	// 4 built-in profiles defined in modules/llm/profiles.lua. The user can
	// add their own profile via the prompt editor (custom prompts persisted
	// in the config). Names match the actual code identifiers.
	const aiProfiles = [
		{
			name: 'Raw',
			tag: 'Continuation littérale',
			desc: 'Aucune instruction injectée — le modèle reçoit juste le contexte brut <code>{context}</code> et continue. Idéal pour le code, les listes, les formats stricts.'
		},
		{
			name: 'Basic',
			tag: 'Profil par défaut',
			desc: 'Instruction française minimale qui contraint le modèle à produire entre N et M mots, sans commentaires. Le compromis vitesse/qualité standard.'
		},
		{
			name: 'Advanced',
			tag: 'Correction + prédiction',
			desc: 'Format à deux lignes : <code>TAIL_CORRECTED</code> (correction) puis <code>NEXT_WORDS</code> (prédiction). Bilingue FR/EN, accompagné d’exemples few-shot pour les petits modèles.'
		},
		{
			name: 'Batch Advanced',
			tag: 'N suggestions en 1 requête',
			desc: 'Une seule requête réseau qui produit N continuations alternatives séparées par <code>===</code>. Beaucoup plus économique qu’N requêtes séquentielles.'
		}
	];

	// ─── Trackpad gestures (Hammerspoon only — macOS) ───────────
	// macOS undocumented touchdevice API gives us raw multi-touch events.
	// 18+ slots configurable. The 3-finger tap → word definition is the
	// killer ergonomic move.
	const trackpadGestures = [
		{
			fingers: '3 doigts',
			type: 'Tap',
			defaut: 'Définition du mot',
			color: '#00838f',
			note: 'Pose 3 doigts sur un mot, sa définition apparaît instantanément. Plus naturel qu’un Cmd+Ctrl+D.'
		},
		{
			fingers: '3 doigts',
			type: 'Swipe ←/→',
			defaut: 'Mot précédent / mot suivant',
			color: '#1e88e5',
			note: 'Glissement horizontal léger pour avancer mot par mot dans n’importe quel champ texte.'
		},
		{
			fingers: '3 doigts',
			type: 'Swipe ↑',
			defaut: 'Volume +',
			color: '#43a047',
			note: 'Le trackpad devient un axe continu : plus le geste est long, plus le volume monte.'
		},
		{
			fingers: '3 doigts',
			type: 'Swipe ↓',
			defaut: 'Volume −',
			color: '#43a047',
			note: 'Symétrique au précédent.'
		},
		{
			fingers: '4 doigts',
			type: 'Tap',
			defaut: 'Copier',
			color: '#fb8c00',
			note: 'Sélectionnez du texte avec deux doigts puis tapez à 4 — c’est plus rapide que Cmd+C.'
		},
		{
			fingers: '4 doigts',
			type: 'Swipe ←/→',
			defaut: 'Onglet précédent / suivant',
			color: '#8e44ad',
			note: 'Navigation entre onglets de navigateur sans toucher au clavier.'
		},
		{
			fingers: '5 doigts',
			type: 'Swipe ↑',
			defaut: 'Mission Control',
			color: '#ec407a',
			note: 'Aperçu de toutes les fenêtres, sans Cmd+Tab.'
		},
		{
			fingers: '5 doigts',
			type: 'Swipe ↓',
			defaut: 'App Switcher',
			color: '#ec407a',
			note: 'Cmd+Tab natif, mais un geste à la place du raccourci.'
		}
	];

	// ─── Comma super-key (Ergopti+ exclusive sugar) ─────────────
	// The , key becomes a multi-purpose helper. It replaces missing
	// letters (j, z, k, q, ç, où) without using any modifier.
	const commaVowels = [
		{ keys: ',a', out: 'ja' },
		{ keys: ',e', out: 'je' },
		{ keys: ',i', out: 'ji' },
		{ keys: ',o', out: 'jo' },
		{ keys: ',u', out: 'ju' },
		{ keys: ',é', out: 'jé' },
		{ keys: ",'", out: 'j’' }
	];

	const commaConsonants = [
		{ keys: ',è', out: 'z', note: 'Lettre Z' },
		{ keys: ',y', out: 'k', note: 'Lettre K' },
		{ keys: ',s', out: 'q', note: 'Lettre Q' },
		{ keys: ',c', out: 'ç', note: 'Cédille' },
		{ keys: ',x', out: 'où', note: 'Mot complet' }
	];

	// ─── Suffixes en À ───────────────────────────────────────────
	// The à key is followed by a suffix to expand frequent French endings.
	const suffixesA = [
		{ keys: 'às', out: 'ement' },
		{ keys: 'àt', out: 'ation' },
		{ keys: 'àn', out: 'ment' },
		{ keys: 'àr', out: 'eur' },
		{ keys: 'àl', out: 'elle' },
		{ keys: 'àp', out: 'isme' }
	];

	// ─── Personal hotstrings (TOML examples) ────────────────────
	const personalExamples = [
		{ trig: 'np★', out: 'Adrien Moyaux', desc: 'Nom complet' },
		{ trig: 'em★', out: 'adrien@example.com', desc: 'E-mail principal' },
		{ trig: 'tel★', out: '+33 6 12 34 56 78', desc: 'Numéro de téléphone' },
		{ trig: 'sig★', out: 'Cordialement,\nAdrien', desc: 'Signature email' },
		{ trig: 'ad★', out: '15 rue Lafayette, Paris', desc: 'Adresse postale' },
		{ trig: 'iban★', out: 'FR76 1234 5678 9012 3456 7890 123', desc: 'IBAN' }
	];

	// ─── Dynamic hotstrings (auto-computed at fire time) ───────
	const dynamicExamples = [
		{ prefix: '@dt', desc: 'Date du jour (FR)', out: '07/05/2026' },
		{ prefix: '@dtL', desc: 'Date du jour en lettres', out: '7 mai 2026' },
		{ prefix: '@ph', desc: 'Téléphone configuré', out: '06 12 34 56 78' },
		{ prefix: '@iban', desc: 'IBAN configuré', out: 'FR76 1234 …' }
	];

	// ─── Repeater (★ to double the previous letter) ─────────────
	const repeaterExamples = [
		{ trig: 'l★', out: 'll', word: 'elle' },
		{ trig: 'r★', out: 'rr', word: 'erreur' },
		{ trig: 't★', out: 'tt', word: 'attendre' },
		{ trig: 'p★', out: 'pp', word: 'frappe' },
		{ trig: 'n★', out: 'nn', word: 'année' }
	];

	// ─── Symbol rolls (programming) ─────────────────────────────
	const symbolRolls = [
		{ trig: '#!', out: ':=', note: 'Affectation (Go, Pascal)' },
		{ trig: '!#', out: '!=', note: 'Différent de' },
		{ trig: '<@', out: '</', note: 'Fermeture HTML/JSX' },
		{ trig: '<%', out: '<=', note: 'Inférieur ou égal' },
		{ trig: '$=', out: '=>', note: 'Fat arrow (JS)' },
		{ trig: '+?', out: '->', note: 'Flèche (Rust, types)' },
		{ trig: '\\"', out: '/*', note: 'Début commentaire bloc' },
		{ trig: '"\\', out: '*/', note: 'Fin commentaire bloc' },
		{ trig: '(#', out: '("', note: 'Ouverture string en argument' },
		{ trig: '[)', out: '=""', note: 'Attribut HTML vide' }
	];

	// ─── Personalization features ───────────────────────────────
	const personalizationCards = [
		{
			icon: '⏯',
			title: 'Pause & rechargement',
			body: 'Un raccourci pour mettre <strong>tout</strong> en pause (gaming, démos, partage d’écran). Un autre pour recharger le driver après un changement de TOML, sans relancer Hammerspoon ou AHK.'
		},
		{
			icon: '🚫',
			title: 'Apps ignorées',
			body: 'Listez les applications dans lesquelles aucun hotstring ne doit se déclencher (gestionnaire de mots de passe, terminal sécurisé, jeu vidéo). Reconnaissance par nom ou expression régulière.'
		},
		{
			icon: '🎨',
			title: 'Couleurs personnalisables',
			body: 'Chaque famille a sa teinte de tooltip. Vert pour l’autocorrection, rouge pour la touche magique, bleu pour vos hotstrings perso. Tout est éditable depuis le menu, ou désactivable.'
		},
		{
			icon: '⏱',
			title: 'Délais par groupe',
			body: 'Tapez vite ? Réduisez le délai d’expansion pour les roulements à 200 ms. Plus posé ? Montez à 800 ms. Chaque famille est réglable indépendamment.'
		},
		{
			icon: '📁',
			title: 'Chemins de configuration',
			body: 'Stockez vos hotstrings où vous voulez : dans iCloud, sur un Dropbox partagé, dans un dotfiles repo Git. L’éditeur de chemins du menu repositionne tous les fichiers en un clic.'
		},
		{
			icon: '🔐',
			title: 'Aucune donnée ne quitte la machine',
			body: 'Toutes les expansions, prédictions IA et métriques sont calculées localement. Pas de cloud, pas de télémétrie, pas de compte à créer.'
		}
	];

	// Unified feature matrix — same wording on both rows so the eye scans
	// horizontally without re-reading. Windows currently lacks the LLM
	// prediction bridge and the typing-metrics module; everything else is
	// at parity (the AHK driver matches Hammerspoon for the core hotstring
	// and tap-hold pipeline).
	const compareFeatures = [
		{ label: 'Hotstrings + autocorrection', mac: true, win: true },
		{ label: 'Touche magique ★', mac: true, win: true },
		{ label: 'Roulements personnalisés', mac: true, win: true },
		{ label: 'Hotstrings personnels (TOML)', mac: true, win: true },
		{ label: 'Tap-holds modificateurs', mac: true, win: true },
		{ label: 'Tooltip temps réel teinté', mac: true, win: true },
		{ label: 'Gestes trackpad', mac: true, win: true },
		{ label: 'Menu de configuration intégré', mac: true, win: true },
		{ label: 'Prédictions IA (bridge LLM)', mac: true, win: false },
		{ label: 'Métriques de frappe', mac: true, win: false }
	];
</script>

<svelte:head>
	<title>Ergopti+ — la disposition qui frappe juste</title>
	<meta
		name="description"
		content="Ergopti+ est une disposition clavier optimisée pour le français, l’anglais et le code, accompagnée d’un driver complet sur macOS (Hammerspoon) et Windows (AutoHotkey)."
	/>
</svelte:head>

<!--
  The site-wide layout (+layout.svelte) and the shared Header expect these
  three IDs to exist:
    #main-content — scanned by makeIds() to assign anchors to headings
    #page-toc-pc, #page-toc — moved around by Header.toggleOverflowMenu()
                              when the menu opens / window resizes
  PageWrapper.svelte normally renders them, but this page uses a custom
  marketing layout instead. We render minimal hidden stubs so the layout's
  $effect blocks don't throw "argument is not an object" / "content is null"
  and break every other client-side script on the page (KPI counters,
  typing demo, OS toggle).
-->
<div id="main-content">
	<div id="page-toc-pc" style="display: none">
		<div id="page-toc"></div>
	</div>
	<!-- Lien temporaire vers l'ancienne page Ergopti+ le temps que la nouvelle soit validée -->
	<div class="legacy-banner">
		<a href="ergopti-plus-old">← Ancienne version de cette page</a>
	</div>
	<main class="ep-main">
		<div class="ep-root">
			<!-- ────────────────────────── Hero ────────────────────────── -->
			<section class="hero">
				<div class="hero-glow"></div>

				<div class="os-toggle">
					<button
						type="button"
						class={osStyle === 'windows' ? 'os-btn active' : 'os-btn'}
						onclick={() => setOS('windows')}
						title="Afficher les fenêtres au style Windows (AutoHotkey)"
						aria-pressed={osStyle === 'windows' ? 'true' : 'false'}
						aria-label="Style Windows"
					>
						<i class="icon-windows"></i><span>Windows</span>
					</button>
					<button
						type="button"
						class={osStyle === 'macos' ? 'os-btn active' : 'os-btn'}
						onclick={() => setOS('macos')}
						title="Afficher les fenêtres au style macOS (Hammerspoon)"
						aria-pressed={osStyle === 'macos' ? 'true' : 'false'}
						aria-label="Style macOS"
					>
						<i class="icon-appleinc"></i><span>macOS</span>
					</button>
				</div>

				<p class="eyebrow">Disposition clavier <span class="dot">•</span> macOS &amp; Windows</p>
				<h1 class="hero-title">
					Tapez moins.<br /><span class="grad">Écrivez plus.</span>
				</h1>
				<p class="hero-sub">
					<ErgoptiPlus></ErgoptiPlus> ajoute à <strong>Ergopti</strong> une couche logicielle complète
					: expansions de texte, autocorrection, roulements, tap-holds, gestes — pensés pour le français,
					l’anglais et le code.
				</p>

				<div class="hero-cta">
					{#if osStyle === 'macos'}
						<a class="btn btn-primary" href={urlMacosApp} download={!!release}>
							<i class="icon-hammerspoon"></i>
							<span>Télécharger pour macOS</span>
						</a>
					{:else}
						<a class="btn btn-primary" href={urlAhkExe} download={!!release}>
							<i class="icon-autohotkey"></i>
							<span>Télécharger pour Windows</span>
						</a>
					{/if}
					<a class="btn btn-secondary" href="utilisation">
						<span>Installer la disposition clavier</span>
					</a>
				</div>

				<!-- Live typing demo — fake terminal-like surface that types a prefix,
		     shows a coloured tooltip, then reveals the expansion. -->
				<div class="demo-stage">
					<div class="demo-window os-{osStyle}" aria-hidden="true">
						<div class="chrome">
							{#if osStyle === 'macos'}
								<span class="mac-dots">
									<span class="dot dot-r"></span>
									<span class="dot dot-y"></span>
									<span class="dot dot-g"></span>
								</span>
								<span class="chrome-title">~/notes/draft.md</span>
								<span class="chrome-spacer"></span>
							{:else}
								<span class="chrome-title chrome-title--win">~/notes/draft.md</span>
								<span class="win-buttons">
									<span class="win-btn" aria-hidden="true">─</span>
									<span class="win-btn" aria-hidden="true">▢</span>
									<span class="win-btn close" aria-hidden="true">✕</span>
								</span>
							{/if}
						</div>
						<div class="demo-viewport">
							{#key demoIndex}
								<div
									class="demo-body"
									in:fly={{ x: 80, duration: 320, opacity: 0.2 }}
									out:fly={{ x: -80, duration: 280, opacity: 0 }}
								>
									<span class="demo-typed">{typed}</span><span class="caret"></span>
									{#if phase === 'tooltip'}
										<div
											class="demo-tooltip"
											style="--tt: {demos[demoIndex].color};"
											data-state="tooltip"
										>
											<span class="tt-text">{demos[demoIndex].output}</span>
											<span class="tt-tag">{demos[demoIndex].group}</span>
										</div>
									{/if}
								</div>
							{/key}
						</div>
					</div>

					<ul class="demo-pager" aria-label="Sélectionner une démo">
						{#each demos as d, i}
							<li>
								<button
									type="button"
									class:active={i === demoIndex}
									onclick={() => goToDemo(i)}
									title="{d.input} → {d.output} ({d.group})"
									aria-label="Démo {i + 1} sur {demos.length} : {d.input} devient {d.output}"
								>
									<span class="pager-input">{d.input}</span>
									<span class="pager-arrow">→</span>
									<span class="pager-output">{d.output}</span>
								</button>
							</li>
						{/each}
					</ul>
				</div>
			</section>

			<!-- ────────────────────────── KPI strip ─────────────────────── -->
			<section class="kpi-strip">
				{#each kpis as kpi, i}
					<div class="kpi">
						<div class="kpi-num">{counters[i]}{kpi.suffix}</div>
						<div class="kpi-label">{kpi.label}</div>
					</div>
				{/each}
			</section>

			<!-- ────────────────────────── Promises (defuse fear) ──────── -->
			<section class="promises">
				<header class="section-head">
					<p class="kicker">Trois promesses</p>
					<h2>Une suite riche, jamais imposante.</h2>
					<p class="lead">
						<ErgoptiPlus></ErgoptiPlus> embarque <strong>une trentaine de fonctionnalités</strong>.
						Pas de panique : aucune n’est obligatoire, tout est désactivable, et le bénéfice arrive
						dès la première session.
					</p>
				</header>

				<div class="promise-grid">
					{#each promises as p}
						<article class="promise-card">
							<div class="promise-icon" aria-hidden="true">{p.icon}</div>
							<h3>{@html p.title}</h3>
							<p>{@html p.body}</p>
						</article>
					{/each}
				</div>
			</section>

			<!-- ────────────────────────── Real session ─────────────────── -->
			<section class="session">
				<header class="section-head">
					<p class="kicker">Au fil de la frappe</p>
					<h2>Une vraie phrase, plusieurs expansions.</h2>
					<p class="lead">
						Voici ce qui se passe à l’écran quand vous tapez naturellement. Les expansions
						s’enchaînent sans rompre le flux.
					</p>
				</header>

				<div class="session-window os-{osStyle}">
					<div class="chrome">
						{#if osStyle === 'macos'}
							<span class="mac-dots">
								<span class="dot dot-r"></span>
								<span class="dot dot-y"></span>
								<span class="dot dot-g"></span>
							</span>
							<span class="chrome-title">message.txt</span>
							<span class="chrome-spacer"></span>
						{:else}
							<span class="chrome-title chrome-title--win">message.txt</span>
							<span class="win-buttons">
								<span class="win-btn" aria-hidden="true">─</span>
								<span class="win-btn" aria-hidden="true">▢</span>
								<span class="win-btn close" aria-hidden="true">✕</span>
							</span>
						{/if}
					</div>
					<div class="session-body">
						<p class="session-line">{sessionText}<span class="caret"></span></p>
						{#if sessionTooltip}
							<div class="session-tooltip" style="--tt: {sessionTooltip.color};">
								<span class="tt-text">{sessionTooltip.text}</span>
								<span class="tt-tag">{sessionTooltip.group}</span>
							</div>
						{/if}
					</div>
				</div>
			</section>

			<!-- ────────────────────────── Features grid ─────────────────── -->
			<section class="features">
				<header class="section-head">
					<p class="kicker">Tout dans un seul driver</p>
					<h2>Une fonctionnalité, un raccourci, une couleur.</h2>
					<p class="lead">
						Chaque famille d’expansion a sa teinte dans le tooltip. Vous savez d’un coup d’œil ce
						qui va se déclencher.
					</p>
				</header>

				<div class="feat-grid">
					{#each features as f}
						<article class="feat-card" style="--accent: {f.color};">
							<div class="feat-glyph" aria-hidden="true">{f.icon}</div>
							<h3>{f.title}</h3>
							<p>{@html f.body}</p>
						</article>
					{/each}
				</div>
			</section>

			<!-- ────────────────────────── Tap-holds spotlight ───────────── -->
			<section class="tapholds">
				<header class="section-head">
					<p class="kicker" style="color:#fb8c00">Confort × 2</p>
					<h2>Une touche, deux comportements.</h2>
					<p class="lead">
						Les modificateurs de la rangée des pouces et de la maison récupèrent une seconde vie. Un
						appui bref envoie une action, un maintien renvoie à leur rôle d’origine. Plus jamais
						besoin d’aller chercher
						<kbd>Ctrl</kbd>
						+ <kbd>C</kbd> avec la main droite.
					</p>
				</header>

				<div class="tap-grid">
					{#each tapHolds as t}
						<article class="tap-card" style="--accent: {t.color};">
							<div class="tap-key">
								<span class="tap-keycap">{t.key}</span>
							</div>
							<div class="tap-rows">
								<div class="tap-row tap-row-tap">
									<span class="tap-pill">Tap</span>
									<span class="tap-glyph">{t.tap.icon}</span>
									<span class="tap-action">{t.tap.label}</span>
								</div>
								<div class="tap-row tap-row-hold">
									<span class="tap-pill tap-pill-hold">Hold</span>
									<span class="tap-glyph">{t.hold.icon}</span>
									<span class="tap-action">{t.hold.label}</span>
								</div>
							</div>
							<p class="tap-note">{t.note}</p>
						</article>
					{/each}
				</div>
			</section>

			<!-- ────────────────────────── Hotstrings deep dive ─────────── -->
			<section class="hotdetail">
				<header class="section-head">
					<p class="kicker">Au cœur de la frappe</p>
					<h2>Quatre familles, un même réflexe.</h2>
					<p class="lead">
						Voici à quoi ressemble chaque catégorie d’expansion <strong>en contexte réel</strong> — pas
						des triggers isolés. Vous tapez un mot, le mot que vous vouliez sort.
					</p>
				</header>

				<div class="hotdetail-grid">
					{#each hotstringDetails as cat}
						<article class="hotdetail-card" style="--accent: {cat.color};">
							<header class="hotdetail-head">
								<span class="hotdetail-dot"></span>
								<div>
									<h3>{cat.title}</h3>
									<p class="hotdetail-tag">{cat.tag}</p>
								</div>
							</header>
							<p class="hotdetail-lead">{cat.lead}</p>
							<ul class="hotdetail-rows">
								{#each cat.rows as r}
									<li>
										<div class="hot-trig">
											<span class="hot-key">{r.trig}</span>
											<span class="hot-arrow">→</span>
											<span class="hot-out">{r.out}</span>
										</div>
										<div class="hot-context">
											{#each r.words as w}
												<span class="hot-word">{w}</span>
											{/each}
										</div>
									</li>
								{/each}
							</ul>
						</article>
					{/each}
				</div>
			</section>

			<!-- ────────────────────────── Hotstrings persos & dynamiques ─ -->
			<section class="hsmore">
				<header class="section-head">
					<p class="kicker" style="color:#1e88e5">Vos propres hotstrings</p>
					<h2>Et ceux que <em>vous</em> tapez tous les jours.</h2>
					<p class="lead">
						Les +3 000 hotstrings livrés sont une base. Au-dessus, ajoutez votre signature, votre
						IBAN, vos formules récurrentes — sans toucher à un seul fichier de code.
					</p>
				</header>

				<div class="hsmore-grid">
					<article class="hsmore-card">
						<header class="hsmore-head">
							<h3>Hotstrings personnels</h3>
							<p class="hsmore-sub">
								Édités depuis le menu, stockés en TOML, rechargés à la volée.
							</p>
						</header>

						<h4>Ajouter un raccourci en 5 secondes</h4>
						<ol class="hsmore-steps">
							<li>Sélectionnez le texte que vous voulez transformer en hotstring.</li>
							<li>Ouvrez le menu → <strong>Hotstrings perso</strong>.</li>
							<li>Donnez un trigger (ex&nbsp;: <code>sig★</code>).</li>
							<li>C’est en place, sans relancer le driver.</li>
						</ol>

						<h4>Quelques exemples typiques</h4>
						<ul class="hsmore-rows">
							{#each personalExamples as p}
								<li>
									<span class="hs-key">{p.trig}</span>
									<span class="hs-arrow">→</span>
									<span class="hs-out">{p.out}</span>
									<span class="hs-desc">{p.desc}</span>
								</li>
							{/each}
						</ul>
					</article>

					<article class="hsmore-card">
						<header class="hsmore-head">
							<h3>Hotstrings dynamiques</h3>
							<p class="hsmore-sub">
								Calculés au moment du déclenchement — date du jour, IBAN, infos perso.
							</p>
						</header>

						<h4>Préfixe <code>@</code> pour les données vivantes</h4>
						<p class="hsmore-text">
							Certaines valeurs changent chaque jour (la date) ou ne doivent pas être codées en dur
							(numéro de téléphone, IBAN). Les hotstrings dynamiques lisent ces valeurs au moment de
							l’expansion.
						</p>

						<ul class="hsmore-rows">
							{#each dynamicExamples as d}
								<li>
									<span class="hs-key">{d.prefix}</span>
									<span class="hs-arrow">→</span>
									<span class="hs-out">{d.out}</span>
									<span class="hs-desc">{d.desc}</span>
								</li>
							{/each}
						</ul>

						<h4>Vos infos en un seul endroit</h4>
						<p class="hsmore-text">
							L’éditeur d’infos personnelles centralise nom, e-mail, téléphone, adresse, IBAN. Les
							hotstrings dynamiques s’en servent automatiquement.
						</p>
					</article>
				</div>
			</section>

			<!-- ────────────────────────── Magic key — full picture ────── -->
			<section class="magic">
				<header class="section-head">
					<p class="kicker" style="color:#e53935">★ — la touche signature</p>
					<h2>Une touche, deux comportements.</h2>
					<p class="lead">
						La touche <kbd class="glow">★</kbd> a deux modes :
						<strong>répéter la lettre précédente</strong>
						ou <strong>déclencher une expansion (hotstring)</strong>. Les deux sont décidés au
						moment du déclenchement selon le contexte — sans configuration.
					</p>
				</header>

				<div class="magic-grid magic-grid-2">
					<article class="magic-card">
						<h3>1. Répéteur de lettre</h3>
						<p>
							Si aucune abréviation ne correspond, <kbd class="glow">★</kbd> double simplement la
							lettre précédente. <strong>Plus de SFB sur les doublons.</strong>
						</p>
						<ul class="magic-rows">
							{#each repeaterExamples as r}
								<li>
									<span class="hs-key">{r.trig}</span>
									<span class="hs-arrow">→</span>
									<span class="hs-out">{r.out}</span>
									<span class="hs-desc">{r.word}</span>
								</li>
							{/each}
						</ul>
					</article>

					<article class="magic-card">
						<h3>2. Déclencheur d’abréviations</h3>
						<p>
							Si la lettre précédente forme un trigger connu, <kbd class="glow">★</kbd> expanse à la
							place. Aucun risque de collision avec la frappe normale.
						</p>
						<ul class="magic-rows">
							<li>
								<span class="hs-key">a★</span><span class="hs-arrow">→</span><span class="hs-out"
									>ainsi</span
								>
							</li>
							<li>
								<span class="hs-key">c★</span><span class="hs-arrow">→</span><span class="hs-out"
									>c’est</span
								>
							</li>
							<li>
								<span class="hs-key">ct★</span><span class="hs-arrow">→</span><span class="hs-out"
									>c’était</span
								>
							</li>
							<li>
								<span class="hs-key">dé★</span><span class="hs-arrow">→</span><span class="hs-out"
									>déjà</span
								>
							</li>
							<li>
								<span class="hs-key">ê★</span><span class="hs-arrow">→</span><span class="hs-out"
									>être</span
								>
							</li>
							<li>
								<span class="hs-key">eef★</span><span class="hs-arrow">→</span><span class="hs-out"
									>en effet</span
								>
							</li>
							<li>
								<span class="hs-key">f★</span><span class="hs-arrow">→</span><span class="hs-out"
									>faire</span
								>
							</li>
							<li>
								<span class="hs-key">m★</span><span class="hs-arrow">→</span><span class="hs-out"
									>mais</span
								>
							</li>
							<li>
								<span class="hs-key">pcq★</span><span class="hs-arrow">→</span><span class="hs-out"
									>parce que</span
								>
							</li>
							<li>
								<span class="hs-key">pê★</span><span class="hs-arrow">→</span><span class="hs-out"
									>peut-être</span
								>
							</li>
							<li>
								<span class="hs-key">pex★</span><span class="hs-arrow">→</span><span class="hs-out"
									>par exemple</span
								>
							</li>
							<li>
								<span class="hs-key">r★</span><span class="hs-arrow">→</span><span class="hs-out"
									>rien</span
								>
							</li>
						</ul>
					</article>
				</div>
			</section>

			<!-- ────────────────────────── Power moves ─────────────────── -->
			<section class="power">
				<header class="section-head">
					<p class="kicker" style="color:#8e44ad">Petits réflexes, gros gain</p>
					<h2>Les détails qui changent la frappe.</h2>
					<p class="lead">Quatre fonctions discrètes mais qu’on ne lâche plus une fois adoptées.</p>
				</header>

				<div class="power-grid">
					{#each powerMoves as p}
						<div class="power-card">
							<div class="power-icon">{p.icon}</div>
							<h3>{p.title}</h3>
							<p>{@html p.body}</p>
						</div>
					{/each}
				</div>
			</section>

			<!-- ────────────────────────── Navigation layer ─────────────── -->
			<section class="navlayer">
				<header class="section-head">
					<p class="kicker" style="color:#fb8c00">Layer maintien</p>
					<h2>Naviguer sans quitter la maison-row.</h2>
					<p class="lead">
						Maintenez <kbd>LAlt</kbd> et la moitié droite du clavier devient un cluster de navigation
						complet. Plus de zigzag vers les flèches, le pavé numérique ou la souris.
					</p>
				</header>

				<div class="navlayer-window">
					<div class="navlayer-hold">
						<span class="navlayer-pill">Hold</span>
						<span class="navlayer-key">LAlt</span>
						<span class="navlayer-plus">+</span>
					</div>
					<div class="navlayer-grid">
						{#each navLayer as n}
							<div class="navlayer-cell">
								<div class="navlayer-base">
									{#each n.keys as k}<kbd>{k}</kbd>{/each}
								</div>
								<div class="navlayer-arrow">becomes</div>
								<div class="navlayer-target">
									<span class="navlayer-glyph">{n.label}</span>
									<span class="navlayer-desc">{n.desc}</span>
								</div>
							</div>
						{/each}
					</div>
				</div>
			</section>

			<!-- ────────────────────────── AI Predictions (mac only) ──── -->
			<section class="ai">
				<header class="section-head">
					<p class="kicker" style="color:#ec407a">Pont LLM intégré · macOS</p>
					<h2>Une IA locale qui prédit ce que vous voulez écrire.</h2>
					<p class="lead">
						Hammerspoon embarque un pont vers un modèle de langage qui tourne <strong
							>sur votre Mac</strong
						>, pas dans le cloud. Aucune donnée n’est envoyée à l’extérieur, le modèle est rapide,
						et il apprend votre style sans rien stocker.
					</p>
				</header>

				<!-- Mock editor with live AI suggestion tooltip -->
				<div class="ai-window os-{osStyle}">
					<div class="chrome">
						{#if osStyle === 'macos'}
							<span class="mac-dots">
								<span class="dot dot-r"></span>
								<span class="dot dot-y"></span>
								<span class="dot dot-g"></span>
							</span>
							<span class="chrome-title">~/inbox/draft.eml</span>
							<span class="chrome-spacer"></span>
						{:else}
							<span class="chrome-title chrome-title--win">~/inbox/draft.eml</span>
							<span class="win-buttons">
								<span class="win-btn" aria-hidden="true">─</span>
								<span class="win-btn" aria-hidden="true">▢</span>
								<span class="win-btn close" aria-hidden="true">✕</span>
							</span>
						{/if}
					</div>
					<div class="ai-body">
						<p class="ai-context">{aiContext}<span class="caret"></span></p>
						<div class="ai-tooltip">
							<div class="ai-tooltip-head">
								<span class="ai-bolt">⚡</span>
								<span>Suggestions IA</span>
								<span class="ai-shortcut"><kbd>Tab</kbd> pour valider</span>
							</div>
							<ul class="ai-list">
								{#each aiSuggestions as s, i}
									<li class:active={i === 0}>
										<span class="ai-num">{i + 1}</span>
										<span>{s}</span>
									</li>
								{/each}
							</ul>
						</div>
					</div>
				</div>

				<!-- Backends — Ollama / MLX -->
				<div class="ai-section">
					<h3>1. Choisissez votre moteur d’inférence</h3>
					<p class="ai-text">
						Deux backends sont supportés en natif. Le driver détecte automatiquement le plus
						performant pour votre matériel, mais vous pouvez toujours forcer votre choix depuis le
						menu.
					</p>
					<div class="ai-backends">
						{#each aiBackends as b}
							<article class="ai-backend">
								<div class="ai-backend-icon">{b.icon}</div>
								<div class="ai-backend-body">
									<h4>{b.name} <span class="ai-port">port {b.port}</span></h4>
									<p class="ai-backend-aud">{b.audience}</p>
									<p class="ai-backend-pro">{b.pro}</p>
								</div>
							</article>
						{/each}
					</div>
				</div>

				<!-- Models — the full catalog, parsed from llm_models.json at build time -->
				<div class="ai-section">
					<h3>2. Choisissez votre modèle parmi <strong>{aiTotalModels}</strong></h3>
					<p class="ai-text">
						Le menu <em>Modèles</em> propose un catalogue curé qui regroupe à ce jour
						<strong>{aiTotalModels} modèles open-weights</strong> issus de
						<strong>{aiTotalProviders} fournisseurs</strong> ({aiTotalFamilies} familles). Du nano 350
						M qui répond en 50 ms au 70 B qui produit des phrases parfaitement contextuelles — vous choisissez
						selon votre matériel et votre besoin. Le menu vous indique la RAM et l’espace disque requis
						avant tout téléchargement.
					</p>
					<p class="ai-text-small">
						Cette liste est <strong>générée automatiquement</strong> depuis le fichier de configuration
						du driver — elle est toujours à jour avec ce que vous installerez réellement.
					</p>
					<div class="ai-providers">
						{#each aiProviders as p}
							<article class="ai-provider">
								<div class="ai-provider-name">{p.name}</div>
								<div class="ai-provider-family">{p.families}</div>
								<div class="ai-provider-meta">
									<span class="ai-provider-count"
										>{p.modelCount} modèle{p.modelCount > 1 ? 's' : ''}</span
									>
									{#if p.range}
										<span class="ai-provider-range">{p.range}</span>
									{/if}
								</div>
							</article>
						{/each}
					</div>

					<article class="ai-custom">
						<div class="ai-custom-icon">＋</div>
						<div class="ai-custom-body">
							<h4>Ajoutez n’importe quel autre modèle</h4>
							<p>
								Une option <em>« Ajouter un modèle personnalisé »</em> accepte n’importe quel
								<strong>identifiant HuggingFace</strong> (pour MLX) ou <strong>tag Ollama</strong>.
								Exemple : <code>mlx-community/Qwen2.5-3B-Instruct-4bit</code> ou
								<code>llama3.2:3b</code>. Le modèle apparaît immédiatement dans la liste, et reste
								persisté entre les sessions.
							</p>
							<p class="ai-custom-foot">
								Vous pouvez littéralement utiliser <strong>n’importe quel modèle</strong> publié sur
								HuggingFace au format MLX, ou n’importe quel modèle disponible dans la bibliothèque Ollama.
							</p>
						</div>
					</article>
				</div>

				<!-- Prompt profiles -->
				<div class="ai-section">
					<h3>3. Choisissez (ou écrivez) votre profil de prompt</h3>
					<p class="ai-text">
						Quatre profils intégrés couvrent les usages courants — chacun avec un prompt système
						précis, rédigé pour fonctionner sur les petits modèles aussi bien que sur les gros.
					</p>
					<div class="ai-profiles">
						{#each aiProfiles as p}
							<article class="ai-profile">
								<header>
									<span class="ai-profile-name">{p.name}</span>
									<span class="ai-profile-tag">{p.tag}</span>
								</header>
								<p>{@html p.desc}</p>
							</article>
						{/each}
					</div>

					<article class="ai-custom">
						<div class="ai-custom-icon">✎</div>
						<div class="ai-custom-body">
							<h4>Ou rédigez votre propre prompt</h4>
							<p>
								L’éditeur de prompts intégré (<em>Menu IA → Profils → Ajouter</em>) accepte
								n’importe quel prompt système avec les variables <code>{'{context}'}</code>,
								<code>{'{min_words}'}</code>, <code>{'{max_words}'}</code>. Imposez un ton, une
								langue, une longueur, des contraintes métier. Vos profils sont persistés et
								réutilisables.
							</p>
							<p class="ai-custom-foot">
								Exemples d’usages : <em>« Réponds toujours en québécois soutenu »</em>,
								<em>« Génère du code TypeScript strict »</em>,
								<em>« Termine ma phrase comme Hemingway »</em>.
							</p>
						</div>
					</article>
				</div>

				<!-- Three faithful AI tooltip mockups, mirroring tooltip_llm.lua -->
				<div class="ai-section">
					<h3>4. Trois modes d’usage, un seul tooltip</h3>
					<p class="ai-text">
						Le tooltip IA est <strong>une seule fenêtre sombre</strong> qui contient toute la phrase
						suggérée, avec un code couleur précis : <span style="color:#7f7f7f">gris</span> pour le
						contexte inchangé, <span style="color:#41e566;font-weight:700">vert</span> pour les
						corrections orthographiques, <span style="color:#ff9d1c;font-weight:700">orange</span>
						pour la suite prédite, <span style="color:#fae138;font-weight:700">jaune</span> pour le marqueur
						de ligne active (✨).
					</p>

					<!-- Example A — prediction only -->
					<article class="ai-example">
						<header class="ai-example-head">
							<span class="ai-example-num">A</span>
							<div>
								<h4>Prédiction simple</h4>
								<p class="ai-example-tag">
									Aucune faute détectée. Seule la <em>continuation</em> apparaît, en orange.
								</p>
							</div>
						</header>
						<div class="ai-example-context">
							Bonjour Madame, je vous écris pour <span class="ai-caret"></span>
						</div>
						<div class="hs-tooltip">
							<div class="hs-tt-line hs-tt-line--selected">
								<span class="hs-tt-spark">✨</span>
								<span class="hs-tt-eq">Bonjour Madame, je vous écris pour</span>
								<span class="hs-tt-nw"> vous proposer un rendez-vous mardi prochain.</span>
								<span class="hs-tt-shortcut">⌥1</span>
							</div>
							<div class="hs-tt-line">
								<span class="hs-tt-eq hs-tt-eq--dim">Bonjour Madame, je vous écris pour</span>
								<span class="hs-tt-nw hs-tt-nw--dim">
									faire suite à notre échange de la semaine dernière.</span
								>
								<span class="hs-tt-shortcut hs-tt-shortcut--dim">⌥2</span>
							</div>
							<div class="hs-tt-line">
								<span class="hs-tt-eq hs-tt-eq--dim">Bonjour Madame, je vous écris pour</span>
								<span class="hs-tt-nw hs-tt-nw--dim">
									accuser réception de votre dossier complet.</span
								>
								<span class="hs-tt-shortcut hs-tt-shortcut--dim">⌥3</span>
							</div>
							<div class="hs-tt-hint">
								⇧G + Tab&nbsp;&nbsp;&nbsp;&nbsp;◀&nbsp;&nbsp;&nbsp;&nbsp;Tab =
								accepter&nbsp;&nbsp;&nbsp;&nbsp;▶&nbsp;&nbsp;&nbsp;&nbsp;⇧D + Tab
							</div>
							<div class="hs-tt-info">Llama 3.2 3B · Basic — ⏱ 0.18 s — 0.42 s</div>
						</div>
					</article>

					<!-- Example B — correction only -->
					<article class="ai-example">
						<header class="ai-example-head">
							<span class="ai-example-num ai-example-num-green">B</span>
							<div>
								<h4>Correction seule</h4>
								<p class="ai-example-tag">
									Une faute détectée, pas de continuation. Seul le mot corrigé est en <strong
										style="color:#41e566">vert</strong
									>.
								</p>
							</div>
						</header>
						<div class="ai-example-context">
							Je vous remercie de me <span class="ai-example-typo">recevoire</span> demain matin.<span
								class="ai-caret"
							></span>
						</div>
						<div class="hs-tooltip">
							<div class="hs-tt-line hs-tt-line--selected">
								<span class="hs-tt-spark">✨</span>
								<span class="hs-tt-eq">Je vous remercie de me</span>
								<span class="hs-tt-corr">recevoir</span>
								<span class="hs-tt-eq">demain matin.</span>
								<span class="hs-tt-shortcut">⌥1</span>
							</div>
							<div class="hs-tt-hint">Tab pour accepter</div>
							<div class="hs-tt-info">Llama 3.2 3B · Advanced — ⏱ 0.21 s — 0.51 s</div>
						</div>
					</article>

					<!-- Example C — correction + prediction (the killer mode) -->
					<article class="ai-example">
						<header class="ai-example-head">
							<span class="ai-example-num ai-example-num-mixed">C</span>
							<div>
								<h4>Correction + prédiction</h4>
								<p class="ai-example-tag">
									Le modèle <strong>corrige</strong> ce que vous avez tapé <em>et</em>
									<strong>continue</strong> la phrase. Tout en une seule ligne, en couleurs.
								</p>
							</div>
						</header>
						<div class="ai-example-context">
							Le projet est <span class="ai-example-typo">paralèle</span> à
							<span class="ai-caret"></span>
						</div>
						<div class="hs-tooltip">
							<div class="hs-tt-line hs-tt-line--selected">
								<span class="hs-tt-spark">✨</span>
								<span class="hs-tt-eq">Le projet est</span>
								<span class="hs-tt-corr">parallèle</span>
								<span class="hs-tt-eq">à</span>
								<span class="hs-tt-nw">
									celui de l’an dernier, mais avec un budget revu à la hausse.</span
								>
								<span class="hs-tt-shortcut">⌥1</span>
							</div>
							<div class="hs-tt-line">
								<span class="hs-tt-eq hs-tt-eq--dim">Le projet est</span>
								<span class="hs-tt-corr hs-tt-corr--dim">parallèle</span>
								<span class="hs-tt-eq hs-tt-eq--dim">à</span>
								<span class="hs-tt-nw hs-tt-nw--dim"> ceux que nous avons livrés en 2024.</span>
								<span class="hs-tt-shortcut hs-tt-shortcut--dim">⌥2</span>
							</div>
							<div class="hs-tt-hint">
								⇧G + Tab&nbsp;&nbsp;&nbsp;&nbsp;◀&nbsp;&nbsp;&nbsp;&nbsp;Tab =
								accepter&nbsp;&nbsp;&nbsp;&nbsp;▶&nbsp;&nbsp;&nbsp;&nbsp;⇧D + Tab
							</div>
							<div class="hs-tt-info">Mistral 7B · Advanced — ⏱ 0.34 s — 0.78 s</div>
						</div>
						<p class="ai-example-foot">
							Un seul <kbd>Tab</kbd> insère la correction <strong>et</strong> la suite — vous écrivez
							80 caractères en appuyant sur 1 touche.
						</p>
					</article>

					<p class="ai-text-small">
						Le code couleur des tooltips est entièrement personnalisable depuis le menu (ou
						désactivable si vous préférez l’affichage neutre).
					</p>
				</div>

				<!-- Validation shortcut -->
				<div class="ai-section">
					<h3>5. Validez en une touche</h3>
					<p class="ai-text">
						Une suggestion vous plaît ? Une seule pression sur <kbd>Tab</kbd> et elle est insérée. Plusieurs
						suggestions ? Naviguez avec les flèches haut/bas, validez celle que vous voulez. Aucune souris,
						aucun pop-up à fermer.
					</p>
					<ul class="ai-shortcuts-list">
						<li><kbd>Tab</kbd> — Valider la suggestion en surbrillance</li>
						<li><kbd>↑</kbd> / <kbd>↓</kbd> — Naviguer entre les suggestions</li>
						<li><kbd>Échap</kbd> ou <strong>n’importe quelle frappe</strong> — Ignorer</li>
					</ul>
				</div>
			</section>

			<!-- ────────────────────────── Trackpad gestures (mac only) ── -->
			<section class="trackpad">
				<header class="section-head">
					<p class="kicker" style="color:#00838f">Gestes trackpad · macOS</p>
					<h2>Le clavier ne fait pas tout. Le trackpad non plus, seul.</h2>
					<p class="lead">
						Le driver intercepte les <strong>gestes bruts</strong> du trackpad (pas les événements de
						souris) et les associe à n’importe quelle action. Plus de zigzag main droite/clavier — vos
						doigts restent là où ils sont.
					</p>
				</header>

				<div class="trackpad-grid">
					{#each trackpadGestures as g}
						<article class="trackpad-card" style="--accent:{g.color};">
							<div class="trackpad-meta">
								<span class="trackpad-fingers">{g.fingers}</span>
								<span class="trackpad-type">{g.type}</span>
							</div>
							<div class="trackpad-action">{g.defaut}</div>
							<p class="trackpad-note">{g.note}</p>
						</article>
					{/each}
				</div>

				<div class="trackpad-callout">
					<h3>Tap 3 doigts = définition instantanée</h3>
					<p>
						Posez 3 doigts sur un mot dans n’importe quel texte (Safari, Mail, Pages, Slack, VS
						Code…) : sa définition apparaît dans une popover. <strong
							>C’est le geste le plus utilisé d’<ErgoptiPlus></ErgoptiPlus></strong
						>
						selon nos métriques internes — plus rapide qu’ouvrir un onglet vers un dictionnaire.
					</p>
				</div>

				<div class="trackpad-extras">
					<h3>Tout est réassignable</h3>
					<p>
						Le menu <em>Trackpad → Gestes</em> propose une liste déroulante par geste. Une trentaine
						d’actions sont fournies : navigation entre fenêtres, contrôle du volume, mots/lignes/paragraphes,
						copier/coller, captures d’écran, raccourcis applicatifs… Vous pouvez aussi pointer vers un
						script Lua pour des actions sur-mesure.
					</p>
				</div>
			</section>

			<!-- ────────────────────────── Typing metrics ──────────────── -->
			<section class="metrics">
				<header class="section-head">
					<p class="kicker" style="color:#00838f">Métriques de frappe</p>
					<h2>Mesurer pour progresser.</h2>
					<p class="lead">
						Le keylogger interne (n’envoie rien dehors) compte les frappes, mots, déclenchements et
						bigrammes inconfortables. De quoi voir d’une semaine sur l’autre où vous gagnez.
					</p>
				</header>

				<div class="metrics-grid">
					{#each metrics as m}
						<div class="metric-card" style="--accent: {m.accent};">
							<div class="metric-label">{m.label}</div>
							<div class="metric-value">{m.value}</div>
							<div class="metric-delta">{m.delta}</div>
						</div>
					{/each}
				</div>
			</section>

			<!-- ────────────────────────── Mac window showcase ───────────── -->
			<section class="showcase">
				<header class="section-head">
					<p class="kicker">Configuration unifiée</p>
					<h2>Un panneau. Tous vos délais et couleurs.</h2>
					<p class="lead">
						Le menu intégré (macOS et Windows) lit et écrit le même fichier <code
							>~/.config/ergopti_plus/hotstrings_config.toml</code
						>. Réglez une fois, profitez partout.
					</p>
				</header>

				<div class="mac-window os-{osStyle}">
					<div class="chrome">
						{#if osStyle === 'macos'}
							<span class="mac-dots">
								<span class="dot dot-r"></span>
								<span class="dot dot-y"></span>
								<span class="dot dot-g"></span>
							</span>
							<span class="chrome-title">Délais et couleurs des hotstrings</span>
							<span class="chrome-spacer"></span>
						{:else}
							<span class="chrome-title chrome-title--win">Délais et couleurs des hotstrings</span>
							<span class="win-buttons">
								<span class="win-btn" aria-hidden="true">─</span>
								<span class="win-btn" aria-hidden="true">▢</span>
								<span class="win-btn close" aria-hidden="true">✕</span>
							</span>
						{/if}
					</div>
					<div class="mac-body">
						<div class="mac-toolbar">
							<button class="mac-btn">Tout en gris</button>
							<button class="mac-btn ghost">Tout réinitialiser</button>
							<span class="spacer"></span>
							<span class="mac-hint">édité dans <code>hotstrings_config.toml</code></span>
						</div>

						{#each [{ name: 'Magic Key', delay: 2000, color: '#e53935', sections: 4 }, { name: 'Autocorrection', delay: 1000, color: '#43a047', sections: 6 }, { name: 'Roulements', delay: 500, color: '#fb8c00', sections: 5 }, { name: 'SFBs', delay: 500, color: '#fb8c00', sections: 3 }, { name: 'Distances', delay: 500, color: '#fb8c00', sections: 4 }, { name: 'Personal', delay: 2000, color: '#1e88e5', sections: 0 }] as row}
							<div class="mac-row">
								<span class="mac-swatch" style="background:{row.color}"></span>
								<span class="mac-name">{row.name}</span>
								<span class="mac-meta">{row.sections} section{row.sections > 1 ? 's' : ''}</span>
								<span class="mac-delay">{row.delay} ms</span>
								<span class="mac-arrow">›</span>
							</div>
						{/each}
					</div>
				</div>
			</section>

			<!-- ────────────────────────── Personnalisation ───────────── -->
			<section class="custo">
				<header class="section-head">
					<p class="kicker">Tout sous votre contrôle</p>
					<h2>Absolument tout est personnalisable. Et désactivable.</h2>
					<p class="lead">
						<strong>Aucune fonctionnalité n’est imposée.</strong> Chaque expansion, chaque tap-hold,
						chaque geste, chaque tooltip, chaque délai, chaque couleur peut être modifié, désactivé,
						réinitialisé. Vous décidez. Le menu est là pour vous mettre à l’aise —
						<strong>jamais pour vous piéger</strong>.
					</p>
				</header>

				<div class="custo-pillars">
					<div class="custo-pillar">
						<span class="custo-pillar-num">1</span>
						<div>
							<h3>Activez fonction par fonction</h3>
							<p>
								Chaque catégorie de hotstrings, chaque tap-hold, chaque geste trackpad a sa case à
								cocher. Démarrez avec 3 fonctions, ajoutez-en 2 le mois suivant, jamais
								d’obligation.
							</p>
						</div>
					</div>
					<div class="custo-pillar">
						<span class="custo-pillar-num">2</span>
						<div>
							<h3>Réglez les valeurs</h3>
							<p>
								Délais, couleurs, modèle d’IA, raccourcis, prompt, longueur de contexte, apps
								ignorées, chemins de fichiers — chaque paramètre est exposé dans le menu, réversible
								d’un clic.
							</p>
						</div>
					</div>
					<div class="custo-pillar">
						<span class="custo-pillar-num">3</span>
						<div>
							<h3>Réécrivez les hotstrings</h3>
							<p>
								Un trigger livré ne vous convient pas ? Modifiez la valeur dans le TOML, le driver
								recharge tout seul. Vous voulez en ajouter ? Le menu écrit le fichier pour vous.
							</p>
						</div>
					</div>
				</div>

				<h3 class="custo-h3">Quelques exemples de réglages disponibles</h3>
				<div class="custo-grid">
					{#each personalizationCards as c}
						<article class="custo-card">
							<div class="custo-icon">{c.icon}</div>
							<h3>{c.title}</h3>
							<p>{@html c.body}</p>
						</article>
					{/each}
				</div>
			</section>

			<!-- ────────────────────────── Privacy / open-source / free ── -->
			<section class="trust">
				<header class="section-head">
					<p class="kicker">Confiance par construction</p>
					<h2>100 % local. 100 % open-source. 100 % gratuit.</h2>
					<p class="lead">
						Pas d’abonnement, pas d’extension à acheter, pas de publicité, pas de compte à créer,
						pas de télémétrie. Le code est lisible, auditable, modifiable.
					</p>
				</header>

				<div class="trust-grid">
					<article class="trust-card">
						<div class="trust-icon" style="color:#43a047;">🔐</div>
						<h3>Tout reste sur votre machine</h3>
						<p>
							Hotstrings, métriques de frappe, prédictions IA, gestes — chaque calcul est local.
							Aucun serveur n’est sollicité. Même les modèles d’IA tournent <strong
								>chez vous</strong
							>, via Ollama ou MLX. Une fois téléchargés, plus besoin d’internet.
						</p>
					</article>

					<article class="trust-card">
						<div class="trust-icon" style="color:#1e88e5;">📂</div>
						<h3>Code source ouvert</h3>
						<p>
							Le driver Hammerspoon (Lua), le driver AutoHotkey (AHK v2) et le site sont publiés sur
							GitHub, sous licence libre. Vous pouvez auditer, modifier, forker, contribuer. Le
							projet vit en public, par conception.
						</p>
					</article>

					<article class="trust-card">
						<div class="trust-icon" style="color:#fb8c00;">💸</div>
						<h3>Gratuit. Pour de bon.</h3>
						<p>
							Pas de freemium qui devient payant après 30 jours. Pas d’extension premium à
							débloquer. Pas de publicité dans le menu. Pas de don forcé. <ErgoptiPlus
							></ErgoptiPlus> est et restera <strong>entièrement gratuit</strong>, sans limitation.
						</p>
					</article>

					<article class="trust-card">
						<div class="trust-icon" style="color:#8e44ad;">🚫</div>
						<h3>Aucune télémétrie</h3>
						<p>
							Le driver ne fait <strong>aucun appel réseau</strong> en dehors du backend LLM local que
							vous avez choisi. Pas de "anonymized usage data", pas de crash report envoyé en arrière-plan,
							pas de pixel de tracking. Vous pouvez littéralement le faire tourner hors-ligne.
						</p>
					</article>
				</div>
			</section>

			<!-- ════════════════════════════════════════════════════════════
	     EXCLUSIVITÉS ERGOPTI
	     Tout ce qui suit ne fait sens QUE sur la disposition Ergopti :
	     les positions de touches sont essentielles. Un avertissement
	     visuel clair indique la rupture.
	     ════════════════════════════════════════════════════════════ -->
			<section class="ergopti-banner">
				<header class="section-head ergopti-head">
					<p class="kicker ergopti-kicker">⚠ Spécifique à la disposition Ergopti</p>
					<h2>Exclusivités Ergopti.</h2>
					<p class="lead">
						Tout ce qui précède fonctionne sur <strong>n’importe quelle disposition</strong>
						(AZERTY, QWERTY, Bépo…). Les fonctionnalités ci-dessous, en revanche, exploitent les
						<strong>positions exactes des touches d’Ergopti</strong> — virgule sous l’index, ★ à la place
						du J, voyelles accentuées dédiées. Sur un autre layout, elles n’auraient aucun sens.
					</p>
					<p class="lead lead-em">
						C’est <em>l’autre moitié</em> du gain. Si vous adoptez Ergopti, vous récupérez tout cela
						gratuitement.
					</p>
				</header>

				<!-- Ergopti-only hotstrings (rolls + SFB reduction + magic Ergopti hs) -->
				<div class="hotdetail-grid">
					{#each ergoptiBigrams as cat}
						<article class="hotdetail-card" style="--accent: {cat.color};">
							<header class="hotdetail-head">
								<span class="hotdetail-dot"></span>
								<div>
									<h3>{cat.title}</h3>
									<p class="hotdetail-tag">{cat.tag}</p>
								</div>
							</header>
							<p class="hotdetail-lead">{cat.lead}</p>
							<ul class="hotdetail-rows">
								{#each cat.rows as r}
									<li>
										<div class="hot-trig">
											<span class="hot-key">{r.trig}</span>
											<span class="hot-arrow">→</span>
											<span class="hot-out">{r.out}</span>
										</div>
										<div class="hot-context">
											{#each r.words as w}
												<span class="hot-word">{w}</span>
											{/each}
										</div>
									</li>
								{/each}
							</ul>
						</article>
					{/each}
				</div>

				<!-- Super-keys (comma magic, Q→QU, ù→où, ê, apostrophe, BackSpace, nt') -->
				<div class="ergopti-block">
					<h3 class="ergopti-h3">Des touches qui font le travail de plusieurs</h3>
					<p class="ergopti-text">
						<ErgoptiPlus></ErgoptiPlus> tire profit de séquences statistiquement absentes du français
						pour placer des raccourcis qui ne créent jamais de faux positifs.
					</p>

					<article class="super-card">
						<h4>La touche <kbd>,</kbd> + voyelle remplace le <kbd>j</kbd></h4>
						<p>
							Le <kbd>j</kbd> minuscule devient la touche magique <kbd class="glow">★</kbd>. À sa
							place, la virgule prend le relais : la séquence <code>,</code> + voyelle est
							inexistante en français (<code>,</code> est toujours suivi d’un espace), donc on la
							détourne pour produire un
							<code>j</code>.
						</p>
						<div class="super-grid super-grid-tight">
							{#each commaVowels as c}
								<div class="suffix-row">
									<span class="hs-key">{c.keys}</span>
									<span class="hs-arrow">→</span>
									<span class="hs-out">{c.out}</span>
								</div>
							{/each}
						</div>
					</article>

					<article class="super-card">
						<h4>La touche <kbd>,</kbd> + consonne pour un layout 1DFH</h4>
						<p>
							Les lettres rares (<kbd>z</kbd>, <kbd>k</kbd>, <kbd>q</kbd>, <kbd>ç</kbd>) sont
							accessibles via la virgule, donc plus à 1u du repos des doigts. Le mot <em>où</em> aussi
							— bonus, en deux frappes au lieu de trois.
						</p>
						<div class="super-grid super-grid-tight">
							{#each commaConsonants as c}
								<div class="suffix-row suffix-row-3col">
									<span class="hs-key">{c.keys}</span>
									<span class="hs-arrow">→</span>
									<span class="hs-out">{c.out}</span>
									<span class="hs-desc">{c.note}</span>
								</div>
							{/each}
						</div>
					</article>

					<div class="super-grid super-grid-2col">
						<article class="super-card">
							<h4>Q + voyelle = QU automatique</h4>
							<p>
								En français, <kbd>q</kbd> + voyelle implique presque toujours un <kbd>u</kbd> caché.
								Tapez
								<code>qe</code>, <code>qi</code>, <code>qa</code> — le <code>u</code> s’insère seul.
							</p>
							<div class="super-mini">
								<span class="hs-key">qe</span><span class="hs-arrow">→</span><span class="hs-out"
									>que</span
								>
								<span class="hs-key">qoi</span><span class="hs-arrow">→</span><span class="hs-out"
									>quoi</span
								>
							</div>
						</article>

						<article class="super-card">
							<h4>Touche <kbd>ù</kbd> = mot <em>où</em></h4>
							<p>
								La touche <kbd>ù</kbd> n’est utilisée <strong>que</strong> pour le mot <em>où</em>.
								Autant en faire le raccourci direct.
							</p>
							<div class="super-mini">
								<span class="hs-key">AltGr+W</span><span class="hs-arrow">→</span><span
									class="hs-out">où</span
								>
							</div>
						</article>

						<article class="super-card">
							<h4>Touche <kbd>ê</kbd> = circonflexe en une frappe</h4>
							<p>
								Le bigramme le plus fréquent du circonflexe est <kbd class="deadkey">◌̂</kbd> +
								<kbd>e</kbd>. Une touche dédiée évite l’aller-retour. Pour <em>â</em>, <em>î</em>,
								<em>ô</em>,
								<em>û</em> : <code>êa</code>, <code>êi</code>, <code>êo</code>, <code>êu</code>.
							</p>
							<div class="super-mini">
								<span class="hs-key">ê</span><span class="hs-arrow">→</span><span class="hs-out"
									>ê</span
								>
								<span class="hs-key">êa</span><span class="hs-arrow">→</span><span class="hs-out"
									>â</span
								>
							</div>
						</article>

						<article class="super-card">
							<h4>Apostrophe typographique automatique</h4>
							<p>
								Tapez <kbd>'</kbd> dans du texte, vous écrivez <kbd-output>’</kbd-output>. Tapez-la
								dans du code, elle reste droite. <strong>Aucun réglage à faire.</strong>
							</p>
							<div class="super-mini">
								<span class="hs-key">l'ami</span><span class="hs-arrow">→</span><span class="hs-out"
									>l’ami</span
								>
							</div>
						</article>

						<article class="super-card">
							<h4>BackSpace à portée de pouce</h4>
							<p>
								La touche la plus utilisée du clavier (BackSpace) est dupliquée sur <kbd>"LAlt"</kbd
								>, juste sous la main. <kbd>Shift</kbd> + cette touche envoie <kbd>Delete</kbd>.
								<kbd>AltGr</kbd> + cette touche envoie <kbd>Ctrl</kbd>+<kbd>BackSpace</kbd> (efface un
								mot entier).
							</p>
						</article>

						<article class="super-card">
							<h4>Roulement <code>nt'</code> pour l’anglais</h4>
							<p>
								<code>nt'</code> devient <code>n’t</code> — la combinaison parfaite pour
								<em>don’t</em>, <em>won’t</em>, <em>can’t</em>. Majeur → annulaire → auriculaire au
								lieu de l’inverse, beaucoup plus confortable.
							</p>
						</article>
					</div>
				</div>

				<!-- Suffixes en À -->
				<div class="ergopti-block">
					<h3 class="ergopti-h3">Suffixes en À — tapez 2, écrivez 5</h3>
					<p class="ergopti-text">
						La touche <kbd>à</kbd> n’est suivie que d’un espace ou d’une ponctuation en français
						(seuls <em>à, là, déjà</em> contiennent <kbd>à</kbd>). On en a profité pour caler dessus
						les suffixes les plus fréquents. Le suffixe <strong>-ement</strong> coûte normalement 5
						frappes : il en coûte <strong>2</strong>.
					</p>
					<div class="suffixes-grid">
						{#each suffixesA as s}
							<div class="suffix-row">
								<span class="hs-key">{s.keys}</span>
								<span class="hs-arrow">→</span>
								<span class="hs-out">{s.out}</span>
							</div>
						{/each}
					</div>
				</div>

				<!-- Symbol rolls (programming) -->
				<div class="ergopti-block">
					<h3 class="ergopti-h3">Symboles de programmation, en roulements confortables</h3>
					<p class="ergopti-text">
						Les combinaisons inconfortables (<code>=&gt;</code>, <code>!=</code>, <code>:=</code>,
						<code>&lt;/</code>, <code>=""</code>…) sont remappées en roulements vers l’intérieur,
						sur la home-row d’Ergopti. Ces emplacements précis n’existent que sur cette disposition.
					</p>
					<div class="symbols-grid">
						{#each symbolRolls as s}
							<div class="symbol-row">
								<span class="hs-key">{s.trig}</span>
								<span class="hs-arrow">→</span>
								<span class="hs-out">{s.out}</span>
								<span class="hs-desc">{s.note}</span>
							</div>
						{/each}
					</div>
				</div>
			</section>

			<!-- ────────────────────────── Layout-agnostic banner ───────── -->
			<section class="agnostic">
				<header class="section-head">
					<p class="kicker">Compatibilité dispositions</p>
					<h2>AZERTY, QWERTY, Bépo, Dvorak — tout fonctionne.</h2>
					<p class="lead">
						<ErgoptiPlus></ErgoptiPlus> est <em>pensé</em> pour la disposition Ergopti, mais le
						driver agit sur le <strong>texte</strong> qui sort de votre clavier — pas sur la touche
						que vous appuyez. <strong>Aucun changement de layout n’est nécessaire.</strong>
					</p>
				</header>

				<div class="agnostic-row">
					<div class="agnostic-card">
						<h3>Hotstrings et autocorrection</h3>
						<p>
							Tout fonctionne quel que soit votre layout, parce qu’ils opèrent sur le texte produit.
							Vos expansions <code>ct★</code>, <code>pex★</code>, <code>chatgpt</code>…
							déclencheront en AZERTY, QWERTY ou Bépo.
						</p>
					</div>
					<div class="agnostic-card">
						<h3>Tap-holds, CapsWord, layer navigation</h3>
						<p>
							Ces fonctions agissent sur le <em>code physique</em> de la touche (scancode), donc indépendantes
							du layout actif côté OS. Elles fonctionnent à l’identique sur tous les claviers.
						</p>
					</div>
					<div class="agnostic-card">
						<h3>Gestes trackpad et IA</h3>
						<p>
							Les gestes trackpad sont des événements multi-touch bruts : aucune dépendance clavier.
							L’IA prédit du texte, peu importe sur quelle touche vous l’avez tapé.
						</p>
					</div>
				</div>

				<p class="agnostic-foot">
					<strong>Notre recommandation :</strong> Ergopti + <ErgoptiPlus></ErgoptiPlus> est la meilleure
					combinaison (la disposition tire profit des roulements et de la touche magique). Mais si vous
					restez sur votre layout actuel, vous récupérez quand même 70 % du gain.
				</p>
			</section>

			<!-- ────────────────────────── Cross-platform ─────────────────── -->
			<section class="platforms">
				<header class="section-head">
					<p class="kicker">Identique partout</p>
					<h2>macOS et Windows, même expérience.</h2>
					<p class="lead">
						Le même fichier de hotstrings, les mêmes raccourcis, le même tooltip. Vous changez de
						machine, pas de réflexe.
					</p>
				</header>

				<div class="compare-table-wrap">
					<table class="compare-table">
						<thead>
							<tr>
								<th class="compare-feature">Fonctionnalité</th>
								<th class="compare-os">
									<i class="icon-appleinc"></i>
									<span class="compare-os-name">macOS</span>
									<span class="compare-os-driver">Hammerspoon</span>
								</th>
								<th class="compare-os">
									<i class="icon-windows"></i>
									<span class="compare-os-name">Windows</span>
									<span class="compare-os-driver">AutoHotkey&nbsp;v2</span>
								</th>
							</tr>
						</thead>
						<tbody>
							{#each compareFeatures as row}
								<tr>
									<td class="compare-feature">{row.label}</td>
									<td class="compare-cell" class:no={!row.mac}>
										{row.mac ? '✅' : '❌'}
									</td>
									<td class="compare-cell" class:no={!row.win}>
										{row.win ? '✅' : '❌'}
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			</section>

			<!-- ────────────────────────── Final CTA ─────────────────────── -->
			<section class="final-cta">
				<div class="cta-card">
					<h2>Passez à la vitesse supérieure.</h2>
					<p>Téléchargez le driver pour votre OS, et tapez <code>ct★</code>.</p>
					<div class="hero-cta">
						<a
							class={osStyle === 'windows' ? 'btn btn-primary' : 'btn btn-secondary'}
							href={urlAhkExe}
							download={!!release}
						>
							<i class="icon-autohotkey"></i><span>Windows (AHK)</span>
						</a>
						<a
							class={osStyle === 'macos' ? 'btn btn-primary' : 'btn btn-secondary'}
							href={urlMacosApp}
							download={!!release}
						>
							<i class="icon-hammerspoon"></i><span>macOS (HS)</span>
						</a>
						<a class="btn btn-secondary" href={urlKanata} download={!!release}>
							<i class="icon-linux"></i><span>Linux (kanata.kbd)</span>
						</a>
					</div>
					<p class="cta-sub">
						<a href="utilisation" class="cta-link">Installer la disposition clavier →</a>
					</p>
				</div>
			</section>
		</div>
	</main>
</div>

<style>
	/* ============================================================
	   Root + utilities — scoped to this page only.
	   ============================================================ */

	.legacy-banner {
		background: rgba(255, 200, 0, 0.12);
		border-bottom: 1px solid rgba(255, 200, 0, 0.3);
		font-size: 0.85em;
		padding: 0.5em 1.5em;
		text-align: center;
	}
	.legacy-banner a {
		color: #ffc800;
		text-decoration: none;
	}
	.legacy-banner a:hover {
		text-decoration: underline;
	}

	.ep-root {
		--ink: #ffffff;
		--ink-soft: rgba(255, 255, 255, 0.72);
		--ink-faint: rgba(255, 255, 255, 0.5);
		--surface: rgba(255, 255, 255, 0.04);
		--surface-strong: rgba(255, 255, 255, 0.07);
		--border: rgba(255, 255, 255, 0.1);
		--border-strong: rgba(255, 255, 255, 0.18);
		--radius: 14px;
		--radius-lg: 22px;
		--ease: cubic-bezier(0.4, 0, 0.2, 1);

		color: var(--ink);
		font-feature-settings: 'cv11', 'ss01';
		margin: 0 auto;
		max-width: 1200px;
		padding: 0 24px 80px;
	}

	.ep-root :global(code) {
		background: rgba(255, 255, 255, 0.08);
		border: 1px solid var(--border);
		border-radius: 6px;
		font-family: 'SF Mono', Menlo, Consolas, monospace;
		font-size: 0.88em;
		padding: 1px 6px;
	}

	.ep-root :global(em) {
		color: #fff;
		font-style: normal;
		font-weight: 600;
	}

	.section-head {
		margin: 0 auto 48px;
		max-width: 700px;
		text-align: center;
	}

	.section-head h2 {
		font-size: clamp(28px, 3.4vw, 44px);
		font-weight: 700;
		letter-spacing: -0.02em;
		line-height: 1.1;
		margin: 8px 0 14px;
	}

	.section-head .kicker {
		color: var(--couleur-bleue);
		font-size: 13px;
		font-weight: 600;
		letter-spacing: 0.08em;
		margin: 0;
		text-transform: uppercase;
	}

	.section-head .lead {
		color: var(--ink-soft);
		font-size: 17px;
		line-height: 1.6;
		margin: 0;
	}

	/* ============================================================
	   1/ Hero
	   ============================================================ */

	.hero {
		padding: clamp(56px, 8vw, 120px) 0 64px;
		position: relative;
		text-align: center;
	}

	.hero-glow {
		background: radial-gradient(
			ellipse at center,
			rgba(49, 190, 255, 0.18) 0%,
			rgba(49, 190, 255, 0) 70%
		);
		height: 600px;
		left: 50%;
		pointer-events: none;
		position: absolute;
		top: -100px;
		transform: translateX(-50%);
		width: 900px;
		z-index: -1;
	}

	.os-toggle {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 999px;
		display: inline-flex;
		gap: 2px;
		margin: 0 auto 28px;
		padding: 4px;
	}
	.os-toggle button {
		align-items: center;
		background: transparent;
		border: 0;
		border-radius: 999px;
		color: var(--ink-soft);
		cursor: pointer;
		display: inline-flex;
		font: inherit;
		font-size: 13px;
		gap: 6px;
		padding: 6px 14px;
		transition:
			background 0.2s var(--ease),
			color 0.2s var(--ease);
	}
	.os-toggle button:hover {
		color: var(--ink);
	}
	.os-toggle button.active {
		background: rgba(49, 190, 255, 0.2);
		color: var(--ink);
	}
	.os-toggle i,
	.btn i {
		align-items: center;
		display: inline-flex;
		font-size: 14px;
		justify-content: center;
		line-height: 1;
	}
	.os-toggle button > span,
	.btn > span {
		line-height: 1;
	}

	.eyebrow {
		color: var(--ink-faint);
		font-size: 13px;
		letter-spacing: 0.06em;
		margin: 0 0 18px;
		text-transform: uppercase;
	}

	.eyebrow .dot {
		color: var(--couleur-bleue);
		margin: 0 6px;
	}

	.hero-title {
		font-size: clamp(30px, 4.4vw, 54px);
		font-weight: 700;
		letter-spacing: -0.025em;
		line-height: 1.06;
		margin: 0 0 22px;
	}

	.grad {
		background: linear-gradient(135deg, var(--gradient-blue));
		-webkit-background-clip: text;
		background-clip: text;
		color: transparent;
	}

	.hero-sub {
		color: var(--ink-soft);
		font-size: clamp(16px, 1.4vw, 19px);
		line-height: 1.6;
		margin: 0 auto 36px;
		max-width: 620px;
	}

	.hero-cta {
		align-items: center;
		display: flex;
		flex-wrap: wrap;
		gap: 12px;
		justify-content: center;
		margin-bottom: 64px;
	}

	.btn {
		align-items: center;
		border: 1px solid transparent;
		border-radius: 10px;
		display: inline-flex;
		font-size: 15px;
		font-weight: 600;
		gap: 8px;
		padding: 12px 22px;
		text-decoration: none;
		transition:
			transform 0.2s var(--ease),
			background 0.2s var(--ease),
			border-color 0.2s var(--ease);
	}
	.btn:hover {
		transform: translateY(-1px);
	}
	.btn-primary {
		background: linear-gradient(135deg, var(--gradient-blue));
		color: #fff;
	}
	.btn-primary:hover {
		box-shadow: 0 6px 20px rgba(48, 136, 237, 0.4);
	}
	.btn-secondary {
		background: var(--surface-strong);
		border-color: var(--border-strong);
		color: var(--ink);
	}
	.btn-secondary:hover {
		background: rgba(255, 255, 255, 0.12);
	}
	.btn-ghost {
		color: var(--ink-soft);
	}
	.btn-ghost:hover {
		color: var(--ink);
	}

	/* ─── Live typing demo ─── */

	.demo-stage {
		margin: 0 auto;
		max-width: 720px;
	}

	.demo-window {
		background: rgba(10, 14, 28, 0.85);
		border: 1px solid var(--border-strong);
		box-shadow:
			0 30px 80px rgba(0, 0, 0, 0.5),
			0 0 0 1px rgba(255, 255, 255, 0.05) inset;
		overflow: hidden;
		text-align: left;
	}
	.demo-window.os-macos,
	.session-window.os-macos,
	.mac-window.os-macos {
		border-radius: var(--radius-lg);
	}
	.demo-window.os-windows,
	.session-window.os-windows,
	.mac-window.os-windows {
		border-radius: 8px;
	}

	.chrome {
		align-items: center;
		background: rgba(255, 255, 255, 0.04);
		border-bottom: 1px solid var(--border);
		display: flex;
		gap: 8px;
		padding: 12px 14px;
	}

	.os-macos .chrome {
		justify-content: flex-start;
	}
	.os-windows .chrome {
		background: rgba(255, 255, 255, 0.03);
		justify-content: space-between;
		padding: 8px 0 8px 14px;
	}

	.mac-dots {
		display: inline-flex;
		gap: 8px;
	}
	.mac-dots .dot {
		border-radius: 50%;
		display: inline-block;
		height: 11px;
		width: 11px;
	}
	.dot-r {
		background: #ff5f57;
	}
	.dot-y {
		background: #febc2e;
	}
	.dot-g {
		background: #28c840;
	}

	.chrome-title {
		color: var(--ink-faint);
		font-family: 'SF Mono', Menlo, Consolas, monospace;
		font-size: 12px;
		margin-left: auto;
		padding-right: 8px;
	}
	.os-macos .chrome-title {
		text-align: center;
	}
	.chrome-spacer {
		flex: 1;
	}

	.chrome-title--win {
		color: var(--ink-soft);
		font-family: 'Segoe UI', system-ui, sans-serif;
		font-size: 12.5px;
		margin: 0;
		padding: 0;
	}

	.win-buttons {
		display: inline-flex;
		font-family: 'Segoe UI Symbol', 'Segoe UI', system-ui, sans-serif;
	}
	.win-btn {
		align-items: center;
		color: var(--ink-soft);
		display: inline-flex;
		font-size: 11px;
		height: 30px;
		justify-content: center;
		transition: background 0.15s var(--ease);
		width: 44px;
	}
	.win-btn:hover {
		background: rgba(255, 255, 255, 0.08);
	}
	.win-btn.close:hover {
		background: #e81123;
		color: #fff;
	}

	.demo-viewport {
		min-height: 130px;
		overflow: hidden;
		position: relative;
	}

	.demo-body {
		font-family: 'SF Mono', Menlo, Consolas, monospace;
		font-size: 22px;
		left: 0;
		line-height: 1.5;
		padding: 32px 28px;
		position: absolute;
		right: 0;
		top: 0;
	}

	.demo-typed {
		color: #fff;
	}

	.caret {
		animation: blink 1s steps(2, end) infinite;
		background: var(--couleur-bleue);
		display: inline-block;
		height: 1.05em;
		margin-left: 2px;
		vertical-align: text-bottom;
		width: 2px;
	}
	@keyframes blink {
		50% {
			opacity: 0;
		}
	}

	.demo-tooltip {
		--mix: color-mix(in srgb, var(--tt) 14%, #1a1a1a);
		animation: ttIn 0.18s var(--ease);
		background: var(--mix);
		border-radius: 10px;
		bottom: -24px;
		box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
		color: #fff;
		display: inline-flex;
		flex-direction: column;
		font-family: 'SF Mono', Menlo, Consolas, monospace;
		font-size: 14px;
		gap: 2px;
		left: 28px;
		padding: 8px 14px;
		position: absolute;
	}

	.demo-tooltip::before {
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 10px;
		content: '';
		inset: 0;
		pointer-events: none;
		position: absolute;
	}

	.tt-text {
		font-size: 16px;
	}
	.tt-tag {
		color: var(--tt);
		font-size: 10.5px;
		letter-spacing: 0.06em;
		text-transform: uppercase;
	}

	@keyframes ttIn {
		from {
			opacity: 0;
			transform: translateY(4px);
		}
		to {
			opacity: 1;
			transform: translateY(0);
		}
	}

	.demo-pager {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		justify-content: center;
		list-style: none;
		margin: 32px 0 0;
		padding: 0;
	}
	.demo-pager li {
		display: inline-flex;
	}
	.demo-pager button {
		align-items: center;
		background: rgba(255, 255, 255, 0.06);
		border: 1px solid var(--border);
		border-radius: 999px;
		color: var(--ink-soft);
		cursor: pointer;
		display: inline-flex;
		font: inherit;
		font-family: 'SF Mono', ui-monospace, Menlo, Consolas, monospace;
		font-size: 12px;
		gap: 6px;
		padding: 6px 12px;
		transition:
			background 0.2s var(--ease),
			border-color 0.2s var(--ease),
			color 0.2s var(--ease),
			transform 0.2s var(--ease);
	}
	.demo-pager button:hover {
		background: rgba(255, 255, 255, 0.12);
		border-color: var(--border-strong);
		color: var(--ink);
		transform: translateY(-1px);
	}
	.demo-pager button.active {
		background: rgba(49, 190, 255, 0.18);
		border-color: var(--couleur-bleue);
		color: var(--ink);
	}
	.pager-arrow {
		color: var(--ink-faint);
	}
	.pager-output {
		color: var(--ink);
	}
	.demo-pager button.active .pager-arrow {
		color: var(--couleur-bleue);
	}

	/* ============================================================
	   2/ KPI strip
	   ============================================================ */

	.kpi-strip {
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border-strong);
		border-radius: var(--radius-lg);
		box-shadow:
			0 30px 80px rgba(0, 0, 0, 0.35),
			0 0 0 1px rgba(255, 255, 255, 0.04) inset;
		display: grid;
		gap: 20px;
		grid-template-columns: repeat(4, 1fr);
		margin: 96px 0;
		padding: 36px 24px;
	}

	.kpi {
		text-align: center;
	}
	.kpi-num {
		background: linear-gradient(135deg, var(--gradient-blue));
		-webkit-background-clip: text;
		background-clip: text;
		color: transparent;
		font-size: clamp(34px, 4vw, 56px);
		font-weight: 800;
		letter-spacing: -0.02em;
		line-height: 1;
	}
	.kpi-label {
		color: var(--ink-soft);
		font-size: 13px;
		margin-top: 8px;
	}

	@media (max-width: 720px) {
		.kpi-strip {
			grid-template-columns: repeat(2, 1fr);
		}
	}

	/* ============================================================
	   2.5/ Real session
	   ============================================================ */

	.session {
		margin: 96px 0;
	}

	.session-window {
		background: rgba(8, 12, 24, 0.9);
		border: 1px solid var(--border-strong);
		border-radius: var(--radius-lg);
		box-shadow:
			0 30px 80px rgba(0, 0, 0, 0.5),
			0 0 0 1px rgba(255, 255, 255, 0.04) inset;
		margin: 0 auto;
		max-width: 760px;
		overflow: hidden;
	}

	.session-body {
		font-family: 'SF Mono', ui-monospace, Menlo, Consolas, monospace;
		font-size: 17px;
		line-height: 1.7;
		min-height: 130px;
		padding: 32px 32px 40px;
		position: relative;
	}

	.session-line {
		color: var(--ink);
		margin: 0;
		white-space: pre-wrap;
		word-break: break-word;
	}

	.session-tooltip {
		--mix: color-mix(in srgb, var(--tt) 14%, #1a1a1a);
		animation: ttIn 0.18s var(--ease);
		background: var(--mix);
		border-radius: 10px;
		bottom: 12px;
		box-shadow: 0 8px 24px rgba(0, 0, 0, 0.45);
		color: #fff;
		display: inline-flex;
		flex-direction: column;
		font-family: 'SF Mono', Menlo, Consolas, monospace;
		font-size: 13px;
		gap: 2px;
		padding: 8px 14px;
		position: absolute;
		right: 24px;
	}
	.session-tooltip::before {
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 10px;
		content: '';
		inset: 0;
		pointer-events: none;
		position: absolute;
	}

	/* ============================================================
	   3/ Features grid
	   ============================================================ */

	.features {
		margin: 96px 0;
	}

	.feat-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(4, 1fr);
	}

	.feat-card {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--radius);
		padding: 24px;
		position: relative;
		transition:
			transform 0.25s var(--ease),
			border-color 0.25s var(--ease),
			background 0.25s var(--ease);
	}
	.feat-card::before {
		background: linear-gradient(135deg, var(--accent), transparent 70%);
		border-radius: inherit;
		content: '';
		inset: 0;
		opacity: 0;
		pointer-events: none;
		position: absolute;
		transition: opacity 0.25s var(--ease);
	}
	.feat-card:hover {
		background: var(--surface-strong);
		border-color: var(--accent);
		transform: translateY(-3px);
	}
	.feat-card:hover::before {
		opacity: 0.07;
	}

	.feat-glyph {
		align-items: center;
		background: color-mix(in srgb, var(--accent) 22%, #0c0c10);
		border: 1px solid color-mix(in srgb, var(--accent) 50%, transparent);
		border-radius: 10px;
		color: #fff;
		display: inline-flex;
		font-size: 22px;
		height: 42px;
		justify-content: center;
		margin-bottom: 18px;
		width: 42px;
	}

	.feat-card h3 {
		font-size: 17px;
		font-weight: 600;
		margin: 0 0 8px;
	}
	.feat-card p {
		color: var(--ink-soft);
		font-size: 14px;
		line-height: 1.55;
		margin: 0;
	}

	@media (max-width: 1024px) {
		.feat-grid {
			grid-template-columns: repeat(2, 1fr);
		}
	}
	@media (max-width: 560px) {
		.feat-grid {
			grid-template-columns: 1fr;
		}
	}

	/* ============================================================
	   3.5/ Tap-holds spotlight
	   ============================================================ */

	.tapholds {
		margin: 96px 0;
	}

	.tap-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(2, 1fr);
		margin: 0 auto;
		max-width: 880px;
	}

	.tap-card {
		background:
			radial-gradient(
				ellipse at top right,
				color-mix(in srgb, var(--accent) 20%, transparent),
				transparent 60%
			),
			rgba(8, 12, 24, 0.8);
		border: 1px solid var(--border-strong);
		border-radius: var(--radius-lg);
		display: grid;
		gap: 18px;
		grid-template-columns: 96px 1fr;
		padding: 22px;
		transition:
			transform 0.25s var(--ease),
			border-color 0.25s var(--ease);
	}
	.tap-card:hover {
		border-color: var(--accent);
		transform: translateY(-2px);
	}

	.tap-key {
		align-items: flex-start;
		display: flex;
		justify-content: center;
		padding-top: 4px;
	}

	.tap-keycap {
		align-items: center;
		background: linear-gradient(180deg, #2a2a30 0%, #1a1a20 100%);
		border: 1px solid rgba(255, 255, 255, 0.18);
		border-bottom: 2px solid rgba(0, 0, 0, 0.6);
		border-radius: 10px;
		box-shadow:
			inset 0 1px 0 rgba(255, 255, 255, 0.12),
			0 4px 0 rgba(0, 0, 0, 0.4),
			0 8px 16px rgba(0, 0, 0, 0.45);
		color: var(--ink);
		display: inline-flex;
		font-family: 'SF Mono', ui-monospace, Menlo, Consolas, monospace;
		font-size: 13px;
		font-weight: 600;
		justify-content: center;
		min-height: 56px;
		min-width: 80px;
		padding: 8px 10px;
	}

	.tap-rows {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.tap-row {
		align-items: center;
		background: rgba(255, 255, 255, 0.04);
		border: 1px solid rgba(255, 255, 255, 0.08);
		border-radius: 10px;
		display: grid;
		gap: 10px;
		grid-template-columns: 56px 28px 1fr;
		padding: 8px 12px;
	}

	.tap-row-hold {
		background: color-mix(in srgb, var(--accent) 18%, rgba(8, 12, 24, 0.9));
		border-color: color-mix(in srgb, var(--accent) 40%, transparent);
	}

	.tap-pill {
		background: rgba(255, 255, 255, 0.1);
		border-radius: 999px;
		color: var(--ink-soft);
		font-size: 10.5px;
		font-weight: 600;
		letter-spacing: 0.06em;
		padding: 3px 0;
		text-align: center;
		text-transform: uppercase;
	}
	.tap-pill-hold {
		background: var(--accent);
		color: #fff;
	}

	.tap-glyph {
		color: var(--accent);
		font-size: 18px;
		text-align: center;
	}

	.tap-action {
		color: var(--ink);
		font-size: 14.5px;
		font-weight: 500;
	}

	.tap-note {
		color: var(--ink-soft);
		font-size: 12.5px;
		grid-column: 1 / -1;
		line-height: 1.5;
		margin: 4px 0 0;
	}

	@media (max-width: 720px) {
		.tap-grid {
			grid-template-columns: 1fr;
		}
	}

	/* ============================================================
	   3.6/ Hotstrings deep dive
	   ============================================================ */

	.hotdetail {
		margin: 96px 0;
	}

	.hotdetail-grid {
		display: grid;
		gap: 18px;
		grid-template-columns: repeat(2, 1fr);
		margin: 0 auto;
		max-width: 980px;
	}

	.hotdetail-card {
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border-strong);
		border-left: 3px solid var(--accent);
		border-radius: var(--radius-lg);
		padding: 24px 26px;
	}

	.hotdetail-head {
		align-items: center;
		display: flex;
		gap: 14px;
		margin-bottom: 12px;
	}
	.hotdetail-dot {
		background: var(--accent);
		border-radius: 50%;
		box-shadow: 0 0 12px var(--accent);
		display: inline-block;
		flex-shrink: 0;
		height: 10px;
		width: 10px;
	}
	.hotdetail-card h3 {
		font-size: 18px;
		font-weight: 700;
		margin: 0;
	}
	.hotdetail-tag {
		color: var(--ink-faint);
		font-size: 12px;
		margin: 2px 0 0;
	}
	.hotdetail-lead {
		color: var(--ink-soft);
		font-size: 13.5px;
		line-height: 1.55;
		margin: 0 0 18px;
	}

	.hotdetail-rows {
		display: flex;
		flex-direction: column;
		gap: 10px;
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.hotdetail-rows li {
		background: rgba(255, 255, 255, 0.04);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 10px;
		padding: 10px 12px;
	}
	.hot-trig {
		align-items: center;
		display: flex;
		font-family: 'SF Mono', ui-monospace, Menlo, Consolas, monospace;
		font-size: 14px;
		gap: 8px;
		margin-bottom: 6px;
	}
	.hot-key {
		background: color-mix(in srgb, var(--accent) 22%, #0c0c10);
		border: 1px solid color-mix(in srgb, var(--accent) 50%, transparent);
		border-radius: 6px;
		color: #fff;
		padding: 2px 8px;
	}
	.hot-arrow {
		color: var(--accent);
	}
	.hot-out {
		color: #fff;
		font-weight: 600;
	}
	.hot-context {
		color: var(--ink-soft);
		display: flex;
		flex-wrap: wrap;
		font-size: 12.5px;
		gap: 4px 10px;
	}
	.hot-word {
		font-family: 'SF Mono', ui-monospace, Menlo, Consolas, monospace;
		white-space: pre-line;
	}

	@media (max-width: 720px) {
		.hotdetail-grid {
			grid-template-columns: 1fr;
		}
	}

	/* ============================================================
	   3.7/ Power features
	   ============================================================ */

	.power {
		margin: 96px 0;
	}

	.power-grid {
		display: grid;
		gap: 14px;
		grid-template-columns: repeat(4, 1fr);
		margin: 0 auto;
		max-width: 1080px;
	}

	.power-card {
		background: rgba(8, 12, 24, 0.7);
		border: 1px solid var(--border);
		border-radius: var(--radius);
		padding: 22px 20px;
		text-align: left;
	}

	.power-icon {
		color: var(--couleur-bleue);
		font-size: 26px;
		margin-bottom: 12px;
	}
	.power-card h3 {
		font-size: 15px;
		font-weight: 600;
		margin: 0 0 6px;
	}
	.power-card p {
		color: var(--ink-soft);
		font-size: 13px;
		line-height: 1.55;
		margin: 0;
	}

	@media (max-width: 880px) {
		.power-grid {
			grid-template-columns: repeat(2, 1fr);
		}
	}
	@media (max-width: 480px) {
		.power-grid {
			grid-template-columns: 1fr;
		}
	}

	/* ============================================================
	   3.8/ Navigation layer
	   ============================================================ */

	.navlayer {
		margin: 96px 0;
	}

	.navlayer-window {
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border-strong);
		border-radius: var(--radius-lg);
		margin: 0 auto;
		max-width: 880px;
		padding: 28px 26px;
	}

	.navlayer-hold {
		align-items: center;
		color: var(--ink-soft);
		display: flex;
		font-family: 'SF Mono', ui-monospace, Menlo, Consolas, monospace;
		gap: 10px;
		justify-content: center;
		margin-bottom: 22px;
	}
	.navlayer-pill {
		background: #fb8c00;
		border-radius: 999px;
		color: #fff;
		font-size: 11px;
		font-weight: 700;
		letter-spacing: 0.06em;
		padding: 4px 10px;
		text-transform: uppercase;
	}
	.navlayer-key {
		background: linear-gradient(180deg, #2a2a30 0%, #1a1a20 100%);
		border: 1px solid rgba(255, 255, 255, 0.18);
		border-bottom: 2px solid rgba(0, 0, 0, 0.6);
		border-radius: 8px;
		color: #fff;
		font-size: 13px;
		font-weight: 600;
		padding: 6px 14px;
	}
	.navlayer-plus {
		color: var(--ink-faint);
	}

	.navlayer-grid {
		display: grid;
		gap: 12px;
		grid-template-columns: repeat(5, 1fr);
	}

	.navlayer-cell {
		align-items: center;
		background: rgba(255, 255, 255, 0.04);
		border: 1px solid rgba(255, 255, 255, 0.07);
		border-radius: 10px;
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 14px 8px;
	}

	.navlayer-cell :global(kbd) {
		background: linear-gradient(180deg, #2a2a30 0%, #1a1a20 100%);
		border: 1px solid rgba(255, 255, 255, 0.16);
		border-bottom: 2px solid rgba(0, 0, 0, 0.5);
		border-radius: 6px;
		color: #fff;
		display: inline-block;
		font-family: 'SF Mono', ui-monospace, Menlo, Consolas, monospace;
		font-size: 12px;
		min-width: 28px;
		padding: 4px 6px;
		text-align: center;
	}

	.navlayer-arrow {
		color: var(--ink-faint);
		font-size: 10.5px;
		letter-spacing: 0.05em;
		text-transform: uppercase;
	}

	.navlayer-target {
		align-items: center;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}
	.navlayer-glyph {
		color: #fb8c00;
		font-size: 22px;
		line-height: 1;
	}
	.navlayer-desc {
		color: var(--ink);
		font-size: 12px;
		font-weight: 500;
	}

	@media (max-width: 720px) {
		.navlayer-grid {
			grid-template-columns: repeat(3, 1fr);
		}
	}
	@media (max-width: 460px) {
		.navlayer-grid {
			grid-template-columns: repeat(2, 1fr);
		}
	}

	/* ============================================================
	   3.9/ AI predictions
	   ============================================================ */

	.ai {
		margin: 96px 0;
	}

	.ai-window {
		background: rgba(8, 12, 24, 0.9);
		border: 1px solid var(--border-strong);
		box-shadow:
			0 30px 80px rgba(0, 0, 0, 0.5),
			0 0 0 1px rgba(255, 255, 255, 0.04) inset;
		margin: 0 auto;
		max-width: 760px;
		overflow: hidden;
	}
	.ai-window.os-macos {
		border-radius: var(--radius-lg);
	}
	.ai-window.os-windows {
		border-radius: 8px;
	}

	.ai-body {
		font-family: 'SF Mono', ui-monospace, Menlo, Consolas, monospace;
		padding: 32px 32px 40px;
		position: relative;
	}

	.ai-context {
		color: var(--ink);
		font-size: 17px;
		line-height: 1.6;
		margin: 0 0 24px;
	}

	.ai-tooltip {
		background: linear-gradient(180deg, rgba(236, 64, 122, 0.12), rgba(8, 12, 24, 0.9));
		border: 1px solid rgba(236, 64, 122, 0.35);
		border-radius: 12px;
		padding: 12px 14px;
	}

	.ai-tooltip-head {
		align-items: center;
		color: var(--ink-soft);
		display: flex;
		font-family: 'Segoe UI', system-ui, sans-serif;
		font-size: 12px;
		gap: 8px;
		margin-bottom: 10px;
	}
	.ai-bolt {
		color: #ec407a;
		font-size: 14px;
	}
	.ai-shortcut {
		background: rgba(255, 255, 255, 0.08);
		border-radius: 4px;
		color: var(--ink);
		font-size: 11px;
		margin-left: auto;
		padding: 2px 6px;
	}

	.ai-list {
		display: flex;
		flex-direction: column;
		gap: 4px;
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.ai-list li {
		align-items: center;
		border-radius: 6px;
		color: var(--ink-soft);
		display: flex;
		font-family: 'Segoe UI', system-ui, sans-serif;
		font-size: 14px;
		gap: 10px;
		padding: 6px 8px;
	}
	.ai-list li.active {
		background: rgba(236, 64, 122, 0.15);
		color: var(--ink);
	}
	.ai-num {
		background: rgba(255, 255, 255, 0.1);
		border-radius: 50%;
		color: var(--ink);
		font-size: 11px;
		font-weight: 600;
		height: 20px;
		line-height: 20px;
		text-align: center;
		width: 20px;
	}
	.ai-list li.active .ai-num {
		background: #ec407a;
	}

	/* ============================================================
	   3.95/ Typing metrics
	   ============================================================ */

	.metrics {
		margin: 96px 0;
	}

	.metrics-grid {
		display: grid;
		gap: 14px;
		grid-template-columns: repeat(3, 1fr);
		margin: 0 auto;
		max-width: 980px;
	}

	.metric-card {
		background:
			radial-gradient(
				ellipse at top right,
				color-mix(in srgb, var(--accent) 22%, transparent),
				transparent 60%
			),
			rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border-strong);
		border-radius: var(--radius-lg);
		padding: 22px 24px;
		position: relative;
	}
	.metric-card::before {
		background: var(--accent);
		border-radius: 4px 0 0 4px;
		bottom: 22px;
		content: '';
		left: 0;
		position: absolute;
		top: 22px;
		width: 3px;
	}

	.metric-label {
		color: var(--ink-soft);
		font-size: 12px;
		letter-spacing: 0.04em;
		text-transform: uppercase;
	}
	.metric-value {
		color: #fff;
		font-size: 30px;
		font-weight: 700;
		letter-spacing: -0.02em;
		margin: 6px 0 4px;
	}
	.metric-delta {
		color: var(--accent);
		font-size: 12.5px;
	}

	@media (max-width: 880px) {
		.metrics-grid {
			grid-template-columns: repeat(2, 1fr);
		}
	}
	@media (max-width: 480px) {
		.metrics-grid {
			grid-template-columns: 1fr;
		}
	}

	/* ============================================================
	   4/ Showcase Mac window
	   ============================================================ */

	.showcase {
		margin: 96px 0;
	}

	.mac-window {
		background: rgba(8, 12, 24, 0.9);
		border: 1px solid var(--border-strong);
		border-radius: var(--radius-lg);
		box-shadow:
			0 40px 100px rgba(0, 0, 0, 0.55),
			0 0 0 1px rgba(255, 255, 255, 0.04) inset;
		margin: 0 auto;
		max-width: 820px;
		overflow: hidden;
	}

	.mac-body {
		padding: 0;
	}

	.mac-toolbar {
		align-items: center;
		border-bottom: 1px solid var(--border);
		display: flex;
		gap: 8px;
		padding: 14px 18px;
	}

	.mac-btn {
		background: rgba(255, 255, 255, 0.06);
		border: 1px solid var(--border);
		border-radius: 8px;
		color: var(--ink);
		cursor: pointer;
		font: inherit;
		font-size: 12.5px;
		padding: 6px 12px;
		transition: background 0.15s var(--ease);
	}
	.mac-btn:hover {
		background: rgba(255, 255, 255, 0.1);
	}
	.mac-btn.ghost {
		background: transparent;
	}

	.mac-toolbar .spacer {
		flex: 1;
	}
	.mac-hint {
		color: var(--ink-faint);
		font-size: 12px;
	}

	.mac-row {
		align-items: center;
		display: grid;
		gap: 14px;
		grid-template-columns: 18px 1fr auto auto 14px;
		padding: 14px 18px;
		transition: background 0.15s var(--ease);
	}
	.mac-row + .mac-row {
		border-top: 1px solid rgba(255, 255, 255, 0.04);
	}
	.mac-row:hover {
		background: rgba(255, 255, 255, 0.03);
	}

	.mac-swatch {
		border: 1px solid rgba(255, 255, 255, 0.15);
		border-radius: 4px;
		display: inline-block;
		height: 14px;
		width: 14px;
	}
	.mac-name {
		font-size: 14px;
		font-weight: 500;
	}
	.mac-meta {
		color: var(--ink-faint);
		font-size: 12.5px;
	}
	.mac-delay {
		color: var(--ink);
		font-family: 'SF Mono', Menlo, Consolas, monospace;
		font-size: 13px;
	}
	.mac-arrow {
		color: var(--ink-faint);
		font-size: 16px;
	}

	/* ============================================================
	   5/ Cross-platform
	   ============================================================ */

	.platforms {
		margin: 96px 0;
	}

	.compare-table-wrap {
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border-strong);
		border-radius: var(--radius-lg);
		box-shadow:
			0 30px 80px rgba(0, 0, 0, 0.35),
			0 0 0 1px rgba(255, 255, 255, 0.04) inset;
		margin: 0 auto;
		max-width: 760px;
		overflow: hidden;
	}

	.compare-table {
		border-collapse: collapse;
		font-size: 14.5px;
		width: 100%;
	}

	.compare-table th,
	.compare-table td {
		padding: 14px 20px;
		text-align: left;
	}

	.compare-table thead th {
		background: rgba(0, 0, 0, 0.35);
		border-bottom: 1px solid var(--border-strong);
		color: var(--ink);
		font-weight: 600;
		vertical-align: top;
	}

	.compare-table th.compare-os {
		text-align: center;
		width: 25%;
	}
	.compare-table th.compare-os i {
		color: var(--couleur-bleue);
		display: block;
		font-size: 22px;
		margin-bottom: 4px;
		text-align: center;
	}
	.compare-os-name {
		display: block;
		font-size: 14px;
	}
	.compare-os-driver {
		color: var(--ink-faint);
		display: block;
		font-size: 12px;
		font-weight: 400;
		margin-top: 2px;
	}

	.compare-table tbody tr + tr td {
		border-top: 1px solid rgba(255, 255, 255, 0.06);
	}
	.compare-table tbody tr:hover td {
		background: rgba(255, 255, 255, 0.04);
	}

	.compare-table td.compare-feature {
		color: var(--ink-soft);
	}

	.compare-table td.compare-cell {
		font-size: 18px;
		text-align: center;
	}
	.compare-table td.compare-cell.no {
		filter: grayscale(0.4);
		opacity: 0.7;
	}

	@media (max-width: 600px) {
		.compare-table th,
		.compare-table td {
			padding: 12px 12px;
		}
		.compare-table {
			font-size: 13.5px;
		}
		.compare-os-driver {
			display: none;
		}
	}

	/* ============================================================
	   6/ Final CTA
	   ============================================================ */

	.final-cta {
		margin: 96px 0 0;
	}

	.cta-card {
		background:
			radial-gradient(ellipse at top, rgba(49, 190, 255, 0.18), transparent 60%),
			rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border-strong);
		border-radius: var(--radius-lg);
		padding: 64px 32px;
		text-align: center;
	}
	.cta-card h2 {
		font-size: clamp(26px, 3vw, 38px);
		font-weight: 700;
		letter-spacing: -0.02em;
		margin: 0 0 12px;
	}
	.cta-card p {
		color: var(--ink-soft);
		font-size: 16px;
		margin: 0 0 28px;
	}
	.cta-card .hero-cta {
		margin-bottom: 0;
	}

	/* ─── Promises section ──────────────────────────────── */
	.promises {
		margin: 72px 0;
	}
	.promise-grid {
		display: grid;
		gap: 24px;
		grid-template-columns: repeat(3, 1fr);
		margin-top: 48px;
	}
	@media (max-width: 880px) {
		.promise-grid {
			grid-template-columns: 1fr;
		}
	}
	.promise-card {
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border);
		border-radius: var(--radius-md);
		padding: 32px 28px;
		text-align: center;
	}
	.promise-icon {
		font-size: 38px;
		margin-bottom: 16px;
	}
	.promise-card h3 {
		font-size: 18px;
		font-weight: 700;
		letter-spacing: -0.01em;
		margin: 0 0 12px;
	}
	.promise-card p {
		color: var(--ink-soft);
		font-size: 14px;
		line-height: 1.6;
		margin: 0;
	}

	/* ─── Hotstrings persos & dynamiques ────────────────── */
	.hsmore {
		margin: 96px 0;
	}
	.hsmore-grid {
		display: grid;
		gap: 32px;
		grid-template-columns: repeat(2, 1fr);
		margin-top: 48px;
	}
	@media (max-width: 880px) {
		.hsmore-grid {
			grid-template-columns: 1fr;
		}
	}
	.hsmore-card {
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border);
		border-radius: var(--radius-md);
		padding: 32px;
	}
	.hsmore-card h3 {
		font-size: 22px;
		font-weight: 700;
		letter-spacing: -0.01em;
		margin: 0 0 6px;
	}
	.hsmore-card h4 {
		color: var(--ink);
		font-size: 14px;
		font-weight: 700;
		letter-spacing: 0.02em;
		margin: 24px 0 12px;
		text-transform: uppercase;
	}
	.hsmore-sub {
		color: var(--ink-soft);
		font-size: 14px;
		margin: 0 0 16px;
	}
	.hsmore-text {
		color: var(--ink-soft);
		font-size: 14px;
		line-height: 1.65;
		margin: 0 0 12px;
	}
	.hsmore-steps {
		color: var(--ink-soft);
		font-size: 14px;
		line-height: 1.7;
		margin: 0 0 12px;
		padding-left: 20px;
	}
	.hsmore-steps li {
		margin-bottom: 6px;
	}
	.hsmore-rows {
		display: flex;
		flex-direction: column;
		gap: 6px;
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.hsmore-rows li {
		align-items: center;
		display: flex;
		gap: 10px;
	}

	.hs-key {
		background: rgba(255, 255, 255, 0.05);
		border: 1px solid var(--border);
		border-radius: 6px;
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 13px;
		min-width: 56px;
		padding: 4px 10px;
		text-align: center;
	}
	.hs-arrow {
		color: var(--ink-faint);
		font-size: 12px;
	}
	.hs-out {
		color: var(--ink);
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 13px;
		font-weight: 600;
	}
	.hs-desc {
		color: var(--ink-faint);
		font-size: 12px;
		margin-left: auto;
	}

	/* ─── Magic key full picture ────────────────────────── */
	.magic {
		margin: 96px 0;
	}
	.magic-grid {
		display: grid;
		gap: 24px;
		grid-template-columns: repeat(3, 1fr);
		margin-top: 48px;
	}
	@media (max-width: 1100px) {
		.magic-grid {
			grid-template-columns: 1fr;
		}
	}
	.magic-card {
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border);
		border-radius: var(--radius-md);
		padding: 28px;
	}
	.magic-card h3 {
		font-size: 18px;
		font-weight: 700;
		letter-spacing: -0.01em;
		margin: 0 0 12px;
	}
	.magic-card p {
		color: var(--ink-soft);
		font-size: 14px;
		line-height: 1.6;
		margin: 0 0 16px;
	}
	.magic-rows {
		display: flex;
		flex-direction: column;
		gap: 4px;
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.magic-rows li {
		align-items: center;
		display: flex;
		gap: 10px;
	}

	/* ─── Suffixes en À ────────────────────────────────── */
	.suffixes {
		margin: 96px 0;
	}
	.suffixes-grid {
		display: grid;
		gap: 12px;
		grid-template-columns: repeat(3, 1fr);
		margin-top: 32px;
	}
	@media (max-width: 720px) {
		.suffixes-grid {
			grid-template-columns: 1fr;
		}
	}
	.suffix-row {
		align-items: center;
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		display: flex;
		gap: 12px;
		padding: 14px 18px;
	}
	.suffix-row-3col {
		justify-content: flex-start;
	}
	.suffixes-foot {
		color: var(--ink-soft);
		font-size: 14px;
		margin: 28px auto 0;
		max-width: 720px;
		text-align: center;
	}

	/* ─── Symbol rolls ────────────────────────────────── */
	.symbols {
		margin: 96px 0;
	}
	.symbols-grid {
		display: grid;
		gap: 10px;
		grid-template-columns: repeat(2, 1fr);
		margin-top: 32px;
	}
	@media (max-width: 720px) {
		.symbols-grid {
			grid-template-columns: 1fr;
		}
	}
	.symbol-row {
		align-items: center;
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		display: flex;
		gap: 12px;
		padding: 12px 16px;
	}

	/* ─── Super-keys section ──────────────────────────── */
	.superkeys {
		margin: 96px 0;
	}
	.superkeys-stack {
		display: flex;
		flex-direction: column;
		gap: 24px;
		margin-top: 48px;
	}
	.super-card {
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border);
		border-radius: var(--radius-md);
		padding: 28px 32px;
	}
	.super-card h3 {
		font-size: 18px;
		font-weight: 700;
		letter-spacing: -0.01em;
		margin: 0 0 12px;
	}
	.super-card p {
		color: var(--ink-soft);
		font-size: 14px;
		line-height: 1.65;
		margin: 0 0 16px;
	}
	.super-grid {
		display: grid;
		gap: 8px;
	}
	.super-grid-tight {
		grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
	}
	.super-grid-2col {
		gap: 24px;
		grid-template-columns: repeat(2, 1fr);
	}
	@media (max-width: 880px) {
		.super-grid-2col {
			grid-template-columns: 1fr;
		}
	}
	.super-mini {
		align-items: center;
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
	}

	/* ─── AI section additions ───────────────────────── */
	.ai-section {
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border);
		border-radius: var(--radius-md);
		margin-top: 32px;
		padding: 32px;
	}
	.ai-section h3 {
		font-size: 20px;
		font-weight: 700;
		letter-spacing: -0.01em;
		margin: 0 0 12px;
	}
	.ai-text {
		color: var(--ink-soft);
		font-size: 14px;
		line-height: 1.7;
		margin: 0 0 20px;
	}
	.ai-text-small {
		color: var(--ink-faint);
		font-size: 13px;
		line-height: 1.6;
		margin: 16px 0 0;
	}
	.ai-backends {
		display: grid;
		gap: 16px;
		grid-template-columns: 1fr 1fr;
	}
	@media (max-width: 720px) {
		.ai-backends {
			grid-template-columns: 1fr;
		}
	}
	.ai-backend {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		display: flex;
		gap: 16px;
		padding: 20px;
	}
	.ai-backend-icon {
		flex-shrink: 0;
		font-size: 32px;
	}
	.ai-backend h4 {
		font-size: 16px;
		font-weight: 700;
		margin: 0 0 4px;
	}
	.ai-port {
		color: var(--ink-faint);
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 11px;
		font-weight: 400;
		margin-left: 8px;
	}
	.ai-backend-aud {
		color: var(--ink-soft);
		font-size: 13px;
		margin: 0 0 8px;
	}
	.ai-backend-pro {
		color: var(--ink-faint);
		font-size: 13px;
		font-style: italic;
		line-height: 1.55;
		margin: 0;
	}
	.ai-providers {
		display: grid;
		gap: 10px;
		grid-template-columns: repeat(4, 1fr);
	}
	@media (max-width: 1100px) {
		.ai-providers {
			grid-template-columns: repeat(3, 1fr);
		}
	}
	@media (max-width: 720px) {
		.ai-providers {
			grid-template-columns: repeat(2, 1fr);
		}
	}
	@media (max-width: 480px) {
		.ai-providers {
			grid-template-columns: 1fr;
		}
	}
	.ai-provider {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 14px 16px;
	}
	.ai-provider-name {
		color: var(--ink);
		font-size: 13px;
		font-weight: 700;
	}
	.ai-provider-family {
		color: var(--ink-soft);
		flex: 1;
		font-size: 12px;
		line-height: 1.45;
	}
	.ai-provider-meta {
		align-items: center;
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		margin-top: 4px;
	}
	.ai-provider-count {
		background: rgba(49, 190, 255, 0.12);
		border: 1px solid rgba(49, 190, 255, 0.3);
		border-radius: 999px;
		color: var(--couleur-bleue);
		font-size: 11px;
		font-weight: 600;
		padding: 2px 9px;
	}
	.ai-provider-range {
		color: var(--ink-faint);
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 11px;
	}
	.ai-custom {
		background: linear-gradient(135deg, rgba(236, 64, 122, 0.12), rgba(8, 12, 24, 0.85));
		border: 1px dashed rgba(236, 64, 122, 0.45);
		border-radius: var(--radius-md);
		display: flex;
		gap: 18px;
		margin-top: 20px;
		padding: 22px 24px;
	}
	.ai-custom-icon {
		color: #ec407a;
		flex-shrink: 0;
		font-size: 32px;
		font-weight: 700;
		line-height: 1;
	}
	.ai-custom h4 {
		color: var(--ink);
		font-size: 16px;
		font-weight: 700;
		margin: 0 0 8px;
	}
	.ai-custom p {
		color: var(--ink-soft);
		font-size: 13px;
		line-height: 1.6;
		margin: 0 0 8px;
	}
	.ai-custom-foot {
		color: var(--ink-faint);
		font-size: 12px !important;
		font-style: italic;
		margin-top: 6px !important;
	}
	.ai-profiles {
		display: grid;
		gap: 14px;
		grid-template-columns: repeat(2, 1fr);
	}
	@media (max-width: 720px) {
		.ai-profiles {
			grid-template-columns: 1fr;
		}
	}
	.ai-profile {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		padding: 18px 20px;
	}
	.ai-profile header {
		align-items: baseline;
		display: flex;
		gap: 12px;
		margin-bottom: 8px;
	}
	.ai-profile-name {
		font-size: 16px;
		font-weight: 700;
	}
	.ai-profile-tag {
		color: var(--ink-faint);
		font-size: 12px;
		letter-spacing: 0.04em;
		text-transform: uppercase;
	}
	.ai-profile p {
		color: var(--ink-soft);
		font-size: 13px;
		line-height: 1.6;
		margin: 0;
	}
	.ai-corrections {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		display: flex;
		flex-direction: column;
		gap: 10px;
		padding: 18px;
	}
	.ai-correction-row {
		align-items: center;
		display: flex;
		flex-wrap: wrap;
		gap: 12px;
	}
	.ai-tooltip-mock {
		border-radius: 6px;
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 13px;
		padding: 4px 10px;
	}
	.ai-tooltip-mock--correct {
		background: #43a047;
		color: #fff;
	}
	.ai-tooltip-mock--predict {
		background: #ec407a;
		color: #fff;
	}
	.ai-correction-arrow {
		color: var(--ink-faint);
		font-size: 12px;
	}
	.ai-correction-orig {
		color: var(--ink-soft);
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 13px;
		text-decoration: line-through;
		text-decoration-color: rgba(244, 67, 54, 0.6);
	}
	.ai-shortcuts-list {
		color: var(--ink-soft);
		font-size: 14px;
		line-height: 2;
		list-style: none;
		margin: 0;
		padding: 0;
	}
	.ai-shortcuts-list kbd {
		background: rgba(255, 255, 255, 0.06);
		border: 1px solid var(--border);
		border-radius: 4px;
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 12px;
		margin-right: 8px;
		padding: 2px 8px;
	}

	/* ─── Trackpad gestures ──────────────────────────── */
	.trackpad {
		margin: 96px 0;
	}
	.trackpad-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(4, 1fr);
		margin-top: 40px;
	}
	@media (max-width: 1100px) {
		.trackpad-grid {
			grid-template-columns: repeat(2, 1fr);
		}
	}
	@media (max-width: 600px) {
		.trackpad-grid {
			grid-template-columns: 1fr;
		}
	}
	.trackpad-card {
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border);
		border-left: 3px solid var(--accent);
		border-radius: var(--radius-sm);
		padding: 20px 18px;
	}
	.trackpad-meta {
		align-items: baseline;
		display: flex;
		gap: 8px;
		margin-bottom: 10px;
	}
	.trackpad-fingers {
		color: var(--accent);
		font-size: 12px;
		font-weight: 700;
		letter-spacing: 0.04em;
		text-transform: uppercase;
	}
	.trackpad-type {
		color: var(--ink-faint);
		font-size: 12px;
	}
	.trackpad-action {
		color: var(--ink);
		font-size: 16px;
		font-weight: 700;
		margin-bottom: 8px;
	}
	.trackpad-note {
		color: var(--ink-soft);
		font-size: 13px;
		line-height: 1.55;
		margin: 0;
	}
	.trackpad-callout {
		background: linear-gradient(135deg, rgba(0, 131, 143, 0.18), rgba(8, 12, 24, 0.85));
		border: 1px solid rgba(0, 131, 143, 0.45);
		border-radius: var(--radius-md);
		margin-top: 24px;
		padding: 28px 32px;
	}
	.trackpad-callout h3 {
		font-size: 20px;
		font-weight: 700;
		margin: 0 0 10px;
	}
	.trackpad-callout p {
		color: var(--ink-soft);
		font-size: 14px;
		line-height: 1.65;
		margin: 0;
	}
	.trackpad-extras {
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border);
		border-radius: var(--radius-md);
		margin-top: 20px;
		padding: 24px 32px;
	}
	.trackpad-extras h3 {
		font-size: 16px;
		font-weight: 700;
		margin: 0 0 8px;
	}
	.trackpad-extras p {
		color: var(--ink-soft);
		font-size: 14px;
		line-height: 1.65;
		margin: 0;
	}

	/* ─── Personnalisation ──────────────────────────── */
	.custo {
		margin: 96px 0;
	}
	.custo-grid {
		display: grid;
		gap: 18px;
		grid-template-columns: repeat(3, 1fr);
		margin-top: 40px;
	}
	@media (max-width: 1100px) {
		.custo-grid {
			grid-template-columns: repeat(2, 1fr);
		}
	}
	@media (max-width: 600px) {
		.custo-grid {
			grid-template-columns: 1fr;
		}
	}
	.custo-card {
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border);
		border-radius: var(--radius-md);
		padding: 24px;
	}
	.custo-icon {
		font-size: 28px;
		margin-bottom: 12px;
	}
	.custo-card h3 {
		font-size: 16px;
		font-weight: 700;
		letter-spacing: -0.01em;
		margin: 0 0 8px;
	}
	.custo-card p {
		color: var(--ink-soft);
		font-size: 13px;
		line-height: 1.65;
		margin: 0;
	}

	/* ─── Layout-agnostic banner ────────────────────── */
	.agnostic {
		background:
			radial-gradient(ellipse at top, rgba(67, 160, 71, 0.12), transparent 60%),
			rgba(8, 12, 24, 0.85);
		border: 1px solid rgba(67, 160, 71, 0.3);
		border-radius: var(--radius-lg);
		margin: 96px 0;
		padding: 56px 32px;
	}
	.agnostic-row {
		display: grid;
		gap: 20px;
		grid-template-columns: repeat(3, 1fr);
		margin-top: 40px;
	}
	@media (max-width: 880px) {
		.agnostic-row {
			grid-template-columns: 1fr;
		}
	}
	.agnostic-card {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid var(--border);
		border-radius: var(--radius-md);
		padding: 22px 24px;
	}
	.agnostic-card h3 {
		font-size: 16px;
		font-weight: 700;
		margin: 0 0 8px;
	}
	.agnostic-card p {
		color: var(--ink-soft);
		font-size: 13px;
		line-height: 1.6;
		margin: 0;
	}
	.agnostic-foot {
		color: var(--ink-soft);
		font-size: 14px;
		line-height: 1.65;
		margin: 32px auto 0;
		max-width: 760px;
		text-align: center;
	}

	/* ─── Ergopti exclusives banner ──────────────────── */
	.ergopti-banner {
		background:
			radial-gradient(ellipse at top, rgba(229, 57, 53, 0.1), transparent 50%),
			rgba(8, 12, 24, 0.85);
		border: 1px solid rgba(229, 57, 53, 0.3);
		border-radius: var(--radius-lg);
		margin: 96px 0;
		padding: 64px 32px;
	}
	.ergopti-head {
		max-width: 820px;
	}
	.ergopti-kicker {
		color: #e53935 !important;
		font-weight: 700;
	}
	.lead-em {
		font-style: italic;
		margin-top: 16px !important;
	}
	.ergopti-block {
		background: rgba(255, 255, 255, 0.02);
		border: 1px solid var(--border);
		border-radius: var(--radius-md);
		margin-top: 32px;
		padding: 32px;
	}
	.ergopti-h3 {
		font-size: 22px;
		font-weight: 700;
		letter-spacing: -0.01em;
		margin: 0 0 12px;
	}
	.ergopti-text {
		color: var(--ink-soft);
		font-size: 14px;
		line-height: 1.7;
		margin: 0 0 24px;
	}
	.ergopti-block .super-card {
		background: rgba(8, 12, 24, 0.6);
		margin-top: 16px;
	}
	.ergopti-block .super-card:first-of-type {
		margin-top: 0;
	}
	.ergopti-block .super-card h4 {
		font-size: 16px;
		font-weight: 700;
		letter-spacing: -0.01em;
		margin: 0 0 10px;
	}
	.ergopti-block .super-card p {
		font-size: 13px;
	}
	.ergopti-banner .hotdetail-grid {
		grid-template-columns: repeat(3, 1fr);
		margin-top: 32px;
	}
	@media (max-width: 1100px) {
		.ergopti-banner .hotdetail-grid {
			grid-template-columns: 1fr;
		}
	}

	/* ─── Magic 2-column override ────────────────────── */
	.magic-grid-2 {
		grid-template-columns: repeat(2, 1fr);
	}
	@media (max-width: 880px) {
		.magic-grid-2 {
			grid-template-columns: 1fr;
		}
	}

	/* ─── AI multi-example mockups ───────────────────── */
	.ai-example {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		margin-bottom: 20px;
		padding: 24px;
	}
	.ai-example:last-of-type {
		margin-bottom: 0;
	}
	.ai-example-head {
		align-items: center;
		display: flex;
		gap: 14px;
		margin-bottom: 16px;
	}
	.ai-example-num {
		align-items: center;
		background: #ec407a;
		border-radius: 8px;
		color: #fff;
		display: inline-flex;
		font-size: 16px;
		font-weight: 700;
		height: 32px;
		justify-content: center;
		width: 32px;
	}
	.ai-example-num-green {
		background: #43a047;
	}
	.ai-example-num-mixed {
		background: linear-gradient(135deg, #43a047 0%, #ec407a 100%);
	}
	.ai-example-head h4 {
		font-size: 16px;
		font-weight: 700;
		margin: 0;
	}
	.ai-example-tag {
		color: var(--ink-faint);
		font-size: 12px;
		margin: 2px 0 0;
	}
	.ai-example-context {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		color: var(--ink);
		font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
		font-size: 14px;
		line-height: 1.6;
		margin-bottom: 14px;
		padding: 14px 18px;
	}
	.ai-example-typo {
		color: #f4433699;
		text-decoration: underline wavy #f44336;
	}
	.ai-caret {
		animation: blink 1s step-end infinite;
		background: var(--ink);
		display: inline-block;
		height: 14px;
		margin-left: 2px;
		opacity: 0.7;
		vertical-align: middle;
		width: 1.5px;
	}
	@keyframes blink {
		50% {
			opacity: 0;
		}
	}
	.ai-example-foot {
		color: var(--ink-faint);
		font-size: 13px;
		line-height: 1.6;
		margin: 14px 0 0;
	}

	/* ─── Faithful AI tooltip (mirrors tooltip_llm.lua) ─── */
	.hs-tooltip {
		background: rgba(25, 25, 25, 0.97);
		border: 1px solid rgba(255, 255, 255, 0.06);
		border-radius: 10px;
		font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', sans-serif;
		font-size: 14px;
		padding: 10px 16px;
	}
	.hs-tt-line {
		align-items: baseline;
		display: flex;
		flex-wrap: wrap;
		gap: 4px;
		line-height: 1.55;
		padding: 3px 0;
	}
	.hs-tt-spark {
		color: #fae138;
		font-size: 14px;
		margin-right: 4px;
	}
	.hs-tt-line:not(.hs-tt-line--selected) .hs-tt-spark {
		visibility: hidden;
	}
	.hs-tt-eq {
		color: #7f7f7f;
	}
	.hs-tt-eq--dim {
		color: #5a5a5a;
		font-weight: 600;
	}
	.hs-tt-corr {
		color: #41e566;
	}
	.hs-tt-line:not(.hs-tt-line--selected) .hs-tt-corr {
		color: #5a5a5a;
		font-weight: 700;
	}
	.hs-tt-corr--dim {
		color: #5a5a5a !important;
		font-weight: 700;
	}
	.hs-tt-nw {
		color: #ff9d1c;
	}
	.hs-tt-line:not(.hs-tt-line--selected) .hs-tt-nw {
		color: #5a5a5a;
		font-weight: 700;
	}
	.hs-tt-nw--dim {
		color: #5a5a5a !important;
		font-weight: 700;
	}
	.hs-tt-shortcut {
		color: rgba(243, 148, 20, 0.75);
		font-size: 11px;
		margin-left: auto;
		padding-left: 12px;
	}
	.hs-tt-shortcut--dim {
		color: #737373;
	}
	.hs-tt-hint {
		border-top: 1px solid rgba(255, 255, 255, 0.06);
		color: #666;
		font-size: 11px;
		margin-top: 8px;
		padding-top: 8px;
		text-align: center;
	}
	.hs-tt-info {
		color: #4d4d4d;
		font-size: 10px;
		margin-top: 4px;
		text-align: center;
	}

	/* ─── Custo pillars + h3 ─────────────────────────── */
	.custo-pillars {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(3, 1fr);
		margin: 40px 0 32px;
	}
	@media (max-width: 1000px) {
		.custo-pillars {
			grid-template-columns: 1fr;
		}
	}
	.custo-pillar {
		background: rgba(8, 12, 24, 0.85);
		border: 1px solid var(--border);
		border-radius: var(--radius-md);
		display: flex;
		gap: 18px;
		padding: 24px 26px;
	}
	.custo-pillar-num {
		align-items: center;
		background: linear-gradient(135deg, var(--gradient-blue));
		border-radius: 10px;
		color: #fff;
		display: inline-flex;
		flex-shrink: 0;
		font-size: 18px;
		font-weight: 700;
		height: 36px;
		justify-content: center;
		width: 36px;
	}
	.custo-pillar h3 {
		font-size: 16px;
		font-weight: 700;
		margin: 0 0 6px;
	}
	.custo-pillar p {
		color: var(--ink-soft);
		font-size: 13px;
		line-height: 1.6;
		margin: 0;
	}
	.custo-h3 {
		color: var(--ink-faint);
		font-size: 13px;
		font-weight: 700;
		letter-spacing: 0.06em;
		margin: 32px 0 16px;
		text-transform: uppercase;
	}

	/* ─── Trust / privacy / free ───────────────────── */
	.trust {
		background:
			radial-gradient(ellipse at top, rgba(67, 160, 71, 0.1), transparent 60%),
			rgba(8, 12, 24, 0.85);
		border: 1px solid rgba(67, 160, 71, 0.3);
		border-radius: var(--radius-lg);
		margin: 96px 0;
		padding: 56px 32px;
	}
	.trust-grid {
		display: grid;
		gap: 18px;
		grid-template-columns: repeat(2, 1fr);
		margin-top: 40px;
	}
	@media (max-width: 880px) {
		.trust-grid {
			grid-template-columns: 1fr;
		}
	}
	.trust-card {
		background: rgba(255, 255, 255, 0.03);
		border: 1px solid var(--border);
		border-radius: var(--radius-md);
		padding: 28px;
	}
	.trust-icon {
		font-size: 36px;
		margin-bottom: 14px;
	}
	.trust-card h3 {
		font-size: 18px;
		font-weight: 700;
		letter-spacing: -0.01em;
		margin: 0 0 10px;
	}
	.trust-card p {
		color: var(--ink-soft);
		font-size: 14px;
		line-height: 1.65;
		margin: 0;
	}
</style>
