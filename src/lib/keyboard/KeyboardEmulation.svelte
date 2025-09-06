<script>
	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
	import { KeyboardEmulation } from '$lib/keyboard/KeyboardEmulation.js';
	import { onMount } from 'svelte';

	let champTexte = '';
	let keyboard = new KeyboardEmulation('emulation');
	onMount(() => {
		keyboard.textarea = document.getElementById('input-text');
		keyboard.keyboardUpdate();
	});
</script>

<KeyboardBasis nom="emulation" />

<tiny-space></tiny-space>

<div style="margin: 0 auto; width: 100%;">
	<textarea
		id="input-text"
		placeholder="Écrivez ici"
		bind:value={champTexte}
		on:keydown={keyboard.KeyboardEmulation}
		on:keyup={keyboard.relacherModificateurs}
	/>
</div>

<style>
	#input-text {
		background-color: rgba(0, 0, 0, 0.4);
		border: none;
		border-radius: 5px;
		color: rgba(255, 255, 255, 0.9);
		display: block;
		height: 200px;
		margin: 0 auto;
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
