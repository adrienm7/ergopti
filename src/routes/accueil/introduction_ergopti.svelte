<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
	import KeyboardControls from '$lib/keyboard/controls/KeyboardControls.svelte';
</script>

<section>
	<div>
		<h1 data-aos="zoom-in" class="ergopti-title">
			Disposition clavier<br /><span>—&nbsp;</span><span style="line-height: 0.75!important;"
				><Ergopti></Ergopti><span>&nbsp;—</span>
			</span>
		</h1>
		<KeyboardBasis id="presentation" />
		<tiny-space></tiny-space>
		<KeyboardControls id="presentation" />
	</div>

	<div style="margin: 0 auto; text-align:center; padding-top: 5px;">
		<a href="#debut" class="scroll-down"><i class="icon-chevron-down"></i></a>
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

	<div class="cards">
		<div class="card">
			<i class="icon-circle-1"><span class="path1"></span><span class="path2"></span></i>
			<strong>Diminution de la distance parcourue</strong> par les doigts pour moins de fatigue et plus
			de vitesse.
		</div>
		<div class="card">
			<i class="icon-circle-2"><span class="path1"></span><span class="path2"></span></i>
			<strong>Frappe extrêmement fluide</strong>
			par élimination de la quasi-totalité des
			<span class="nowrap"><SFB />s.</span>
		</div>
		<div class="card">
			<i class="icon-circle-3"><span class="path1"></span><span class="path2"></span></i>
			<strong>Alternance des mains</strong> maximisée pour paralléliser la frappe et ainsi écrire plus
			vite.
		</div>
		<div class="card">
			<i class="icon-circle-4"><span class="path1"></span><span class="path2"></span></i>
			<strong>Frappe ultra-confortable</strong> grâce à une optimisation des roulements.
		</div>
		<div class="card">
			<i class="icon-circle-5"><span class="path1"></span><span class="path2"></span></i>
			<strong>Placement logique</strong> des symboles, permettant de s’en souvenir aisément.
		</div>
		<div class="card">
			<i class="icon-circle-6"><span class="path1"></span><span class="path2"></span></i>
			<strong>Chiffres en accès direct</strong>, raccourcis sur la main gauche, ponctuations
			insécables, et plus…
		</div>
	</div>
	<p class="encart-introduction">
		L’intégralité du code de la disposition et de ce site est disponible<br />sous licence MIT sur
		<a class="link" href="https://github.com/adrienm7/ergopti">le GitHub du projet</a>.
	</p>

	<tiny-space></tiny-space>

	<div style="text-align:center;">
		<a href="/utilisation">
			<button class="alt-button">➜ Essayer en ligne / Installation</button>
		</a>
	</div>

	<big-space></big-space>
</section>

<style>
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
