<script>
	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
	import { KeyboardEmulation } from '$lib/keyboard/KeyboardEmulation.js';
	import { onMount } from 'svelte';

	const keyboard = new KeyboardEmulation('emulation');
	let readiness = 'loading';
	onMount(() => {
		let active = true;
		keyboard.textarea = document.getElementById('input-text');
		keyboard
			.loadMagic()
			.then(() => {
				if (!active) return;
				keyboard.mount();
				readiness = 'ready';
			})
			.catch((error) => {
				if (!active) return;
				readiness = 'error';
				console.error('[KeyboardEmulation] Initialization failed', error);
			});
		return () => {
			active = false;
			if (keyboard.magicState !== 'disposed') keyboard.destroy();
		};
	});
</script>

<KeyboardBasis id="emulation" />

<tiny-space></tiny-space>

<div class="main">
	<textarea
		id="input-text"
		data-emulation-state={readiness}
		disabled={readiness !== 'ready'}
		aria-busy={readiness === 'loading'}
		placeholder="Tapez ici"
		on:keydown={keyboard.emulateKey}
		on:keyup={keyboard.releaseKey}
	>
	</textarea>
</div>

<style>
	.main {
		/* Override the .main class */
		padding-bottom: 0;
		padding-top: 10px;
	}

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
