# Claude Shell

*Una carcasa nativa discreta sobre el Claude Code que ya usas.*

[English](README.md) · [简体中文](README.zh-Hans.md) · [繁體中文](README.zh-Hant.md) · [Français](README.fr.md) · [日本語](README.ja.md) · **Español** · [Deutsch](README.de.md)

Claude Shell es una pequeña app de macOS que le pone a tu Claude Code local una cara al estilo de Codex. A la izquierda: todas las sesiones de `~/.claude/projects`, agrupadas por proyecto — incluidas las que iniciaste en una terminal. A la derecha: la conversación actual, con texto en Markdown, pasos de razonamiento y de herramientas plegables, y tarjetas de permisos. Por debajo no es más que `~/.local/bin/claude`, así que el modelo, los modos de permiso, `CLAUDE.md`, la memoria, las skills, los servidores MCP y los hooks son exactamente los mismos que en tu terminal.

## Solo una carcasa — y ahí está la gracia

No reimplementa Claude Code. No trae su propio cliente de modelo, ni una autenticación aparte, ni una segunda copia de tus datos. Lanza el mismo binario `claude` en el que ya confías y lee los mismos archivos de sesión que este ya escribe. La app solo guarda para sí tres cositas — un título renombrado, una marca de oculto y los ajustes por conversación — bajo `~/Library/Application Support/Claude Shell/`. Las conversaciones en sí viven siempre en `~/.claude`, y nada sale de tu equipo que la línea de comandos no fuera a enviar de todos modos.

Así obtienes una ventana nativa de verdad — un icono en el Dock, ⌘N, un campo de texto como es debido — sin conceder a nada una vista más amplia de tus archivos o tus datos que la que la línea de comandos ya tiene. El mismo límite de confianza, con mejor superficie.

## Qué hace

- **Sigue tu terminal, en directo.** Una sesión en marcha en una terminal muestra un punto verde; ábrela y Claude Shell sigue el archivo de sesión, de modo que cada paso del otro lado aparece aquí en tiempo real.
- **Responde de vuelta en la terminal.** Escribe en una sesión de terminal activa y tu mensaje se le entrega mediante la mensajería entre sesiones del propio Claude Code — la terminal responde y la respuesta se sincroniza aquí.
- **Muestra lo que muestra la terminal.** Resúmenes recap, mensajes de tus otras sesiones, entrada en cola, avisos de compactación de contexto y el nivel de esfuerzo en la línea de razonamiento.
- **Modelo y esfuerzo explícitos.** Las píldoras y la barra de herramientas siempre muestran el valor realmente en vigor (`Opus 5 (1M) · xhigh`), incluido `ultracode` — nada escondido tras un «seguir los ajustes».
- **Un proceso por conversación**, mantenido caliente y reanudado con `--resume` tras quedar inactivo.

## Ejecutar

```
./scripts/build.sh            # build Debug en DerivedData/
./scripts/install.sh          # build Release → /Applications → añadir al Dock
./scripts/shot.sh out.png     # captura la ventana en ejecución
```

Atajos: ⌘N nuevo · ⇧⌘N nuevo-en-carpeta · ⏎ enviar · ⇧⏎ salto de línea · ⌘. detener · ⌘R actualizar.

## Por dentro

- Swift 6 + SwiftUI + AppKit, proyecto generado con XcodeGen, sin dependencias Swift de terceros.
- El texto se renderiza en una `WKWebView` con marked + highlight.js incluidos sin conexión.
- Sin sandbox (lanza un proceso hijo y lee `~/.claude`), firmada para ejecución local.
- La entrega entre sesiones, el protocolo stream-json y el sistema de diseño están documentados en `docs/` y `DESIGN.md`.

## Estructura

```
App/Sources/Engine/   proceso hijo, stream-json → eventos, entrega entre sesiones
App/Sources/Model/    una conversación, la lista de sesiones, el modelo del transcript
App/Sources/UI/       barra lateral, vista de hilo, compositor, tarjeta de permisos, tema
App/Resources/web/    transcript.html / .css / .js — el texto de las conversaciones
docs/ · DESIGN.md · PRODUCT.md   notas de protocolo, sistema de diseño, registro de producto
```

Requiere macOS 15+ y una instalación funcional de Claude Code (`~/.local/bin/claude`).
