#!/bin/bash
# ================================================================
#  Techno Serverless OMS — Step 5 Only
#  Lambda Layer + Functions
#
#  Usage:
#    bash judge5-only.sh <nama_siswa> <email>
#    Contoh: bash judge5-only.sh budi budi@gmail.com
# ================================================================

set -euo pipefail

# ── Color helpers ─────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; BLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${CYN}[$(date '+%H:%M:%S')]${NC} $1"; }
ok()      { echo -e "${GRN}[$(date '+%H:%M:%S')] ✓  $1${NC}"; }
warn()    { echo -e "${YEL}[$(date '+%H:%M:%S')] ⚠  $1${NC}"; }
err()     { echo -e "${RED}[$(date '+%H:%M:%S')] ✗  $1${NC}"; exit 1; }
section() {
    printf "\n${BLD}${BLU}══════════════════════════════════════════${NC}\n"
    printf "${BLD}${BLU}  %s${NC}\n" "$1"
    printf "${BLD}${BLU}══════════════════════════════════════════${NC}\n"
}

# ── Args ──────────────────────────────────────────────────
STUDENT_NAME="${1:-}"
EMAIL="${2:-}"
[ -z "$STUDENT_NAME" ] && echo "Usage: bash judge5-only.sh <nama_siswa> <email>" && exit 1
[ -z "$EMAIL" ]        && echo "Usage: bash judge5-only.sh <nama_siswa> <email>" && exit 1

REGION="us-east-1"
PROJECT="techno"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null \
    || { echo "ERROR: AWS CLI tidak terkonfigurasi."; exit 1; })
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SN="${STUDENT_NAME}"
S3_DEPLOY="${PROJECT}-deploy-${SN}-2026"
S3_LOGS="${PROJECT}-logs-${SN}-2026"
S3_ORDERS="${PROJECT}-orders-${SN}-26"
LAYER_NAME="${PROJECT}-layer-dependencies"

section "STEP 5/11 — Lambda Layer + Functions"
log "Account : $ACCOUNT_ID"
log "Student : $STUDENT_NAME"
log "Region  : $REGION"
echo ""

# ── Resolve state dari step sebelumnya ────────────────────
log "Resolving state dari step 1-4..."

# Coba CloudFormation exports dulu, fallback ke query langsung by tag/name
PRIV_SN1=$(aws cloudformation list-exports \
    --query "Exports[?Name=='${PROJECT}-private-subnet-1'].Value" \
    --output text --region "$REGION" 2>/dev/null || echo "")
PRIV_SN2=$(aws cloudformation list-exports \
    --query "Exports[?Name=='${PROJECT}-private-subnet-2'].Value" \
    --output text --region "$REGION" 2>/dev/null || echo "")
SG_LAMBDA=$(aws cloudformation list-exports \
    --query "Exports[?Name=='${PROJECT}-sg-lambda-id'].Value" \
    --output text --region "$REGION" 2>/dev/null || echo "")

# Fallback: query langsung dari AWS jika CFN exports kosong
if [ -z "$PRIV_SN1" ] || [ "$PRIV_SN1" = "None" ]; then
    log "  CFN export tidak ada, query subnet langsung..."
    # Ambil semua private subnet (yang tidak punya route ke IGW) dari VPC techno
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=${PROJECT}-vpc-serverless" \
        --query "Vpcs[0].VpcId" --output text --region "$REGION" 2>/dev/null || echo "")
    [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ] && \
        VPC_ID=$(aws ec2 describe-vpcs \
            --filters "Name=tag:Name,Values=*${PROJECT}*" \
            --query "Vpcs[0].VpcId" --output text --region "$REGION" 2>/dev/null || echo "")

    if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
        # Ambil subnet private (tag Name mengandung "private")
        PRIV_SUBNETS=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${VPC_ID}" \
                      "Name=tag:Name,Values=*private*" \
            --query "Subnets[*].SubnetId" --output text --region "$REGION" 2>/dev/null || echo "")
        # Fallback: ambil semua subnet di VPC jika tidak ada tag private
        [ -z "$PRIV_SUBNETS" ] || [ "$PRIV_SUBNETS" = "None" ] && \
            PRIV_SUBNETS=$(aws ec2 describe-subnets \
                --filters "Name=vpc-id,Values=${VPC_ID}" \
                --query "Subnets[*].SubnetId" --output text --region "$REGION" 2>/dev/null || echo "")
        PRIV_SN1=$(echo "$PRIV_SUBNETS" | awk '{print $1}')
        PRIV_SN2=$(echo "$PRIV_SUBNETS" | awk '{print $2}')
        [ -z "$PRIV_SN2" ] && PRIV_SN2="$PRIV_SN1"
        log "  VPC: $VPC_ID | Subnets: $PRIV_SN1, $PRIV_SN2"
    fi
