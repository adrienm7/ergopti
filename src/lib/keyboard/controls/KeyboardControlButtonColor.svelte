<script lang="ts">
	export let colorValue: string;
	export let updateConfig: (partial: { color: string }) => void;

	function toggleColor() {
		const newColor = colorValue === 'yes' ? 'no' : 'yes';
		updateConfig({ color: newColor });
	}
</script>

<keyboard-control-color>
	<button onclick={toggleColor}>
		{#if colorValue === 'yes'}
			<p><span class="color-text-gradient">Color</span>&nbsp;➜ Bicolor</p>
		{:else}
			<p>Bicolor ➜&nbsp;<span class="color-text-gradient">Color</span></p>
		{/if}
	</button>
</keyboard-control-color>
