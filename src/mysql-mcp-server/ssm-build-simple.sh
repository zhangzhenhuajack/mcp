#!/bin/bash
set -e

INSTANCE_ID="i-0bd584877eeddfab4"
AWS_REGION="us-west-2"
AWS_ACCOUNT_ID="640168427976"
IMAGE_TAG="${1:-latest}"
ECR_REPO="mysql-mcp-server"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

# 创建临时目录并打包代码
echo "Packaging source code..."
TEMP_DIR=$(mktemp -d)
tar -czf ${TEMP_DIR}/mysql-mcp-server.tar.gz \
    --exclude='.venv' \
    --exclude='.git' \
    --exclude='__pycache__' \
    --exclude='.idea' \
    -C /Users/zhenhuae/gongsi/github/mcp/src/mysql-mcp-server .

# 上传到 S3
S3_BUCKET="your-build-bucket"
echo "Uploading to S3..."
aws s3 cp ${TEMP_DIR}/mysql-mcp-server.tar.gz s3://${S3_BUCKET}/mysql-mcp-server.tar.gz

echo "Executing build on EC2 via SSM..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids ${INSTANCE_ID} \
    --region ${AWS_REGION} \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=[
        "set -e",
        "cd /tmp",
        "rm -rf mysql-mcp-server",
        "mkdir -p mysql-mcp-server",
        "cd mysql-mcp-server",
        "aws s3 cp s3://'${S3_BUCKET}'/mysql-mcp-server.tar.gz .",
        "tar -xzf mysql-mcp-server.tar.gz",
        "docker build -f Dockerfile.http -t '${ECR_REPO}':'${IMAGE_TAG}' .",
        "docker tag '${ECR_REPO}':'${IMAGE_TAG}' '${ECR_URI}':'${IMAGE_TAG}'",
        "aws ecr get-login-password --region '${AWS_REGION}' | docker login --username AWS --password-stdin '${ECR_URI}'",
        "docker push '${ECR_URI}':'${IMAGE_TAG}'",
        "echo Image pushed: '${ECR_URI}':'${IMAGE_TAG}'"
    ]' \
    --output text \
    --query 'Command.CommandId')

echo "Command ID: ${COMMAND_ID}"
echo "Monitoring execution..."

# 清理临时文件
rm -rf ${TEMP_DIR}

# 等待完成
aws ssm wait command-executed \
    --command-id ${COMMAND_ID} \
    --instance-id ${INSTANCE_ID} \
    --region ${AWS_REGION} 2>&1 || true

# 显示输出
aws ssm get-command-invocation \
    --command-id ${COMMAND_ID} \
    --instance-id ${INSTANCE_ID} \
    --region ${AWS_REGION} \
    --query '[Status, StandardOutputContent, StandardErrorContent]' \
    --output text