fi

if [ -z "$SG_LAMBDA" ] || [ "$SG_LAMBDA" = "None" ]; then
    log "  CFN export tidak ada, query SG langsung..."
    SG_LAMBDA=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${PROJECT}-sg-lambda" \
        --query "SecurityGroups[0].GroupId" --output text --region "$REGION" 2>/dev/null || echo "")
    # Fallback: cari SG yang mengandung nama lambda
    [ -z "$SG_LAMBDA" ] || [ "$SG_LAMBDA" = "None" ] && \
        SG_LAMBDA=$(aws ec2 describe-security-groups \
            --filters "Name=group-name,Values=*lambda*" \
            --query "SecurityGroups[0].GroupId" --output text --region "$REGION" 2>/dev/null || echo "")
fi

[ -z "$PRIV_SN1" ] || [ "$PRIV_SN1" = "None" ] && err "Subnet private tidak ditemukan. Pastikan VPC sudah dibuat."
[ -z "$SG_LAMBDA" ] || [ "$SG_LAMBDA" = "None" ] && err "Security Group Lambda tidak ditemukan. Pastikan SG sudah dibuat."

SECRET_ARN=$(aws secretsmanager describe-secret \
    --secret-id "${PROJECT}-secret-rds-credentials" \
    --query ARN --output text --region "$REGION" 2>/dev/null || echo "")
[ -z "$SECRET_ARN" ] || [ "$SECRET_ARN" = "None" ] && err "SECRET_ARN tidak ditemukan. Pastikan step 4 (Secrets) sudah selesai."

SNS_TOPIC_ARN=$(aws sns list-topics --region "$REGION" \
    --query "Topics[?ends_with(TopicArn,':${PROJECT}-sns-order-notifications')].TopicArn" \
    --output text 2>/dev/null || echo "")

ok "PRIV_SN1  : $PRIV_SN1"
ok "PRIV_SN2  : $PRIV_SN2"
ok "SG_LAMBDA : $SG_LAMBDA"
ok "SECRET_ARN: $SECRET_ARN"

# ── Fix S3 bucket policy ──────────────────────────────────
log "Re-applying S3 bucket policy..."
cat > /tmp/techno_s3_policy_step5.json << S3POL5
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowVoclabsAccess",
      "Effect": "Allow",
      "Principal": {
        "AWS": [
          "arn:aws:iam::${ACCOUNT_ID}:role/LabRole",
          "arn:aws:iam::${ACCOUNT_ID}:role/voclabs"
        ]
      },
      "Action": ["s3:PutObject","s3:GetObject","s3:GetObjectVersion","s3:DeleteObject","s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::${S3_DEPLOY}",
        "arn:aws:s3:::${S3_DEPLOY}/*"
      ]
    }
  ]
}
S3POL5
aws s3api put-bucket-policy \
    --bucket "$S3_DEPLOY" \
    --policy file:///tmp/techno_s3_policy_step5.json \
    --region "$REGION" --no-cli-pager 2>/dev/null \
    && ok "S3 bucket policy OK" || warn "S3 bucket policy: skip"

# ── Fix Lambda SG egress ──────────────────────────────────
log "Memastikan Lambda SG egress allow-all..."
aws ec2 revoke-security-group-egress \
    --group-id "$SG_LAMBDA" \
    --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' \
    --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
aws ec2 authorize-security-group-egress \
    --group-id "$SG_LAMBDA" --protocol -1 --port -1 \
    --cidr 0.0.0.0/0 \
    --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
ok "Lambda SG egress: allow-all OK"

