#!/bin/bash
set -e

# 配置
AWS_ACCOUNT_ID="640168427976"
AWS_REGION="us-west-2"
ECR_REPO="mysql-mcp-server"
IMAGE_TAG="${1:-latest}"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

echo "Building Docker image..."
docker build -f Dockerfile.http -t ${ECR_REPO}:${IMAGE_TAG} .

echo "Tagging image for ECR..."
docker tag ${ECR_REPO}:${IMAGE_TAG} ${ECR_URI}:${IMAGE_TAG}

echo "Logging in to ECR..."
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_URI}

echo "Pushing image to ECR..."
docker push ${ECR_URI}:${IMAGE_TAG}

echo "Done! Image pushed to: ${ECR_URI}:${IMAGE_TAG}"
