<script>
	import '$lib/keyboard/Keyboard.css';
	import { Keyboard } from '$lib/keyboard/Keyboard.js';
	import { onMount } from 'svelte';

	export let id;
	const keyboard = new Keyboard(id);
	onMount(() => {
		keyboard.updateKeyboard();
	});
</script>

<keyboard id={'keyboard_' + id}>
	{#each Array(7) as _, i}
		<keyboard-row data-row={i + 1}>
			{#each Array(16) as _, j}
				<keyboard-key data-key="none" data-row={i + 1} data-column={j} style="--size: 1;">
				</keyboard-key>
			{/each}
		</keyboard-row>
	{/each}
</keyboard>