# ── Fix RDS SG ────────────────────────────────────────────
_SG_RDS=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${PROJECT}-sg-rds" \
    --query "SecurityGroups[0].GroupId" --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$_SG_RDS" ] && [ "$_SG_RDS" != "None" ]; then
    aws ec2 authorize-security-group-ingress \
        --group-id "$_SG_RDS" --protocol tcp --port 5432 \
        --source-group "$SG_LAMBDA" \
        --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
    aws ec2 revoke-security-group-ingress \
        --group-id "$_SG_RDS" --protocol tcp --port 5432 \
        --cidr 0.0.0.0/0 \
        --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
    ok "RDS SG: hanya allow dari sg-lambda"
fi

# ── Build Lambda Layer ────────────────────────────────────
log "Menghapus layer version lama..."
_OLD_VERS=$(aws lambda list-layer-versions \
    --layer-name "$LAYER_NAME" --region "$REGION" \
    --query "LayerVersions[].Version" --output text 2>/dev/null | tr "\t" "\n" || echo "")
for _V in $_OLD_VERS; do
    [ -z "$_V" ] || [ "$_V" = "None" ] && continue
    aws lambda delete-layer-version \
        --layer-name "$LAYER_NAME" --version-number "$_V" \
        --region "$REGION" 2>/dev/null && log "  Deleted layer v$_V" || true
done
aws s3 rm "s3://${S3_DEPLOY}/layer/" --recursive --region "$REGION" 2>/dev/null || true
LAYER_ARN=""

LAYER_DIR="/tmp/techno_layer"
REQUIREMENTS_FILE="${SCRIPT_DIR}/lambda/requirements.txt"
LAYER_BUILD_OK=false

if [ ! -f "$REQUIREMENTS_FILE" ]; then
    warn "requirements.txt tidak ditemukan — akan buat placeholder layer"
else
    rm -rf "$LAYER_DIR" && mkdir -p "${LAYER_DIR}/python"

    # Metode 1: Docker
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        log "Metode 1: Docker build (Amazon Linux 2023)..."
        docker run --rm \
            -v "${LAYER_DIR}/python:/var/task/python" \
            -v "${REQUIREMENTS_FILE}:/var/task/requirements.txt:ro" \
            public.ecr.aws/lambda/python:3.11 \
            pip install -r /var/task/requirements.txt \
                --target /var/task/python \
                --upgrade -q \
        && LAYER_BUILD_OK=true && ok "Docker build sukses" \
        || warn "Docker build gagal, coba metode lain..."
    else
        warn "Docker tidak tersedia, skip metode 1"
    fi

    # Metode 2: pip manylinux
    if [ "$LAYER_BUILD_OK" = "false" ]; then
        log "Metode 2: pip manylinux build..."
        pip3 install -r "$REQUIREMENTS_FILE" \
            --target "${LAYER_DIR}/python" \
            --platform manylinux2014_x86_64 \
            --implementation cp \
            --python-version 311 \
            --only-binary=:all: \
            --upgrade -q 2>/dev/null \
        && LAYER_BUILD_OK=true && ok "pip manylinux build sukses" \
        || warn "pip manylinux gagal, coba metode 3..."
    fi

    # Metode 3: aws-psycopg2 fallback
    if [ "$LAYER_BUILD_OK" = "false" ]; then
        log "Metode 3: aws-psycopg2 fallback..."
        rm -rf "${LAYER_DIR}/python" && mkdir -p "${LAYER_DIR}/python"
        grep -v "psycopg2" "$REQUIREMENTS_FILE" > /tmp/req_no_psyco.txt || true
        pip3 install -r /tmp/req_no_psyco.txt --target "${LAYER_DIR}/python" -q 2>/dev/null || true
        if pip3 install aws-psycopg2 --target "${LAYER_DIR}/python" -q 2>/dev/null; then
            LAYER_BUILD_OK=true && ok "aws-psycopg2 installed"
        elif pip3 install psycopg2-binary \
                --target "${LAYER_DIR}/python" \
                --platform manylinux2014_x86_64 \
                --implementation cp --python-version 311 \
                --only-binary=:all: -q 2>/dev/null; then
            LAYER_BUILD_OK=true && ok "psycopg2-binary manylinux wheel installed"
        else
            err "Semua metode instalasi psycopg2 gagal. Pastikan internet tersedia atau Docker bisa dijalankan."
        fi
    fi

    # Verifikasi
    if [ -d "${LAYER_DIR}/python/psycopg2" ]; then
        ok "psycopg2/ folder ditemukan di layer ✓"
    else
        warn "psycopg2/ folder TIDAK ditemukan di layer!"
    fi

    log "Zipping layer..."
    cd "$LAYER_DIR" && zip -qr /tmp/techno_layer.zip python/ && cd - > /dev/null
    LAYER_ZIP_SIZE=$(wc -c < /tmp/techno_layer.zip)
    log "Layer size: $(( LAYER_ZIP_SIZE / 1024 / 1024 )) MB"

    if [ "$LAYER_ZIP_SIZE" -gt 52428800 ]; then
        log "Layer > 50MB — upload via S3..."
        LAYER_S3_KEY="layer/${LAYER_NAME}-$(date +%s).zip"
        aws s3 cp /tmp/techno_layer.zip "s3://${S3_DEPLOY}/${LAYER_S3_KEY}" \
            --region "$REGION" --no-cli-pager
        LAYER_ARN=$(aws lambda publish-layer-version \
            --layer-name "$LAYER_NAME" \
            --description "Techno OMS deps manylinux" \
            --content "S3Bucket=${S3_DEPLOY},S3Key=${LAYER_S3_KEY}" \
            --compatible-runtimes python3.11 python3.10 \
            --region "$REGION" \
            --query LayerVersionArn --output text)
    else
        LAYER_ARN=$(aws lambda publish-layer-version \
            --layer-name "$LAYER_NAME" \
            --description "Techno OMS deps manylinux" \
            --zip-file "fileb:///tmp/techno_layer.zip" \
            --compatible-runtimes python3.11 python3.10 \
            --region "$REGION" \
            --query LayerVersionArn --output text)
    fi
    ok "Lambda Layer published: $LAYER_ARN"
