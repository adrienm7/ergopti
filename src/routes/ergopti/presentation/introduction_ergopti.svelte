<script>
	import Ergopti from '#lib/components/Ergopti.svelte';
	import ErgoptiPlus from '#lib/components/ErgoptiPlus.svelte';
	import SFB from '#lib/components/SFB.svelte';

	import KeyboardBasis from '#lib/keyboard/KeyboardBasis.svelte';
	import KeyboardControls from '#lib/keyboard/controls/KeyboardControls.svelte';

	import { resolve } from '$app/paths';
</script>

<section>
	<header>
		<h1 data-aos="zoom-in" class="ergopti-title">
			Disposition clavier<br /><span aria-hidden="true">—&nbsp;</span><span
				style="line-height: 0.75!important;"
				><Ergopti></Ergopti><span aria-hidden="true">&nbsp;—</span>
			</span>
		</h1>
		<KeyboardBasis id="presentation" />
		<tiny-space></tiny-space>
		<KeyboardControls id="presentation" />
	</header>

	<div style="margin: 0 auto; text-align:center; padding-top: 5px;">
		<a href="#debut" class="scroll-down" aria-label="Aller au début de la présentation"
			><i class="icon-chevron-down" aria-hidden="true"></i></a
		>
	</div>
	<div id="debut">
		<small-space />
		<hr />
		<p class="encart-introduction">
			<strong><Ergopti></Ergopti></strong> est une
			<strong>disposition clavier ergonomique et optimisée</strong>
			pour le
			<b>français</b>, l’<b>anglais</b> et la <b>programmation</b>. Fruit de nombreuses réflexions
			et expérimentations, elle permet une frappe fluide, rapide et
			<strong class="nowrap">un confort d’exception</strong>.
		</p>
		<hr />
	</div>

	<tiny-space></tiny-space>

	<ul class="cards">
		<li class="card">
			<i class="icon-circle-1" aria-hidden="true"
				><span class="path1"></span><span class="path2"></span></i
			>
			<strong>Diminution de la distance parcourue</strong> par les doigts pour moins de fatigue et plus
			de vitesse.
		</li>
		<li class="card">
			<i class="icon-circle-2" aria-hidden="true"
				><span class="path1"></span><span class="path2"></span></i
			>
			<strong>Frappe extrêmement fluide</strong>
			par élimination de la quasi-totalité des
			<span class="nowrap"><SFB />s.</span>
		</li>
		<li class="card">
			<i class="icon-circle-3" aria-hidden="true"
				><span class="path1"></span><span class="path2"></span></i
			>
			<strong>Alternance des mains</strong> maximisée pour paralléliser la frappe et ainsi écrire plus
			vite.
		</li>
		<li class="card">
			<i class="icon-circle-4" aria-hidden="true"
				><span class="path1"></span><span class="path2"></span></i
			>
			<strong>Frappe ultra-confortable</strong> grâce à une optimisation des roulements.
		</li>
		<li class="card">
			<i class="icon-circle-5" aria-hidden="true"
				><span class="path1"></span><span class="path2"></span></i
			>
			<strong>Placement logique</strong> des symboles, permettant de s’en souvenir aisément.
		</li>
		<li class="card">
			<i class="icon-circle-6" aria-hidden="true"
				><span class="path1"></span><span class="path2"></span></i
			>
			<strong>Chiffres en accès direct</strong>, raccourcis sur la main gauche, ponctuations
			insécables, et plus…
		</li>
	</ul>
	<p class="encart-introduction">
		L’intégralité du code de la disposition et de ce site est disponible sous licence MIT sur
		<a href="https://github.com/adrienm7/ergopti" target="_blank" class="link nowrap"
			>le GitHub du projet</a
		>.
	</p>

	<tiny-space></tiny-space>

	<div style="text-align:center;">
		<a class="button-link alt-button" href={resolve('/ergopti/utilisation')}>
			➜ Essayer en ligne / Installation
		</a>
	</div>

	<big-space></big-space>
</section>

<style>
	/* The cards are a list of features: drop the list's own marker, indent,
	   column cap and item spacing so the grid looks as it did with divs. */
	.cards {
		list-style: none;
		padding: 0;
		text-align: inherit;
	}

	.card {
		margin: 0;
		text-align: inherit;
	}

	.scroll-down {
		-webkit-animation: bounce7 2.5s infinite;
		animation: bounce7 2.5s infinite;
		color: white;
		display: block;
		font-size: 4rem;
		font-size: clamp(20px, 4rem, 100px);
		margin: 0 auto;
		width: fit-content;
	}

	@keyframes bounce7 {
		0% {
			opacity: 0;
			-webkit-transform: translate(0, -20px);
		}
		50% {
			opacity: 1;
		}
		100% {
			opacity: 0;
			-webkit-transform: translate(0, 40px);
		}
	}
	@media (prefers-reduced-motion: reduce) {
		.scroll-down {
			animation: none;
		}
	}
</style>
