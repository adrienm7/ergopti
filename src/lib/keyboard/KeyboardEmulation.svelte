<script>
	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
	import { KeyboardEmulation } from '$lib/keyboard/KeyboardEmulation.js';
	import { onMount } from 'svelte';

	const keyboard = new KeyboardEmulation('emulation');
	onMount(() => {
		keyboard.textarea = document.getElementById('input-text');
		keyboard.updateKeyboard();
	});
</script>

<KeyboardBasis id="emulation" />

<tiny-space></tiny-space>

<textarea
	id="input-text"
	placeholder="Tapez ici"
	on:keydown={keyboard.emulateKey}
	on:keyup={keyboard.releaseKey}
>
</textarea>

<style>
	#input-text {
		background-color: rgba(0, 0, 0, 0.4);
		border: none;
		border-radius: 5px;
		color: rgba(255, 255, 255, 0.9);
		height: 200px;
		padding: 15px;
		resize: none;
		width: 100%;
	}

	#input-text:focus-visible {
		background-color: white;
		color: black;
		outline: none;
	}
</style>
