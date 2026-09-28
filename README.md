# Claudex Shell

A native macOS workspace for your local **Claude Code and Codex** conversations, with saved Claude, GLM/API-provider, and Codex accounts.

[简体中文](README.zh-Hans.md) · [Account behavior](docs/accounts.md) · [Protocol](docs/protocol.md)

## Conversations

- A complete Codex-style application shell: persistent navigation rail, back/forward titlebar, searchable conversation sidebar, History, Library, Images, Apps and Settings pages, plus a live outputs/agents/sources inspector.
- Native microphone dictation inserts text only after user authorization; it never sends a message automatically. Switching pages preserves unsent text and attachments. Library removal never deletes the original file.
- Choose **Claude** or **Codex** when starting a conversation. Existing conversations keep their engine, so their history and session IDs cannot accidentally be sent to the other CLI.
- Claude uses its local stream-JSON protocol. Codex uses its official stdio app-server protocol, including streaming replies, tool progress, approvals, stop, and resume.
- Local Claude and Codex histories appear together. Files and images can be attached to messages.
- **Continue with Claude** from a Codex conversation: start a genuine Claude Code session with a private context attachment containing the prior visible conversation. The source remains available and unchanged.

## Accounts

**Selecting an account changes Claudex Shell only.** The account menu separates selection from explicit external actions:

- **Push to terminal** applies the selected Claude/GLM configuration or Codex login to the corresponding local CLI.
- **Push to Codex App** applies a saved Codex login to the shared local Codex authentication store. Codex CLI also uses that store; an already-running desktop client may need to be reopened by the user.
- **Save local login states** imports local Claude, GLM/API-provider, and Codex credentials. Secrets are kept in the login Keychain or private CLI runtime files, not in account-list metadata.
- Explicit pushes save a recoverable previous state. Claudex Shell never restarts the user's terminal or Codex desktop client.

The app retains its existing bundle identifier and legacy `~/Library/Application Support/Claude Shell/` metadata paths so upgrading the display name does not discard saved accounts, titles, or settings. See [accounts.md](docs/accounts.md) for storage and compatibility details.

## Build and install

Requires macOS 15+, Xcode, XcodeGen, and the CLI for each engine you use. No third-party Swift dependencies.

```sh
./scripts/build.sh             # Debug build, no launch
./scripts/build.sh Release
./scripts/test.sh              # Isolated regression fixtures, no live account changes
./scripts/install.sh           # Install /Applications/Claudex Shell.app, no launch or Dock changes
```

If the destination app is running, installation stops and preserves it. The old `Claude Shell.app` is left intact during the rename.

Shortcuts: ⌘K search · ⌘[/⌘] back/forward · ⌃⌘S toggle sidebar · ⌥⌘I inspector · ⌘N new conversation · ⇧⌘N choose a folder · ⏎ send · ⇧⏎ newline · ⌘. stop · ⌘R refresh · ⌃1…⌃9 select Claude account.

## Layout

```text
App/Sources/Engine/   Claude stream-JSON, Codex app-server, local credentials
App/Sources/Model/    accounts, sessions, conversation state, attachments
App/Sources/UI/       SwiftUI sidebar, composer, approvals, account controls
App/Resources/web/   offline Markdown transcript renderer
docs/                protocol and account semantics
```

The visual reference is the user-supplied full Codex desktop shell; see [DESIGN.md](DESIGN.md). Cloud Apps marketplace, cloud synchronization and a standalone image-generation service are not emulated. The app uses the tools configured in each native engine, displays truthful availability, and manages local files.
