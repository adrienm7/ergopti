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
	import { countup } from './countup.js';
	import { reveal } from './reveal.js';
	import { t } from './i18n.svelte.js';

	/**
	 * @type {{
	 *   locales: Array<{code: string, name: string}>,
	 *   webviews: Array<{id: string, width: number, height: number}>,
	 *   geo: Record<string, {width: number, height: number}>
	 * }}
	 */
	let { locales, webviews, geo } = $props();

	// $derived so every list re-translates the instant the language toggles.
	let settingChips = $derived([
		t('Délais par famille'),
		t('Couleurs des tooltips'),
		t('Touches et actions des tap-holds'),
		t('Raccourcis clavier'),
		t('Apps ignorées'),
		t('Rechargement à chaud'),
		t('Chemins de config'),
		t('Modèle et backend IA'),
		t('Prompts personnalisés'),
		t('Sensibilité des gestes'),
		t('Widget MPM')
	]);

	// Display names for the full native-window list.
	let windowNames = $derived({
		action_picker: t('Sélecteur d’actions'),
		changelog: t('Versions'),
		download_window: t('Téléchargements'),
		healthcheck: t('Diagnostic'),
		hotstring_editor: t('Éditeur de hotstrings'),
		hotstrings_config_window: t('Réglages hotstrings'),
		metrics_apps: t('Temps d’écran'),
		metrics_typing: t('Statistiques de frappe'),
		model_browser: t('Catalogue de modèles'),
		onboarding: t('Assistant de démarrage'),
		paths_editor: t('Dossier de config'),
		personal_info_editor: t('Infos personnelles'),
		prompt_editor: t('Éditeur de prompts'),
		token_prompt: t('Jeton HuggingFace')
	});

	let trust = $derived([
		{
			icon: '🔐',
			color: '#43a047',
			title: t('Tout reste chez vous'),
			body: t(
				'Hotstrings, métriques, prédictions IA : chaque calcul est local. Les serveurs d’inférence n’écoutent que sur votre machine. Une fois le modèle téléchargé, tout fonctionne hors-ligne.'
			)
		},
		{
			icon: '📂',
			color: '#1e88e5',
			title: t('Open-source, auditable'),
			body: t(
				'Trois drivers, un site, plus de 200 000 lignes de code publiées sur GitHub sous licence libre — et plus de 1 300 fichiers de tests automatisés qui les verrouillent.'
			)
		},
		{
			icon: '💸',
			color: '#fb8c00',
			title: t('Gratuit. Pour de bon.'),
			body: t(
				'Pas de freemium, pas de version « Pro », pas de publicité, pas de compte. Le projet est un travail de passion — il est et restera entièrement gratuit.'
			)
		},
		{
			icon: '🚫',
			color: '#8e44ad',
			title: t('Zéro télémétrie'),
			body: t(
				'Aucun appel réseau en dehors du backend IA que vous avez choisi et de la vérification de mise à jour. Pas de « données anonymisées », pas de pistage. Rien.'
			)
		}
	]);
</script>

<section class="custo" id="ep-personnalisation" style="--section-accent: var(--accent-blue);">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">{t('Vous gardez la main')}</p>
			<h2>
				<span use:countup={335}>335</span>
				{t('réglages. Zéro obligation. Zéro code.')}
			</h2>
			<p class="lead">
				{@html t(
					'Nous livrons de bons défauts — touches, délais, couleurs, raccourcis — mais <strong>tout se change depuis le menu</strong>, sans écrire une ligne de code. Le menu est généré depuis un manifeste unique, pour que les trois drivers exposent exactement les mêmes options.'
				)}
			</p>
		</header>

		<ul class="chips" use:reveal>
			{#each settingChips as c}
				<li class="chip">{c}</li>
			{/each}
			<li class="chip chip--more">{t('et 300 autres…')}</li>
		</ul>

		<!-- Comfort band: languages / guest pause -->
		<div class="comfort-grid">
			<article class="ep-card comfort-card comfort-card--wide" use:reveal>
				<h3>{t('🌍 Parle votre langue — {n} au choix', { n: locales.length })}</h3>
				<p>
					{t(
						'Menus, fenêtres, assistants : toute l’interface est traduite. Liste découverte automatiquement depuis les fichiers du driver, dans l’ordre de ses menus :'
					)}
				</p>
				<ul class="lang-chips">
					{#each locales as l}
						<li class="lang-chip" title={l.code} lang={l.code}>
							<span class="lang-flag" aria-hidden="true">{l.flag}</span>{l.name}
						</li>
					{/each}
				</ul>
			</article>

			<article class="ep-card comfort-card" use:reveal={{ delay: 60 }}>
				<h3>{t('⏯ La pause qui rend le PC prêtable')}</h3>
				<p>
					{@html t(
						'Un raccourci met tout en pause : le clavier redevient <strong>AZERTY</strong>, les raccourcis redeviennent ceux de l’OS — passez votre machine à un collègue sans le dérouter. Réactivez : la disposition Ergopti (si émulée), vos hotstrings et vos raccourcis personnalisés reviennent instantanément.'
					)}
				</p>
			</article>

			<article class="ep-card comfort-card" use:reveal={{ delay: 120 }}>
				<h3>{t('🔄 Mise à jour depuis l’app')}</h3>
				<p>
					{@html t(
						'Le driver vérifie les nouvelles versions et se met à jour <strong>depuis le menu</strong> — canal stable ou dev, notes de version intégrées. La fenêtre ci-dessous est la vraie : elle interroge GitHub en direct.'
					)}
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
				{@html t(
					'Le driver ouvre <strong>{n} fenêtres natives</strong> — réglages, éditeurs, assistants, tableaux de bord. Chacune est une vraie fenêtre de votre système (WebView2 sur Windows, WKWebView sur macOS, WebKitGTK sur Linux). Toutes partagent pourtant <strong>un seul et même code</strong> : même apparence, même comportement sur les trois OS. Liste générée depuis le manifeste du driver :',
					{ n: webviews.length }
				)}
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
			{#each trust as item, i}
				<article
					class="ep-card ep-card--hover trust-card"
					style="--accent: {item.color};"
					use:reveal={{ delay: (i % 2) * 90 }}
				>
					<span class="trust-icon" aria-hidden="true">{item.icon}</span>
					<h3>{item.title}</h3>
					<p>{item.body}</p>
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
		max-width: min(760px, 55ch);
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
