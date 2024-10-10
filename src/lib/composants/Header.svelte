<script>
	import { page } from '$app/stores';
	import Nom from '../composants/Nom.svelte';

	function fermerMenu() {
		document.getElementById('menu-btn').checked = false;
		document.getElementById('clavier-ref').style.zIndex =
			'-999'; /* Si le clavier était ouvert, on le ferme */
	}

	import { version } from '$lib/stores_infos.js';
	let versionValue;
	version.subscribe((value) => {
		versionValue = value;
	});

	// Utiliser `set` pour mettre à jour la version dans le store
	function handleVersionChange() {
		version.set(versionValue);
	}

	let liste_versions = ['1.0.5', '1.0.12', '1.0.16', '1.0.19', '1.1.2'];
</script>

<header>
	<div class="header-logo">
		<a href="/"><img src="img/logo/logo_hypertexte_transparent.png" style="height: 55px;" /></a>
		<p style="font-variant: small-caps;">
			<a href="/">Disposition clavier </a><span class="hyper"
				><a href="/">HyperTexte</a>
				<div class="myselect">
					<select id="selection-version" bind:value={versionValue} on:change={handleVersionChange}>
						{#each liste_versions.reverse() as value}<option {value}>{value}</option>{/each}
					</select>
				</div></span
			>
		</p>
	</div>
	<input class="menu-btn" type="checkbox" id="menu-btn" />
	<label class="menu-icon" for="menu-btn"><span class="navicon" /></label>
	<nav id="menu">
		<p aria-current={$page.url.pathname === '/' ? 'page' : undefined} on:click={fermerMenu}>
			<a href="/"><i class="fad fa-keyboard"></i> <span class="titre">HyperTexte</span></a>
		</p>
		<p
			aria-current={$page.url.pathname === '/hypertexte-plus' ? 'page' : undefined}
			on:click={fermerMenu}
		>
			<a href="/hypertexte-plus"
				><i class="fad fa-star"></i>
				<span class="titre">HyperTexte<span class="glow">+</span></span></a
			>
		</p>
		<p
			aria-current={$page.url.pathname === '/benchmarks' ? 'page' : undefined}
			on:click={fermerMenu}
		>
			<a href="/benchmarks"
				><span class="couleur"><i class="fad fa-analytics"></i></span>
				<span class="titre">Benchmarks</span></a
			>
		</p>
		<p
			aria-current={$page.url.pathname === '/telechargements' ? 'page' : undefined}
			on:click={fermerMenu}
		>
			<a href="/telechargements"
				><i class="fad fa-download"></i> <span class="titre">Téléchargements</span></a
			>
		</p>
		<p
			aria-current={$page.url.pathname === '/informations' ? 'page' : undefined}
			on:click={fermerMenu}
		>
			<a href="/informations"
				><i class="fad fa-info-circle"></i> <span class="titre">Informations</span></a
			>
		</p>
	</nav>
</header>
<div style="height: var(--hauteur-header);"></div>

<style>
	:root {
		--couleur-header: rgba(0, 0, 0, 0.9);
		--couleur-header-mobile: rgba(0, 16, 36, 0.9);
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

	#selection-version {
		margin: 0;
		padding: 0;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: inherit;
		border: none;
		font-variant: small-caps;
	}

	.myselect {
		position: relative;
		display: inline-block;
		margin: 0;
		padding: 0;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: inherit;
		border: none;
		font-variant: small-caps;
	}

	.myselect::after {
		content: '';
		position: absolute;
		right: -1px;
		top: 8px;
		width: 0;
		height: 0;
		border-left: 8px solid transparent;
		border-right: 8px solid transparent;
		border-top: 8px solid rgb(255, 255, 255);
		pointer-events: none;
	}

	#selection-version option {
		background-color: white;
		color: black;
		font-style: normal;
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

	header #menu p {
		display: inline-block;
	}

	header #menu i {
		color: #3088ed;
	}
	header #menu i::before {
		-webkit-background-clip: text;
		background-clip: text;
		-webkit-text-fill-color: transparent;
		color: transparent;
		-webkit-box-decoration-break: clone;
		box-decoration-break: clone;
		background-image: linear-gradient(to right, var(--gradient-blue));
	}

	header #menu p[aria-current='page'] .titre,
	header #menu p:not([aria-current='page']) .titre:hover {
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
	header .header-logo p {
		display: inline;
		font-family: 'Times New Roman', Times, serif;
	}

	header .menu-btn {
		display: none;
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
			overflow: scroll; /* Pour désactiver le scroll derrière le menu (1/3) */
			overscroll-behavior: contain; /* Pour désactiver le scroll derrière le menu (2/3) */
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
		}
		header .menu-btn:checked ~ #menu ul {
			min-height: calc(
				100vh - var(--hauteur-header)
			); /* Pour désactiver le scroll derrière le menu (3/3) */
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
		header #menu {
			display: flex !important;
			flex-direction: row;
			background-color: transparent;
			z-index: 1;
			border: none;
			margin: 0;
			padding: 0;
			padding-right: var(--marge-bords-menu);
		}

		header #menu p {
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

		header #menu p:not(:last-child)::after {
			content: '';
			background-color: transparent;
			height: 100%;
			width: 5px;
			position: relative;
			right: calc((-1) * var(--espacement-items-menu));
			box-shadow: 2px 0 2px 0px var(--couleur-ombre);
		}

		header #menu p a {
			padding: calc(2 * var(--espacement-items-menu));
		}
		header #menu p a p {
			text-align: center; /* Dans le cas où le texte passe sur deux lignes car trop long */
		}
		header #menu p:last-child a {
			padding-right: 0;
		}

		header #menu p[aria-current='page'] a::after {
			content: '';
			display: block;
			position: relative;
			bottom: -5px;
			width: 100%;
			height: 3px;
			border-radius: 5px;
			background-image: linear-gradient(to right, var(--gradient-blue));
		}

		/* header #menu p:not([aria-current='page']) .titre:hover::after {
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
