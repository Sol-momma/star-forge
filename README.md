**English** | [日本語](README.ja.md)

# star-forge

Shared distribution repository for **Solcast**, **Snapsol** and **Thor**.

## Releases
Releases are tagged with the app name:
- `solcast-vX.Y.Z`
- `snapsol-vX.Y.Z`
- `thor-vX.Y.Z`

## Sparkle appcasts
Appcasts are served from GitHub Pages at `/<app>/appcast.xml`:
- https://sol-momma.github.io/star-forge/solcast/appcast.xml
- https://sol-momma.github.io/star-forge/snapsol/appcast.xml
- https://sol-momma.github.io/star-forge/thor/appcast.xml

No secrets are stored in this repository.

## Release script
Use `scripts/release.sh` to publish a release (run on the Mac with the Sparkle keys in the keychain):

```sh
scripts/release.sh --app solcast --version 1.2.3 --dmg path/to/Solcast.dmg
scripts/release.sh --app thor --version 1.0.0 --dmg path/to/Thor.dmg   # thor: DMG upload only
scripts/release.sh --app snapsol --version 2.0.0 --dmg Snapsol.dmg --dry-run
```

- Creates the tag `<app>-vX.Y.Z` and a GitHub Release with the DMG attached (`gh release create`).
- For solcast/snapsol, runs Sparkle `generate_appcast --account <app>`, writes `<app>/appcast.xml`, and commits/pushes it to `main` (run from a clean `main` checkout).
- `--no-appcast` skips the appcast (always the case for thor). `--dry-run` only prints the actions.
- Refuses to run if the tag already exists. Sparkle tools path: `SPARKLE_BIN` (default `~/strange-signing/sparkle-2.10.0/bin`).
