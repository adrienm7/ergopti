<script>
	import * as stores_infos from '$lib/stores_infos.js';

	export let id;

	let typeValue;

	stores_infos[id].subscribe((config) => {
		typeValue = config.type;
	});

	function toggleType() {
		const newType = typeValue === 'iso' ? 'ergodox' : 'iso';

		stores_infos[id].update((current) => ({
			...current,
			type: newType
		}));
	}
</script>

<keyboard-control-type>
	<button onclick={toggleType}>
		{#if typeValue === 'ergodox'}
			<p><span class="ergodox-text-gradient">Ergodox</span> ➜&nbsp;ISO</p>
		{:else}
			<p>ISO&nbsp;➜ <span class="ergodox-text-gradient">Ergodox</span></p>
		{/if}
	</button>
</keyboard-control-type>
