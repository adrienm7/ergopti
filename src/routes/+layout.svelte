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
		display: flex;
		flex-direction: column;
		margin: 0;
		padding: 0;
		min-height: 100vh;
		background: linear-gradient(
			90deg,
			rgba(0, 2, 12, 1) 0%,
			rgba(0, 3, 38, 1) 50%,
			rgba(0, 0, 0, 1) 100%
		);
		color: white;
	}

	main {
		flex-grow: 1;
		padding-top: var(--hauteur-header); /* Pour que le contune soit en-dessous du header */
	}

</style>
