# Claude Shell

*Une coque native discrète par-dessus le Claude Code que vous utilisez déjà.*

[English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · **Français** · [日本語](README.ja.md) · [Español](README.es.md) · [Deutsch](README.de.md)

Claude Shell est une petite app macOS qui donne à votre Claude Code local une allure à la Codex. À gauche : toutes les sessions de `~/.claude/projects`, regroupées par projet — y compris celles lancées dans un terminal. À droite : la conversation en cours, avec du Markdown, des étapes de réflexion et d'outils repliables, et des cartes d'autorisation. En dessous, ce n'est que `~/.local/bin/claude` : le modèle, les modes d'autorisation, `CLAUDE.md`, la mémoire, les compétences, les serveurs MCP et les hooks sont exactement ceux de votre terminal.

## Juste une coque — et c'est tout l'intérêt

Elle ne réimplémente pas Claude Code. Pas de client de modèle maison, pas d'authentification séparée, pas de deuxième copie de vos données. Elle lance le même binaire `claude` auquel vous faites déjà confiance et lit les mêmes fichiers de session qu'il écrit déjà. L'app ne conserve pour elle-même que quatre toutes petites choses — un titre renommé, un indicateur « masqué », les réglages par conversation et la liste des comptes que vous avez enregistrés (identités dans un fichier JSON, jetons dans votre trousseau de session) — sous `~/Library/Application Support/Claude Shell/`. Les conversations, elles, résident toujours dans `~/.claude`, et rien ne quitte votre machine que la ligne de commande n'enverrait de toute façon.

Vous obtenez donc une vraie fenêtre native — une icône dans le Dock, ⌘N, un vrai champ de texte — sans accorder à quoi que ce soit une vue plus large sur vos fichiers ou vos données que celle qu'a déjà la ligne de commande. Même périmètre de confiance, une meilleure surface.

## Ce qu'elle fait

- **Elle suit votre terminal, en direct.** Une session lancée dans un terminal affiche une pastille verte ; ouvrez-la et Claude Shell suit le fichier de session, si bien que chaque étape de l'autre côté apparaît ici en temps réel.
- **Elle répond dans le terminal.** Écrivez dans une session de terminal active et votre message y est livré via la messagerie inter-sessions de Claude Code — le terminal répond, et la réponse se synchronise ici.
- **Elle montre ce que montre le terminal.** Les résumés recap, les messages de vos autres sessions, la saisie mise en file, les notes de compactage de contexte, et le niveau d'effort sur la ligne de réflexion.
- **Glissez des fichiers et des photos, collez des captures.** Glissez des fichiers, des photos ou des dossiers entiers sur la fenêtre (ou cliquez le « + » du composeur, ou ⌘V une capture d'écran) : ils s'attachent au message en cours. Les images arrivent à Claude sous forme de blocs image (HEIC et consorts sont convertis en JPEG et réduits à la limite de l'API) ; fichiers et dossiers sont référencés comme Claude Code le fait lui-même, en `@chemin` — les fichiers texte et le contenu des dossiers sont joints automatiquement, les PDF et autres, Claude les lit lui-même. Les images collées dans le terminal apparaissent ici aussi en vignettes.
- **Modèle et effort explicites.** Les pastilles et la barre d'outils affichent toujours la valeur réellement en vigueur (`Opus 5 (1M) · xhigh`), y compris `ultracode` — rien de caché derrière un « suivre les réglages ».
- **Un processus par conversation**, gardé au chaud et repris avec `--resume` après une période d'inactivité.
- **Plusieurs comptes, un clic pour changer.** Ajoutez un second compte Claude une seule fois (le `claude auth login` de la CLI, dans le navigateur) ; ensuite, choisissez un compte en bas de la barre latérale ou appuyez sur ⌃1…⌃9. Le changement réécrit la connexion enregistrée dans l'entrée de trousseau de Claude Code lui-même, donc le terminal suit aussi — les sessions déjà ouvertes basculent dès leur requête suivante, sans redémarrage, sans navigateur, sans reconnexion.

## Lancer

```
./scripts/build.sh            # build Debug dans DerivedData/
./scripts/install.sh          # build Release → /Applications → ajout au Dock
./scripts/shot.sh out.png     # capture la fenêtre en cours d'exécution
```

Raccourcis : ⌘N nouveau · ⇧⌘N nouveau-dans-le-dossier · ⏎ envoyer · ⇧⏎ retour ligne · ⌘. arrêter · ⌘R rafraîchir · ⌃1…⌃9 changer de compte.

## Sous le capot

- Swift 6 + SwiftUI + AppKit, projet généré par XcodeGen, sans dépendance Swift tierce.
- Le texte est rendu dans une `WKWebView` avec marked + highlight.js embarqués hors ligne.
- Pas de sandbox (elle lance un processus enfant et lit `~/.claude`), signée pour un usage local.
- La livraison inter-sessions, le protocole stream-json, le changement de compte et le système de design sont documentés dans `docs/` et `DESIGN.md`.

## Structure

```
App/Sources/Engine/   processus enfant, stream-json → événements, livraison inter-sessions
App/Sources/Model/    une conversation, la liste des sessions, le modèle de transcript
App/Sources/UI/       barre latérale, vue de fil, composeur, carte d'autorisation, thème
App/Resources/web/    transcript.html / .css / .js — le texte des conversations
docs/ · DESIGN.md · PRODUCT.md   notes de protocole, système de design, journal produit
```

Nécessite macOS 15+ et une installation fonctionnelle de Claude Code (`~/.local/bin/claude`).
