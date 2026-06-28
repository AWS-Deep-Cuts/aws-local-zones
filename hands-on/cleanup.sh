#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"
REGION="us-west-2"
PROJECT_NAME="aws-deepcuts"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Local Zone クリーンアップ"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ ! -f "${RESOURCE_FILE}" ]; then
  echo "エラー: ${RESOURCE_FILE} が見つかりません。"
  echo "setup.sh を実行したディレクトリで実行してください。"
  exit 1
fi

source "${RESOURCE_FILE}"

# EC2 インスタンスを終了（手動作成のためNameタグで検索）
echo "[1/5] EC2 インスタンスを終了..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-lz-local,${PROJECT_NAME}-lz-regional" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --region "${REGION}" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text)

if [ -n "${INSTANCE_IDS}" ]; then
  aws ec2 terminate-instances --instance-ids ${INSTANCE_IDS} --region "${REGION}" >/dev/null
  echo "  終了待機中: ${INSTANCE_IDS}"
  aws ec2 wait instance-terminated --instance-ids ${INSTANCE_IDS} --region "${REGION}"
  echo "  完了"
else
  echo "  対象インスタンスなし"
fi
echo ""

# Security Group 削除
echo "[2/5] Security Group を削除..."
if [ -n "${SECURITY_GROUP_ID:-}" ]; then
  aws ec2 delete-security-group --group-id "${SECURITY_GROUP_ID}" --region "${REGION}" 2>/dev/null || true
  echo "  完了: ${SECURITY_GROUP_ID}"
fi
echo ""

# サブネット削除
echo "[3/5] サブネットを削除..."
for SUBNET_ID in "${LOCAL_SUBNET_ID:-}" "${REGIONAL_SUBNET_ID:-}"; do
  [ -z "${SUBNET_ID}" ] && continue
  aws ec2 delete-subnet --subnet-id "${SUBNET_ID}" --region "${REGION}" 2>/dev/null || true
  echo "  完了: ${SUBNET_ID}"
done
echo ""

# IGW・ルートテーブル削除
echo "[4/5] Internet Gateway・Route Table を削除..."
if [ -n "${IGW_ID:-}" ]; then
  aws ec2 detach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}" --region "${REGION}" 2>/dev/null || true
  aws ec2 delete-internet-gateway --internet-gateway-id "${IGW_ID}" --region "${REGION}" 2>/dev/null || true
  echo "  IGW 削除: ${IGW_ID}"
fi
if [ -n "${RTB_ID:-}" ]; then
  # ルートテーブルのサブネットアソシエーションを解除
  ASSOC_IDS=$(aws ec2 describe-route-tables \
    --route-table-ids "${RTB_ID}" \
    --region "${REGION}" \
    --query 'RouteTables[].Associations[?!Main].RouteTableAssociationId' \
    --output text 2>/dev/null || true)
  for ASSOC_ID in ${ASSOC_IDS}; do
    aws ec2 disassociate-route-table --association-id "${ASSOC_ID}" --region "${REGION}" 2>/dev/null || true
  done
  aws ec2 delete-route-table --route-table-id "${RTB_ID}" --region "${REGION}" 2>/dev/null || true
  echo "  Route Table 削除: ${RTB_ID}"
fi
echo ""

# VPC 削除
echo "[5/5] VPC を削除..."
if [ -n "${VPC_ID:-}" ]; then
  aws ec2 delete-vpc --vpc-id "${VPC_ID}" --region "${REGION}" 2>/dev/null || true
  echo "  完了: ${VPC_ID}"
fi
echo ""

rm -f "${RESOURCE_FILE}" "${SCRIPT_DIR}/user-data.sh"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ すべてのリソースの削除が完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
