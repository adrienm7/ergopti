<script>
	import Nom from '../composants/Nom.svelte';
	import NomPlus from '../composants/NomPlus.svelte';

	import { page } from '$app/stores';

	import { loadData } from '$lib/clavier/getData.js';
	import { version, data_disposition, liste_versions } from '$lib/stores_infos.js';
	let versionValue;
	version.subscribe((value) => {
		versionValue = value;
	});

	function handleVersionChange() {
		loadData(versionValue)
			.then((data) => {
				data_disposition.set(data);
				version.set(versionValue); // Utiliser `set` pour mettre à jour la version dans le store
				// console.log('Données chargées :', data);
			})
			.catch((error) => {
				console.error('Erreur lors du chargement des données :', error);
			});
	}
	handleVersionChange();

	function fermerMenu() {
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

		// Si le menu est ouvert et que la largeur de l'écran est inférieure ou égale à 1400px
		if (menuBtn.checked && siteWidth <= 1400) {
			document.body.style.overflowY = 'hidden';
		} else {
			document.body.style.overflowY = 'visible';
		}

		// Changement de l'emplacement du menu de la page selon qu’on soit sur pc ou mobile
		if (siteWidth <= 1400) {
			tocMobile.appendChild(toc);
		} else {
			tocPc.appendChild(toc);
		}
	}

	// Exécuter la fonction après la mise à jour et au redimensionnement
	$effect(() => {
		toggleOverflowMenu();
		window.addEventListener('resize', toggleOverflowMenu);
	});
</script>

