#!/bin/bash
# ============================================================
# Build Lambda Layer menggunakan Docker (Amazon Linux 2023)
# Gunakan ini jika build-and-deploy.sh gagal karena binary mismatch
# Usage: bash build-layer-docker.sh <S3_BUCKET>
# ============================================================
set -e

S3_BUCKET="${1:-}"
if [ -z "$S3_BUCKET" ]; then
  echo "Usage: bash build-layer-docker.sh <S3_BUCKET>"
  exit 1
fi

echo "Building layer dengan Docker (Amazon Linux 2023 / python3.11)..."

docker run --rm \
  -v "$(pwd)/lambda:/lambda" \
  -v "/tmp:/output" \
  public.ecr.aws/lambda/python:3.11 \
  bash -c "
    pip install \
      psycopg2-binary==2.9.9 \
      'boto3>=1.34.0' \
      'requests>=2.31.0' \
      'pandas>=2.1.0' \
      'openpyxl>=3.1.2' \
      'aws-xray-sdk>=2.12.0' \
      --target /tmp/python -q && \
    cd /tmp && \
    zip -r /output/techno-layer-dependencies.zip python/ -q && \
    echo 'Layer zip created.'
  "

echo "Uploading ke s3://$S3_BUCKET/layer/techno-layer-dependencies.zip ..."
aws s3 cp /tmp/techno-layer-dependencies.zip "s3://$S3_BUCKET/layer/techno-layer-dependencies.zip"
echo "Done. Layer berhasil diupload."
