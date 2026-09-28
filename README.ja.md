# Claudex Shell

Claude Code と Codex のためのネイティブ macOS ワークスペース。

アカウント選択は Claudex Shell 内だけに適用されます。ターミナルへの反映と Codex App への反映は別の明示的な操作です。Claude、GLM、Codex のローカル認証状態を保存できます。Codex CLI とデスクトップアプリは認証キャッシュを共有するため、起動中のクライアントは再度開く必要がある場合があります。

[English — full documentation](README.md) · [简体中文](README.zh-Hans.md)

```sh
./scripts/build.sh Release
./scripts/test.sh
./scripts/install.sh
```

macOS 15+ · Swift 6 · XcodeGen
