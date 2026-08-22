# Audit de performance — AutoHotkey

Point d’entrée compatible pour un agent sans découverte automatique des skills.
Lis [`perf-profiling/SKILL.md`](../../.agents/skills/perf-profiling/SKILL.md), puis
[la référence AHK](../../.agents/skills/perf-profiling/references/ahk.md).

Mesure le code actuel avant toute proposition. Résous le vrai dossier de logs,
tiens compte des seuils propres à chaque segment et de l’attribution
imbriquée/exclusive du profiler, et distingue chiffres observés, complexité et
hypothèses.

Écris le rapport sous
`docs/audits/performance/ahk/<YYYY_MM_DD>/report.md` sans écraser une passe
existante. Cet audit ne modifie pas le driver et ne pousse rien.
