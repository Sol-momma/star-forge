#!/usr/bin/env bash
# star-forge 共通リリーススクリプト
#
# 使い方:
#   scripts/release.sh --app <solcast|snapsol|thor> --version X.Y.Z --dmg <path> \
#     [--source-repo <path> --source-ref <tag|commit>] [--no-appcast] [--dry-run]
#
# - タグ <app>-vX.Y.Z で Sol-momma/star-forge に GitHub Release を作成し、DMG を添付します。
# - solcast / snapsol は Sparkle の generate_appcast で <app>/appcast.xml を更新し、main にコミット・プッシュします。
# - thor（または --no-appcast 指定時）は DMG のアップロードのみ行います。
# - --source-repo / --source-ref を指定すると、ソースリポジトリ（Solcast は非公開の r2d2 のローカル clone）の
#   そのタグ／コミットから git archive で <app>-<version>-source.zip を作り、秘密情報をスキャンしてから
#   リリースに添付します。スキャンで疑いが見つかったらリリースを作らずに中止します。
#   solcast は AGPL-3.0 のため必須です。
#
# 秘密情報はこのスクリプトにもリポジトリにも含めません。
# Sparkle の EdDSA 鍵は Mac のキーチェーン（--account <app>）から generate_appcast が読み込みます。
set -euo pipefail

readonly REPO="Sol-momma/star-forge"
# Sparkle の bin ディレクトリ（環境変数 SPARKLE_BIN で上書き可能）
SPARKLE_BIN="${SPARKLE_BIN:-$HOME/strange-signing/sparkle-2.10.0/bin}"

usage() {
  cat <<'USAGE'
使い方: scripts/release.sh --app <solcast|snapsol|thor> --version X.Y.Z --dmg <path>
         [--source-repo <path> --source-ref <tag|commit>] [--no-appcast] [--dry-run]

  --app         対象アプリ（solcast / snapsol / thor）
  --version     バージョン（X.Y.Z 形式）
  --dmg         アップロードする DMG のパス
  --source-repo ソースリポジトリのローカル clone のパス（solcast は必須）
  --source-ref  ソース zip を作るタグまたはコミット（solcast は必須）
  --no-appcast  appcast を更新せず DMG のアップロードのみ行う（thor は常にこのモード）
  --dry-run     実行内容を表示するだけで何も変更しない（ソース zip の作成とスキャンは一時ディレクトリで行う）
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
SOURCE_REPO=""
SOURCE_REF=""
NO_APPCAST=false
DRY_RUN=false

# --- 引数の解析 ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) [[ $# -ge 2 ]] || die "--app に値がありません"; APP="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || die "--version に値がありません"; VERSION="$2"; shift 2 ;;
    --dmg) [[ $# -ge 2 ]] || die "--dmg に値がありません"; DMG="$2"; shift 2 ;;
    --source-repo) [[ $# -ge 2 ]] || die "--source-repo に値がありません"; SOURCE_REPO="$2"; shift 2 ;;
    --source-ref) [[ $# -ge 2 ]] || die "--source-ref に値がありません"; SOURCE_REF="$2"; shift 2 ;;
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

if [[ -n "$SOURCE_REPO" || -n "$SOURCE_REF" ]]; then
  [[ -n "$SOURCE_REPO" && -n "$SOURCE_REF" ]] || die "--source-repo と --source-ref は両方指定してください"
fi
if [[ "$APP" == "solcast" && -z "$SOURCE_REF" ]]; then
  die "solcast は AGPL-3.0 のため --source-repo と --source-ref が必須です"
fi

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
SOURCE_TMP=""
cleanup() {
  if [[ -n "$STAGING" ]]; then rm -rf "$STAGING"; fi
  if [[ -n "$SOURCE_TMP" ]]; then rm -rf "$SOURCE_TMP"; fi
}
trap cleanup EXIT

# --- ソース zip の作成とスキャン（リリース作成より前に行い、問題があれば何も公開せずに中止） ---
RELEASE_ASSETS=("$DMG")
NOTES="$APP $VERSION"
if [[ -n "$SOURCE_REF" ]]; then
  [[ -d "$SOURCE_REPO" ]] || die "ソースリポジトリが見つかりません: $SOURCE_REPO"
  SOURCE_COMMIT="$(git -C "$SOURCE_REPO" rev-parse --verify --quiet "${SOURCE_REF}^{commit}")" \
    || die "ソースのタグ／コミットが見つかりません: $SOURCE_REF"
  # project.yml の MARKETING_VERSION がリリースのバージョンと一致するか確認
  SOURCE_VERSION="$(git -C "$SOURCE_REPO" show "${SOURCE_COMMIT}:project.yml" 2>/dev/null \
    | sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' | head -n1 || true)"
  if [[ -n "$SOURCE_VERSION" && "$SOURCE_VERSION" != "$VERSION" ]]; then
    die "ソース $SOURCE_REF の MARKETING_VERSION（$SOURCE_VERSION）が --version（$VERSION）と一致しません"
  fi
  [[ -n "$SOURCE_VERSION" ]] || echo "注意: ソースの project.yml から MARKETING_VERSION を読めませんでした（バージョン照合は未確認）" >&2

  SOURCE_ZIP_NAME="${APP}-${VERSION}-source.zip"
  SOURCE_TMP="$(mktemp -d)"
  SOURCE_ZIP="$SOURCE_TMP/$SOURCE_ZIP_NAME"
  git -C "$SOURCE_REPO" archive --format=zip --prefix="${APP}-${VERSION}-source/" -o "$SOURCE_ZIP" "$SOURCE_COMMIT"
  echo "ソース zip: $SOURCE_ZIP_NAME（コミット $SOURCE_COMMIT）"
  "$(dirname "${BASH_SOURCE[0]}")/scan-source-zip.sh" "$SOURCE_ZIP" \
    || die "ソース zip の秘密情報スキャンに失敗したため中止します（何も公開していません）"

  RELEASE_ASSETS+=("$SOURCE_ZIP")
  NOTES="$APP $VERSION

ソースコード（AGPL-3.0）: ${SOURCE_ZIP_NAME}（コミット ${SOURCE_COMMIT:0:12}）"
fi

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

# GitHub Release を作成し DMG（とソース zip）を添付
run gh release create "$TAG" "${RELEASE_ASSETS[@]}" --repo "$REPO" --title "$APP $VERSION" --notes "$NOTES"

if [[ "$NO_APPCAST" == false ]]; then
  # 生成した appcast を反映して main にコミット・プッシュ
  run mkdir -p "$REPO_ROOT/$APP"
  run cp "$STAGING/appcast.xml" "$APPCAST"
  run git -C "$REPO_ROOT" add "$APP/appcast.xml"
  run git -C "$REPO_ROOT" commit -m "$APP: appcast を $VERSION に更新"
  run git -C "$REPO_ROOT" push origin main
fi

echo "完了: $TAG"
