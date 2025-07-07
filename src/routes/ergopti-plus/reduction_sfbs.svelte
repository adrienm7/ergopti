<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
</script>

<h2>Diminution des SFBs</h2>
<p>L’un des avantages majeurs de <NomPlus /> est qu’il réduit presque totalement les <SFB />s.</p>
<p>
	Les <SFB />s les plus fréquents de la disposition sont : <kbd>CT</kbd>,
	<kbd>PT</kbd>, <kbd>EO</kbd>, <kbd>OE</kbd>,
	<kbd>UB</kbd>, <kbd>BU</kbd> et <kbd>DS</kbd>. <kbd>CT</kbd> est de loin le plus fréquent.
	<kbd>EO</kbd>
	et
	<kbd>OE</kbd> sont aussi relativement fréquents en anglais (pour écrire
	<kbd-sortie>DOES</kbd-sortie>,
	<kbd-sortie>PEOPLE</kbd-sortie>, etc.) Tous ces <SFB />s sont supprimés avec <NomPlus />, plus de
	nombreux autres encore plus rares.
</p>

<h3>
	Utilisation de la touche <kbd>,</kbd> + <kbd>Consonne</kbd>
</h3>
<p>
	La touche <kbd>,</kbd> est l’une des plus importantes dans <NomPlus />. C’est grâce à elle que la
	plupart des <SFB />s restants sont supprimés. De plus, certaines combinaisons ont aussi été
	ajoutées pour plus de confort, afin d’éviter de devoir sauter de 2 rangées avec des doigts
	consécutifs pour écrire un bigramme (donc éviter les <i>ciseaux</i>). C’est le cas de
	<kbd>CL</kbd>
	ou encore de <kbd>PH</kbd>.
</p>
<BlocClavier nom="virgule" />
<p>
	Comme vous pouvez le constater, la touche <kbd>,</kbd> est vraiment pour supprimer les derniers
	petits <SFB />s restants. La disposition <Nom /> éliminait déjà la majorité d’entre eux.
</p>

<h3>Utilisation des touches <kbd>È</kbd> et <kbd>Ê</kbd></h3>
<p>
	Les touches <kbd>È</kbd> et <kbd>Ê</kbd> permettent de se débarrasser des quelques <SFB />s se trouvant sur la main
	gauche. Plus particulièrement, ce sont les <SFB />s sur les touches
	<kbd>I</kbd>,
	<kbd>E</kbd>
	ainsi qu’en
	<kbd>U</kbd> :
</p>
<ul class="margin-top-2">
	<li>
		<kbd>ÈO</kbd> ➜ <kbd-sortie>OE</kbd-sortie> ;
	</li>
	<li>
		<kbd>ÈE</kbd> ou <kbd>ÊE</kbd> ➜ <kbd-sortie>EO</kbd-sortie> ;
	</li>
	<li>
		<kbd>È,</kbd> ou <kbd>Ê,</kbd> ➜ <kbd-sortie>U,</kbd-sortie> ;
	</li>
	<li>
		<kbd>È.</kbd> ou <kbd>Ê.</kbd> ➜ <kbd-sortie>U.</kbd-sortie> ;
	</li>
	<li>
		<kbd>ÈY</kbd> ➜ <kbd-sortie>IÉ</kbd-sortie> ;
	</li>
	<li>
		<kbd>YÈ</kbd> ➜ <kbd-sortie>ÉI</kbd-sortie>
	</li>
	<p>
		Idéalement, cela devrait plutôt être l’inverse afin d’être plus logique (le son YÈ donnant IÉ).
		Toutefois, <kbd-sortie>IÉ</kbd-sortie> étant beaucoup plus fréquent,
		il mérite d’avoir le roulement vers l’intérieur qui est plus confortable.
	</p>
</ul>
<h3>Utilisation de roulements</h3>
<ul class="margin-top-2">
	<li><kbd>ÊÉ</kbd> ➜ <kbd-sortie>AÎ</kbd-sortie> ;</li>
	<li><kbd>ÉÊ</kbd> ➜ <kbd-sortie>Â</kbd-sortie> ;</li>
	<li><kbd>P'</kbd> ➜ <kbd-sortie>CT</kbd-sortie>.</li>
</ul>

<h3>Touche <kbd>★</kbd> de répétition</h3>
<p>
	De nombreux <SFB />s se produisent non pas à cause de deux touches devant être tapées par le même
	doigt, mais lors de la répétition de la même touche. C’est par exemple le cas avec
	<kbd>LL</kbd>
	(elle, pelle, telle, etc.) ou encore <kbd>RR</kbd> (terre, erreur, etc.).
</p>
<p>
	Sur le logiciel Excel, la touche <kbd>F4</kbd> permet de répéter la dernière action. Ne pourrait-on
	pas avoir la même chose sur sa disposition clavier ?
</p>
<mini-espace />
<BlocClavier nom="magique" />
<mini-espace />
<p>
	La touche <kbd>★</kbd> est <span class="important">l’ajout principal de</span>
	<NomPlus /> et mérite son excellent emplacement sous l’index gauche. Elle vient en remplacement de
	la touche <kbd>J</kbd>
	(mais pas le contenu des autres couches de la touche <kbd>J</kbd> tel qu’en
	<kbd>AltGr</kbd>
	ou <kbd>Ctrl</kbd>). Le <kbd>J</kbd> se retrouve quant à lui en <kbd>,</kbd> + <kbd>Voyelle</kbd>.
</p>
<p>
	La nouvelle touche <kbd>★</kbd>
	<span class="important">va répéter la dernière touche tapée</span>. Ainsi, <kbd>L★</kbd>
	va envoyer
	<kbd-sortie>LL</kbd-sortie>, tandis que <kbd>R★</kbd> va envoyer <kbd-sortie>RR</kbd-sortie>. Cela
	engendrera cependant un petit <SFB></SFB> pour les lettres doublées suivies d’un <kbd>U</kbd>, tel
	que « connu » ou « battu ». La combinaison <kbd>★Ê</kbd> permet d’éviter ce problème. Ainsi, «
	connu » pourra s’écrire <kbd>CON★Ê</kbd> et « battu » pourra s’écrire <kbd>BAT★Ê</kbd>.
</p>
<p>
	L’utilisation de la touche <kbd>★</kbd> va instantanément fluidifier la fra<kbd>p★</kbd>e et
	réduire le nombre de <SFB />s. Une fois qu’on y est habitué, l’écriture au clavier devient encore
	un peu plus rapide et efficace, car même les lettres doublées peuvent être parallélisées. D’autant
	que
	<span class="important">doubler les lettres est loin d’être la seule fonction de la touche </span>
	<kbd>★</kbd>…
</p>
