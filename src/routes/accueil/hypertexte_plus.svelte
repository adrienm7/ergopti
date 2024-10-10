<script>
	import '$lib/css/orb.css';

	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<div style="border-bottom: 1px solid rgba(255, 255, 255, 0.5);" class="fullwidth"></div>
<div
	style="background:black; padding-top: 10px; padding-bottom: 100px; margin-bottom:-15vh;"
	class="fullwidth"
>
	<div id="orb">
		<div class="wrap">
			{#each Array(300) as _, index}
				<div class="c" />
			{/each}
		</div>
		<h2
			class="text-orange-gradient text-center"
			style="margin: 0 auto; margin-top: 30vh; padding-top: 15vh; padding-bottom:10vh; border:none; box-shadow: none; font-weight:bolder;"
		>
			★ Pour aller encore <b>+</b> loin ★
		</h2>
		<div class="texte-orb" style="max-width: 850px; margin:0 auto; margin-top:-50px">
			<hr />
			<p class="encart-introduction">
				<NomPlus /> permet d’avoir une disposition encore meilleure. Les <SFB />s sont éradiqués,
				les roulements sont améliorés et les doigts ont encore moins de distance à parcourir.
				Découvrez cette amélioration de la disposition en consultant la page associée :
			</p>
			<a href="/hypertexte-plus" style="text-decoration: none;"
				><button
					style="display:block; margin: 0 auto; margin-bottom: 25px; background: rgba(0, 0, 0, 0.2); padding: 10px; padding-top: 6px; border-radius: 3px; border: 1px solid white;"
					><NomPlus /></button
				></a
			>
			<hr />
		</div>
	</div>
</div>

<style>
	.text-orange-gradient {
		color: #ff6300;
	}

	@supports (background-clip: text) or (-webkit-background-clip: text) {
		.text-orange-gradient {
			-webkit-background-clip: text;
			background-clip: text;
			-webkit-text-fill-color: transparent;
			color: transparent;
			-webkit-box-decoration-break: clone;
			box-decoration-break: clone;
			background-image: linear-gradient(90deg, #fcaa00 30%, #ff6300 50%, #ff0063 100%);
		}
	}
</style>
