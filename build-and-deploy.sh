#!/bin/bash
# ============================================================
# Script: Build Layer + Lambda ZIPs dan Upload ke S3
# Usage : bash build-and-deploy.sh <LAYER_S3_BUCKET> <LAMBDA_S3_BUCKET>
# ============================================================
set -e

LAYER_BUCKET="${1:-}"
LAMBDA_BUCKET="${2:-$LAYER_BUCKET}"

if [ -z "$LAYER_BUCKET" ]; then
  echo "Usage: bash build-and-deploy.sh <LAYER_S3_BUCKET> [LAMBDA_S3_BUCKET]"
  echo "  LAYER_S3_BUCKET  = bucket untuk layer zip"
  echo "  LAMBDA_S3_BUCKET = bucket untuk lambda zips (default: sama dengan layer bucket)"
  exit 1
fi

echo "=== Layer bucket  : $LAYER_BUCKET"
echo "=== Lambda bucket : $LAMBDA_BUCKET"
echo ""

# ── 1. BUILD LAYER ──────────────────────────────────────────
echo "[1/3] Building Lambda Layer (python3.11 compatible)..."
rm -rf /tmp/layer-build /tmp/techno-layer-dependencies.zip
mkdir -p /tmp/layer-build/python

pip install \
  psycopg2-binary==2.9.9 \
  "boto3>=1.34.0" \
  "requests>=2.31.0" \
  "pandas>=2.1.0" \
  "openpyxl>=3.1.2" \
  "aws-xray-sdk>=2.12.0" \
  --target /tmp/layer-build/python \
  --platform manylinux2014_x86_64 \
  --python-version 3.11 \
  --only-binary=:all: \
  --upgrade \
  -q

cd /tmp/layer-build
zip -r /tmp/techno-layer-dependencies.zip python/ -q
echo "   Layer zip size: $(du -sh /tmp/techno-layer-dependencies.zip | cut -f1)"

# Upload layer
echo "   Uploading layer to s3://$LAYER_BUCKET/layer/techno-layer-dependencies.zip ..."
aws s3 cp /tmp/techno-layer-dependencies.zip "s3://$LAYER_BUCKET/layer/techno-layer-dependencies.zip"
echo "   Layer uploaded."

# ── 2. BUILD LAMBDA ZIPS ────────────────────────────────────
echo ""
echo "[2/3] Building Lambda function ZIPs..."

FUNCTIONS=(
  "order_management"
  "process_payment"
  "update_inventory"
  "send_notification"
  "generate_report"
  "health_check"
  "init_db"
)

cd "$(dirname "$0")/lambda"

for fn in "${FUNCTIONS[@]}"; do
  if [ -d "$fn" ]; then
    echo "   Zipping $fn ..."
    cd "$fn"
    zip -r "/tmp/${fn}_lambda.zip" lambda_function.py -q
    cd ..
    echo "   Uploading s3://$LAMBDA_BUCKET/${fn}/lambda_function.zip ..."
    aws s3 cp "/tmp/${fn}_lambda.zip" "s3://$LAMBDA_BUCKET/${fn}/lambda_function.zip"
  else
    echo "   WARNING: folder $fn tidak ditemukan, skip."
  fi
done

# ── 3. DONE ─────────────────────────────────────────────────
echo ""
echo "[3/3] Semua file berhasil diupload."
echo ""
echo "Langkah selanjutnya:"
echo "  1. Deploy stack 04-compute.yaml dengan parameter:"
echo "     LayerS3Bucket=$LAYER_BUCKET"
echo "     LambdaS3Bucket=$LAMBDA_BUCKET"
echo "  2. Deploy stack 05-orchestration.yaml"
