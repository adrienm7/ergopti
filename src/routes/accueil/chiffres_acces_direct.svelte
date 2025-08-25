<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardBasis from '$lib/keyboard/KeyboardBasis.svelte';
</script>

<h2>Chiffres en accès direct et couche AltGr de symboles</h2>
<p>
	Les chiffres sont en accès direct sur les dispositions QWERTY ou encore DVORAK, mais pas en
	AZERTY, BÉPO ni Optimot. Chaque manière de faire a ses avantages, car en AZERTY les symboles sont
	alors directement accessibles et donc plus facilement réalisables. En revanche, il devient
	compliqué d’écrire un nombre en plein milieu d’une phrase, car cela nécessite de passer en <kbd
		>Shift</kbd
	> momentanément pour l’écrire.
</p>
<p>
	Avoir les chiffres en accès direct permet d’<span class="important"
		>écrire très rapidement des nombres</span
	>. C’est un réel gain en confort. La rangée des nombres n’est de toute façon pas très accessible.
	Par conséquent, il vaut mieux placer les symboles qu’elle contenait sur la couche <kbd>AltGr</kbd>
	qui est plus proche des doigts. C’est exactement ce que fait <Ergopti /> avec sa couche AltGr de symboles
	qui amène les symboles directement sous les doigts.
</p>
<mini-espace></mini-espace>
<KeyboardBasis nom="symboles" />
