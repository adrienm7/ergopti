<script>
	import '$lib/keyboard/controls/KeyboardControls.css';

	import KeyboardControlButtonType from '$lib/keyboard/controls/KeyboardControlButtonType.svelte';
	import KeyboardControlButtonColor from '$lib/keyboard/controls/KeyboardControlButtonColor.svelte';
	import KeyboardControlButtonPlus from '$lib/keyboard/controls/KeyboardControlButtonPlus.svelte';
	import KeyboardControlButtonLayer from '$lib/keyboard/controls/KeyboardControlButtonLayer.svelte';

	export let id;
</script>

<keyboard-controls id={`controls_${id}`}>
	<KeyboardControlButtonPlus {id} />
	<KeyboardControlButtonType {id} />
	<KeyboardControlButtonColor {id} />
	<KeyboardControlButtonLayer {id} />
</keyboard-controls>
