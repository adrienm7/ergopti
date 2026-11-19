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
	import { t } from './i18n.svelte.js';

	// $derived so the cards re-translate the instant the language toggles.
	let promises = $derived([
		{
			icon: '⏱',
			title: t('Utile dès la première heure'),
			body: t(
				'Apostrophes typographiques, accents, expansions classiques : l’essentiel du gain est livré <strong>par défaut</strong>, sans rien apprendre. Vous tapez normalement, le reste se règle tout seul.'
			)
		},
		{
			icon: '🌱',
			title: t('Progressif, jamais imposé'),
			body: t(
				'Chaque fonctionnalité est <strong>activable indépendamment</strong>. Démarrez avec les expansions de texte (hotstrings), ajoutez les touches à double fonction (tap-holds) plus tard, l’IA en bonus. Tout se désactive d’un clic.'
			)
		},
		{
			icon: '🌐',
			title: t('Toutes les dispositions'),
			body: t(
				'AZERTY, QWERTY, Bépo, Dvorak… Le logiciel agit sur le <strong>texte produit</strong>, pas sur la touche physique. Gardez votre disposition — ou adoptez Ergopti pour le combo idéal.'
			)
		}
	]);
</script>

<section class="promises" id="ep-promesses">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">{t('Trois promesses')}</p>
			<h2>{t('Une suite riche, jamais envahissante.')}</h2>
		</header>

		<ul class="promise-grid">
			{#each promises as p, i}
				<li class="promise-item">
					<article class="ep-card ep-card--hover promise-card" use:reveal={{ delay: i * 80 }}>
						<div class="promise-icon" aria-hidden="true">{p.icon}</div>
						<h3>{p.title}</h3>
						<p>{@html p.body}</p>
					</article>
				</li>
			{/each}
		</ul>
	</div>
</section>

<style>
	.promise-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(3, 1fr);
		/* A list of like cards: drop the list look and the prose line height
		   that typography.css gives ul and li. */
		line-height: inherit;
		list-style: none;
	}

	/* The item is a one-cell grid so its card still stretches to the row. */
	.promise-item {
		display: grid;
		line-height: inherit;
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
