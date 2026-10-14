[English](README.md) | **日本語**

# star-forge

**Solcast**・**Snapsol**・**Thor** 共通の配布用リポジトリです。

## リリース
リリースはアプリ名付きのタグで管理します:
- `solcast-vX.Y.Z`
- `snapsol-vX.Y.Z`
- `thor-vX.Y.Z`

## Sparkle appcast
appcast は GitHub Pages の `/<app>/appcast.xml` で配信します:
- https://sol-momma.github.io/star-forge/solcast/appcast.xml
- https://sol-momma.github.io/star-forge/snapsol/appcast.xml
- https://sol-momma.github.io/star-forge/thor/appcast.xml

このリポジトリには秘密情報を置きません。

## リリーススクリプト
`scripts/release.sh` でリリースを公開します（Sparkle の鍵がキーチェーンにある Mac で実行）:

```sh
scripts/release.sh --app solcast --version 1.2.3 --dmg path/to/Solcast.dmg
scripts/release.sh --app thor --version 1.0.0 --dmg path/to/Thor.dmg   # thor は DMG のアップロードのみ
scripts/release.sh --app snapsol --version 2.0.0 --dmg Snapsol.dmg --dry-run
```

- タグ `<app>-vX.Y.Z` を作成し、DMG を添付した GitHub Release を作成します（`gh release create`）。
- solcast / snapsol では Sparkle の `generate_appcast --account <app>` を実行して `<app>/appcast.xml` を更新し、`main` にコミット・プッシュします（クリーンな `main` で実行してください）。
- `--no-appcast` で appcast 更新を省略します（thor は常に省略）。`--dry-run` は実行内容の表示のみです。
- タグが既に存在する場合は中止します。Sparkle のパスは `SPARKLE_BIN`（既定値 `~/strange-signing/sparkle-2.10.0/bin`）。
