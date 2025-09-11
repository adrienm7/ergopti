<script lang="ts">
	export let typeValue: string;
	export let updateConfig: (partial: { type: string }) => void;

	function toggleType() {
		const newType = typeValue === 'iso' ? 'ergodox' : 'iso';
		updateConfig({ type: newType });
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
