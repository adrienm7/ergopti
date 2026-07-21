<!-- src/routes/ergopti-plus/DriverWindows.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Real Driver Windows
DESCRIPTION:
Embeds the driver's ACTUAL webview windows in iframes — the same HTML/JS/CSS
bundles the drivers open natively, served as-is from static/. The page plays
the native host's role: same-origin iframes let it call the exact injection
entry points the drivers use (injectModels, initData), so the model browser
shows the REAL 110-model catalog and the hotstring editor runs live.

FEATURES & RATIONALE:
1. Zero Screenshots: restyle a driver window and this section updates
   instantly — the strongest possible "what you see is what you install".
2. Host Emulation: injection happens through the drivers' own contracts
   (model_browser/script.js injectModels, hotstring_editor initData, …), so
   the demo can never diverge from the real UI.
==============================================================================
-->

<script>
	import { base } from '$app/paths';
	import WindowChrome from './WindowChrome.svelte';
	import { reveal } from './reveal.js';
	import { ui } from './state.svelte.js';

	/** Downscale threshold — frames narrower than this scale down to fit. */
	const FRAME_DISPLAY_HEIGHT = 600;

	/** @type {{webviews: Array<{id: string, width: number, height: number}>}} */
	let { webviews } = $props();

	// The four windows demoed live, with their injection strategy.
	const tabs = [
		{
			id: 'model_browser',
			label: 'Catalogue de modèles',
			blurb:
				'Le VRAI navigateur de modèles du driver, alimenté ici avec le VRAI catalogue (models.json). Triez, cherchez, comparez — c’est exactement la fenêtre qui s’ouvre depuis le menu.'
		},
		{
			id: 'hotstring_editor',
			label: 'Éditeur de hotstrings',
			blurb:
				'La fenêtre d’édition de vos hotstrings personnels : sections pliables, recherche, ajout en deux champs. Ici avec un jeu de données de démonstration — chez vous, avec vos raccourcis.'
		},
		{
			id: 'personal_info_editor',
			label: 'Infos personnelles',
			blurb:
				'L’éditeur centralisant nom, e-mail, téléphone, IBAN… que les hotstrings dynamiques injectent ensuite à la frappe. Données de démonstration, bien entendu.'
		},
		{
			id: 'changelog',
			label: 'Notes de version',
			blurb:
				'La fenêtre de changelog du driver — elle interroge les releases GitHub en direct. Ce que vous voyez ici est la vraie liste des versions publiées.'
		}
	];

	let activeTab = $state('model_browser');

	let geometry = $derived(
		Object.fromEntries(webviews.map((w) => [w.id, { width: w.width, height: w.height }]))
	);
	let active = $derived(tabs.find((t) => t.id === activeTab) ?? tabs[0]);
	let nativeSize = $derived(geometry[activeTab] ?? { width: 900, height: 600 });

	// French display names for the full window list strip.
	const windowNames = {
		action_picker: 'Sélecteur d’actions',
		changelog: 'Notes de version',
		download_window: 'Téléchargements',
		healthcheck: 'Diagnostic',
		hotstring_editor: 'Éditeur de hotstrings',
		hotstrings_config_window: 'Réglages hotstrings',
		metrics_apps: 'Temps d’écran',
		metrics_typing: 'Statistiques de frappe',
		model_browser: 'Catalogue de modèles',
		onboarding: 'Assistant de démarrage',
		paths_editor: 'Dossier de config',
		personal_info_editor: 'Infos personnelles',
		prompt_editor: 'Éditeur de prompts',
		token_prompt: 'Jeton HuggingFace'
	};

	/**
	 * Parse a "30.53B" / "350M" parameter string into billions.
	 * @param {unknown} raw
	 * @returns {number}
	 */
	function parseParams(raw) {
		if (typeof raw !== 'string' || raw === '') return 0;
		const m = raw.match(/([\d.]+)\s*([BMK]?)/i);
		if (!m) return 0;
		const value = parseFloat(m[1]);
		const unit = (m[2] || 'B').toUpperCase();
		if (unit === 'B') return value;
		if (unit === 'M') return value / 1000;
		return value;
	}

	/**
	 * Feed the model browser with the real catalog, exactly like the native
	 * hosts do: flatten models.json into injectModels() rows.
	 * @param {Window} win
	 */
	async function injectModelBrowser(win) {
		const res = await fetch(`${base}/ergopti_plus/_shared/modules/llm/models.json`);
		const catalog = await res.json();
		const models = [];
		for (const provider of catalog) {
			for (const family of provider.families ?? []) {
				for (const m of family.models ?? []) {
					const total = parseParams(m.parameters?.total);
					const activeB = parseParams(m.parameters?.active);
					models.push({
						name: m.name,
						family: family.label,
						provider: provider.label,
						params_b: total,
						active_b: activeB,
						is_moe: activeB > 0 && activeB < total,
						ram_gb:
							m.hardware_requirements?.ollama?.ram_gb ?? m.hardware_requirements?.mlx?.ram_gb ?? 0,
						speed_tok_s: m.capabilities?.speed_tok_s ?? 0,
						type: m.type || 'chat',
						installed: false,
						url: m.urls?.hf || ''
					});
				}
			}
		}
		const defaultModel = models.find((m) => /qwen/i.test(m.name)) ?? models[0];
		if (defaultModel) defaultModel.installed = true;
		win.injectModels?.({ backend: 'ollama', active: defaultModel?.name ?? '', models });
	}

	/**
	 * Feed the hotstring editor with a small demo dataset through its real
	 * initData() contract.
	 * @param {Window} win
	 */
	function injectHotstringEditor(win) {
		const entry = (trigger, output) => ({
			trigger,
			output,
			is_word: false,
			auto_expand: false,
			is_case_sensitive: false,
			final_result: false
		});
		win.initData?.({
			trigger_char: '★',
			star: '★',
			compact_view: false,
			auto_close: false,
			open_mode: 'menu',
			sections: [
				{
					name: 'signatures',
					description: 'Signatures',
					_exp: true,
					entries: [
						entry('sig★', 'Cordialement,\nAdrien'),
						entry('np★', 'Adrien Moyaux'),
						entry('em★', 'adrien@exemple.fr')
					]
				},
				{
					name: 'travail',
					description: 'Travail',
					_exp: true,
					entries: [
						entry('adr★', '15 rue Lafayette, 75009 Paris'),
						entry('iban★', 'FR76 1234 5678 9012 3456 789'),
						entry('tel★', '+33 6 12 34 56 78')
					]
				}
			]
		});
	}

	/**
	 * Feed the personal-info editor with demo fields + the real French locale
	 * strings so its chrome labels render.
	 * @param {Window} win
	 */
	async function injectPersonalInfo(win) {
		let strings = {};
		try {
			const res = await fetch(`${base}/ergopti_plus/_shared/data/locales/fr.json`);
			strings = await res.json();
		} catch (_) {
			/* labels simply stay blank — the fields still render */
		}
		win.initData?.({
			strings,
			fields: [
				{ key: 'first_name', label: 'Prénom', value: 'Adrien' },
				{ key: 'last_name', label: 'Nom', value: 'Moyaux' },
				{ key: 'email', label: 'E-mail', value: 'adrien@exemple.fr' },
				{ key: 'phone', label: 'Téléphone', value: '+33 6 12 34 56 78' },
				{ key: 'address', label: 'Adresse', value: '15 rue Lafayette, 75009 Paris' },
				{ key: 'iban', label: 'IBAN', value: 'FR76 1234 5678 9012 3456 789' }
			]
		});
	}

	/**
	 * Play the native host: once the iframe loads, inject the data through
	 * the same entry point the driver uses for this window.
	 * @param {Event} ev
	 */
	function onFrameLoad(ev) {
		const win = ev.currentTarget?.contentWindow;
		if (!win) return;
		try {
			if (activeTab === 'model_browser') injectModelBrowser(win);
			else if (activeTab === 'hotstring_editor') injectHotstringEditor(win);
			else if (activeTab === 'personal_info_editor') injectPersonalInfo(win);
			// changelog needs nothing — it fetches GitHub releases on its own.
		} catch (e) {
			console.error('Injection dans la fenêtre du driver impossible :', e);
		}
	}
