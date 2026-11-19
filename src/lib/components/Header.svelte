<script>
	import Ergopti from '../components/Ergopti.svelte';
	import A11ySettings from '../components/A11ySettings.svelte';

	import { page } from '$app/state';
	import { asset, resolve } from '$app/paths';

	import { getKeyboardData } from '#lib/keyboard/data/getKeyboardData.js';
	import { version, layoutData, versionsList, discordLink } from '#lib/stores_infos.js';
	import { PRODUCTS, isInSection } from '#lib/js/siteNavigation.js';

	function closeMenu() {
		document.getElementById('menu-btn').checked = false;
		const reference = document.getElementById('clavier-ref');
		if (reference) reference.style.zIndex = '-999'; /* Si le clavier était ouvert, on le ferme */
		document.body.style.overflowY = 'visible';
	}

	function toggleOverflowMenu() {
		const menuBtn = document.getElementById('menu-btn');
		const siteWidth = document.documentElement.clientWidth;
		const toc = document.querySelector('#page-toc');
		const tocPc = document.querySelector('#page-toc-pc');
		const tocMobile = document.querySelector('#page-toc-mobile');

		// Si le menu est ouvert et que la largeur de l'écran est inférieure ou égale à 1280px
		if (menuBtn.checked && siteWidth <= 1280) {
			document.body.style.overflowY = 'hidden';
		} else {
			document.body.style.overflowY = 'visible';
		}

		// Pages without a table of contents (home, overviews, Studio) have nothing to move.
		hasToc = Boolean(toc && tocPc);
		if (!hasToc) return;

		// Changement de l'emplacement du menu de la page selon qu’on soit sur pc ou mobile
		if (siteWidth <= 1280) {
			tocMobile.appendChild(toc);
		} else {
			tocPc.appendChild(toc);
		}
	}

	let hasToc = $state(true);

	// Exécuter la fonction après la mise à jour et au redimensionnement
	$effect(() => {
		page.url.pathname;
		toggleOverflowMenu();
		window.addEventListener('resize', toggleOverflowMenu);

		return () => {
			window.removeEventListener('resize', toggleOverflowMenu);
		};
	});

	/** @type {HTMLElement | undefined} */
	let headerElement = $state();

	// The header is at least --header-height tall and grows with the text
	// (200 % text, wide spacing, a narrow window): what sits under it (the
	// sticky table of contents, the narrow-screen banner, anchored headings)
	// offsets by its measured height, --header-offset, not by that minimum.
	$effect(() => {
		if (!headerElement) throw new Error('Header: the header element is not bound');
		const root = document.documentElement;
		const observer = new ResizeObserver(([entry]) => {
			root.style.setProperty('--header-offset', entry.borderBoxSize[0].blockSize + 'px');
		});
		observer.observe(headerElement);
		return () => {
			observer.disconnect();
			root.style.removeProperty('--header-offset');
		};
	});

	function isCurrent(route) {
		return isInSection(page.url.pathname, resolve(route));
	}

	// The layout version selector belongs to the Disposition Ergopti pages only.
	let onLayoutPages = $derived(isCurrent('/ergopti'));

	$effect(() => {
		getKeyboardData($version)
			.then((data) => {
				layoutData.set(data);
			})
			.catch((error) => {
				console.error('Error while loading layout data:', error);
			});
	});
</script>

