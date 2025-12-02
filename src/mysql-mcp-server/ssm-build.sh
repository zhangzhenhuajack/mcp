#!/bin/bash
set -e

INSTANCE_ID="i-0bd584877eeddfab4"
AWS_REGION="us-west-2"
AWS_ACCOUNT_ID="640168427976"
IMAGE_TAG="${1:-latest}"
ECR_REPO="mysql-mcp-server"
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

echo "Executing build on EC2 instance via SSM..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids ${INSTANCE_ID} \
    --region ${AWS_REGION} \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=[
        "set -e",
        "cd /tmp",
        "rm -rf mcp",
        "git clone https://github.com/awslabs/mcp.git",
        "cd mcp/src/mysql-mcp-server",
        "echo Building Docker image...",
        "docker build -f Dockerfile.http -t '${ECR_REPO}':'${IMAGE_TAG}' .",
        "echo Tagging image for ECR...",
        "docker tag '${ECR_REPO}':'${IMAGE_TAG}' '${ECR_URI}':'${IMAGE_TAG}'",
        "echo Logging in to ECR...",
        "aws ecr get-login-password --region '${AWS_REGION}' | docker login --username AWS --password-stdin '${ECR_URI}'",
        "echo Pushing image to ECR...",
        "docker push '${ECR_URI}':'${IMAGE_TAG}'",
        "echo Done! Image pushed to: '${ECR_URI}':'${IMAGE_TAG}'"
    ]' \
    --output text \
    --query 'Command.CommandId')

echo "Command ID: ${COMMAND_ID}"
echo "Waiting for command to complete..."

aws ssm wait command-executed \
    --command-id ${COMMAND_ID} \
    --instance-id ${INSTANCE_ID} \
    --region ${AWS_REGION}

echo "Getting command output..."
aws ssm get-command-invocation \
    --command-id ${COMMAND_ID} \
    --instance-id ${INSTANCE_ID} \
    --region ${AWS_REGION} \
    --query 'StandardOutputContent' \
    --output text

echo "Build completed successfully!"
