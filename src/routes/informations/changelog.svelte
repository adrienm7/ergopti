<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<h2>Changelog</h2>

<h3>Version 2.2 (Septembre 2025)</h3>
<p>
	Le changement le plus visible d’<Nom></Nom> v2.2 est l’interversion de la touche <kbd>€</kbd> avec
	la touche <kbd>%</kbd>. Celle-ci a été réalisée, car le <kbd>%</kbd> est beaucoup plus fréquemment
	utilisé que le <kbd>€</kbd>, que ce soit dans la vie quotidienne et en programmation. Ainsi, il
	fallait que la touche la plus facile d’accès des deux (celle située le plus vers l’intérieur du
	clavier) soit aussi la plus utile. En outre, le touche <kbd>€</kbd> a été modifaée pour mettre le
	<kbd-sortie>€</kbd-sortie> en AltGr et placer le <kbd-sortie>$</kbd-sortie> en accès direct. Ici encore,
	c’est parce que ce caractère est beaucoup plus utilisé, que ce soit en tant que monnaiee, mais aussi
	en programmation ou sur Excel par exemple.
</p>
<p>
	Le deuxième changement, moins visible, est une amélioration des touches mortes. Celles-ci sont
	désormais beaucoup plus complètes et plus logiquement agencées.
</p>
<p>
	Enfin, un gros changement concerne <NomPlus></NomPlus> où le code AutoHotKey a été complètement refactoré.
	Celui-ci est désormais beaucoup plus simple et robuste. En outre, chaque feature peut désormais s’activer
	ou se désactiver grâce à la création d’un menu de configuration apparaissant lors du clic sur l’icône
	du script dans la barre des taches. Cette nouvelle version permet à tout le monde d’utiliser des raccourcis,
	la couche de symboles, les chiffres en accès direct, etc. à la carte, quelle que soit sa disposition
	actuelle. Ainsi, même une personne utilisant AZERTY et ne souhaitant pas apprendre <Nom></Nom> peut
	avoir à sa disposition ces nombreuses features.
</p>

<h3>Version 2.1 (Janvier 2025)</h3>
<p>
	<Nom></Nom> v2.1 intervertit le <kbd>C</kbd> et le <kbd>G</kbd>. Les résultats sur les analyseurs
	sont tous un peu moins bons avec ce changement, car le <SFB></SFB> <kbd>CT</kbd> est plus fréquent
	que l'ancien qui était <kbd>SC</kbd> et intervient sur l’annulaire au lieu de l’index.
</p>
<p>
	Cependant, cette modification était importante à réaliser, car le <kbd>C</kbd> est désormais plus
	accessible. C’est, tout comme le passage en v2.0, une histoire de longueur des doigts. En outre,
	le roulement <kbd>CH</kbd> s’en trouve être beaucoup plus confortable, étant désormais un
	roulement vers l’intérieur. Une autre amélioration est que le <kbd>C</kbd> n’est plus sur le même
	doigt que le <kbd>D</kbd>, ce qui permet de taper la commande <kbd-sortie>cd</kbd-sortie> (change
	directory) sans <SFB></SFB>.
</p>

<h3>Version 2.0 (Janvier 2025)</h3>
<p>
	<Nom></Nom> v2.0 est une évolution majeure de la disposition, d’où le changement de numérotation. La
	modification est en réalité très simple :
	<strong>interversion de la rangée inférieure de la main droite avec la rangée supérieure</strong>.
</p>
<p>Ce changement n’est pas anodin et apporte les bénéfices suivants :</p>
<ul>
	<li>bigrammes <kbd>TH</kbd> et <kbd>SH</kbd> beaucoup plus confortables sur clavier ISO ;</li>
	<li>bigramme <kbd>ND</kbd> beaucoup plus confortable ;</li>
	<li>
		positionnement du <kbd>M</kbd> plus près du <kbd>P</kbd>, car désormais sur la même rangée et
		non plus à 2 rangées d’écart.
	</li>
</ul>
<br />
<p>
	Ce changement n’a pas été pris à la légère, celui-ci faisant bouger 8 touches. Il n’améliore en
	plus même pas le taux de <SFB></SFB>s, car les touches assignées à chaque doigt restent les mêmes.
	C’est vraiment une interversion de confort pour taper des bigrammes.
</p>
<p>
	Elle demeure une évolution souhaitable, car le bigramme <kbd>TH</kbd> est <b>de loin</b> le plus
	fréquent en anglais. <kbd>ND</kbd> est lui aussi extrêmement fréquent, en particulier en anglais,
	et prend la place de <kbd>NC</kbd> dont la fréquence d’apparition est en comparaison minime.
</p>
<p>
	La raison pour laquelle le <kbd>TH</kbd> est beaucoup plus confortable avec la version 2.0 est que
	le majeur et l’annulaire étant des doigts longs, ils ont plus de facilité à atteindre la rangée
	supérieure que celle inférieure. Au contraire, l’index étant un peu plus court, c’est la rangée
	inférieure qui est plus accessible pour ce doigt. C’est d’ailleurs aussi pour cela que la touche
	<kbd>★</kbd> a été placée sur l’index gauche en rangée du bas et non du haut : car cette position est
	la plus confortable.
</p>
<p>
	Le <kbd>L</kbd>, très fréquent en français mais moins en anglais, est donc sur une touche un peu
	moins accessible. Cela permet au <kbd>H</kbd>, une lettre à la fréquence extrêmement forte en
	anglais et fréquence moyenne-faible en français, d’être plus accessible.
</p>
<br />
<p>
	En résumé, la version 2.0 d’<Nom></Nom> conserve ses excellents scores en alternance des mains, distance
	parcourue, minimisation des <SFB></SFB>s, etc. Toutefois, elle
	<strong>est désormais beaucoup plus confortable pour l’écriture de l’anglais</strong>.
</p>

<h3>Version 1.1 (Octobre 2024)</h3>
<p>
	<Nom></Nom> v1.1 est la première version de la disposition à être dévoilée au public. Elle fige enfin
	les quelques lettres qui changeaient au fil des versions de test v1.0.x pour une disposition stable
	suite à tous ces essais.
</p>