</script>

<section class="windows" id="fenetres" style="--section-accent: var(--accent-cyan);">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Pas des captures d’écran</p>
			<h2>Les vraies fenêtres du driver, en direct.</h2>
			<p class="lead">
				Ce que vous voyez ci-dessous n’est pas une maquette : ce sont les
				<strong>fichiers HTML réels</strong> des fenêtres du driver, servis tels quels par ce site et
				pilotés par la page comme le ferait le driver. Un changement de style dans le driver se reflète
				ici instantanément.
			</p>
		</header>

		<div class="win-tabs" role="tablist" aria-label="Fenêtres du driver" use:reveal>
			{#each tabs as t}
				<button
					type="button"
					role="tab"
					aria-selected={activeTab === t.id}
					class:active={activeTab === t.id}
					onclick={() => (activeTab = t.id)}
				>
					{t.label}
				</button>
			{/each}
		</div>

		<p class="win-blurb">{active.blurb}</p>

		<!-- The shell hugs the window's native width so the iframe fills it
		     edge to edge — no leftover gutter, narrow windows stay centered -->
		<div
			class="frame-shell ep-window os-{ui.osStyle}"
			style="max-width: {nativeSize.width}px;"
			use:reveal
		>
			<WindowChrome
				title="/ergopti_plus/_shared/ui/{activeTab}/ · {nativeSize.width}×{nativeSize.height}"
				live={true}
			/>
			<div
				class="frame-wrap"
				style="height: {Math.min(FRAME_DISPLAY_HEIGHT, nativeSize.height)}px;"
			>
				{#key activeTab}
					<iframe
						src="{base}/ergopti_plus/_shared/ui/{activeTab}/index.html"
						title={active.label}
						loading="lazy"
						onload={onFrameLoad}
					></iframe>
				{/key}
			</div>
		</div>

		<div class="win-all" use:reveal>
			<p class="win-all-lead">
				<strong>{webviews.length} fenêtres</strong>, un seul code partagé entre Windows, macOS et
				Linux — liste générée depuis le manifeste du driver :
			</p>
			<ul class="win-chips">
				{#each webviews as w}
					<li
						class="win-chip"
						class:current={w.id === activeTab}
						title="{w.id} · {w.width}×{w.height}"
					>
						{windowNames[w.id] ?? w.id}
					</li>
				{/each}
			</ul>
		</div>
	</div>
</section>

<style>
	.win-tabs {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		justify-content: center;
		margin-bottom: 16px;
	}

	.win-tabs button {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 999px;
		color: var(--ink-faint);
		cursor: pointer;
		font: inherit;
		font-size: 0.88rem;
		font-weight: 600;
		padding: 8px 18px;
		transition:
			background-color 0.25s var(--ease),
			border-color 0.25s var(--ease),
			color 0.25s var(--ease);
	}

	.win-tabs button:hover {
		border-color: var(--border-strong);
		color: var(--ink-soft);
	}

	.win-tabs button.active {
		background: rgba(2, 201, 219, 0.13);
		border-color: rgba(2, 201, 219, 0.45);
		color: var(--ink);
	}

	.win-blurb {
		color: var(--ink-soft);
		font-size: 0.92rem;
		line-height: 1.6;
		margin: 0 auto 20px;
		max-width: 640px;
		text-align: center;
	}

	.frame-shell {
		margin: 0 auto;
		width: 100%;
	}

	.frame-wrap {
		background: #101018;
		overflow: hidden;
		position: relative;
	}

	.frame-wrap iframe {
		border: 0;
		display: block;
		height: 100%;
		width: 100%;
	}

	.win-all {
		margin-top: 26px;
		text-align: center;
	}

	.win-all-lead {
		color: var(--ink-soft);
		font-size: 0.9rem;
		margin: 0 0 12px;
		text-align: center;
	}

	.win-chips {
		display: flex;
		flex-wrap: wrap;
		gap: 7px;
		justify-content: center;
		list-style: none;
	}

	.win-chip {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 999px;
		color: var(--ink-faint);
		font-size: 0.78rem;
		padding: 4px 12px;
	}

	.win-chip.current {
		border-color: rgba(2, 201, 219, 0.45);
		color: var(--ink);
	}

	@media (max-width: 720px) {
		.frame-wrap {
			height: 460px !important;
		}
	}
</style>
