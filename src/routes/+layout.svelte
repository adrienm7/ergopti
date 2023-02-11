<script>
	import Header from '../composants/Header.svelte';
	import Footer from '../composants/Footer.svelte';

	import '$lib/css/normalize.css';
	import '$lib/css/global.css';
	import '$lib/css/espacements.css';
	import '$lib/css/typography.css';
	import '$lib/css/buttons.css';
	import '$lib/css/miscellaneous.css';
</script>

<div id="page">
	<Header />

	<main>
		<slot />
	</main>

	<Footer />
</div>

<style>
	/* Permet de toujours placer le footer en bas de la page */

	/* « Je vous conseille fortement d’utiliser un conteneur global, comme ici avec #page, pour réaliser ce genre de mise en page.
 * En effet, définir un contexte flex directement sur <body> comme on peut le voir sur d’autres d’articles peut causer des problèmes avec les plugins
 * qui créent des éléments en bas de page avant </body> (popup, autocomplete, etc.).
 * Ces éléments risquent de ne pas s’afficher correctement, à cause du contexte flex hérité. Just saying. »
 */

	#page {
		--couleur: 80;
		display: flex;
		flex-direction: column;
		margin: 0;
		padding: 0;
		min-height: 100vh;
		background: linear-gradient(
			90deg,
			rgba(0, 0, var(--couleur), 1) 0%,
			rgba(0, 0, calc(var(--couleur) / 1.5), 1) 10%,
			rgba(0, 0, calc(var(--couleur) / 2.25), 1) 20%,
			rgba(0, 0, calc(var(--couleur) / 3), 1) 30%,
			rgba(0, 0, calc(var(--couleur) / 3.5), 1) 40%,
			rgba(0, 0, calc(var(--couleur) / 4), 1) 50%,
			rgba(0, 0, calc(var(--couleur) / 3.5), 1) 60%,
			rgba(0, 0, calc(var(--couleur) / 3), 1) 70%,
			rgba(0, 0, calc(var(--couleur) / 2.25), 1) 80%,
			rgba(0, 0, calc(var(--couleur) / 1.5), 1) 90%,
			rgba(0, 0, var(--couleur), 1) 100%
		);
		color: white;
	}

	@media (max-width: 800px) {
		#page {
			--couleur: 150;
			background: linear-gradient(
				90deg,
				rgba(0, 0, calc(var(--couleur) / 3), 1) 0%,
				rgba(0, 0, calc(var(--couleur) / 4), 1) 50%,
				rgba(0, 0, calc(var(--couleur) / 3), 1) 100%
			);
		}
	}

	main {
		flex-grow: 1;
		padding-top: var(--hauteur-header); /* Pour que le contune soit en-dessous du header */
	}
</style>
