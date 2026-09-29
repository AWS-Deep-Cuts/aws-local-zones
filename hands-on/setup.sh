#!/bin/bash
set -euo pipefail

PROJECT_NAME="aws-deepcuts"
REGION="us-west-2"
LOCAL_ZONE_GROUP="us-west-2-hnl-1"
VPC_CIDR="10.42.0.0/16"
LOCAL_SUBNET_CIDR="10.42.1.0/24"
REGIONAL_SUBNET_CIDR="10.42.2.0/24"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"

# AWS 認証チェック (CloudShell / IAM Identity Center / aws login / アクセスキー に対応)
source "${SCRIPT_DIR}/aws_auth_check.sh"
# プロファイルにリージョンが無い場合 (Identity Center のプロファイルなど) でも動くように固定
export AWS_REGION="${REGION}" AWS_DEFAULT_REGION="${REGION}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Local Zone セットアップ"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

aws_auth_check "${REGION}" || exit 1

# 前回の setup.sh のリソース情報が残っている場合は、VPC の二重作成を防ぐため停止
if [ -f "${RESOURCE_FILE}" ]; then
  echo "エラー: 前回の setup.sh のリソース情報 (${RESOURCE_FILE}) が残っています。"
  echo "作成済みのリソースを削除する場合は bash ./cleanup.sh を実行してから、再度 setup.sh を実行してください。"
  exit 1
fi

# 作成したリソースの ID を、作成するたびに保存する
# (途中で失敗しても cleanup.sh で作成済みの分を削除できるようにするため)
VPC_ID="" IGW_ID="" RTB_ID="" LOCAL_SUBNET_ID="" REGIONAL_SUBNET_ID="" SG_ID=""
LOCAL_ZONE_NAME="" REGIONAL_AZ=""
save_resources() {
  cat > "${RESOURCE_FILE}" <<EOF
# AWS Deep Cuts Local Zone - リソース情報
# このファイルは setup.sh が自動生成しました
SETUP_AWS_PROFILE="${AWS_PROFILE:-default}"
ACCOUNT_ID="${AWS_ACCOUNT_ID}"
REGION="${REGION}"
VPC_ID="${VPC_ID}"
IGW_ID="${IGW_ID}"
RTB_ID="${RTB_ID}"
LOCAL_SUBNET_ID="${LOCAL_SUBNET_ID}"
REGIONAL_SUBNET_ID="${REGIONAL_SUBNET_ID}"
SECURITY_GROUP_ID="${SG_ID}"
LOCAL_ZONE_NAME="${LOCAL_ZONE_NAME}"
REGIONAL_AZ="${REGIONAL_AZ}"
EOF
}

on_error() {
  local line="$1"
  echo ""
  echo "❌ エラーが発生したため、セットアップを中断しました (setup.sh ${line} 行目)。"
  echo "   上に表示されている AWS CLI のエラーメッセージを確認してください。"
  aws_permission_hint
  if [ -f "${RESOURCE_FILE}" ]; then
    echo ""
    echo "   作成途中のリソースは bash ./cleanup.sh で削除できます。"
  fi
}
trap 'on_error ${LINENO}' ERR

# Local Zone オプトイン確認・有効化
echo "[1/6] Local Zone のオプトイン状態を確認..."
OPT_IN_STATUS=$(aws ec2 describe-availability-zones \
  --all-availability-zones \
  --filters "Name=group-name,Values=${LOCAL_ZONE_GROUP}" \
  --region "${REGION}" \
  --query 'AvailabilityZones[0].OptInStatus' \
  --output text)

if [ "${OPT_IN_STATUS}" != "opted-in" ]; then
  echo "  Local Zone を有効化しています..."
  aws ec2 modify-availability-zone-group \
    --group-name "${LOCAL_ZONE_GROUP}" \
    --opt-in-status opted-in \
    --region "${REGION}" >/dev/null
  for _ in $(seq 1 30); do
    OPT_IN_STATUS=$(aws ec2 describe-availability-zones \
      --all-availability-zones \
      --filters "Name=group-name,Values=${LOCAL_ZONE_GROUP}" \
      --region "${REGION}" \
      --query 'AvailabilityZones[0].OptInStatus' \
      --output text)
    [ "${OPT_IN_STATUS}" = "opted-in" ] && break
    sleep 10
  done
  if [ "${OPT_IN_STATUS}" != "opted-in" ]; then
    echo "エラー: Local Zone のオプトインが完了しませんでした (現在: ${OPT_IN_STATUS})。"
    echo "数分待ってから再度 setup.sh を実行してください。"
    exit 1
  fi
