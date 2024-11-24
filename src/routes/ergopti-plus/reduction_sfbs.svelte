<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
</script>

<h2>Diminution des SFBs</h2>
<p>L’un des avantages majeurs de <NomPlus /> est qu’il réduit presque totalement les <SFB />s.</p>
<p>
	Les <SFB />s les plus fréquents de la disposition sont : <kbd>SC</kbd>,
	<kbd>PT</kbd>, <kbd>EO</kbd>, <kbd>OE</kbd>,
	<kbd>UB</kbd>, <kbd>BU</kbd> et <kbd>GT</kbd>. <kbd>SC</kbd> est de loin le plus fréquent. En
	outre, <kbd>EO</kbd> et
	<kbd>OE</kbd> sont également relativement fréquents en anglais (pour écrire
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
	consécutifs pour écrire un bigramme. C’est le cas de <kbd>CL</kbd> ou encore de <kbd>PH</kbd>.
</p>
<ul class="margin-top-2">
	<li><kbd>,C</kbd> ➜ <kbd-sortie>CD</kbd-sortie> ;</li>
	<li><kbd>,D</kbd> ➜ <kbd-sortie>DS</kbd-sortie> ;</li>
	<li><kbd>,F</kbd> ➜ <kbd-sortie>FS</kbd-sortie> ;</li>
	<li><kbd>,G</kbd> ➜ <kbd-sortie>GL</kbd-sortie> ;</li>
	<li><kbd>,H</kbd> ➜ <kbd-sortie>PH</kbd-sortie> ;</li>
	<li><kbd>,L</kbd> ➜ <kbd-sortie>CL</kbd-sortie> ;</li>
	<li><kbd>,M</kbd> ➜ <kbd-sortie>MPL</kbd-sortie> ;</li>
	<li><kbd>,N</kbd> ➜ <kbd-sortie>NL</kbd-sortie> ;</li>
	<li><kbd>,P</kbd> ➜ <kbd-sortie>XP</kbd-sortie> ;</li>
	<li><kbd>,Q</kbd> ➜ <kbd-sortie>QU’</kbd-sortie> ;</li>
	<li><kbd>,R</kbd> ➜ <kbd-sortie>RQ</kbd-sortie> ;</li>
	<li><kbd>,S</kbd> ➜ <kbd-sortie>SC</kbd-sortie> ;</li>
	<li><kbd>,T</kbd> ➜ <kbd-sortie>PT</kbd-sortie> ;</li>
	<li><kbd>,V</kbd> ➜ <kbd-sortie>DV</kbd-sortie> ;</li>
	<li><kbd>,X</kbd> ➜ <kbd-sortie>'RE</kbd-sortie>, utilisé en anglais (we're) ;</li>
	<li>
		<kbd>,Y</kbd> ➜ <kbd-sortie>YI</kbd-sortie> pour tous les
		<span class="hyper text-bold">YI</span> en anglais ;
	</li>
	<li><kbd>,'</kbd> ➜ <kbd-sortie>J’</kbd-sortie>.</li>
</ul>
<p>
	Comme vous pouvez le constater, la touche <kbd>,</kbd> est vraiment pour supprimer les derniers
	petits <SFB />s restants. La disposition <Nom /> éliminait déjà la majorité d’entre eux.
</p>

<h3>Utilisation de la touche <kbd>È</kbd></h3>
<p>
	La touche <kbd>È</kbd> permet de se débarrasser des quelques <SFB />s se trouvant sur la main
	gauche. Plus particulièrement, ce sont les <SFB />s se sur les touches
	<kbd>I</kbd>,
	<kbd>E</kbd>
	ainsi qu’en
	<kbd>U</kbd> :
</p>
<ul class="margin-top-2">
	<li>
		<kbd>ÈO</kbd> ➜ <kbd-sortie>EO</kbd-sortie> et <kbd>ÈE</kbd> ➜ <kbd-sortie>OE</kbd-sortie> ;
	</li>
	<li>
		<kbd>È,</kbd> ➜ <kbd-sortie>U,</kbd-sortie> et <kbd>È.</kbd> ➜ <kbd-sortie>U.</kbd-sortie> ;
	</li>
	<li>
		<kbd>ÈY</kbd> ➜ <kbd-sortie>IÉ</kbd-sortie> et <kbd>YÈ</kbd> ➜ <kbd-sortie>ÉI</kbd-sortie>.
	</li>
	<p>
		Même si, idéalement, cela devrait plutôt être l’inverse afin d’être plus logique (le son YÈ
		donnant IÉ). Toutefois,
		<kbd-sortie>IÉ</kbd-sortie> étant beaucoup plus fréquent, il mérite d’avoir le roulement vers l’intérieur
		qui est beaucoup plus confortable.
	</p>
</ul>
<h3>Utilisation de roulements</h3>
<ul class="margin-top-2">
	<li><kbd>ÊÉ</kbd> ➜ <kbd-sortie>AÎ</kbd-sortie> ;</li>
	<li><kbd>ÉÊ</kbd> ➜ <kbd-sortie>Â</kbd-sortie> ;</li>
	<li><kbd>GX</kbd> ➜ <kbd-sortie>GT</kbd-sortie>.</li>
</ul>
<p>
	Le bigramme <kbd>GT</kbd> est remplacé par le roulement <kbd>GX</kbd>. Ce roulement est très
	confortable et plus judicieux que l’utilisation d’une combinaison avec la touche <kbd>,</kbd>, car
	réaliser <kbd>NGT</kbd> (comme dans VI<span class="hyper text-bold">NGT</span>) devient alors très
	rapide. Cependant, ce roulement empêche dans le même temps d’écrire normalement
	<kbd-sortie>GX</kbd-sortie> (par exemple pour écrire "Yu-Gi-Oh GX"). Les autres remplacements sont
	quant à eux sur des combinaisons qui ne sont a priori jamais réalisées.
</p>

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
	La touche <kbd>★</kbd> est <span class="important">l’ajout majeur de</span>
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
	<span class="important"
		>doubler les lettres est loin d’être la seule fonction de la touche
	</span><kbd>★</kbd>…
</p>