fi

# Fallback placeholder layer jika belum ada
_LAYER_EXISTS=$(aws lambda list-layer-versions \
    --layer-name "$LAYER_NAME" --region "$REGION" \
    --query "LayerVersions[0].LayerVersionArn" --output text 2>/dev/null || echo "")
if [ -z "$_LAYER_EXISTS" ] || [ "$_LAYER_EXISTS" = "None" ]; then
    log "Membuat placeholder layer..."
    python3 -c "
import zipfile, io
code = b'# Techno OMS Lambda Layer placeholder\n'
buf = io.BytesIO()
with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('python/__init__.py', code)
open('/tmp/techno_layer_placeholder.zip','wb').write(buf.getvalue())
"
    LAYER_ARN=$(aws lambda publish-layer-version \
        --layer-name "$LAYER_NAME" \
        --description "Techno OMS layer (placeholder)" \
        --zip-file "fileb:///tmp/techno_layer_placeholder.zip" \
        --compatible-runtimes python3.11 python3.10 python3.9 \
        --region "$REGION" \
        --query LayerVersionArn --output text 2>/dev/null || echo "")
    [ -n "$LAYER_ARN" ] && ok "Placeholder layer published: $LAYER_ARN" || warn "Gagal publish placeholder layer"
else
    LAYER_ARN="$_LAYER_EXISTS"
    log "Layer sudah ada: $LAYER_ARN"
fi

# ── Placeholder zip untuk Lambda functions ────────────────
python3 -c "
import zipfile, io
code = b'import json\ndef lambda_handler(event, context):\n    return {\"statusCode\": 200, \"body\": json.dumps({\"status\": \"ok\"})}\n'
buf = io.BytesIO()
with zipfile.ZipFile(buf, 'w') as z:
    z.writestr('lambda_function.py', code)
open('/tmp/techno_placeholder.zip','wb').write(buf.getvalue())
"

