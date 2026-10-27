#!/bin/bash
# ─────────────────────────────────────────────────────────────────
# AWS Deep Cuts 共通: AWS 認証チェック
#
# setup.sh / cleanup.sh から source して使います。
#   source "$(dirname "${BASH_SOURCE[0]}")/aws_auth_check.sh"
#   aws_auth_check            # 成功すると AWS_ACCOUNT_ID / AWS_CALLER_ARN が設定される
#
# 対応している認証方式:
#   - CloudShell (マネジメントコンソールのサインイン情報。IAM Identity Center 経由も可)
#   - IAM Identity Center (AWS SSO) プロファイル   … aws configure sso / aws sso login
#   - aws login (コンソール認証情報でのサインイン) … aws login
#   - IAM ユーザーのアクセスキー                     … aws configure
#   - AssumeRole プロファイル / credential_process / 環境変数
#
# 失敗した場合は、原因と具体的な対処コマンドを表示して終了します。
# ─────────────────────────────────────────────────────────────────

# AWS CLI のページャーを無効化 (ローカル環境で less が起動して止まるのを防ぐ)
export AWS_PAGER=""

_aws_profile_label() {
  echo "${AWS_PROFILE:-${AWS_DEFAULT_PROFILE:-default}}"
}

_aws_profile_opt() {
  local profile
  profile="$(_aws_profile_label)"
  if [[ "${profile}" != "default" ]]; then
    echo " --profile ${profile}"
  fi
}

_aws_auth_fail() {
  # $1: タイトル, 以降: 対処方法
  local title="$1"
  shift
  echo "" >&2
  echo "❌ ${title}" >&2
  local hint
  for hint in "$@"; do
    echo "   → ${hint}" >&2
  done
  echo "" >&2
}

aws_auth_check() {
  local region="${1:-}"

  # 1. AWS CLI の存在確認
  if ! command -v aws >/dev/null 2>&1; then
    _aws_auth_fail "AWS CLI が見つかりません。" \
      "AWS CloudShell で実行するか、AWS CLI v2 をインストールしてください。" \
      "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    return 1
  fi

  local cli_version
  cli_version="$(aws --version 2>&1 || true)"

  # 2. 認証確認 (エラーメッセージは握りつぶさずに分類する)
  local output
  local region_opt=()
  if [[ -n "${region}" ]]; then
    region_opt=(--region "${region}")
  fi
  if output="$(aws sts get-caller-identity ${region_opt[@]+"${region_opt[@]}"} --query '[Account,Arn]' --output text 2>&1)"; then
    AWS_ACCOUNT_ID="$(echo "${output}" | awk '{print $1}')"
    AWS_CALLER_ARN="$(echo "${output}" | awk '{print $2}')"
    export AWS_ACCOUNT_ID AWS_CALLER_ARN
    echo "🔐 AWS 認証 OK"
    echo "   アカウント: ${AWS_ACCOUNT_ID}"
    echo "   実行ユーザー/ロール: ${AWS_CALLER_ARN}"
    if [[ -z "${AWS_EXECUTION_ENV:-}" ]]; then
      echo "   プロファイル: $(_aws_profile_label)"
    fi
    echo ""
    return 0
  fi

  local opt
  opt="$(_aws_profile_opt)"
  local env_key_hint=()
  if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    env_key_hint=("環境変数 AWS_ACCESS_KEY_ID が設定されています。環境変数はプロファイル (SSO 含む) より優先されます。不要なら unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN を実行してください。")
  fi

  case "${output}" in
    *"could not be found"*|*"ProfileNotFound"*)
      _aws_auth_fail "プロファイル '$(_aws_profile_label)' が見つかりません。" \
        "aws configure list-profiles で設定済みのプロファイル名を確認し、export AWS_PROFILE=<プロファイル名> を実行してください。"
      ;;
    *"Unable to locate credentials"*|*"NoCredentials"*)
      _aws_auth_fail "AWS の認証情報が見つかりません。" \
        "AWS CloudShell で実行するのが最も簡単です (マネジメントコンソール右上の CloudShell アイコン)。" \
        "IAM Identity Center (SSO) の場合: aws configure sso → aws sso login --profile <プロファイル名> → export AWS_PROFILE=<プロファイル名>" \
        "aws login を使う場合: aws login" \
        "アクセスキーの場合: aws configure"
      ;;
    *"sso"*|*"SSO"*)
      if [[ "${cli_version}" == aws-cli/1.* ]]; then
        _aws_auth_fail "AWS CLI v1 は IAM Identity Center の sso-session 形式に対応していません。" \
          "AWS CLI v2 をインストールしてください (現在: ${cli_version%% *})。"
      else
        _aws_auth_fail "IAM Identity Center (SSO) のセッションが切れているか、ログインしていません。" \
          "aws sso login${opt} を実行してから、もう一度スクリプトを実行してください。"
      fi
      ;;
    *"aws login"*|*"login session"*|*"Login"*)
      _aws_auth_fail "aws login のセッションが切れています。" \
        "aws login${opt} を実行してから、もう一度スクリプトを実行してください。"
      ;;
    *"ExpiredToken"*|*"RequestExpired"*|*"expired"*)
      _aws_auth_fail "一時的な認証情報の有効期限が切れています。" \
        ${env_key_hint[@]+"${env_key_hint[@]}"} \
        "IAM Identity Center の場合: aws sso login${opt}" \
        "CloudShell の場合: ブラウザを再読み込みして CloudShell を開き直してください。"
      ;;
    *"InvalidClientTokenId"*|*"SignatureDoesNotMatch"*|*"UnrecognizedClient"*)
      _aws_auth_fail "認証情報が無効です (アクセスキーの誤り・削除、または PC の時刻ずれ)。" \
        ${env_key_hint[@]+"${env_key_hint[@]}"} \
        "aws configure で再設定するか、IAM Identity Center の場合は aws sso login${opt} を実行してください。"
      ;;
    *"You must specify a region"*|*"NoRegion"*)
      _aws_auth_fail "リージョンが設定されていません。" \
        "export AWS_DEFAULT_REGION=ap-northeast-1 を実行してから、もう一度実行してください。"
      ;;
    *"Could not connect"*|*"Connect timeout"*|*"EndpointConnectionError"*)
      _aws_auth_fail "AWS に接続できません。" \
        "ネットワーク・プロキシ・VPN の設定を確認してください。"
      ;;
    *)
      _aws_auth_fail "AWS の認証確認に失敗しました。" \
        "以下のエラー内容を確認してください。"
      ;;
  esac
  echo "   (AWS CLI の出力)" >&2
  echo "${output}" | sed 's/^/   | /' >&2
  echo "" >&2
  return 1
}

# 権限エラー時の共通ヒント
aws_permission_hint() {
  echo "" >&2
  echo "   ℹ️  AccessDenied / UnauthorizedOperation の場合は IAM 権限が不足しています。" >&2
  echo "      実行ユーザー/ロール: ${AWS_CALLER_ARN:-不明}" >&2
  echo "      IAM Identity Center の場合は、許可セット (Permission set) に必要な権限があるか管理者に確認してください。" >&2
  echo "      SCP (サービスコントロールポリシー) で拒否されている可能性もあります。" >&2
}
