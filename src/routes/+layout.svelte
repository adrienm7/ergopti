<script>
	import Header from '$lib/composants/Header.svelte';
	import Footer from '$lib/composants/Footer.svelte';

	import IntroductionHypertexte from './accueil/introduction_hypertexte.svelte';
	import IntroductionHypertextePlus from './hypertexte-plus/introduction_hypertexte_plus.svelte';
	import IntroductionBenchmarks from './benchmarks/introduction_benchmarks.svelte';
	import IntroductionTelechargements from './telechargements/introduction_telechargements.svelte';
	import IntroductionInformations from './informations/introduction_informations.svelte';
	import HypertextePlus from './accueil/hypertexte_plus.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import BlocControlesClavier from '$lib/clavier/BlocControlesClavier.svelte';

	import { afterUpdate, beforeUpdate, onDestroy, onMount } from 'svelte';
	import { page } from '$app/stores';
	import { navigating } from '$app/stores';
	import AOS from 'aos';
	import { typography } from '$lib/js/typography.js';
	import { matomo } from '$lib/js/code-matomo.js';
	import { makeIds } from '$lib/js/make-ids.js';
	import tocbot from 'tocbot';

	import '$lib/css/normalize.css';
	import '$lib/css/global.css';
	import '$lib/css/layout.css';
	import '$lib/css/cards.css';
	import '$lib/css/espacements.css';
	import '$lib/css/titres.css';
	import '$lib/css/typographie.css';
	import '$lib/css/hypertexte.css';
	import '$lib/css/images.css';
	import '$lib/css/clavier_reference.css';
	import '$lib/css/boutons.css';
	import '$lib/css/aos.css';
	import '$lib/css/tocbot.css';
	import '$lib/css/scrollbar.css';
	import '$lib/css/old.css';

	/* Icônes */
	import '$lib/icons/fontawesome/css/fontawesome.min.css';
	import '$lib/icons/fontawesome/css/regular.min.css';
	import '$lib/icons/fontawesome/css/duotone.min.css';

	onMount(() => {
		matomo(true); /* Lancer Matomo lors de l’arrivée sur le site */
		tocbot.init({
			// Where to render the table of contents.
			tocSelector: '#page-toc',
			// Where to grab the headings to build the table of contents.
			contentSelector: 'main',
			// Which headings to grab inside of the contentSelector element.
			headingSelector: 'h2, h3, h4, h5, h6',
			// For headings inside relative or absolute positioned containers within content.
			hasInnerContainers: true,
			// Prend en compte la hauteur du header pour le scroll
			headingsOffset: 120,
			scrollSmoothOffset: -120,
			scrollSmoothDuration: 300,
			orderedList: false
		});
	});

	/* Lancer Matomo lors du changement de page */
	$: if ($navigating) {
		/* Il est nécessaire de modifier le titre et l’url, car sinon ils sont identiques à la page d’entrée */
		matomo(
			false,
			$navigating.to.url.pathname,
			'https://hypertexte.beseven.fr' + $navigating.to.url.pathname
		);
	}

	afterUpdate(() => {
		makeIds(document.getElementById('main-content'));
		document.querySelectorAll('h2').forEach(function (h2) {
			h2.setAttribute('data-aos', 'zoom-out');
		});
		document.querySelectorAll('h3').forEach(function (h3) {
			h3.setAttribute('data-aos', 'fade-right');
		});

		AOS.init({ mirror: true, offset: 0, anchorPlacement: 'top-bottom' });
		typography(document.getElementsByTagName('main')[0]);
		tocbot.refresh();
	});

	let zIndex = -999;
	let affiche = 'none';
	function toggleZIndex() {
		zIndex = zIndex === -999 ? 80 : -999;
		affiche = affiche === 'none' ? 'block' : 'none';
		// document.getElementById('menu-btn').checked = false; /* Si le menu était ouvert, on le ferme */
	}
</script>

<div id="page" class="bg-blue">
	<div style="flex-grow:1">
		<Header />
		<div>
			{#if $page.url.pathname === '/'}
				<IntroductionHypertexte></IntroductionHypertexte>
			{/if}
			{#if $page.url.pathname === '/hypertexte-plus'}
				<IntroductionHypertextePlus></IntroductionHypertextePlus>
			{/if}
			{#if $page.url.pathname === '/benchmarks'}
				<IntroductionBenchmarks></IntroductionBenchmarks>
			{/if}
			{#if $page.url.pathname === '/telechargements'}
				<IntroductionTelechargements></IntroductionTelechargements>
			{/if}
			{#if $page.url.pathname === '/informations'}
				<IntroductionInformations></IntroductionInformations>
			{/if}
		</div>
		<div style="display:flex; flex-direction:row">
			<aside id="sidebar">
				<p style="text-align:center; color:white; margin:0; padding:0; font-weight: bold">
					Contenu de la page
				</p>
				<div id="page-toc"></div>
			</aside>
			<div id="main-content">
				<main>
					<slot />
				</main>
			</div>
		</div>
		{#if $page.url.pathname === '/'}
			<HypertextePlus></HypertextePlus>
		{/if}
	</div>
	<Footer />
</div>

<div>
	<button id="afficher-clavier-reference" on:click={toggleZIndex}>
		<i class="fa-duotone fa-keyboard" style="display:{affiche === 'none' ? 'block' : 'none'}"></i>
		<i class="fa-duotone fa-square-xmark" style="display:{affiche}"></i>
	</button>

	<div id="clavier-ref" class="bg-blue" style="z-index: {zIndex}; display:{affiche}">
		<div class="conteneur">
			<BlocClavier nom="reference" />
			<mini-espace />
			<BlocControlesClavier nom="reference" />
		</div>
	</div>
</div>

<!-- <div class="banner">
	<p>En construction</p>
</div> -->
