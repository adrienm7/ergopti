<script>
	import '#lib/keyboard/Keyboard.css';
	import { Keyboard } from '#lib/keyboard/Keyboard.js';
	import { onMount } from 'svelte';

	export let id;
	const keyboard = new Keyboard(id);
	onMount(() => {
		keyboard.mount();
		return () => keyboard.destroy();
	});
</script>

<!-- A table for assistive technology: one row per keyboard row, one cell per
     key, so a screen reader can walk the layout as text (WCAG 1.1.1, 1.3.1). -->
<keyboard id={'keyboard_' + id} role="table" aria-label="Dessin du clavier">
	{#each Array(7) as _, i}
		<keyboard-row data-row={i + 1} role="row">
			{#each Array(16) as _, j}
				<keyboard-key
					data-key="none"
					data-row={i + 1}
					data-column={j}
					role="cell"
					style="--size: 1;"
				>
				</keyboard-key>
			{/each}
		</keyboard-row>
	{/each}
</keyboard>
