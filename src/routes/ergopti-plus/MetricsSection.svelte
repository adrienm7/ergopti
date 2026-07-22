<!-- src/routes/ergopti-plus/MetricsSection.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Typing Metrics & App Stats
DESCRIPTION:
Dedicated showcase of the analytics pipeline: the live WPM widget, the
typing-metrics dashboard (WPM over time, hotstring/AI delegation, n-grams,
keyboard heatmaps) and the screen-time dashboard — all computed locally
into SQLite.

FEATURES & RATIONALE:
1. "You only improve what you measure" is the section's thesis: the
   dashboards exist to make progress visible, not to collect data.
2. The preview cards are hand-drawn (deterministic sparklines) and clearly
   captioned as a preview — the real dashboards ship as driver windows.
==============================================================================
-->

<script>
	import DriverFrame from './DriverFrame.svelte';
	import LiveWpm from './LiveWpm.svelte';
	import { reveal } from './reveal.js';

	/** @type {{geo: Record<string, {width: number, height: number}>}} */
	let { geo } = $props();

	// The two real dashboard windows, switchable.
	const dashboards = [
		{ id: 'metrics_typing', label: 'Statistiques de frappe' },
		{ id: 'metrics_apps', label: 'Temps d’écran' }
	];
	let activeDashboard = $state('metrics_typing');

	// Deterministic upward-trending sparkline points (no Math.random — the
	// page is prerendered and the shape should read as steady progress).
	const wpmSpark = [38, 42, 41, 47, 52, 50, 57, 61, 60, 66, 71, 74];
	const delegSpark = [4, 6, 9, 8, 12, 15, 14, 19, 22, 26, 25, 31];

	/**
	 * Build an SVG polyline points string from values.
	 * @param {number[]} values
	 * @returns {string}
	 */
	function sparkPoints(values) {
		const min = Math.min(...values);
		const max = Math.max(...values);
		const span = max - min || 1;
		return values
			.map((v, i) => `${(i / (values.length - 1)) * 100},${30 - ((v - min) / span) * 26}`)
			.join(' ');
	}

	// 26-week activity calendar, deterministic intensity pattern.
	const calendar = Array.from({ length: 26 * 7 }, (_, i) => (i * 7 + (i % 13)) % 5);

	const capabilities = [
		{
			title: 'Évolution des MPM',
			body: 'Votre vitesse jour après jour, semaine après semaine — avec les records et les moyennes glissantes.'
		},
		{
			title: 'Impact des hotstrings et de l’IA',
			body: 'Les caractères « + Hotstrings » et « + IA » sont comptés à part : vous voyez exactement combien de frappe vous déléguez.'
		},
		{
			title: 'N-grammes — 19 onglets',
			body: 'Des caractères aux heptagrammes, mots et raccourcis les plus tapés : la matière première pour créer vos prochains hotstrings.'
		},
		{
			title: 'Heatmaps clavier',
			body: 'Deux cartes de chaleur montrent quelles touches travaillent le plus — et valident (ou non) votre disposition.'
		},
		{
			title: 'Ergonomie mesurée',
			body: 'SFBs, roulements, redirections : les métriques des passionnés de layouts, calculées sur VOTRE frappe réelle.'
		},
		{
			title: 'Temps d’écran par app',
			body: 'Temps par application, bascules entre apps, séries et scores de productivité — dans un second tableau de bord dédié.'
		}
	];
</script>

