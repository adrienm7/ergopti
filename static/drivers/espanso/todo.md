    - trigger: "sx"
      replace: "sk"
      propagate_case: true
    - trigger: "hc"
      replace: "wh"
      propagate_case: true
créer un fichier avec les rolls. fichier à n'utiliser qe si l'on n'a pas d'autres choix. car il envoie en sendinput et on ne peut pas utiliser d'autre remplacement de texte dessus

mettre en commun les listes de hotstrings d'alfred, espanso, etc.

l'extension doit être en .yml et pas .yaml

créer un fichier de repeat key avec lettre devant + lettre + ★ au lieu de simplement lettre + ★
  - trigger: "ct★"
  # TODO: auto create this file and remove conflicts by looking at the other file
    replace: "ctt"
    propagate_case: true

si trigger avec une seule lettre, forcer que majuscule c'est en titlecase et non caps

Il faut trouver un autre moyen de mettre ★ sur la touche j, car sur vscode de macos et de linux cela entraine que ctrl s est trouvé comme ctrl j