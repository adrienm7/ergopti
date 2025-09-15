<script>
	import '$lib/css/orb.css';

	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
</script>

<section>
	<div style="border-bottom: 1px solid rgba(255, 255, 255, 0.5);"></div>
	<div
		style="background:black; padding-top: 10px; padding-bottom: 100px;
	overflow-x: hidden; /* Très important pour que les animations AOS horizontales n’agrandissent pas l’écran */"
	>
		<div id="orb">
			<div class="wrap">
				{#each Array(300) as _, index}
					<div class="c" />
				{/each}
			</div>
			<p
				class="text-orange-gradient text-center"
				style="margin-top: 30vh; padding-top: 15vh; padding-bottom:8vh; border:none; box-shadow: none; font-weight:bolder; font-size:2rem"
				data-aos="none"
			>
				★&nbsp;Pour aller encore <b>+</b>&nbsp;loin&nbsp;★
			</p>
			<div class="texte-orb" style="max-width: 850px; margin:0 auto; margin-top:-50px">
				<hr />
				<p class="encart-introduction">
					<ErgoptiPlus /> permet d’avoir une disposition encore meilleure. Les <SFB />s sont
					éradiqués, les roulements sont améliorés et les doigts ont encore moins de distance à
					parcourir. Découvrez cette amélioration (optionnelle) de la disposition en consultant la
					page associée :
				</p>
				<a href="/ergopti-plus" style="text-decoration: none;"
					><button
						style="display:block; margin: 0 auto; margin-bottom: 25px; background: rgba(0, 0, 0, 0.2); padding: 10px; padding-top: 6px; border-radius: 3px; border: 1px solid white;"
						><ErgoptiPlus /></button
					></a
				>
				<hr />
			</div>
		</div>
	</div>
</section>

<style>
	.text-orange-gradient {
		color: #ff6300;
	}

	@supports (background-clip: text) or (-webkit-background-clip: text) {
		.text-orange-gradient {
			-webkit-background-clip: text;
			background-clip: text;
			-webkit-text-fill-color: transparent;
			background-image: linear-gradient(90deg, #fcaa00 30%, #ff6300 50%, #ff0063 100%);
			-webkit-box-decoration-break: clone;
			box-decoration-break: clone;
			color: transparent;
		}
	}
</style>
