<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<h2>Minimisation des SFBs</h2>
<p>
	La disposition AZERTY est extrêmement mauvaise au vu de la distance nécessaire pour atteindre les
	touches les plus fréquentes. Toutefois, c’est loin d’être son seul défaut. L’un de ses autres
	problèmes majeurs est son grand nombre de <SFB />s.
</p>
<p>
	Qu’est-ce qu’un SFB ? C’est le fait de <span class="important"
		>devoir taper deux touches d’affilée avec exactement le même doigt</span
	>. Par exemple, c’est taper <kbd>CE</kbd> en AZERTY : il faut d’abord utiliser le majeur gauche
	pour descendre d’une rangée et atteindre le <kbd>C</kbd>, puis remonter de deux rangées pour
	atteindre le <kbd>E</kbd>. Avec <Nom />, le <kbd>C</kbd> est sur l’index droit sur la rangée du
	haut et le <kbd>E</kbd> est directement sur la rangée du milieu, sur le majeur gauche.
</p>
<p>
	Il est donc impossible de paralléliser sa frappe lors d’un <SFB />. Suivre un chemin linéaire est
	nécessaire : d’abord taper la première touche, puis bouger son doigt pour atteindre la deuxième,
	puis enfin frapper la deuxième touche, ceci avec le même doigt. Impossible de déplacer deux doigts
	en même temps pour ne plus avoir qu’à taper dans le bon ordre sur les touches atteintes. Le pire
	est quand ces <SFB />s constituent la majorité de vos frappes, ce qui se produit si vous utilisez
	une disposition non optimisée telle que AZERTY.
</p>
<p>
	Une combinaison de deux touches, c’est-à-dire deux caractères qui se suivent, est appelée <em
		>bigramme</em
	>
	(ou <em>digramme</em>). Pour optimiser une disposition clavier, il faut s’assurer que les
	bigrammes les plus fréquents ne se fassent pas avec le même doigt : on parle de
	<span class="important">limiter les <em>Same Finger Bigrams</em></span>.
</p>
<mini-espace />
<p>
	➜ Cette tâche est bien plus difficile qu’on le pense, car certaines lettres comme le <kbd>E</kbd>
	ou le <kbd>R</kbd> se combinent avec presque toutes les autres. Il faut alors choisir de les
	regrouper avec les lettres faisant les bigrammes les moins fréquents. Par conséquent, la
	suppression totale des <SFB />s est impossible. Toutefois, il est quand même possible de les
	réduire drastiquement. C’est ce que fait <Nom />.
</p>