<header lang="fr" bind:this={headerElement}>
	<div id="ergopti-header">
		<a href={resolve('/')} aria-label="Ergopti, page d’accueil">
			<img src={asset('img/logo/logo.svg')} class="logo" alt="" />
		</a>
		<div id="ergopti-title">
			<strong class="no-gradient text-white">
				<a href={resolve('/')} aria-label="Ergopti, page d’accueil">
					<Ergopti></Ergopti>
				</a>
				<span class="min-width-400">
					{#if onLayoutPages}
						<select
							id="version-selection"
							bind:value={$version}
							aria-label="Version de la Disposition Ergopti"
						>
							{#each versionsList as v}
								<option value={v}>{v}</option>
							{/each}
						</select>
						<a
							href={resolve('/ergopti/informations') + '#changelog'}
							aria-label="Voir l’historique des versions de la Disposition Ergopti"
							style="position:relative; left:-0.1em; top:-0.65em; font-size:0.8em"
						>
							<i class="icon-circle-info"><span class="path1"></span><span class="path2"></span></i>
						</a>
					{/if}
					<span style="display:inline-block; width:0.15em"></span>
					<span class="links">
						<a href="https://github.com/adrienm7/ergopti" target="_blank" aria-label="Repo GitHub">
							<i class="icon-github" style="transform: scale(0.927536)"></i>
						</a>
						<span> – </span>
						<a href={discordLink} target="_blank" aria-label="Serveur Discord">
							<i class="icon-discord"></i>
						</a>
					</span>
				</span>
			</strong>
			<!-- A tagline, not a paragraph: the wide spacing setting's 2 em under
			     each paragraph would make the wrapped header taller still. -->
			<div id="ergopti-subtitle">
				<strong class="min-width-300" style="font-size:1.1em"
					>Optimisation de l’ergonomie clavier</strong
				>
			</div>
		</div>
	</div>
	<A11ySettings />
	<input
		class="menu-btn"
		type="checkbox"
		id="menu-btn"
		aria-label="Menu"
		aria-controls="menu"
		onclick={toggleOverflowMenu}
	/>
	<label class="menu-icon" for="menu-btn"><span class="navicon"></span></label>
	<nav id="menu">
		<div id="menu-pages">
			{#each PRODUCTS as product (product.id)}
				<a
					href={resolve(product.route)}
					onclick={closeMenu}
					data-product={product.id}
					aria-label={'Accéder à la page ' + product.name}
					aria-current={isCurrent(product.route) ? 'page' : undefined}
				>
					<img class="product-icon" src={asset(product.icon)} alt="" width="22" height="22" />
					<span class="title">
						{#if product.id === 'ergopti-plus'}
							Ergopti<span class="glow plus">+</span>
						{:else}
							{product.menuLabel}
						{/if}
					</span>
				</a>
			{/each}
		</div>
		<div id="menu-page-content">
			{#if hasToc}
				<nav id="menu-page-content-title">Contenu de la page</nav>
				<hr />
				<br />
			{/if}
			<div
				id="page-toc-mobile"
				onclick={closeMenu}
				aria-label="Ouvrir le lien et fermer le menu"
			></div>
			<div style="height:70px"></div>
			<div class="links">
				<a href="https://github.com/adrienm7/ergopti" target="_blank">
					Repo GitHub <i class="icon-github" style="transform: scale(0.927536)"></i>
				</a>
				<span> — </span>
				<a href={discordLink} target="_blank">
					Serveur Discord
					<i class="icon-discord"></i>
				</a>
			</div>
			<div style="height:70px"></div>
		</div>
	</nav>
</header>
<!-- Room for the banner, fixed under the header on narrow screens. -->
<div style="height: var(--banner-height);"></div>

<style>
	:root {
		--header-color: rgba(0, 0, 0, 0.8);
		--header-color-mobile: rgba(0, 18, 30, 0.975);
		--couleur-liens-header: rgba(255, 255, 255, 0.9);
		--hauteur-element-menu-mobile: 30px;
		--items-menu-spacing: clamp(4px, 0.8vw, 25px);
		--menu-separators-color: rgb(200, 233, 255);
		--marge-fenetre: var(--marge-bords-menu);
		--header-height: clamp(70px, 5.5vw, 120px);
		/* The header's real height, measured once the page runs (the effect
		   above); until then the header is at its minimum height. */
		--header-offset: var(--header-height);
		--couleur-icone-hamburger: white;
		--marge-bords-menu: clamp(15px, 1vw, 50px);
		--longueur-traits-hamburger: 18px;
	}

	/* Sticky in the page's flow and at least --header-height tall, not fixed
	   at that height over a spacer of the same height: with 200 % text or the
	   wide spacing the title wrapped out of a fixed box, above the window and
	   over the page (tools/test/browser/site-reading.cjs).
	   It wraps: with 200 % text on a phone the title alone fills the width, so
	   the accessibility button and the menu icon go to a second row, right
	   aligned by the button's auto margin, instead of past the window's edge
	   where the whole page scrolled sideways (WCAG 1.4.10, the « reflow »
	   check of site-reading.cjs). */
	header {
		align-items: center;
		backdrop-filter: blur(30px);
		background-color: var(--header-color);
		box-shadow: 0px 0px 5px 2px var(--couleur-ombre);
		display: flex;
		flex-wrap: wrap;
		justify-content: space-between;
		margin: 0;
		min-height: var(--header-height);
		padding: 0;
		position: sticky;
		top: 0;
		z-index: 100;
	}
	header a {
		color: var(--couleur-liens-header);
		font-size: 1.1rem;
		text-decoration: none;
	}

	.links {
		text-align: center;
	}
	.links a {
		display: inline !important;
		font-size: 1em !important;
	}

	/*
=============================
======= Ergopti title =======
=============================
*/

	/* Alone on its row, the title may still be wider than the window (the
	   logo and one long word at 200 % text): it shrinks and breaks that word
	   rather than overflow, as a flex item's min-content would make it. */
	#ergopti-header {
		align-items: center;
		display: flex;
		margin-left: calc(0.125 * var(--header-height));
		min-width: 0;
	}

	#ergopti-header .logo {
		height: calc(0.85 * var(--header-height));
		margin-top: calc(0.05 * var(--header-height));
	}

	#ergopti-header #ergopti-title {
		margin-left: calc(0.1 * var(--header-height));
		margin-top: 1px; /* Looks better as the (i) takes vertical space */
		min-width: 0;
		overflow-wrap: break-word;
	}

	#ergopti-header #ergopti-subtitle {
		font-size: 0.85em;
		margin: 0;
	}

	.min-width-300,
	.min-width-400 {
		display: none;
	}
	@media (min-width: 300px) {
		.min-width-300 {
			display: inline;
		}
	}
	@media (min-width: 400px) {
		.min-width-400 {
			display: inline;
		}
	}

	#version-selection {
		border: 1px solid rgb(0, 76, 139);
		border-radius: 5px;
		color: white;
		margin: 0;
		margin-bottom: -4px;
		padding: 4px;
		padding-bottom: 2px;
		padding-top: 1px;
	}

	#version-selection option {
		background-color: black;
		color: white;
		font-style: normal;
		font-weight: normal;
	}

	/*
==========================
======= Menu style =======
==========================
*/

	/* Hidden from sight but not from the keyboard: on a narrow screen it is the
	   only way to open the menu, and its focus ring is drawn on the hamburger. */
	header .menu-btn {
		height: 1px;
		margin: -1px;
		opacity: 0;
		overflow: hidden;
		position: absolute;
		width: 1px;
	}

	header .menu-btn:focus-visible + .menu-icon {
		outline: 3px solid #ffd60a;
		outline-offset: -3px;
	}

	#menu-pages {
		display: flex;
	}

	#menu-pages a {
		align-items: center;
		display: flex;
	}

	#menu-pages a .title {
		display: inline-flex;
		font-size: 0.95em;
	}

	#menu-pages .product-icon {
		flex: none;
		height: 22px;
		margin-right: 7px;
		width: 22px;
	}

	#menu-pages a:not([aria-current='page']) .title:hover {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		background-image: linear-gradient(var(--gradient-blue));
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		color: transparent;
	}

	#menu-pages a .title {
		/* Otherwise, the gradient is cut */
		padding: 0.08em 0;
	}

	#menu-pages a[aria-current='page'] .title {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		background-image: linear-gradient(var(--gradient-purple));
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		color: transparent;
	}

	/* Correct problem of the "+" of Ergopti+ title being too low */
	.title .glow {
		top: -0.125em;
	}

	/* Menu mobile */
	@media (max-width: 1280px) {
		#menu {
			background-color: var(--header-color-mobile);
			border-top: 1px solid rgba(255, 255, 255, 0.2);
			left: 0;
			margin: 0;
			overflow: hidden;
			padding: 0;
			/* Under the header whatever its height (the header is its containing block). */
			position: absolute;
			top: 100%;
			transition: height 0.15s ease-out; /* Effet de déroulement du menu vers le bas si passage de height 0 à 100 */
			width: 100%;
			z-index: 98;
		}

		#menu-pages {
			flex-direction: column;
		}

		#menu-pages a {
			border-bottom: 1px solid rgba(255, 255, 255, 0.2);
			padding: var(--hauteur-element-menu-mobile) 0;
			padding-left: var(--marge-fenetre);
		}

		/* menu icon */

		header .menu-icon {
			cursor: pointer;
			display: inline-block;
			padding: var(--marge-bords-menu);
			user-select: none;
		}

		header .menu-icon .navicon {
			background: var(--couleur-icone-hamburger);
			border-radius: 5px;
			display: block;
			height: 1.7px;
			position: relative;
			transition: background 0.1s ease-out;
			width: var(--longueur-traits-hamburger);
		}

		header .menu-icon .navicon:before,
		header .menu-icon .navicon:after {
			background: var(--couleur-icone-hamburger);
			border-radius: 5px;
			content: '';
			display: block;
			height: 1.5px;
			position: absolute;
			transition: all 0.1s ease-out;
			width: var(--longueur-traits-hamburger);
		}

		header .menu-icon .navicon:before {
			top: 6px; /* Écartement des barres du hamburger */
		}

		header .menu-icon .navicon:after {
			top: -5px; /* Écartement des barres du hamburger */
		}

		/* menu btn */

		/* A closed menu is hidden, not only flattened: its links must not
		   take the keyboard focus while nobody can see them. */
		header #menu,
		header .menu-btn:not(:checked) ~ #menu {
			height: 0;
			visibility: hidden;
		}

		header .menu-btn:checked ~ #menu {
			height: calc(100vh - var(--header-offset));
			overflow: scroll;
			visibility: visible;
		}

		header .menu-btn:checked ~ .menu-icon .navicon {
			background: transparent;
		}

		header .menu-btn:checked ~ .menu-icon .navicon:before {
			transform: rotate(-45deg);
		}

		header .menu-btn:checked ~ .menu-icon .navicon:after {
			transform: rotate(45deg);
		}

		header .menu-btn:checked ~ .menu-icon:not(.steps) .navicon:before,
		header .menu-btn:checked ~ .menu-icon:not(.steps) .navicon:after {
			top: 0;
		}
	}

	/* Menu on large screens */
	@media (min-width: 1281px) {
		#menu-pages {
			flex-direction: row;
			padding-right: var(--marge-bords-menu);
		}

		#menu-pages a {
			margin: 0 var(--items-menu-spacing);
		}

		#menu-pages a:not(:last-child)::after {
			background-color: #5b5b5b;
			border-radius: 3px;
			content: '';
			display: inline-block;
			height: calc(0.5 * var(--header-height));
			position: relative;
			right: calc(-1 * var(--items-menu-spacing));
			width: 3px;
		}

		/* Underline selected page */
		/* #menu-pages a[aria-current='page'] a::after {
			background-image: linear-gradient(var(--gradient-purple));
			border-radius: 5px;
			bottom: -5px;
			content: '';
			display: block;
			height: 3px;
			position: relative;
			width: 100%;
		} */

		/* #menu-pages a:not([aria-current='page']) .title:hover::after {
		content: '';
		display: block;
		position: relative;
		bottom: -5px;
		width: 100%;
		height: 3px;
		border-radius: 5px;
		background-image: linear-gradient(to right, var(--gradient-purple));
	} */
	}

	#menu-page-content-title {
		font-weight: bold;
		padding-bottom: 5px;
		padding-top: 30px;
		text-align: center;
	}
</style>