<section class="metrics" id="ep-metriques" style="--section-accent: #00bfa5;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Métriques de frappe</p>
			<h2>On n’améliore que ce que l’on mesure.</h2>
			<p class="lead">
				Un enregistreur local compte vos frappes, mots et expansions dans une base
				<strong>SQLite sur votre machine</strong> — rien ne part jamais ailleurs. Deux tableaux de bord
				complets et un widget flottant en font un vrai coach de frappe.
			</p>
		</header>

		<!-- Hand-drawn dashboard preview -->
		<div class="preview" use:reveal>
			<div class="preview-card">
				<div class="preview-label">Vitesse moyenne</div>
				<div class="preview-value">74 <span class="preview-unit">MPM</span></div>
				<svg class="spark" viewBox="0 0 100 32" preserveAspectRatio="none" aria-hidden="true">
					<polyline points={sparkPoints(wpmSpark)} />
				</svg>
				<div class="preview-delta">+9 % ce mois-ci</div>
			</div>

			<div class="preview-card">
				<div class="preview-label">Frappe déléguée</div>
				<div class="preview-value">31 <span class="preview-unit">%</span></div>
				<svg
					class="spark spark--pink"
					viewBox="0 0 100 32"
					preserveAspectRatio="none"
					aria-hidden="true"
				>
					<polyline points={sparkPoints(delegSpark)} />
				</svg>
				<div class="preview-delta">+ Hotstrings · + IA</div>
			</div>

			<div class="preview-card preview-card--calendar">
				<div class="preview-label">Activité — 26 semaines</div>
				<div class="calendar" aria-hidden="true">
					{#each calendar as level}
						<span class="cell" data-level={level}></span>
					{/each}
				</div>
			</div>
		</div>
		<p class="preview-note" use:reveal>
			Aperçu illustratif — les vrais tableaux de bord (<em>Statistiques de frappe</em> et
			<em>Temps d’écran</em>) sont deux fenêtres du driver, avec vos données réelles.
		</p>

		<div class="cap-grid">
			{#each capabilities as c, i}
				<article
					class="ep-card ep-card--hover cap-card"
					style="--accent: #00bfa5;"
					use:reveal={{ delay: (i % 3) * 70 }}
				>
					<h3>{c.title}</h3>
					<p>{c.body}</p>
				</article>
			{/each}
		</div>

		<!-- The two REAL dashboard windows -->
		<div class="dash-block">
			<h3 class="dash-title" use:reveal>Les vraies fenêtres, servies depuis le driver.</h3>
			<div class="dash-tabs" role="tablist" aria-label="Tableaux de bord" use:reveal>
				{#each dashboards as d}
					<button
						type="button"
						role="tab"
						aria-selected={activeDashboard === d.id}
						class:active={activeDashboard === d.id}
						onclick={() => (activeDashboard = d.id)}
					>
						{d.label}
					</button>
				{/each}
			</div>
			{#key activeDashboard}
				<DriverFrame
					id={activeDashboard}
					width={geo[activeDashboard]?.width ?? 1020}
					height={geo[activeDashboard]?.height ?? 680}
				/>
			{/key}
			<p class="dash-note" use:reveal>
				Données de démonstration générées pour l’aperçu — chez vous, ces tableaux de bord se
				remplissent de VOTRE frappe, et rien ne quitte jamais votre machine.
			</p>
		</div>

		<div class="widget-live ep-card" use:reveal>
			<header class="widget-live-head">
				<h3>Le widget MPM, toujours sous les yeux</h3>
				<p>
					Un petit compteur flottant, toujours au premier plan, affiche votre vitesse en temps réel.
					Regardez-le <strong>bondir</strong> quand une hotstring ou l’IA tape à votre place — c’est
					toute la frappe déléguée qui devient visible :
				</p>
			</header>
			<LiveWpm />
		</div>

		<p class="metrics-privacy" use:reveal>
			🔐 Tout est calculé et stocké <strong>localement</strong>. Les champs de mot de passe sont
			ignorés, le module entier se désactive d’un clic, et la base SQLite vous appartient.
		</p>
	</div>
</section>

<style>
	.preview {
		display: grid;
		gap: 14px;
		grid-template-columns: 1fr 1fr 1.6fr;
		margin-bottom: 10px;
	}

	.preview-card {
		background: linear-gradient(180deg, rgba(255, 255, 255, 0.055), rgba(255, 255, 255, 0.025));
		border: 1px solid var(--border);
		border-radius: var(--radius);
		padding: 18px 20px;
	}

	.preview-label {
		color: var(--ink-faint);
		font-size: 0.78rem;
		font-weight: 600;
		letter-spacing: 0.04em;
		margin-bottom: 6px;
		text-transform: uppercase;
	}

	.preview-value {
		font-size: 2rem;
		font-variant-numeric: tabular-nums;
		font-weight: 800;
	}

	.preview-unit {
		color: var(--ink-faint);
		font-size: 1rem;
		font-weight: 600;
	}

	.spark {
		display: block;
		height: 34px;
		margin-top: 8px;
		width: 100%;
	}

	.spark polyline {
		fill: none;
		stroke: #00bfa5;
		stroke-linecap: round;
		stroke-linejoin: round;
		stroke-width: 2;
		vector-effect: non-scaling-stroke;
	}

	.spark--pink polyline {
		stroke: var(--family-ia);
	}

	.preview-delta {
		color: var(--ink-faint);
		font-size: 0.78rem;
		margin-top: 6px;
	}

	/* ─── Activity calendar ─────────────────────────────────── */

	.calendar {
		display: grid;
		gap: 3px;
		grid-auto-flow: column;
		grid-template-rows: repeat(7, 1fr);
		margin-top: 10px;
	}

	.cell {
		aspect-ratio: 1;
		background: rgba(255, 255, 255, 0.06);
		border-radius: 2px;
	}

	.cell[data-level='1'] {
		background: rgba(0, 191, 165, 0.25);
	}
	.cell[data-level='2'] {
		background: rgba(0, 191, 165, 0.45);
	}
	.cell[data-level='3'] {
		background: rgba(0, 191, 165, 0.65);
	}
	.cell[data-level='4'] {
		background: rgba(0, 191, 165, 0.9);
	}

	.preview-note {
		color: var(--ink-faint);
		font-size: 0.8rem;
		margin: 0 0 26px;
		text-align: center;
	}

	/* ─── Capabilities ──────────────────────────────────────── */

	.cap-grid {
		display: grid;
		gap: 14px;
		grid-template-columns: repeat(3, 1fr);
		margin-bottom: 26px;
	}

	/* ─── Real dashboards ───────────────────────────────────── */

	.dash-block {
		margin-bottom: 26px;
	}

	.dash-title {
		font-size: 1.25rem;
		font-weight: 700;
		margin-bottom: 14px;
		text-align: center;
	}

	.dash-tabs {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 999px;
		display: flex;
		gap: 2px;
		margin: 0 auto 18px;
		padding: 4px;
		width: fit-content;
	}

	.dash-tabs button {
		background: transparent;
		border: 0;
		border-radius: 999px;
		color: var(--ink-faint);
		cursor: pointer;
		font: inherit;
		font-size: 0.85rem;
		font-weight: 600;
		padding: 7px 16px;
		transition:
			background-color 0.25s var(--ease),
			color 0.25s var(--ease);
	}

	.dash-tabs button:hover {
		color: var(--ink-soft);
	}

	.dash-tabs button.active {
		background: rgba(0, 191, 165, 0.15);
		color: var(--ink);
	}

	.dash-note {
		color: var(--ink-faint);
		font-size: 0.82rem;
		margin: 14px auto 0;
		max-width: 560px;
		text-align: center;
	}

	/* ─── Live WPM widget ───────────────────────────────────── */

	.widget-live {
		--accent: #00bfa5;
		margin: 0 auto;
		max-width: 760px;
	}

	.widget-live-head {
		margin-bottom: 18px;
		text-align: center;
	}

	.widget-live-head h3 {
		font-size: 1.15rem;
		margin-bottom: 8px;
	}

	.widget-live-head p {
		color: var(--ink-soft);
		font-size: 0.92rem;
		line-height: 1.6;
		margin: 0 auto;
		max-width: 620px;
	}

	.metrics-privacy {
		color: var(--ink-soft);
		font-size: 0.9rem;
		margin: 22px auto 0;
		max-width: 640px;
		text-align: center;
	}

	@media (max-width: 880px) {
		.preview {
			grid-template-columns: 1fr 1fr;
		}

		.preview-card--calendar {
			grid-column: span 2;
		}

		.cap-grid {
			grid-template-columns: 1fr;
		}
	}
</style>
