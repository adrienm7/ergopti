<script>
	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
	import { KeyboardEmulation } from '$lib/keyboard/KeyboardEmulation.js';
	import { onMount, afterUpdate } from 'svelte';

	let champTexte = '';
	let clavier = new KeyboardEmulation('emulation');
	onMount(() => {
		clavier.textarea = document.getElementById('input-text');
		clavier.majClavier();
	});
</script>

<KeyboardBasis nom="emulation" />

<mini-espace />

<div style="margin: 0 auto; width: 100%;">
	<textarea
		id="input-text"
		placeholder="Écrivez ici"
		bind:value={champTexte}
		on:keydown={clavier.KeyboardEmulation}
		on:keyup={clavier.relacherModificateurs}
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
