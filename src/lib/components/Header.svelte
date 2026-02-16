<script>
	import Ergopti from '../components/Ergopti.svelte';
	import ErgoptiPlus from '../components/ErgoptiPlus.svelte';

	import { page } from '$app/stores';

	import { getKeyboardData } from '$lib/keyboard/data/getKeyboardData.js';
	import { version, layoutData, versionsList, discordLink } from '$lib/stores_infos.js';

	function closeMenu() {
		document.getElementById('menu-btn').checked = false;
		document.getElementById('clavier-ref').style.zIndex =
			'-999'; /* Si le clavier était ouvert, on le ferme */
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

		// Changement de l'emplacement du menu de la page selon qu’on soit sur pc ou mobile
		if (siteWidth <= 1280) {
			tocMobile.appendChild(toc);
		} else {
			tocPc.appendChild(toc);
		}
	}

	// Exécuter la fonction après la mise à jour et au redimensionnement
	$effect(() => {
		toggleOverflowMenu();
		window.addEventListener('resize', toggleOverflowMenu);

		return () => {
			window.removeEventListener('resize', toggleOverflowMenu);
		};
	});

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

<header>
	<div id="ergopti-header">
		<a href="./" aria-label="Accéder à la page d’accueil">
			<img src="img/logo/logo.svg" class="logo" alt="Logo Ergopti" />
		</a>
		<div id="ergopti-title">
			<strong class="no-gradient text-white">
				<a href="./" aria-label="Accéder à la page d’accueil">
					<span class="min-width-300">Disposition </span>
					<span class="min-width-350">clavier </span>
				</a>
				<a href="./" aria-label="Accéder à la page d’accueil">
					<Ergopti></Ergopti>
				</a>
				<div class="min-width-400">
					<select id="version-selection" bind:value={$version}>
						{#each versionsList as v}
							<option value={v}>{v}</option>
						{/each}
					</select>
					<a
						href="informations/#changelog"
						aria-label="Accéder à la page d’accueil"
						style="position:relative; left:-0.1em; top:-0.65em; font-size:0.8em"
					>
						<i class="icon-circle-info"><span class="path1"></span><span class="path2"></span></i>
					</a>
					<span style="display:inline-block; width:0.15em"></span>
					<span class="links">
						<a href="https://github.com/adrienm7/ergopti" target="_blank">
							<i class="icon-github" style="transform: scale(0.927536)"></i>
						</a>
						<span> – </span>
						<a href={discordLink} target="_blank">
							<i class="icon-discord"></i>
						</a>
					</span>
				</div>
			</strong>
			<p id="ergopti-subtitle">
				<strong class="min-width-300" style="font-size:1.1em">Ergonomie optimisée</strong>
				<span class="min-width-600"> pour le français, l’anglais et le code</span>
			</p>
		</div>
	</div>
	<input class="menu-btn" type="checkbox" id="menu-btn" onclick={toggleOverflowMenu} />
	<label class="menu-icon" for="menu-btn"><span class="navicon"></span></label>
	<nav id="menu">
		<div id="menu-pages">
			<a
				href="./"
				onclick={closeMenu}
				aria-label="Accéder à la page Ergopti"
				aria-current={$page.url.pathname === '/' || $page.url.pathname === '/dev'
					? 'page'
					: undefined}
			>
				<i class="icon-keyboard-duotone" style="margin-right:7px;">
					<span class="path1"></span><span class="path2"></span>
				</i>
				<span class="title">Ergopti</span>
			</a>
			<a
				href="ergopti-plus"
				onclick={closeMenu}
				aria-label="Accéder à la page Ergopti+"
				aria-current={$page.url.pathname === '/ergopti-plus' ||
				$page.url.pathname === '/dev/ergopti-plus'
					? 'page'
					: undefined}
			>
				<i class="icon-circle-star" style="margin-right:3px; margin-top:1px">
					<span class="path1"></span><span class="path2"></span>
				</i>
				<span class="title" style="margin-top:3px;">
					Ergopti<span class="glow plus">+</span>
				</span>
			</a>
			<a
				href="benchmarks"
				onclick={closeMenu}
				aria-label="Accéder à la page Benchmarks"
				aria-current={$page.url.pathname === '/benchmarks' ||
				$page.url.pathname === '/dev/benchmarks'
					? 'page'
					: undefined}
			>
				<i class="icon-chart-mixed" style="margin-right:7px;">
					<span class="path1"></span><span class="path2"></span>
				</i>
				<span class="title" style="margin-top:3px;">Benchmarks</span>
			</a>
			<a
				href="utilisation"
				onclick={closeMenu}
				aria-label="Accéder à la page Utilisation"
				aria-current={$page.url.pathname === '/utilisation' ||
				$page.url.pathname === '/dev/utilisation'
					? 'page'
					: undefined}
			>
				<i class="icon-download" style="margin-right:5px">
					<span class="path1"></span><span class="path2"></span>
				</i>
				<span class="title">Utilisation</span>
			</a>
			<a
				href="informations"
				onclick={closeMenu}
				aria-current={$page.url.pathname === '/informations' ||
				$page.url.pathname === '/dev/informations'
					? 'page'
					: undefined}
				aria-label="Accéder à la page Informations"
			>
				<i class="icon-circle-info" style="margin-right:5px; margin-top:2px">
					<span class="path1"></span><span class="path2"></span>
				</i>
				<span class="title">Informations</span>
			</a>
		</div>
		<div id="menu-page-content">
			<nav id="menu-page-content-title">Contenu de la page</nav>
			<hr />
			<br />
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
<div style="height: calc(var(--header-height) + var(--banner-height));"></div>

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
		--couleur-icone-hamburger: white;
		--marge-bords-menu: clamp(15px, 1vw, 50px);
		--longueur-traits-hamburger: 18px;
	}

	header {
		align-items: center;
		backdrop-filter: blur(30px);
		background-color: var(--header-color);
		box-shadow: 0px 0px 5px 2px var(--couleur-ombre);
		display: flex;
		height: var(--header-height);
		justify-content: space-between;
		left: 0;
		margin: 0;
		padding: 0;
		position: fixed;
		top: 0;
		width: 100vw;
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

	#ergopti-header {
		align-items: center;
		display: flex;
		margin-left: calc(0.125 * var(--header-height));
	}

	#ergopti-header .logo {
		height: calc(0.85 * var(--header-height));
		margin-top: calc(0.05 * var(--header-height));
	}

	#ergopti-header #ergopti-title {
		margin-left: calc(0.1 * var(--header-height));
		margin-top: 1px; /* Looks better as the (i) takes vertical space */
	}

	#ergopti-header #ergopti-subtitle {
		font-size: 0.85em;
		margin: 0;
	}

	.min-width-300,
	.min-width-350,
	.min-width-400,
	.min-width-600 {
		display: none;
	}
	@media (min-width: 300px) {
		.min-width-300 {
			display: inline;
		}
	}
	@media (min-width: 350px) {
		.min-width-350 {
			display: inline;
		}
	}
	@media (min-width: 400px) {
		.min-width-400 {
			display: inline;
		}
	}
	@media (min-width: 600px) {
		.min-width-600 {
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

	header .menu-btn {
		display: none;
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

	#menu-pages a[aria-current='page'] .title,
	#menu-pages a[aria-current='page'] i .path1::before,
	#menu-pages a[aria-current='page'] i .path2::before {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		background-image: linear-gradient(var(--gradient-purple));
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		color: transparent;
	}

	#menu-pages a[aria-current='page'] i .path1::before {
		background-image: linear-gradient(var(--gradient-purple-dark));
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
			position: fixed;
			top: var(--header-height);
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

		header #menu,
		header .menu-btn:not(:checked) ~ #menu {
			height: 0;
		}

		header .menu-btn:checked ~ #menu {
			height: calc(100vh - var(--header-height));
			overflow: scroll;
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
