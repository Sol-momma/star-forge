#!/usr/bin/env bash
# ソース zip の秘密情報スキャン
#
# 使い方: scripts/scan-source-zip.sh <zip>
#
# 次のいずれかが見つかったら終了コード 1 で中止します。
# - .env 系ファイル（.env.example / .env.sample / .env.template は除く）
# - 秘密鍵・証明書ファイル（*.p12 *.pfx *.pem *.key *.keychain *.mobileprovision *.p8 id_rsa など）
# - Sparkle の秘密鍵／EdDSA 秘密鍵らしいファイル名
# - 本文中の秘密鍵・トークン・認証情報のパターン
# - 個人の絶対パス（/Users/<名前>/ や /home/<名前>/。テスト用の仮名は許可リストで除外）
set -euo pipefail

die() { echo "エラー: $*" >&2; exit 2; }

[[ $# -eq 1 ]] || die "使い方: $0 <zip>"
ZIP="$1"
[[ -f "$ZIP" ]] || die "zip が見つかりません: $ZIP"
command -v unzip >/dev/null 2>&1 || die "unzip コマンドが見つかりません"

# テストやドキュメントで使う仮のユーザー名（個人の絶対パスとはみなさない）
readonly PLACEHOLDER_USERS='me|you|user|username|USER|USERNAME|name|other|reader|test|tester|x|solcast-harness|example|shared|Shared|runner|\.\.\.|<[^/]*>|\$[A-Za-z_{}]+'

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FOUND=0
report() { echo "検出: $*"; FOUND=1; }

# --- ファイル名のチェック ---
unzip -Z1 "$ZIP" > "$WORK/names.txt"
while IFS= read -r name; do
  base="${name##*/}"
  [[ -z "$base" ]] && continue
  lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    .env.example|.env.sample|.env.template) ;;
    .env|.env.*|*.env) report "環境変数ファイル: $name" ;;
  esac
  case "$lower" in
    *.p12|*.pfx|*.pem|*.key|*.p8|*.keychain|*.keychain-db|*.mobileprovision|*.provisionprofile|*.jks|*.keystore|id_rsa*|id_ecdsa*|id_ed25519*)
      report "鍵・証明書ファイル: $name" ;;
    *eddsa*priv*|*priv*eddsa*|*ed25519*priv*|*sparkle*priv*|*sparkle*key*|*private*key*|*secret*key*)
      report "Sparkle/EdDSA 秘密鍵らしいファイル: $name" ;;
    *.netrc|.npmrc|.pypirc|credentials|credentials.json|*.credentials|service-account*.json|.git-credentials)
      report "認証情報ファイル: $name" ;;
  esac
done < "$WORK/names.txt"

# --- 本文のチェック ---
mkdir -p "$WORK/x"
unzip -qq "$ZIP" -d "$WORK/x"

scan() {
  local label="$1" pattern="$2"
  local hits
  hits="$(cd "$WORK/x" && grep -rnIE -- "$pattern" . 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    report "$label"
    printf '%s\n' "$hits" | cut -c1-200 | sed 's/^/    /'
  fi
}

scan "秘密鍵ブロック" '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----'
scan "GitHub トークン" '(gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,})'
scan "AWS アクセスキー" '(AKIA|ASIA)[0-9A-Z]{16}'
scan "Slack トークン" 'xox[abprs]-[A-Za-z0-9-]{10,}'
scan "OpenAI/Anthropic などの API キー" '(sk-(proj-|ant-)?[A-Za-z0-9_-]{32,})'
scan "Google API キー" 'AIza[0-9A-Za-z_-]{35}'
scan "Stripe 秘密キー" '(sk|rk)_live_[0-9A-Za-z]{20,}'
scan "認証情報らしい代入" '(password|passwd|secret|api[_-]?key|access[_-]?token|private[_-]?key)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9+/=_-]{16,}["'"'"']'
scan "Sparkle EdDSA 秘密鍵らしい値" '(SUPrivateEDKey|ed25519[_-]?priv|EdDSA[_ ]?private)[^A-Za-z0-9]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+/]{40,}={0,2}'

# 個人の絶対パス（仮名は除外）
# shellcheck disable=SC2016  # ${} は正規表現の文字として使う
paths="$(cd "$WORK/x" && grep -rnoIE '(/Users|/home)/[A-Za-z0-9._<>${}-]+' . 2>/dev/null \
  | grep -vE ":(/Users|/home)/(${PLACEHOLDER_USERS})\$" || true)"
if [[ -n "$paths" ]]; then
  report "個人の絶対パス"
  printf '%s\n' "$paths" | sed 's/^/    /'
fi

if [[ "$FOUND" -ne 0 ]]; then
  echo "スキャン失敗: $ZIP に秘密情報の疑いがあります" >&2
  exit 1
fi
echo "スキャン OK: $ZIP（$(wc -l < "$WORK/names.txt" | tr -d ' ') エントリ）"
