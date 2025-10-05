L’installation sur macOS ne fonctionne pas avec la méthode recommandée, cliquer sur l’application ne l’affiche pas dans la barre des tâches.
résolution:

A simple espanso service register fixed the issue.

If espanso is not yet in your terminal, you can run

/Applications/Espanso.app/Contents/MacOS/espanso service register

From then on, the espanso command should be globally accessible.
