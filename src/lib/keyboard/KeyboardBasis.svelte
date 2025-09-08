<script>
	import { Keyboard } from '$lib/keyboard/Keyboard.js';
	import { onMount, afterUpdate } from 'svelte';

	export let name;
	let clavier = new Keyboard(name);
	onMount(() => {
		clavier.updateKeyboard();
	});
</script>

<keyboard id={'clavier_' + name}>
	{#each Array(7) as _, i}
		<keyboard-row data-row={i + 1}>
			{#each Array(16) as _, j}
				<keyboard-key data-key="vide" data-row={i + 1} data-column={j} style="--size: 1;">
				</keyboard-key>
			{/each}
		</keyboard-row>
	{/each}
</keyboard>
