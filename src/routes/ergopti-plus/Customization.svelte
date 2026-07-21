<!-- src/routes/ergopti-plus/Customization.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Customization & Trust
DESCRIPTION:
Two arguments that close the deal: everything is configurable (335 toggles
measured from the shared feature manifest) and everything is private (local,
open-source, free, telemetry-free).

FEATURES & RATIONALE:
1. Merged Section: the old page said "everything is configurable" three
   times across three sections; one strong statement converts better.
==============================================================================
-->

<script>
	import { reveal } from './reveal.js';

	const settingChips = [
		'Délais par famille',
		'Couleurs des tooltips',
		'Apps ignorées',
		'Pause globale',
		'Rechargement à chaud',
		'Chemins de config',
		'Modèle et backend IA',
		'Prompts personnalisés',
		'Sensibilité des gestes',
		'Délais des tap-holds',
		'Raccourcis clavier',
		'Widget WPM'
	];

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
			<h2>335 réglages. Zéro obligation.</h2>
			<p class="lead">
				Chaque fonctionnalité de cette page est <strong>activable indépendamment</strong> depuis le menu
				— généré automatiquement depuis un manifeste unique, pour que les trois drivers exposent exactement
				les mêmes options. Une case ne vous convient pas ? Décochez-la.
			</p>
		</header>

		<ul class="chips" use:reveal>
			{#each settingChips as c}
				<li class="chip">{c}</li>
			{/each}
			<li class="chip chip--more">et 300 autres…</li>
		</ul>

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
		.trust-grid {
			grid-template-columns: 1fr;
		}
	}
</style>
