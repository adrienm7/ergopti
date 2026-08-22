# Audit adversarial — AutoHotkey

Ce fichier est un point d’entrée léger, utilisable par un agent qui ne découvre
pas automatiquement les skills du dépôt. La procédure canonique n’est pas
dupliquée ici : lis, dans cet ordre,

1. [`adversarial-audit/SKILL.md`](../../.agents/skills/adversarial-audit/SKILL.md) ;
2. [la référence AHK](../../.agents/skills/adversarial-audit/references/ahk.md) ;
3. [le contrat du rapport](../../.agents/skills/adversarial-audit/references/report-contract.md).

Exécute ensuite un audit AHK uniquement. Reproduis et re-dérive chaque preuve
depuis le code, les tests ou les artefacts actuels. Une hypothèse sans
reproduction reste une hypothèse et n’entre pas dans `findings.json`.

Produis le nouveau rapport sous
`docs/audits/ahk/<YYYY_MM_DD>/{report.md,findings.json}`, puis valide le manifeste
avec `node tools/audit/workflow.cjs validate-report --report <findings.json>`.
N’écrase aucun rapport existant, n’implémente aucune correction et ne pousse
rien.
