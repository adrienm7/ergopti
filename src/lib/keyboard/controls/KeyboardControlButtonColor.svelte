<script>
	import * as stores_infos from '#lib/stores_infos.js';

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
			<span class="color-text-gradient">Couleur</span>&nbsp;➜ Bicolore
		{:else}
			Bicolore ➜&nbsp;<span class="color-text-gradient">Couleur</span>
		{/if}
	</button>
</keyboard-control-color>
