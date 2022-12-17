<script>
	import { page } from '$app/stores';
</script>

<header>
	<div class="logo">
		<a href="/"
			>⌨ <p>Disposition optimisée HyperTexte</p></a
		>
	</div>
	<input class="menu-btn" type="checkbox" id="menu-btn" />
	<label class="menu-icon" for="menu-btn"><span class="navicon" /></label>
	<ul class="menu">
		<li aria-current={$page.url.pathname === '/' ? 'page' : undefined}>
			<a href="/">HyperTexte</a>
		</li>
		<li aria-current={$page.url.pathname === '/hypertexte-plus' ? 'page' : undefined}>
			<a href="/hypertexte-plus">HyperTexte<span class="glow">+</span></a>
		</li>
		<li aria-current={$page.url.pathname === '/benchmarks' ? 'page' : undefined}>
			<a href="/benchmarks">Benchmarks</a>
		</li>
		<li aria-current={$page.url.pathname === '/telechargement' ? 'page' : undefined}>
			<a href="/telechargements">Téléchargements</a>
		</li>
		<li aria-current={$page.url.pathname === '/contact' ? 'page' : undefined}>
			<a href="/contact">Contact</a>
		</li>
	</ul>
</header>

<style>
	/* header */
	header {
		background-color: var(--couleur-header-mobile);
		box-shadow: 0px 3px 10px 3px var(--couleur-ombre);
		position: fixed;
		width: 100%;
		height: var(--hauteur-header);
		z-index: 3;
	}
	header a {
		color: var(--couleur-liens-header);
		text-decoration: none;
	}
	header ul {
		margin: 0;
		padding: 0;
		list-style: none;
		overflow: hidden;
		background-color: var(--couleur-header-mobile);
	}

	header .menu li {
		display: block;
		padding: var(--hauteur-element-menu-mobile) 0;
		padding-left: var(--marge-fenetre);
		text-decoration: none;
		/* font-family: 'Times New Roman', Times, serif; */
		text-shadow: rgba(255, 255, 255, 0.8) 1px 0 10px;
	}

	header .logo {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		height: 100%;
		padding: 0.5rem;
	}
	header .logo p {
		display: inline;
		font-style: italic;
		font-family: 'Times New Roman', Times, serif;
	}

	/* menu */

	header .menu {
		clear: both;
		max-height: 0;
		transition: max-height 0.2s ease-out;
	}

	/* menu icon */

	header .menu-icon {
		cursor: pointer;
		float: right;
		padding: 28px 20px;
		position: relative;
		user-select: none;
	}

	header .menu-icon .navicon {
		background: #333;
		display: block;
		height: 2px;
		position: relative;
		transition: background 0.2s ease-out;
		width: 18px;
	}

	header .menu-icon .navicon:before,
	header .menu-icon .navicon:after {
		background: #333;
		content: '';
		display: block;
		height: 100%;
		position: absolute;
		transition: all 0.2s ease-out;
		width: 100%;
	}

	header .menu-icon .navicon:before {
		top: 5px; /* Écartement des barres du hamburger */
	}

	header .menu-icon .navicon:after {
		top: -5px; /* Écartement des barres du hamburger */
	}

	/* menu btn */

	header .menu-btn {
		display: none;
	}

	header .menu-btn:checked ~ .menu {
		max-height: 240px;
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

	/* 48em = 768px, donc pour les grands écrans */

	@media (min-width: 48em) {
		header {
			background-color: var(--couleur-header);
			backdrop-filter: blur(60px);
		}
		header .menu {
			display: flex;
			background-color: transparent;
			margin-right: 15px;
		}
		header a {
			color: white;
		}
		header .menu li {
			display: flex;
			justify-content: center;
			align-items: center;
			height: var(--hauteur-header);
			margin: 0;
			padding: 0;
			padding-left: calc(2 * var(--espacement-items-menu) + 5px);
			background-color: transparent;
		}

		header .menu li::after {
			content: '';
			background-color: transparent;
			height: 100%;
			width: 5px;
			position: relative;
			right: calc((-1) * var(--espacement-items-menu));
			box-shadow: 2px 0 1px 0px var(--couleur-ombre);
		}

		header .menu li a {
			padding: var(--espacement-items-menu);
			margin: var(--espacement-items-menu);
		}
		header .menu li a:hover,
		header .menu li[aria-current='page'] a {
			background-color: #f4f4f4;
			color: black !important;
			border-radius: 3px;
		}

		header .menu {
			clear: none;
			float: right;
			max-height: none;
		}
		header .menu-icon {
			display: none;
		}
	}

</style>
