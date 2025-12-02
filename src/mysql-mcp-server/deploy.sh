#!/bin/bash
set -e

COMMAND_ID="5d861856-815e-49c0-868e-f5982e20bddd"
SECRET_ARN="${1:-arn:aws:secretsmanager:us-west-2:640168427976:secret:YOUR_SECRET_NAME}"

echo "=== 步骤 1: 等待镜像构建完成 ==="
echo "Command ID: ${COMMAND_ID}"
for i in {1..30}; do
    STATUS=$(aws ssm get-command-invocation --command-id ${COMMAND_ID} --instance-id i-0bd584877eeddfab4 --region us-west-2 --query 'Status' --output text 2>/dev/null || echo "Pending")
    echo "[$i/30] 构建状态: ${STATUS}"
    if [ "$STATUS" = "Success" ]; then
        echo "✅ 镜像构建成功！"
        break
    elif [ "$STATUS" = "Failed" ]; then
        echo "❌ 构建失败，查看错误："
        aws ssm get-command-invocation --command-id ${COMMAND_ID} --instance-id i-0bd584877eeddfab4 --region us-west-2 --query 'StandardErrorContent' --output text
        exit 1
    fi
    sleep 10
done

echo ""
echo "=== 步骤 2: 验证 ECR 镜像 ==="
aws ecr describe-images --repository-name rds-mysql-mcp-server --region us-west-2 --query 'imageDetails[0].[imageTags[0], imagePushedAt]' --output table

echo ""
echo "=== 步骤 3: 更新 K8s 配置中的 SECRET_ARN ==="
sed -i.bak "s|arn:aws:secretsmanager:us-west-2:640168427976:secret:YOUR_SECRET_NAME|${SECRET_ARN}|g" k8s-deployment.yaml

echo ""
echo "=== 步骤 4: 部署到 Kubernetes ==="
kubectl apply -f k8s-deployment.yaml

echo ""
echo "=== 步骤 5: 等待 Pod 就绪 ==="
kubectl wait --for=condition=ready pod -l app=mysql-mcp-server --timeout=300s

echo ""
echo "=== 步骤 6: 检查部署状态 ==="
kubectl get pods -l app=mysql-mcp-server
kubectl get svc mysql-mcp-server-nlb
kubectl get svc mysql-mcp-server-internal

echo ""
echo "=== 部署完成 ==="
echo "外网访问: kubectl get svc mysql-mcp-server-nlb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
echo "内网访问: mysql-mcp-server-internal:8000"
