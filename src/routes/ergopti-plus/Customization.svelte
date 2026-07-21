<!-- src/routes/ergopti-plus/Customization.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Customization, Comfort & Trust
DESCRIPTION:
Everything is configurable (335 toggles from the shared manifest), the app
speaks the visitor's language (locale chips discovered at build time),
updates itself from the menu (real changelog window embedded), pauses
politely for guests, and respects privacy end to end.

FEATURES & RATIONALE:
1. Automated Language List: the chips come from scanning the driver's
   locales directory at build — adding a locale updates the page alone.
2. Real Update Window: the changelog webview is embedded live next to the
   updater pitch; it queries GitHub releases itself.
==============================================================================
-->

<script>
	import DriverFrame from './DriverFrame.svelte';
	import { reveal } from './reveal.js';

	/**
	 * @type {{
	 *   locales: Array<{code: string, name: string}>,
	 *   webviews: Array<{id: string, width: number, height: number}>,
	 *   geo: Record<string, {width: number, height: number}>
	 * }}
	 */
	let { locales, webviews, geo } = $props();

	const settingChips = [
		'Délais par famille',
		'Couleurs des tooltips',
		'Touches et actions des tap-holds',
		'Raccourcis clavier',
		'Apps ignorées',
		'Rechargement à chaud',
		'Chemins de config',
		'Modèle et backend IA',
		'Prompts personnalisés',
		'Sensibilité des gestes',
		'Widget MPM'
	];

	// French display names for the full native-window list.
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

	const trust = [
		{
			icon: '🔐',
			color: '#43a047',
			title: 'Tout reste chez vous',
			body: 'Hotstrings, métriques, prédictions IA : chaque calcul est local. Les serveurs d’inférence n’écoutent que sur votre machine. Une fois le modèle téléchargé, tout fonctionne hors-ligne.'
		},
		{
			icon: '📂',
			color: '#1e88e5',
			title: 'Open-source, auditable',
			body: 'Trois drivers, un site, plus de 200 000 lignes de code publiées sur GitHub sous licence libre — et plus de 1 300 fichiers de tests automatisés qui les verrouillent.'
		},
		{
			icon: '💸',
			color: '#fb8c00',
			title: 'Gratuit. Pour de bon.',
			body: 'Pas de freemium, pas de version « Pro », pas de publicité, pas de compte. Le projet est un travail de passion — il est et restera entièrement gratuit.'
		},
		{
			icon: '🚫',
			color: '#8e44ad',
			title: 'Zéro télémétrie',
			body: 'Aucun appel réseau en dehors du backend IA que vous avez choisi et de la vérification de mise à jour. Pas de « données anonymisées », pas de tracking. Rien.'
		}
	];
</script>

