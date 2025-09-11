<script>
	import * as stores_infos from '$lib/stores_infos.js';
	import '$lib/keyboard/controls/KeyboardControls.css';

	import KeyboardControlButtonType from '$lib/keyboard/controls/KeyboardControlButtonType.svelte';
	import KeyboardControlButtonColor from '$lib/keyboard/controls/KeyboardControlButtonColor.svelte';
	import KeyboardControlButtonPlus from '$lib/keyboard/controls/KeyboardControlButtonPlus.svelte';
	import KeyboardControlButtonLayer from '$lib/keyboard/controls/KeyboardControlButtonLayer.svelte';

	export let id;

	let keyboardConfig;
	stores_infos[id].subscribe((value) => {
		keyboardConfig = value;
	});

	function updateKeyboardConfig(event) {
		stores_infos[id].update((currentKeyboardConfig) => ({
			...currentKeyboardConfig,
			...event.detail
		}));
	}
</script>

<keyboard-controls id={`controls_${id}`}>
	<KeyboardControlButtonPlus
		on:message={updateKeyboardConfig}
		plusValue={keyboardConfig['plus']}
		layerValue={keyboardConfig['layer']}
	/>
	<KeyboardControlButtonType on:message={updateKeyboardConfig} typeValue={keyboardConfig['type']} />
	<KeyboardControlButtonColor
		on:message={updateKeyboardConfig}
		colorValue={keyboardConfig['color']}
	/>
	<KeyboardControlButtonLayer
		on:message={updateKeyboardConfig}
		layerValue={keyboardConfig['layer']}
	/>
</keyboard-controls>
