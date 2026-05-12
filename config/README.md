# config/

Dossier monté en lecture/écriture dans le conteneur (`/home/claude/claude-yolo-config/`).

## `projects.settings.json` (ignoré par git)

État du wizard de configuration par-projet. Créé automatiquement par
`container/feature-wizard.sh` à la première ouverture d'un projet dans
Claude YOLO.

Format :

```json
{
  "version": 1,
  "projects": {
    "/mnt/c/Users/.../mon-projet": {
      "preset": "dotnet-vue",
      "plugins": ["claude-md-management@claude-plugins-official", "code-simplifier@claude-plugins-official"],
      "mcp":     ["fetch", "context7"],
      "skills":  [],
      "hooks":   {"rtk": true},
      "model":   null,
      "effortLevel": null,
      "createdAt": "2026-05-12T10:30:00Z",
      "lastUsed":  "2026-05-12T11:45:00Z"
    }
  }
}
```

Pour relancer le wizard sur un projet déjà configuré :

```bash
./tools/launch_shortcuts/run-claude.sh --reconfigure
```

Pour démarrer sans wizard (mode CI / batch) :

```bash
./tools/launch_shortcuts/run-claude.sh --no-prompt
```

## `config.json` (à la racine du repo)

Voir le README principal — `sourcesRoot` pour la racine du navigateur de projets.