<section class="custo" id="personnalisation" style="--section-accent: var(--accent-blue);">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Vous gardez la main</p>
			<h2>335 réglages. Zéro obligation. Zéro code.</h2>
			<p class="lead">
				Nous livrons de bons défauts — touches, délais, couleurs, raccourcis — mais
				<strong>tout se change depuis le menu</strong>, sans écrire une ligne de code. Le menu est
				généré depuis un manifeste unique, pour que les trois drivers exposent exactement les mêmes
				options.
			</p>
		</header>

		<ul class="chips" use:reveal>
			{#each settingChips as c}
				<li class="chip">{c}</li>
			{/each}
			<li class="chip chip--more">et 300 autres…</li>
		</ul>

		<!-- Comfort band: languages / guest pause -->
		<div class="comfort-grid">
			<article class="ep-card comfort-card comfort-card--wide" use:reveal>
				<h3>🌍 Parle votre langue — {locales.length} au choix</h3>
				<p>
					Menus, fenêtres, assistants : toute l’interface est traduite. Liste découverte
					automatiquement depuis les fichiers du driver, dans l’ordre de ses menus :
				</p>
				<ul class="lang-chips">
					{#each locales as l}
						<li class="lang-chip" title={l.code}>
							<span class="lang-flag" aria-hidden="true">{l.flag}</span>{l.name}
						</li>
					{/each}
				</ul>
			</article>

			<article class="ep-card comfort-card" use:reveal={{ delay: 60 }}>
				<h3>⏯ La pause qui rend le PC prêtable</h3>
				<p>
					Un raccourci met tout en pause : le clavier redevient <strong>AZERTY</strong>, les
					raccourcis redeviennent ceux de l’OS — passez votre machine à un collègue sans le
					dérouter. Réactivez : la disposition Ergopti (si émulée), vos hotstrings et vos raccourcis
					personnalisés reviennent instantanément.
				</p>
			</article>

			<article class="ep-card comfort-card" use:reveal={{ delay: 120 }}>
				<h3>🔄 Mise à jour depuis l’app</h3>
				<p>
					Le driver vérifie les nouvelles versions et se met à jour <strong>depuis le menu</strong>
					— canal stable ou dev, notes de version intégrées. La fenêtre ci-dessous est la vraie : elle
					interroge GitHub en direct.
				</p>
			</article>
		</div>

		<!-- Real changelog window, live from GitHub -->
		<div class="changelog-embed">
			<DriverFrame
				id="changelog"
				width={geo.changelog?.width ?? 860}
				height={geo.changelog?.height ?? 580}
				displayHeight={520}
			/>
		</div>

		<!-- Native windows strip -->
		<div class="win-all" use:reveal>
			<p class="win-all-lead">
				Le driver ouvre <strong>{webviews.length} fenêtres natives</strong> — réglages, éditeurs,
				assistants, tableaux de bord. Chacune est une vraie fenêtre de votre système (WebView2 sur
				Windows, WKWebView sur macOS, WebKitGTK sur Linux), mais toutes partagent
				<strong>un seul et même code</strong> : même apparence, même comportement sur les trois OS. Liste
				générée depuis le manifeste du driver :
			</p>
			<ul class="win-chips">
				{#each webviews as w}
					<li class="win-chip" title="{w.id} · {w.width}×{w.height}">
						{windowNames[w.id] ?? w.id}
					</li>
				{/each}
			</ul>
		</div>

		<div class="trust-grid">
			{#each trust as t, i}
				<article
					class="ep-card ep-card--hover trust-card"
					style="--accent: {t.color};"
					use:reveal={{ delay: (i % 2) * 90 }}
				>
					<span class="trust-icon" aria-hidden="true">{t.icon}</span>
					<h3>{t.title}</h3>
					<p>{t.body}</p>
				</article>
			{/each}
		</div>
	</div>
</section>

<style>
	.chips {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
		justify-content: center;
		list-style: none;
		margin: 0 auto clamp(30px, 4.5vw, 48px);
		max-width: 820px;
	}

	.chip {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 999px;
		color: var(--ink-soft);
		font-size: 0.83rem;
		font-weight: 600;
		padding: 6px 14px;
	}

	.chip--more {
		border-style: dashed;
		color: var(--ink-faint);
	}

	/* ─── Comfort band ──────────────────────────────────────── */

	.comfort-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(2, 1fr);
		margin-bottom: 18px;
	}

	.comfort-card h3 {
		margin-bottom: 10px;
	}

	.comfort-card--wide {
		grid-column: 1 / -1;
	}

	.lang-chips {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		list-style: none;
		margin-top: 14px;
	}

	.lang-chip {
		background: rgba(49, 190, 255, 0.08);
		border: 1px solid rgba(49, 190, 255, 0.22);
		border-radius: 999px;
		color: var(--ink-soft);
		font-size: 0.78rem;
		font-weight: 600;
		padding: 3px 10px;
	}

	.lang-flag {
		margin-right: 5px;
	}

	.changelog-embed {
		margin-bottom: clamp(30px, 4.5vw, 48px);
	}

	/* ─── Native windows strip ──────────────────────────────── */

	.win-all {
		margin-bottom: clamp(30px, 4.5vw, 48px);
		text-align: center;
	}

	.win-all-lead {
		color: var(--ink-soft);
		font-size: 0.9rem;
		line-height: 1.65;
		margin: 0 auto 12px;
		max-width: 760px;
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

	/* ─── Trust ─────────────────────────────────────────────── */

	.trust-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(2, 1fr);
	}

	.trust-icon {
		display: inline-block;
		font-size: 1.5rem;
		margin-bottom: 10px;
	}

	@media (max-width: 880px) {
		.comfort-grid,
		.trust-grid {
			grid-template-columns: 1fr;
		}
	}
</style>