fi

LOCAL_ZONE_NAME=$(aws ec2 describe-availability-zones \
  --all-availability-zones \
  --filters "Name=group-name,Values=${LOCAL_ZONE_GROUP}" "Name=state,Values=available" \
  --region "${REGION}" \
  --query 'AvailabilityZones[0].ZoneName' \
  --output text)

REGIONAL_AZ=$(aws ec2 describe-availability-zones \
  --filters "Name=zone-type,Values=availability-zone" "Name=state,Values=available" \
  --region "${REGION}" \
  --query 'AvailabilityZones[0].ZoneName' \
  --output text)

echo "  Local Zone: ${LOCAL_ZONE_NAME} (opted-in)"
echo "  Regional AZ: ${REGIONAL_AZ}"
echo ""

# VPC 作成
echo "[2/6] VPC を作成..."
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "${VPC_CIDR}" \
  --region "${REGION}" \
  --query 'Vpc.VpcId' --output text)
save_resources
aws ec2 create-tags --resources "${VPC_ID}" \
  --tags "Key=Name,Value=${PROJECT_NAME}-lz-vpc" "Key=Project,Value=${PROJECT_NAME}" \
  --region "${REGION}"
aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-support Value=true --region "${REGION}"
aws ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-hostnames Value=true --region "${REGION}"
echo "  VPC: ${VPC_ID}"
echo ""

# Internet Gateway 作成
echo "[3/6] Internet Gateway を作成..."
IGW_ID=$(aws ec2 create-internet-gateway \
  --region "${REGION}" \
  --query 'InternetGateway.InternetGatewayId' --output text)
save_resources
aws ec2 attach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}" --region "${REGION}"
aws ec2 create-tags --resources "${IGW_ID}" \
  --tags "Key=Name,Value=${PROJECT_NAME}-lz-igw" "Key=Project,Value=${PROJECT_NAME}" \
  --region "${REGION}"

RTB_ID=$(aws ec2 create-route-table --vpc-id "${VPC_ID}" --region "${REGION}" \
  --query 'RouteTable.RouteTableId' --output text)
save_resources
aws ec2 create-route --route-table-id "${RTB_ID}" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "${IGW_ID}" --region "${REGION}" >/dev/null
aws ec2 create-tags --resources "${RTB_ID}" \
  --tags "Key=Name,Value=${PROJECT_NAME}-lz-rtb" "Key=Project,Value=${PROJECT_NAME}" \
  --region "${REGION}"
echo "  IGW: ${IGW_ID}"
echo "  Route Table: ${RTB_ID}"
echo ""

# サブネット作成
echo "[4/6] サブネットを作成..."
LOCAL_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "${VPC_ID}" --cidr-block "${LOCAL_SUBNET_CIDR}" \
  --availability-zone "${LOCAL_ZONE_NAME}" --region "${REGION}" \
  --query 'Subnet.SubnetId' --output text)
save_resources
aws ec2 modify-subnet-attribute --subnet-id "${LOCAL_SUBNET_ID}" --map-public-ip-on-launch --region "${REGION}"
aws ec2 associate-route-table --route-table-id "${RTB_ID}" --subnet-id "${LOCAL_SUBNET_ID}" --region "${REGION}" >/dev/null

REGIONAL_SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "${VPC_ID}" --cidr-block "${REGIONAL_SUBNET_CIDR}" \
  --availability-zone "${REGIONAL_AZ}" --region "${REGION}" \
  --query 'Subnet.SubnetId' --output text)
save_resources
aws ec2 modify-subnet-attribute --subnet-id "${REGIONAL_SUBNET_ID}" --map-public-ip-on-launch --region "${REGION}"
aws ec2 associate-route-table --route-table-id "${RTB_ID}" --subnet-id "${REGIONAL_SUBNET_ID}" --region "${REGION}" >/dev/null

aws ec2 create-tags --resources "${LOCAL_SUBNET_ID}" \
  --tags "Key=Name,Value=${PROJECT_NAME}-lz-local-subnet" "Key=Project,Value=${PROJECT_NAME}" --region "${REGION}"
