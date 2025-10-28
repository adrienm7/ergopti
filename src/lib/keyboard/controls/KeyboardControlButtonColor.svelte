<script>
	import * as stores_infos from '$lib/stores_infos.js';

	export let id;

	let colorValue;

	stores_infos[id].subscribe((config) => {
		colorValue = config.color;
	});

	function toggleColor() {
		const newColor = colorValue === 'yes' ? 'no' : 'yes';

		stores_infos[id].update((current) => ({
			...current,
			color: newColor
		}));
	}
</script>

<keyboard-control-color>
	<button onclick={toggleColor}>
		{#if colorValue === 'yes'}
			<p><span class="color-text-gradient">Couleur</span>&nbsp;➜ Bicolore</p>
		{:else}
			<p>Bicolore ➜&nbsp;<span class="color-text-gradient">Couleur</span></p>
		{/if}
	</button>
</keyboard-control-color>
