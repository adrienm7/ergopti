<script>
	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import { EmulationClavier } from '$lib/clavier/EmulationClavier.js';
	import { onMount } from 'svelte';

	let clavier = new EmulationClavier('emulation');
	onMount(() => {
		clavier.textarea = document.getElementById('input-text');
	});

	let champTexte = '';
</script>

<BlocClavier nom="emulation" />

<mini-espace />

<div style="margin: 0 auto; width: 100%;">
	<textarea
		id="input-text"
		placeholder="Écrivez ici"
		bind:value={champTexte}
		on:keydown={clavier.emulationClavier}
		on:keyup={clavier.relacherModificateurs}
	/>
</div>

<style>
	#input-text {
		display: block;
		margin: 0 auto;
		width: 100%;
		height: 200px;
		padding: 15px;
		border-radius: 5px;
		border: none;
		resize: none;
		background-color: rgba(0, 0, 0, 0.4);
		color: rgba(255, 255, 255, 0.9);
	}

	#input-text:focus-visible {
		background-color: white;
		color: black;
		outline: none;
	}
</style>