<header>
	<div class="header-logo">
		<a href="/"><img src="img/logo/logo.svg" class="logo" /></a>
		<div style="margin:0; margin-left: 0.5em; padding:0; text-align: left; width:max-content">
			<p style="margin:0; font-weight:bold">
				<a href="/">Disposition <span class="morespace">clavier </span></a>
				<span style="display:inline-block;"
					><a href="/"><Nom></Nom></a>
					<span class="myselect">
						<select
							id="selection-version"
							bind:value={versionValue}
							onchange={handleVersionChange}
							data-version={versionValue}
						>
							{#each liste_versions.reverse() as value}<option {value}>{value}</option>{/each}
						</select>
					</span></span
				>
				<a href="/informations/#changelog" style="position:relative; top:-0.65em; font-size:0.8em"
					><i class="fa-duotone fa-solid fa-circle-info"></i></a
				>
			</p>
			<p style="margin:0; padding-top: 0; padding-left: 0; font-size: 0.8em">
				<strong class="hyper" style="font-size:1.1em">Ergonomie optimisée</strong>
				<span class="morespace2" style="color:white;"> pour le français, l’anglais et le code</span>
			</p>
		</div>
	</div>
	<input class="menu-btn" type="checkbox" id="menu-btn" onclick={toggleOverflowMenu} />
	<label class="menu-icon" for="menu-btn"><span class="navicon" /></label>
	<nav id="menu">
		<div id="menu-pages">
			<p aria-current={$page.url.pathname === '/' ? 'page' : undefined} onclick={fermerMenu}>
				<a href="/"
					><i class="fa-duotone fa-keyboard"></i>
					<span class="titre">Ergopti</span></a
				>
			</p>
			<p
				aria-current={$page.url.pathname === '/ergopti-plus' ? 'page' : undefined}
				onclick={fermerMenu}
			>
				<a href="/ergopti-plus"
					><i class="fa-duotone fa-circle-star"></i>
					<span class="titre">Ergopti<span class="glow">+</span></span></a
				>
			</p>
			<p
				aria-current={$page.url.pathname === '/benchmarks' ? 'page' : undefined}
				onclick={fermerMenu}
			>
				<a href="/benchmarks"
					><span class="couleur"><i class="fa-duotone fa-chart-mixed"></i></span>
					<span class="titre">Benchmarks</span></a
				>
			</p>
			<p
				aria-current={$page.url.pathname === '/telechargements' ? 'page' : undefined}
				onclick={fermerMenu}
			>
				<a href="/telechargements"
					><i class="fa-duotone fa-download"></i>
					<span class="titre">Téléchargements</span></a
				>
			</p>
			<p
				aria-current={$page.url.pathname === '/informations' ? 'page' : undefined}
				onclick={fermerMenu}
			>
				<a href="/informations"
					><i class="fa-duotone fa-circle-info"></i>
					<span class="titre">Informations</span></a
				>
			</p>
		</div>
		<div id="menu-contenu">
			<p style="text-align:center; font-weight:bold; padding-top: 30px; padding-bottom: 15px;">
				Contenu de la page
			</p>
			<hr />
			<br />
			<div id="page-toc-mobile" onclick={fermerMenu}></div>
			<div style="height:70px"></div>
		</div>
	</nav>
</header>
<div style="height: var(--hauteur-header);"></div>

<style>
	:root {
		--couleur-header: rgba(0, 0, 0, 0.9);
		--couleur-header-mobile: rgba(0, 16, 36, 0.975);
		--couleur-liens-header: rgba(255, 255, 255, 0.9);
		--hauteur-element-menu-mobile: 30px;
		--espacement-items-menu: clamp(5px, 0.45vw, 14px);
		--couleur-ombre: rgba(200, 233, 255, 0.4);
		--marge-fenetre: var(--marge-bords-menu);
		--hauteur-header: clamp(70px, 5.5vw, 120px);
		--couleur-icone-hamburger: white;
		--marge-bords-menu: clamp(15px, 2vw, 50px);
		--longueur-traits-hamburger: 18px;
	}

	.morespace,
	.morespace2 {
		display: none;
	}
	@media (min-width: 400px) {
		.morespace {
			display: inline;
		}
	}
	@media (min-width: 600px) {
		.morespace2 {
			display: inline;
		}
	}

	#selection-version {
		margin: 0;
		padding: 0;
		background-clip: text;
		/* -webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: inherit; */
		-webkit-appearance: none;
		-moz-appearance: none;
		color: white;
		padding: 4px;
		margin-bottom: -4px;
		padding-top: 1px;
		padding-bottom: 2px;
		border-radius: 5px;
		/* width: 2.3em; */
	}

	.myselect {
		position: relative;
		display: inline-block;
		margin: 0;
		padding: 0;
		/* padding-right: 0.2em; */
		color: white;
		/* background-clip: text;
		-webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: inherit; */
		font-weight: normal !important;
	}

	/* .myselect::after {
		content: '';
		position: absolute;
		right: 0px;
		top: 0.3em;
		width: 0;
		height: 0;
		border-left: 0.45em solid transparent;
		border-right: 0.45em solid transparent;
		border-top: 0.7em solid rgb(255, 255, 255);
		pointer-events: none;
	} */

	#selection-version option {
		background-color: black;
		color: white;
		font-style: normal;
		font-weight: normal;
	}

	header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		position: fixed;
		top: 0;
		left: 0;
		z-index: 100;
		height: var(--hauteur-header);
		width: 100vw;
		margin: 0;
		padding: 0;
		backdrop-filter: blur(30px);
		background-color: var(--couleur-header);
		box-shadow: 0px 0px 6px 3px var(--couleur-ombre);
	}
	header a {
		color: var(--couleur-liens-header);
		font-size: 1.1rem;
		text-decoration: none;
	}

	header #menu #menu-pages p {
		display: inline-block;
	}

	header #menu #menu-pages p[aria-current='page'] .titre,
	header #menu #menu-pages p:not([aria-current='page']) .titre:hover {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: linear-gradient(to right, var(--gradient-blue));
	}

	header .header-logo {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		height: 100%;
		margin-left: clamp(3px, 1vw, 10px);
		/* margin-left: var(--marge-bords-menu); */
	}
	header .menu-btn {
		display: none;
	}

	.logo {
		height: calc(0.85 * var(--hauteur-header));
		margin-top: 3px;
		/*  
		margin-right: 10px;
		padding: 3px;
		background-color: #010017;
		border: 1px solid white;
		border-radius: 10px;
		*/
	}

	/* Menu mobile */
	@media (max-width: 1400px) {
		header #menu {
			position: fixed;
			top: var(--hauteur-header);
			left: 0;
			width: 100%;
			margin: 0;
			padding: 0;
			background-color: var(--couleur-header-mobile);
			backdrop-filter: blur(30px);
			border-top: 1px solid rgba(255, 255, 255, 0.2);
			transition: height 0.15s ease-out; /* Effet de déroulement du menu vers le bas si passage de height 0 à 100 */
			overflow: hidden;
			z-index: 98;
		}

		header #menu p a {
			display: block;
			padding: var(--hauteur-element-menu-mobile) 0;
			padding-left: var(--marge-fenetre);
			text-decoration: none;
			border-bottom: 1px solid rgba(255, 255, 255, 0.2);
			line-height: 1em;
		}
		header #menu p,
		header #menu p a p {
			width: 100%;
			margin: 0;
			padding: 0;
			font-size: 1.1rem;
			line-height: 1em !important;
		}

		/* menu icon */

		header .menu-icon {
			display: inline-block;
			padding: var(--marge-bords-menu);
			cursor: pointer;
			user-select: none;
		}

		header .menu-icon .navicon {
			display: block;
			position: relative;
			width: var(--longueur-traits-hamburger);
			height: 2px;
			transition: background 0.1s ease-out;
			background: var(--couleur-icone-hamburger);
		}

		header .menu-icon .navicon:before,
		header .menu-icon .navicon:after {
			background: var(--couleur-icone-hamburger);
			content: '';
			display: block;
			height: 100%;
			position: absolute;
			transition: all 0.1s ease-out;
			width: 100%;
		}

		header .menu-icon .navicon:before {
			top: 5px; /* Écartement des barres du hamburger */
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
			height: calc(100vh - var(--hauteur-header));
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

	/* Menu ordinateur */
	@media (min-width: 1400px) {
		header #menu #menu-pages {
			display: flex !important;
			flex-direction: row;
			background-color: transparent;
			z-index: 1;
			border: none;
			margin: 0;
			padding: 0;
			padding-right: var(--marge-bords-menu);
		}

		header #menu #menu-pages p {
			display: flex;
			justify-content: center;
			align-items: center;
			height: var(--hauteur-header);
			margin: 0;
			padding: 0;
			padding-left: calc(2 * var(--espacement-items-menu) + 5px);
			background-color: transparent;
			border-bottom: 0;
			font-size: 1rem;
		}

		header #menu #menu-pages p:not(:last-child)::after {
			content: '';
			background-color: transparent;
			height: 100%;
			width: 5px;
			position: relative;
			right: calc((-1) * var(--espacement-items-menu));
			box-shadow: 2px 0 2px 0px var(--couleur-ombre);
		}

		header #menu #menu-pages p a {
			padding: calc(2 * var(--espacement-items-menu));
		}
		header #menu #menu-pages p a p {
			text-align: center; /* Dans le cas où le texte passe sur deux lignes car trop long */
		}
		header #menu #menu-pages p:last-child a {
			padding-right: 0;
		}

		header #menu #menu-pages p[aria-current='page'] a::after {
			content: '';
			display: block;
			position: relative;
			bottom: -5px;
			width: 100%;
			height: 3px;
			border-radius: 5px;
			background-image: linear-gradient(to right, var(--gradient-blue));
		}

		/* header #menu #menu-pages p:not([aria-current='page']) .titre:hover::after {
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
</style>
