# Workspace

Mode: Operate. Native macOS 15+, SwiftUI/AppKit/WebKit.

Pinned visual authority: the two user screenshots provided 2026-09-28 04:28:37 and 04:29:01. Match the complete application: 52pt persistent rail, 288pt secondary sidebar, 44pt global titlebar, rounded main surface, 300pt right inspector. Normal desktop thread-only static metrics are subordinate when they conflict with these screenshots. No visual concept tournament; the user chose Codex.

Success: rail, all corresponding local pages, back/forward, conversation navigation, search, inspector, account controls and native engines all remain usable. No decorative dead destinations. Cloud-only functionality must be explained accurately, not represented as a successful fake integration.

Persistent constraints: no app/window activation, order-front, screen/input control or visible previews during development and QA; use pure in-memory fixtures and prohibited-activation offscreen hosts. Never invoke Chrome, Superpowers or Teacher. The reference variant includes real native titlebar controls in an unordered titled window; inactive control colors are expected and no controls are drawn imitations.

Build fully, run one batched 17-frame review, fix concrete findings together, and confirm once. Fresh reviewer compares directly with both supplied screenshot references and checks functional navigation paths. Regression tests exercise navigation branching, private answer export, transcript-derived outputs/sources/agents and existing native-engine/account fixtures.