ENV_COMMON="Variables={SECRET_ARN=${SECRET_ARN},SNS_TOPIC_ARN=${SNS_TOPIC_ARN},S3_ORDERS_BUCKET=${S3_ORDERS},S3_LOGS_BUCKET=${S3_LOGS},STEP_FUNCTIONS_ARN=PLACEHOLDER,REGION=${REGION},LOW_STOCK_THRESHOLD=5}"

get_func_config() {
    case "$1" in
        order_management)  echo "512:30:true"   ;;
        process_payment)   echo "512:30:true"   ;;
        update_inventory)  echo "256:45:true"   ;;
        send_notification) echo "256:60:true"   ;;
        generate_report)   echo "1024:120:true" ;;
        init_db)           echo "512:300:true"  ;;
        health_check)      echo "128:10:true"   ;;
    esac
}

# ── Deploy Lambda functions ───────────────────────────────
log "Deploying Lambda functions..."
for FUNC_BASE in order_management process_payment update_inventory \
                 send_notification generate_report init_db health_check; do
    case "$FUNC_BASE" in
        order_management)  FUNC_NAME="techno-lambda-order-management"  ;;
        process_payment)   FUNC_NAME="techno-lambda-process-payment"   ;;
        update_inventory)  FUNC_NAME="techno-lambda-update-inventory"  ;;
        send_notification) FUNC_NAME="techno-lambda-send-notification" ;;
        generate_report)   FUNC_NAME="techno-lambda-generate-report"   ;;
        init_db)           FUNC_NAME="techno-lambda-init-db"           ;;
        health_check)      FUNC_NAME="techno-lambda-health-check"      ;;
    esac
    CFG=$(get_func_config "$FUNC_BASE")
    IFS=':' read -r MEM TMO USE_VPC <<< "$CFG"

    FUNC_STATE=$(aws lambda get-function \
        --function-name "$FUNC_NAME" \
        --region "$REGION" --query "Configuration.State" \
        --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "$FUNC_STATE" = "NOT_FOUND" ]; then
        log "  Creating: $FUNC_NAME (${MEM}MB, ${TMO}s)"
        CREATE_ARGS=(
            --function-name "$FUNC_NAME"
            --runtime python3.11
            --role "$ROLE_ARN"
            --handler "lambda_function.lambda_handler"
            --zip-file "fileb:///tmp/techno_placeholder.zip"
            --memory-size "$MEM"
            --timeout "$TMO"
            --environment "$ENV_COMMON"
            --layers "$LAYER_ARN"
            --region "$REGION"
            --no-cli-pager
        )
        if [ "$USE_VPC" = "true" ]; then
            CREATE_ARGS+=(--vpc-config "SubnetIds=${PRIV_SN1},${PRIV_SN2},SecurityGroupIds=${SG_LAMBDA}")
        fi
        aws lambda create-function "${CREATE_ARGS[@]}" > /dev/null
        aws lambda wait function-active \
            --function-name "$FUNC_NAME" --region "$REGION"
        ok "  Created: $FUNC_NAME"
    else
        CURRENT_LAYER=$(aws lambda get-function-configuration \
            --function-name "$FUNC_NAME" --region "$REGION" \
            --query "Layers[0].Arn" --output text 2>/dev/null || echo "")
        if [ "$CURRENT_LAYER" != "$LAYER_ARN" ]; then
            aws lambda update-function-configuration \
                --function-name "$FUNC_NAME" \
                --environment "$ENV_COMMON" \
                --layers "$LAYER_ARN" \
                --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
            log "  Updated layer+env: $FUNC_NAME"
        else
            log "  Already OK (skip): $FUNC_NAME [$FUNC_STATE]"
        fi
    fi
done
ok "Lambda functions ready"

