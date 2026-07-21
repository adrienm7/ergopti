<!-- src/routes/ergopti-plus/Hotstrings.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Hotstrings Tour
DESCRIPTION:
The core value proposition: the shipped hotstring families with their REAL
entry counts (measured at build time from the driver's TOML files), real
tooltip colors, in-context examples, and the dual-mode magic key.

FEATURES & RATIONALE:
1. Honest Numbers: counts come from +page.server.js parsing the same TOMLs
   the drivers load at boot — adding entries updates the page on deploy.
2. Context Beats Triggers: examples show the word being typed, not just the
   isolated trigger, so visitors see the actual benefit.
==============================================================================
-->

<script>
	import DriverFrame from './DriverFrame.svelte';
	import LiveSession from './LiveSession.svelte';
	import { reveal } from './reveal.js';

	/**
	 * @type {{
	 *   categories: Array<{id: string, label: string, count: number, color: string, delaySec: number}>,
	 *   total: number,
	 *   geo: Record<string, {width: number, height: number}>
	 * }}
	 */
	let { categories, total, geo } = $props();

	// In-context example cards — universal families that work on ANY layout
	// (they operate on the produced text, not the physical key).
	const details = [
		{
			title: 'Autocorrection',
			color: '#43a047',
			tag: 'Les fautes les plus fréquentes, balayées à la frappe',
			lead: 'Apostrophes typographiques, capitalisation des marques, accents oubliés. Ce n’est pas un correcteur après coup : c’est appliqué pendant que vous tapez.',
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
			lead: 'Pour vos snippets fréquents — formules, signatures, identifiants — la touche ★ déclenche l’expansion sans aucune ambiguïté. Aucun risque de collision avec la frappe normale.',
			rows: [
				{ trig: 'ct★', out: 'c’était', words: ['ct★ génial → c’était génial'] },
				{ trig: 'pex★', out: 'par exemple', words: ['pex★ ce matin → par exemple ce matin'] },
				{ trig: 'pcq★', out: 'parce que', words: ['pcq★ il pleut → parce qu’il pleut'] },
				{ trig: 'eef★', out: 'en effet', words: ['eef★, c’est vrai → en effet, c’est vrai'] }
			]
		}
	];

	// The ★ key's two modes, decided from context at fire time.
	const repeaterExamples = [
		{ trig: 'l★', out: 'll', word: 'elle' },
		{ trig: 'r★', out: 'rr', word: 'erreur' },
		{ trig: 't★', out: 'tt', word: 'attendre' },
		{ trig: 'n★', out: 'nn', word: 'année' }
	];

	const triggerExamples = [
		{ trig: 'a★', out: 'ainsi' },
		{ trig: 'c★', out: 'c’est' },
		{ trig: 'dé★', out: 'déjà' },
		{ trig: 'ê★', out: 'être' },
		{ trig: 'm★', out: 'mais' },
		{ trig: 'pê★', out: 'peut-être' }
	];

	/**
	 * Format a count with the French thousands separator.
	 * @param {number} n
	 * @returns {string}
	 */
	function fmt(n) {
		return n.toLocaleString('fr-FR');
	}
</script>

<section class="hotstrings" id="hotstrings" style="--section-accent: #43a047;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Expansions en temps réel</p>
			<h2>{fmt(total)} corrections et expansions, prêtes à l’emploi.</h2>
			<p class="lead">
				Cinq familles livrées avec le driver, chacune avec sa couleur de tooltip et son délai
				réglable. Ce compteur est <strong>mesuré automatiquement</strong> depuis les fichiers du driver
				à chaque mise à jour du site.
			</p>
		</header>

		<!-- Real-sentence typing demo -->
		<LiveSession />

		<!-- Family catalog — one row per REAL category, measured at build -->
		<div class="family-band" use:reveal>
			{#each categories as cat, i}
				<div class="family" style="--accent: {cat.color}; --reveal-delay: {i * 60}ms;">
					<span class="family-dot" aria-hidden="true"></span>
					<span class="family-name">{cat.label}</span>
					<span class="family-count">{fmt(cat.count)}</span>
					<span class="family-delay">{cat.delaySec} s</span>
				</div>
			{/each}
			<p class="family-note">
				Couleurs et délais réels du driver — chaque famille est personnalisable et désactivable
				depuis le menu.
			</p>
		</div>

		<!-- In-context examples -->
		<div class="detail-grid">
			{#each details as cat, i}
				<article
					class="ep-card detail-card"
					style="--accent: {cat.color};"
					use:reveal={{ delay: i * 90 }}
				>
					<header class="detail-head">
						<span class="detail-dot" aria-hidden="true"></span>
						<div>
							<h3>{cat.title}</h3>
							<p class="detail-tag">{cat.tag}</p>
						</div>
					</header>
					<p class="detail-lead">{cat.lead}</p>
					<ul class="detail-rows">
						{#each cat.rows as r}
							<li>
								<div class="detail-trig">
									<span class="hs-key">{r.trig}</span>
									<span class="hs-arrow">→</span>
									<span class="hs-out">{r.out}</span>
								</div>
								<div class="detail-context">
									{#each r.words as w}
										<span class="detail-word">{w}</span>
									{/each}
								</div>
							</li>
						{/each}
					</ul>
				</article>
			{/each}
		</div>

		<!-- Magic key dual behavior -->
		<div class="magic-duo">
			<article class="ep-card magic-card" style="--accent: #e53935;" use:reveal>
				<h3><span class="magic-num">1</span> Répéteur de lettre</h3>
				<p>
					Si aucune abréviation ne correspond, <kbd class="star">★</kbd> double simplement la lettre
					précédente. <strong>Plus aucun SFB sur les doublons.</strong>
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

			<article class="ep-card magic-card" style="--accent: #e53935;" use:reveal={{ delay: 90 }}>
				<h3><span class="magic-num">2</span> Déclencheur d’abréviations</h3>
				<p>
					Si les lettres précédentes forment un trigger connu, <kbd class="star">★</kbd> expanse à la
					place. Les deux modes sont décidés au moment de la frappe — sans configuration.
				</p>
				<ul class="magic-rows magic-rows--compact">
					{#each triggerExamples as r}
						<li>
							<span class="hs-key">{r.trig}</span>
							<span class="hs-arrow">→</span>
							<span class="hs-out">{r.out}</span>
						</li>
					{/each}
				</ul>
			</article>
		</div>

		<!-- The REAL editor window, embedded live -->
		<div class="editor-block">
			<h3 class="editor-title" use:reveal>Et voici la vraie fenêtre d’édition.</h3>
			<p class="editor-lead" use:reveal>
				Pas une capture d’écran : c’est la fenêtre d’édition du driver, servie depuis ses propres
				fichiers et pilotée ici avec des données de démonstration. Sections pliables, recherche,
				ajout en deux champs — chez vous, avec vos raccourcis.
			</p>
			<DriverFrame
				id="hotstring_editor"
				width={geo.hotstring_editor?.width ?? 960}
				height={geo.hotstring_editor?.height ?? 640}
			/>
		</div>
	</div>
</section>

<style>
	/* ─── Family catalog band ───────────────────────────────── */

	.family-band {
		background: linear-gradient(180deg, rgba(255, 255, 255, 0.05), rgba(255, 255, 255, 0.02));
		border: 1px solid var(--border);
		border-radius: var(--radius-lg);
		margin-bottom: clamp(28px, 4vw, 44px);
		overflow: hidden;
		padding: 8px 8px 0;
	}

	.family {
		align-items: center;
		border-radius: var(--radius-sm);
		display: grid;
		gap: 14px;
		grid-template-columns: 12px 1fr auto auto;
		padding: 13px 16px;
		transition: background-color 0.25s var(--ease);
	}

	.family:hover {
		background: color-mix(in srgb, var(--accent) 7%, transparent);
	}

	.family-dot {
		background: var(--accent);
		border-radius: 50%;
		box-shadow: 0 0 12px color-mix(in srgb, var(--accent) 60%, transparent);
		height: 10px;
		width: 10px;
	}

	.family-name {
		font-size: 0.98rem;
		font-weight: 600;
	}

	.family-count {
		color: var(--accent);
		font-size: 1.05rem;
		font-variant-numeric: tabular-nums;
		font-weight: 800;
	}

	.family-delay {
		color: var(--ink-faint);
		font-size: 0.8rem;
		font-variant-numeric: tabular-nums;
		min-width: 42px;
		text-align: right;
	}

	.family-note {
		border-top: 1px solid var(--border);
		color: var(--ink-faint);
		font-size: 0.82rem;
		margin: 4px 0 0;
		padding: 12px 16px;
		text-align: center;
	}

	/* ─── Detail cards ──────────────────────────────────────── */

	.detail-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(2, 1fr);
		margin-bottom: clamp(28px, 4vw, 44px);
	}

	.detail-head {
		align-items: flex-start;
		display: flex;
		gap: 12px;
		margin-bottom: 12px;
	}

	.detail-dot {
		background: var(--accent);
		border-radius: 50%;
		box-shadow: 0 0 14px color-mix(in srgb, var(--accent) 65%, transparent);
		flex-shrink: 0;
		height: 11px;
		margin-top: 6px;
		width: 11px;
	}

	.detail-tag {
		color: var(--ink-faint);
		font-size: 0.85rem;
		margin: 2px 0 0;
	}

	.detail-lead {
		color: var(--ink-soft);
		font-size: 0.92rem;
		line-height: 1.6;
		margin: 0 0 16px;
	}

	.detail-rows {
		display: flex;
		flex-direction: column;
		gap: 10px;
		list-style: none;
	}

	.detail-rows li {
		align-items: baseline;
		display: flex;
		flex-wrap: wrap;
		gap: 8px 14px;
	}

	.detail-trig {
		align-items: baseline;
		display: inline-flex;
		flex-shrink: 0;
		gap: 8px;
		min-width: 150px;
	}

	.detail-context {
		display: inline-flex;
		flex-wrap: wrap;
		gap: 6px;
	}

	.detail-word {
		background: rgba(255, 255, 255, 0.05);
		border-radius: 6px;
		color: var(--ink-faint);
		font-size: 0.82rem;
		padding: 2px 8px;
	}

	/* ─── Magic key duo ─────────────────────────────────────── */

	.magic-duo {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(2, 1fr);
	}

	.magic-card h3 {
		align-items: center;
		display: flex;
		gap: 10px;
	}

	.magic-num {
		align-items: center;
		background: color-mix(in srgb, var(--accent) 18%, transparent);
		border: 1px solid color-mix(in srgb, var(--accent) 40%, transparent);
		border-radius: 50%;
		color: color-mix(in srgb, var(--accent) 65%, #fff);
		display: inline-flex;
		flex-shrink: 0;
		font-size: 0.8rem;
		font-weight: 800;
		height: 26px;
		justify-content: center;
		width: 26px;
	}

	.magic-card > p {
		margin-bottom: 14px;
	}

	kbd.star {
		background: linear-gradient(135deg, #e53935, #ff7043);
		border-color: rgba(255, 255, 255, 0.3);
		color: #fff;
		text-shadow: 0 0 8px rgba(255, 255, 255, 0.6);
	}

	.magic-rows {
		display: flex;
		flex-direction: column;
		gap: 9px;
		list-style: none;
	}

	.magic-rows li {
		align-items: baseline;
		display: flex;
		gap: 10px;
	}

	.magic-rows--compact {
		display: grid;
		gap: 9px 18px;
		grid-template-columns: repeat(2, 1fr);
	}

	@media (max-width: 880px) {
		.detail-grid,
		.magic-duo {
			grid-template-columns: 1fr;
		}

		.magic-rows--compact {
			grid-template-columns: 1fr;
		}
	}

	@media (max-width: 520px) {
		.family {
			gap: 10px;
			grid-template-columns: 10px 1fr auto;
		}

		.family-delay {
			display: none;
		}
	}

	/* ─── Embedded editor window ────────────────────────────── */

	.editor-block {
		margin-top: clamp(28px, 4vw, 44px);
	}

	.editor-title {
		font-size: 1.25rem;
		font-weight: 700;
		margin-bottom: 8px;
		text-align: center;
	}

	.editor-lead {
		color: var(--ink-soft);
		font-size: 0.92rem;
		line-height: 1.6;
		margin: 0 auto 20px;
		max-width: 640px;
		text-align: center;
	}
</style>
