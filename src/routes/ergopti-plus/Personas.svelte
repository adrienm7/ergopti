<!-- src/routes/ergopti-plus/Personas.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Use Cases / Personas
DESCRIPTION:
Makes the abstract feature list concrete by showing who benefits and how.
Placed early so a visitor recognises themselves before diving into details.
==============================================================================
-->

<script>
	import { reveal } from './reveal.js';

	const personas = [
		{
			icon: '💻',
			who: 'Développeur',
			body: 'Symboles de code en roulements (<code>=></code>, <code>!=</code>), snippets de boilerplate, ouverture de chemins de fichiers, et une IA locale qui complète sans jamais envoyer votre code ailleurs.'
		},
		{
			icon: '✍️',
			who: 'Rédacteur',
			body: 'Autocorrection en continu, signatures et formules en une abréviation, apostrophes typographiques automatiques, et des prédictions qui terminent vos phrases.'
		},
		{
			icon: '🌍',
			who: 'Multilingue',
			body: 'FR/EN et bien plus : corrections et prédictions bilingues, symboles et accents à portée de doigt, interface en 21 langues.'
		},
		{
			icon: '🖐️',
			who: 'Ergonomie & confort',
			body: 'Tap-holds pour garder les mains au repos, layer de navigation sans flèches, gestes trackpad, et des métriques pour voir vos progrès.'
		}
	];
</script>

<section class="personas" id="ep-pourqui" style="--section-accent: #a78bfa;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Pour qui ?</p>
			<h2>Chacun y gagne, à sa façon.</h2>
			<p class="lead">
				Ergopti+ n’impose pas une manière de travailler — il accélère la vôtre. Quelques exemples.
			</p>
		</header>

		<div class="personas-grid">
			{#each personas as p, i}
				<article class="ep-card ep-card--hover persona-card" use:reveal={{ delay: (i % 2) * 80 }}>
					<span class="persona-ico" aria-hidden="true">{p.icon}</span>
					<div class="persona-text">
						<h3>{p.who}</h3>
						<p>{@html p.body}</p>
					</div>
				</article>
			{/each}
		</div>
	</div>
</section>

<style>
	.personas-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(2, 1fr);
	}

	.persona-card {
		--accent: #a78bfa;
		align-items: flex-start;
		display: flex;
		gap: 16px;
	}

	.persona-ico {
		flex-shrink: 0;
		font-size: 1.8rem;
		line-height: 1.1;
	}

	.persona-text :global(code) {
		background: rgba(255, 255, 255, 0.08);
		border-radius: 4px;
		font-size: 0.85em;
		padding: 1px 5px;
	}

	@media (max-width: 720px) {
		.personas-grid {
			grid-template-columns: 1fr;
		}
	}
</style>
