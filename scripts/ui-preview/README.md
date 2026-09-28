# Offline workspace previews

Run `scripts/ui-preview/render.sh` after UI edits are stable. The default output is `.impeccable/review/workspace/`.

The harness renders the **actual production `WorkspaceView`**, `SidebarView`, `ThreadView`, composer, and transcript resources. It does not rebuild the interface in an independent mock. Ten PNGs cover empty and populated conversation states at 1200×800 and 880×560, each in light and dark appearance, plus two rich Markdown cases (1200×800 light and 880×560 dark) with a three-line Swift code block and a two-row table.

All identity/history/transcript inputs are synthetic in-memory snapshots. `WorkspaceView` has no bootstrap task. The fixture constructors do not read credentials or real session files, persist preferences, register timers, or start engines. Cocoa preferences use a disposable directory through `CFFIXED_USER_HOME`; `HOME` is unchanged. No app/window is ordered, activated, focused, or made key. No global input is sent.

Native views render using `NSView.cacheDisplay`. WebKit remote-layer caching varies by OS version: the native bitmap may already contain part or all of its paint. Before compositing the **same production WKWebView** snapshot at its real view coordinates, the harness replaces that rectangle with opaque, appearance-resolved `Theme.background`. This prevents doubled text and translucent bubble opacity. This is screenshot composition, not a replacement transcript implementation. The preview intentionally excludes operating-system window chrome; it captures the production workspace itself.

`workspace-preview.json` records dimensions, appearance, web overflow metrics, and checks that each window remained invisible/non-key/non-main. Verify these fields and inspect the PNGs before accepting the UI. These static images do not establish native engine or account behavior; use `scripts/test.sh` for those fixtures.
