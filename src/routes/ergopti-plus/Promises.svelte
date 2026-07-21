<!-- src/routes/ergopti-plus/Promises.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Three Promises
DESCRIPTION:
Reassurance section placed right after the hero to defuse the fear of
complexity: instant value, progressive adoption, works on every layout.

FEATURES & RATIONALE:
1. Benefit Phrasing: each card is written from the user's point of view
   ("you gain X"), not as a feature list.
==============================================================================
-->

<script>
	import { reveal } from './reveal.js';

	const promises = [
		{
			icon: '⏱',
			title: 'Utile dès la première heure',
			body: 'Apostrophes typographiques, accents, expansions classiques : l’essentiel du gain est livré <strong>par défaut</strong>, sans rien apprendre. Vous tapez normalement, le reste se règle tout seul.'
		},
		{
			icon: '🌱',
			title: 'Progressif, jamais imposé',
			body: 'Chaque fonctionnalité est <strong>activable indépendamment</strong>. Démarrez avec les hotstrings, ajoutez les tap-holds plus tard, l’IA en bonus. Tout se désactive d’un clic.'
		},
		{
			icon: '🌐',
			title: 'Toutes les dispositions',
			body: 'AZERTY, QWERTY, Bépo, Dvorak… Le driver agit sur le <strong>texte produit</strong>, pas sur la touche physique. Gardez votre layout — ou adoptez Ergopti pour le combo idéal.'
		}
	];
</script>

<section class="promises" id="ep-promesses">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Trois promesses</p>
			<h2>Une suite riche, jamais envahissante.</h2>
		</header>

		<div class="promise-grid">
			{#each promises as p, i}
				<article class="ep-card ep-card--hover promise-card" use:reveal={{ delay: i * 80 }}>
					<div class="promise-icon" aria-hidden="true">{p.icon}</div>
					<h3>{p.title}</h3>
					<p>{@html p.body}</p>
				</article>
			{/each}
		</div>
	</div>
</section>

<style>
	.promise-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(3, 1fr);
	}

	.promise-card {
		text-align: left;
	}

	.promise-icon {
		align-items: center;
		background: rgba(49, 190, 255, 0.1);
		border: 1px solid rgba(49, 190, 255, 0.22);
		border-radius: var(--radius-sm);
		display: inline-flex;
		font-size: 1.25rem;
		height: 44px;
		justify-content: center;
		margin-bottom: 14px;
		width: 44px;
	}

	@media (max-width: 880px) {
		.promise-grid {
			grid-template-columns: 1fr;
		}
	}
</style>
