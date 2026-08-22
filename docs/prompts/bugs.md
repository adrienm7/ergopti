# Audit adversarial — point d’entrée générique

Pour un driver, utilise le point d’entrée spécialisé :

- [AutoHotkey](bugs_ahk.md)
- [Hammerspoon](bugs_hs.md)

Pour Linux, le site ou l’outillage, lis la méthode partagée dans
[`adversarial-audit/SKILL.md`](../../.agents/skills/adversarial-audit/SKILL.md),
puis les instructions et la mémoire du périmètre concerné.

Cartographie les entrées et les flux de bout en bout, attaque chaque frontière
asynchrone et vérifie les fixes récents jusqu’aux sites frères. Re-dérive chaque
preuve depuis l’artefact actuel, cherche les tests qui confirment ou réfutent
l’hypothèse, et sépare sévérité, confiance et provenance. Une hypothèse sans
reproduction n’est pas un finding.

Le rapport doit distinguer findings confirmés, hypothèses réfutées, mesures,
watch-list mémoire et couverture explicite. Un audit ne modifie pas le code et
ne pousse rien sans demande séparée d’implémentation.
