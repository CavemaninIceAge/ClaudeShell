# Claude Shell

*Eine ruhige native Hülle um das Claude Code, das du ohnehin schon nutzt.*

[English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · [Français](README.fr.md) · [日本語](README.ja.md) · [Español](README.es.md) · **Deutsch**

Claude Shell ist eine kleine macOS-App, die deiner lokalen Claude-Code-CLI ein Gesicht im Codex-Stil gibt. Links: alle Sitzungen unter `~/.claude/projects`, nach Projekt gruppiert — auch die, die du in einem Terminal gestartet hast. Rechts: die aktuelle Unterhaltung mit Markdown-Text, einklappbaren Denk- und Werkzeugschritten und Berechtigungskarten. Darunter läuft nur `~/.local/bin/claude`, also sind Modell, Berechtigungsmodi, `CLAUDE.md`, Gedächtnis, Skills, MCP-Server und Hooks genau die, die du schon im Terminal hast.

## Nur eine Hülle — und genau das ist der Punkt

Sie setzt Claude Code nicht neu um. Kein eigener Modell-Client, keine separate Anmeldung, keine zweite Kopie deiner Daten. Sie startet dasselbe `claude`-Binary, dem du ohnehin vertraust, und liest dieselben Sitzungsdateien, die es ohnehin schreibt. Die App selbst bewahrt nur vier winzige Dinge auf — einen umbenannten Titel, ein Ausblenden-Flag, die Einstellungen pro Unterhaltung und die Liste deiner gespeicherten Konten (Identitäten in einer JSON-Datei, Tokens in deinem Anmelde-Schlüsselbund) — unter `~/Library/Application Support/Claude Shell/`. Die Unterhaltungen selbst liegen immer in `~/.claude`, und nichts verlässt deinen Rechner, was die Kommandozeile nicht ohnehin senden würde.

So bekommst du ein echtes natives Fenster — ein Dock-Symbol, ⌘N, ein ordentliches Textfeld — ohne irgendetwas einen weiteren Blick auf deine Dateien oder Daten zu gewähren, als die Kommandozeile ihn bereits hat. Dieselbe Vertrauensgrenze, nur eine schönere Oberfläche.

## Was sie kann

- **Folgt deinem Terminal, live.** Eine im Terminal laufende Sitzung zeigt einen grünen Punkt; öffne sie, und Claude Shell verfolgt die Sitzungsdatei, sodass jeder Schritt der Gegenseite hier in Echtzeit erscheint.
- **Antwortet ins Terminal zurück.** Tippe in eine laufende Terminal-Sitzung, und deine Nachricht wird ihr über das sitzungsübergreifende Messaging von Claude Code zugestellt — das Terminal antwortet, und die Antwort wird hierher synchronisiert.
- **Zeigt, was das Terminal zeigt.** recap-Zusammenfassungen, Nachrichten aus deinen anderen Sitzungen, eingereihte Eingaben, Hinweise zur Kontextverdichtung und die Effort-Stufe in der Denkzeile.
- **Modell und Effort explizit.** Die Pillen und die Symbolleiste zeigen stets den tatsächlich wirksamen Wert (`Opus 5 (1M) · xhigh`), auch `ultracode` — nichts versteckt hinter „Einstellungen folgen".
- **Ein Prozess pro Unterhaltung**, warm gehalten und nach Leerlauf mit `--resume` fortgesetzt.
- **Mehrere Konten, ein Klick zum Wechseln.** Ein zweites Claude-Konto fügst du einmal hinzu (das `claude auth login` der CLI, im Browser); danach wählst du unten in der Seitenleiste ein Konto oder drückst ⌃1…⌃9. Der Wechsel schreibt die gespeicherte Anmeldung in den Schlüsselbund-Eintrag von Claude Code selbst zurück, sodass das Terminal mitzieht — bereits laufende Sitzungen wechseln mit ihrer nächsten Anfrage, ohne Neustart, ohne Browser, ohne erneute Anmeldung.

## Starten

```
./scripts/build.sh            # Debug-Build nach DerivedData/
./scripts/install.sh          # Release-Build → /Applications → zum Dock hinzufügen
./scripts/shot.sh out.png     # Screenshot des laufenden Fensters
```

Kurzbefehle: ⌘N neu · ⇧⌘N neu-im-Ordner · ⏎ senden · ⇧⏎ Zeilenumbruch · ⌘. stoppen · ⌘R aktualisieren · ⌃1…⌃9 Konto wechseln.

## Unter der Haube

- Swift 6 + SwiftUI + AppKit, Projekt per XcodeGen erzeugt, keine Swift-Abhängigkeiten von Dritten.
- Der Text wird in einer `WKWebView` mit offline eingebettetem marked + highlight.js gerendert.
- Keine Sandbox (startet einen Kindprozess und liest `~/.claude`), zum lokalen Ausführen signiert.
- Die sitzungsübergreifende Zustellung, das stream-json-Protokoll, der Kontowechsel und das Designsystem sind in `docs/` und `DESIGN.md` beschrieben.

## Aufbau

```
App/Sources/Engine/   Kindprozess, stream-json → Ereignisse, sitzungsübergreifende Zustellung
App/Sources/Model/    eine Unterhaltung, die Sitzungsliste, das Transcript-Modell
App/Sources/UI/       Seitenleiste, Thread-Ansicht, Composer, Berechtigungskarte, Theme
App/Resources/web/    transcript.html / .css / .js — der Unterhaltungstext
docs/ · DESIGN.md · PRODUCT.md   Protokollnotizen, Designsystem, Produktnotizen
```

Benötigt macOS 15+ und eine funktionierende Claude-Code-Installation (`~/.local/bin/claude`).
