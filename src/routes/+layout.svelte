<script>
	import Header from '$lib/composants/Header.svelte';
	import Footer from '$lib/composants/Footer.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import BlocControlesClavier from '$lib/clavier/BlocControlesClavier.svelte';

	import { afterUpdate, beforeUpdate, onDestroy, onMount } from 'svelte';
	import { navigating } from '$app/stores';
	import AOS from 'aos';
	import { typography } from '$lib/js/typography.js';
	import { matomo } from '$lib/js/code-matomo';

	import '$lib/css/normalize.css';
	import '$lib/css/global.css';
	import '$lib/css/espacements.css';
	import '$lib/css/titres.css';
	import '$lib/css/typographie.css';
	import '$lib/css/hypertexte.css';
	import '$lib/css/images.css';
	import '$lib/css/boutons.css';
	import '$lib/css/aos.css';

	import '$lib/icons/fontawesome/css/fontawesome.min.css';
	import '$lib/icons/fontawesome/css/regular.min.css';
	import '$lib/icons/fontawesome/css/duotone.min.css';
	import { log } from 'console';

	$: if($navigating) matomo();

	afterUpdate(() => {
		AOS.init();
		typography(document.getElementById('page'));
	});

	let zIndex = -999;
	let affiche = 'none';

	function toggleZIndex() {
		zIndex = zIndex === -999 ? 80 : -999;
		affiche = affiche === 'none' ? 'block' : 'none';
		// document.getElementById('menu-btn').checked = false; /* Si le menu était ouvert, on le ferme */
	}
</script>

<!-- <div class="banner">
	<p>En construction</p>
</div> -->

<button id="afficher-clavier-reference" on:click={toggleZIndex}>
	<i class="fad fa-keyboard" style="display:{affiche === 'none' ? 'block' : 'none'}"></i>
	<i class="fad fa-times" style="display:{affiche}"></i>
</button>

<div id="clavier-ref" class="bg-blue" style="z-index: {zIndex}; display:{affiche}">
	<div>
		<BlocClavier nom="reference" />
		<mini-espace />
		<BlocControlesClavier nom="reference" />
	</div>
</div>

<div id="page" class="bg-blue">
	<Header />

	<main>
		<slot />
	</main>

	<Footer />
</div>

<style>
	#afficher-clavier-reference {
		position: fixed;
		z-index: 99;
		bottom: 1rem;
		right: 1rem;
		padding: 0.5rem;
		margin: 0 auto;
		height: 3rem;
		width: 3rem;
		background-color: rgba(0, 1, 14, 0.9);
		cursor: pointer;
		border: 1px solid rgba(0, 0, 0, 0.5);
		border-radius: 5px;
		font-size: 1.5rem;
		box-shadow: 0px 0px 7px 3px #0087b4b1;
		animation: glowing 3s infinite alternate ease-in-out;
	}

	@keyframes glowing {
		0% {
			box-shadow: 0px 0px 1px 1px #0087b4b1;
		}
		70% {
			box-shadow: 0px 0px 1px 1px #0087b4b1;
		}
		100% {
			box-shadow: 0px 0px 20px 7px #0087b4b1;
		}
	}

	#afficher-clavier-reference i {
		color: #3088ed;
	}
	#afficher-clavier-reference i::before {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: linear-gradient(to right, var(--gradient-blue));
	}
	.banner {
		display: flex;
		align-items: center;
		justify-content: center;
		position: fixed;
		bottom: 6vw;
		right: -41vw;
		z-index: 90;
		width: 100vw;
		height: 3.5rem;
		background-color: #a40606;
		background-image: linear-gradient(0, #c80000 0%, #ff6f00 100%);
		transform: rotate(315deg);
		text-align: center;
		margin: 0 auto;
		border: 2px solid white;
		box-shadow:
			rgba(0, 0, 0, 0.6) 0px -2px 4px,
			rgba(0, 0, 0, 0.7) 0px 3px 8px;
	}

	@media (max-width: 700px) {
		.banner {
			display: none;
		}
	}

	.banner p {
		text-transform: uppercase;
		color: white;
		font-size: clamp(10px, 1.7vw, 18px);
		font-weight: bold;
		text-align: center;
		line-height: 1;
	}

	#clavier-ref {
		--couleur: 60;
		position: fixed;
		bottom: 0;
		left: 0;
		width: 100vw;
		height: 100vh;
		padding-top: var(--hauteur-header);
		overflow: scroll;
		transition: all 0.2s ease-in-out;
		overscroll-behavior: contain; /* Pour désactiver le scroll derrière le menu */
	}

	#clavier-ref div {
		/* Permet d’avoir une div qui ne scrolle pas ce qui est dessous */
		--marge: 10vh;
		display: flex;
		align-items: center;
		justify-content: center;
		flex-direction: column;
		min-height: calc(100vh - var(--hauteur-header) - 2 * var(--marge) + 1px);
		margin: var(--marge) 0;
	}

	/* Le code ci-dessous permet de toujours placer le footer en bas de la page */

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
		overflow-x: hidden; /* Très important pour que les animations css horizontales n’agrandissent pas l’écran */
		color: white; /* Couleur par défaut du texte */
	}
	main {
		flex-grow: 1;
		margin-top: var(--hauteur-header); /* Pour que le contenu soit en-dessous du header */
	}
</style>