aws ec2 create-tags --resources "${REGIONAL_SUBNET_ID}" \
  --tags "Key=Name,Value=${PROJECT_NAME}-lz-regional-subnet" "Key=Project,Value=${PROJECT_NAME}" --region "${REGION}"
echo "  Local Zone subnet: ${LOCAL_SUBNET_ID}"
echo "  Regional subnet: ${REGIONAL_SUBNET_ID}"
echo ""

# Security Group 作成
echo "[5/6] Security Group を作成..."
SG_ID=$(aws ec2 create-security-group \
  --group-name "${PROJECT_NAME}-lz-http" \
  --description "HTTP access for Local Zone latency test" \
  --vpc-id "${VPC_ID}" --region "${REGION}" \
  --query 'GroupId' --output text)
save_resources
aws ec2 authorize-security-group-ingress \
  --group-id "${SG_ID}" \
  --ip-permissions 'IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]' \
  --region "${REGION}" >/dev/null
aws ec2 create-tags --resources "${SG_ID}" \
  --tags "Key=Name,Value=${PROJECT_NAME}-lz-http-sg" "Key=Project,Value=${PROJECT_NAME}" --region "${REGION}"
echo "  Security Group: ${SG_ID}"
echo ""

# user-data.sh 作成
echo "[6/6] user-data.sh を生成..."
cat > "${SCRIPT_DIR}/user-data.sh" <<'USERDATA'
#!/bin/bash
set -eux
mkdir -p /opt/aws-deepcuts
echo "ok" > /opt/aws-deepcuts/ping
cat > /opt/aws-deepcuts/index.html <<'HTML'
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>AWS Local Zone Latency</title>
<style>
body{font-family:sans-serif;margin:0;background:#f3f6f8;color:#1f2937}
header{background:#232f3e;color:#fff;padding:24px;text-align:center}
main{max-width:800px;margin:0 auto;padding:20px}
button{background:#ff9900;border:0;border-radius:8px;padding:12px 18px;font-weight:700;cursor:pointer;font-size:15px}
.result{border:1px solid #dbe4ee;border-radius:8px;padding:14px;margin:12px 0;background:#fff}
.fastest{border-color:#16a34a;background:#f0fdf4}
.latency{font-size:28px;font-weight:800;color:#2563eb}
</style>
</head>
<body>
<header><h1>AWS Local Zone Latency</h1><p>Local Zone EC2 vs Parent Region EC2</p></header>
<main>
<button id="btn">測定開始</button>
<div id="results"></div>
</main>
<script>
const params=new URLSearchParams(location.search);
const endpoints=[
  {key:'local',name:'Local Zone EC2',url:params.get('local')},
  {key:'regional',name:'Parent Region EC2',url:params.get('regional')}
].filter(e=>e.url);
async function measure(ep){
  const vals=[];
  for(let i=0;i<5;i++){
    const s=performance.now();
    await fetch(ep.url+(ep.url.includes('?')?'&':'?')+'t='+Date.now(),{method:'HEAD',mode:'no-cors',cache:'no-store'});
    vals.push(performance.now()-s);
    await new Promise(r=>setTimeout(r,120));
  }
  vals.sort((a,b)=>a-b);
  return{...ep,latency:vals[2]};
}
document.getElementById('btn').onclick=async()=>{
  const btn=document.getElementById('btn'),res=document.getElementById('results');
  btn.disabled=true;btn.textContent='測定中...';res.innerHTML='';
  const results=[];
  for(const ep of endpoints)results.push(await measure(ep));
  const fastest=results.reduce((a,b)=>a.latency<b.latency?a:b);
  res.innerHTML=results.map(r=>`<div class="result ${r.key===fastest.key?'fastest':''}"><strong>${r.name}${r.key===fastest.key?' ⚡最速':''}</strong><div class="latency">${Math.round(r.latency)} ms</div></div>`).join('');
  btn.disabled=false;btn.textContent='再測定';
};
</script>
</body>
</html>
HTML
cat > /etc/systemd/system/aws-deepcuts-web.service <<'SVC'
[Unit]
Description=AWS Deep Cuts latency web server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 80 --directory /opt/aws-deepcuts
Restart=always
[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload
systemctl enable --now aws-deepcuts-web.service
USERDATA
echo "  user-data.sh を生成しました"
echo ""

# リソース情報を保存
save_resources
trap - ERR

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ セットアップが完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "リソース情報: ${RESOURCE_FILE}"
echo ""
echo "次のステップ: README の「２．EC2 の作成」に進んでください。"