# ── Upload kode asli dari repo ────────────────────────────
log "Mengupload kode Lambda dari repo..."
for FUNC_BASE in order_management process_payment update_inventory \
                 send_notification generate_report init_db health_check; do
    case "$FUNC_BASE" in
        order_management)  FUNC_NAME="techno-lambda-order-management"  ;;
        process_payment)   FUNC_NAME="techno-lambda-process-payment"   ;;
        update_inventory)  FUNC_NAME="techno-lambda-update-inventory"  ;;
        send_notification) FUNC_NAME="techno-lambda-send-notification" ;;
        generate_report)   FUNC_NAME="techno-lambda-generate-report"   ;;
        init_db)           FUNC_NAME="techno-lambda-init-db"           ;;
        health_check)      FUNC_NAME="techno-lambda-health-check"      ;;
    esac
    SRC="${SCRIPT_DIR}/lambda/${FUNC_BASE}/lambda_function.py"
    if [ -f "$SRC" ]; then
        cd "${SCRIPT_DIR}/lambda/${FUNC_BASE}"
        zip -qj "/tmp/${FUNC_BASE}.zip" lambda_function.py
        cd - > /dev/null
        aws lambda update-function-code \
            --function-name "$FUNC_NAME" \
            --zip-file "fileb:///tmp/${FUNC_BASE}.zip" \
            --region "$REGION" --no-cli-pager > /dev/null
        aws lambda wait function-updated \
            --function-name "$FUNC_NAME" --region "$REGION" 2>/dev/null || true
        ok "  Code updated: $FUNC_NAME"
    else
        warn "  Source tidak ditemukan: $SRC"
    fi
done

# ── Refresh SECRET_ARN env var ────────────────────────────
log "Refreshing SECRET_ARN env var di semua Lambda..."
for _FN in techno-lambda-order-management techno-lambda-process-payment \
           techno-lambda-update-inventory techno-lambda-generate-report \
           techno-lambda-init-db techno-lambda-health-check; do
    _CURR=$(aws lambda get-function-configuration --function-name "$_FN" \
        --region "$REGION" --query "Environment.Variables.SECRET_ARN" \
        --output text 2>/dev/null || echo "")
    if [ "$_CURR" != "$SECRET_ARN" ]; then
        _ENV=$(aws lambda get-function-configuration --function-name "$_FN" \
            --region "$REGION" --query "Environment.Variables" --output json 2>/dev/null || echo "{}")
        _NEW_ENV=$(echo "$_ENV" | python3 -c "
import json,sys
e=json.load(sys.stdin)
e['SECRET_ARN']='${SECRET_ARN}'
print('Variables={' + ','.join(f'{k}={v}' for k,v in e.items()) + '}')
" 2>/dev/null || echo "Variables={SECRET_ARN=${SECRET_ARN}}")
        aws lambda update-function-configuration \
            --function-name "$_FN" \
            --environment "$_NEW_ENV" \
            --region "$REGION" --no-cli-pager > /dev/null 2>&1 || true
        log "  Updated SECRET_ARN: $_FN"
    fi
done
ok "Lambda SECRET_ARN env vars refreshed"

# ── Verifikasi akhir ──────────────────────────────────────
section "Verifikasi Step 5"
ALL_OK=true
for FUNC_NAME in techno-lambda-order-management techno-lambda-process-payment \
                 techno-lambda-update-inventory techno-lambda-send-notification \
                 techno-lambda-generate-report techno-lambda-init-db \
                 techno-lambda-health-check; do
    STATE=$(aws lambda get-function \
        --function-name "$FUNC_NAME" --region "$REGION" \
        --query "Configuration.State" --output text 2>/dev/null || echo "NOT_FOUND")
    if [ "$STATE" = "Active" ] || [ "$STATE" = "Idle" ]; then
        ok "$FUNC_NAME: $STATE"
    else
        warn "$FUNC_NAME: $STATE"
        ALL_OK=false
    fi
done

LAYER_CHECK=$(aws lambda list-layer-versions \
    --layer-name "$LAYER_NAME" --region "$REGION" \
    --query "LayerVersions[0].LayerVersionArn" --output text 2>/dev/null || echo "")
if [ -n "$LAYER_CHECK" ] && [ "$LAYER_CHECK" != "None" ]; then
    ok "Layer: $LAYER_CHECK"
else
    warn "Layer tidak ditemukan"
    ALL_OK=false
fi

echo ""
if [ "$ALL_OK" = "true" ]; then
    ok "Step 5 SELESAI — semua Lambda dan Layer OK."
    echo ""
    echo -e "${GRN}Lanjut ke step 6: bash judge4.sh deploy $STUDENT_NAME $EMAIL 6${NC}"
else
    warn "Step 5 selesai dengan beberapa warning. Cek output di atas."
fi

exit 0
