<script>
	import { page } from '$app/stores';
</script>

<header class="header">
	<div class="logo"><a href="/">⌨</a></div>
	<input class="menu-btn" type="checkbox" id="menu-btn" />
	<label class="menu-icon" for="menu-btn"><span class="navicon" /></label>
	<ul class="menu">
		<li aria-current={$page.url.pathname === '/' ? 'page' : undefined}>
			<a href="/">HyperTexte</a>
		</li>
		<li aria-current={$page.url.pathname === '/hypertexte-plus' ? 'page' : undefined}>
			<a href="/hypertexte-plus">HyperTexte<b>+</b></a>
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
	header a {
		color: #000;
		color: white;
		text-decoration: none;
	}

	/* header */

	.header {
		background-color: #fff;
		background-color: transparent;
		backdrop-filter: blur(60px);
		box-shadow: 1px 1px 4px 0 rgba(0, 0, 0, 0.1);
		position: fixed;
		width: 100%;
		height: var(--hauteur-header);
		z-index: 3;
	}

	.header ul {
		margin: 0;
		padding: 0;
		list-style: none;
		overflow: hidden;
		background-color: #fff;
		background-color: transparent;
	}

	.header li a {
		display: block;
		margin: 0 20px;
		text-decoration: none;
	}

	.header li a:hover,
	.header .menu-btn:hover {
		background-color: #f4f4f4;
		color: black;
		border-radius: 5px;
	}

	.header .logo {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		height: 100%;
		padding: 0.5rem;
	}

	/* menu */

	.header .menu {
		clear: both;
		max-height: 0;
		transition: max-height 0.2s ease-out;
	}

	/* menu icon */

	.header .menu-icon {
		cursor: pointer;
		float: right;
		padding: 28px 20px;
		position: relative;
		user-select: none;
	}

	.header .menu-icon .navicon {
		background: #333;
		display: block;
		height: 2px;
		position: relative;
		transition: background 0.2s ease-out;
		width: 18px;
	}

	.header .menu-icon .navicon:before,
	.header .menu-icon .navicon:after {
		background: #333;
		content: '';
		display: block;
		height: 100%;
		position: absolute;
		transition: all 0.2s ease-out;
		width: 100%;
	}

	.header .menu-icon .navicon:before {
		top: 5px;
	}

	.header .menu-icon .navicon:after {
		top: -5px;
	}

	/* menu btn */

	.header .menu-btn {
		display: none;
	}

	.header .menu-btn:checked ~ .menu {
		max-height: 240px;
	}

	.header .menu-btn:checked ~ .menu-icon .navicon {
		background: transparent;
	}

	.header .menu-btn:checked ~ .menu-icon .navicon:before {
		transform: rotate(-45deg);
	}

	.header .menu-btn:checked ~ .menu-icon .navicon:after {
		transform: rotate(45deg);
	}

	.header .menu-btn:checked ~ .menu-icon:not(.steps) .navicon:before,
	.header .menu-btn:checked ~ .menu-icon:not(.steps) .navicon:after {
		top: 0;
	}

	/* 48em = 768px */

	@media (min-width: 48em) {
		.header li {
			float: left;
		}
		.header li a {
			display: flex;
			justify-content: center;
			align-items: center;
			height: var(--hauteur-header);
			padding: 0 20px;
		}
		.header .menu {
			clear: none;
			float: right;
			max-height: none;
		}
		.header .menu-icon {
			display: none;
		}
	}

</style>
