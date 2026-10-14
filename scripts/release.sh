#!/usr/bin/env bash
# star-forge 共通リリーススクリプト
#
# 使い方:
#   scripts/release.sh --app <solcast|snapsol|thor> --version X.Y.Z --dmg <path> [--no-appcast] [--dry-run]
#
# - タグ <app>-vX.Y.Z で Sol-momma/star-forge に GitHub Release を作成し、DMG を添付します。
# - solcast / snapsol は Sparkle の generate_appcast で <app>/appcast.xml を更新し、main にコミット・プッシュします。
# - thor（または --no-appcast 指定時）は DMG のアップロードのみ行います。
#
# 秘密情報はこのスクリプトにもリポジトリにも含めません。
# Sparkle の EdDSA 鍵は Mac のキーチェーン（--account <app>）から generate_appcast が読み込みます。
set -euo pipefail

readonly REPO="Sol-momma/star-forge"
# Sparkle の bin ディレクトリ（環境変数 SPARKLE_BIN で上書き可能）
SPARKLE_BIN="${SPARKLE_BIN:-$HOME/strange-signing/sparkle-2.10.0/bin}"

usage() {
  cat <<'USAGE'
使い方: scripts/release.sh --app <solcast|snapsol|thor> --version X.Y.Z --dmg <path> [--no-appcast] [--dry-run]

  --app         対象アプリ（solcast / snapsol / thor）
  --version     バージョン（X.Y.Z 形式）
  --dmg         アップロードする DMG のパス
  --no-appcast  appcast を更新せず DMG のアップロードのみ行う（thor は常にこのモード）
  --dry-run     実行内容を表示するだけで何も変更しない
USAGE
}

die() {
  echo "エラー: $*" >&2
  exit 1
}

# dry-run 時はコマンドを表示するだけ、通常時は実行する
run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

APP=""
VERSION=""
DMG=""
NO_APPCAST=false
DRY_RUN=false

# --- 引数の解析 ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) [[ $# -ge 2 ]] || die "--app に値がありません"; APP="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || die "--version に値がありません"; VERSION="$2"; shift 2 ;;
    --dmg) [[ $# -ge 2 ]] || die "--dmg に値がありません"; DMG="$2"; shift 2 ;;
    --no-appcast) NO_APPCAST=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "不明な引数: $1" ;;
  esac
done

# --- 入力の検証 ---
[[ -n "$APP" && -n "$VERSION" && -n "$DMG" ]] || { usage >&2; die "--app, --version, --dmg は必須です"; }

case "$APP" in
  solcast|snapsol) ;;
  thor) NO_APPCAST=true ;;  # thor は appcast を使わない
  *) die "--app は solcast / snapsol / thor のいずれかを指定してください: $APP" ;;
esac

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "バージョンは X.Y.Z 形式で指定してください: $VERSION"
[[ -f "$DMG" ]] || die "DMG が見つかりません: $DMG"

TAG="${APP}-v${VERSION}"
DMG_NAME="$(basename "$DMG")"
DOWNLOAD_PREFIX="https://github.com/${REPO}/releases/download/${TAG}/"

command -v gh >/dev/null 2>&1 || die "gh コマンドが見つかりません"

# 既存タグがあれば中止（リモートのリリース／タグを確認）
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  die "リリース $TAG は既に存在します"
fi
if git ls-remote --exit-code --tags "https://github.com/${REPO}.git" "refs/tags/${TAG}" >/dev/null 2>&1; then
  die "タグ $TAG は既に存在します"
fi

echo "アプリ: $APP / タグ: $TAG / DMG: $DMG / appcast 更新: $([[ "$NO_APPCAST" == true ]] && echo しない || echo する)"

STAGING=""
cleanup() { if [[ -n "$STAGING" ]]; then rm -rf "$STAGING"; fi; }
trap cleanup EXIT

if [[ "$NO_APPCAST" == false ]]; then
  REPO_ROOT="$(git rev-parse --show-toplevel)"
  APPCAST="$REPO_ROOT/$APP/appcast.xml"
  GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
  [[ -x "$GENERATE_APPCAST" ]] || die "generate_appcast が見つかりません: $GENERATE_APPCAST（SPARKLE_BIN を確認してください）"

  # main ブランチ上で、作業ツリーがクリーンであることを確認
  [[ "$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)" == "main" ]] || die "main ブランチで実行してください"
  [[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]] || die "作業ツリーに未コミットの変更があります"
  run git -C "$REPO_ROOT" pull --ff-only origin main

  # ステージングディレクトリに DMG と既存の appcast を置いて generate_appcast を実行
  STAGING="$(mktemp -d)"
  run cp "$DMG" "$STAGING/$DMG_NAME"
  if [[ -f "$APPCAST" ]]; then
    run cp "$APPCAST" "$STAGING/appcast.xml"
  fi
  # 署名鍵はキーチェーンのアカウント <app> から読み込まれる
  run "$GENERATE_APPCAST" --account "$APP" --download-url-prefix "$DOWNLOAD_PREFIX" -o "$STAGING/appcast.xml" "$STAGING"
fi

# GitHub Release を作成し DMG を添付
run gh release create "$TAG" "$DMG" --repo "$REPO" --title "$APP $VERSION" --notes "$APP $VERSION"

if [[ "$NO_APPCAST" == false ]]; then
  # 生成した appcast を反映して main にコミット・プッシュ
  run mkdir -p "$REPO_ROOT/$APP"
  run cp "$STAGING/appcast.xml" "$APPCAST"
  run git -C "$REPO_ROOT" add "$APP/appcast.xml"
  run git -C "$REPO_ROOT" commit -m "$APP: appcast を $VERSION に更新"
  run git -C "$REPO_ROOT" push origin main
fi

echo "完了: $TAG"
