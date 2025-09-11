<script>
	import { createEventDispatcher } from 'svelte';
	const dispatch = createEventDispatcher();

	export let typeValue;

	function toggleType() {
		const newType = typeValue === 'iso' ? 'ergodox' : 'iso';
		typeValue = newType;

		dispatch('message', { type: newType });
	}
</script>

<keyboard-control-type>
	<button on:click={toggleType}>
		{#if typeValue === 'ergodox'}
			<p><span class="ergodox-text-gradient">Ergodox</span> ➜&nbsp;ISO</p>
		{:else}
			<p>ISO&nbsp;➜ <span class="ergodox-text-gradient">Ergodox</span></p>
		{/if}
	</button>
</keyboard-control-type>
