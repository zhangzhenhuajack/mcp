# MySQL MCP Server HTTP 部署指南

## 前置准备

### 1. 创建 ECR 仓库
```bash
aws ecr create-repository \
    --repository-name mysql-mcp-server \
    --region us-west-2
```

记录输出的 repositoryUri，格式为：`YOUR_AWS_ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/mysql-mcp-server`

### 2. 创建 IAM Role (用于 IRSA)
```bash
# 创建信任策略
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::YOUR_AWS_ACCOUNT_ID:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/YOUR_OIDC_ID"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.us-west-2.amazonaws.com/id/YOUR_OIDC_ID:sub": "system:serviceaccount:default:mysql-mcp-server"
        }
      }
    }
  ]
}
EOF

# 创建 Role
aws iam create-role \
    --role-name mysql-mcp-server-role \
    --assume-role-policy-document file://trust-policy.json

# 附加策略
aws iam attach-role-policy \
    --role-name mysql-mcp-server-role \
    --policy-arn arn:aws:iam::aws:policy/AmazonRDSDataFullAccess

aws iam attach-role-policy \
    --role-name mysql-mcp-server-role \
    --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite
```

## 构建和推送镜像

### 方式 1: 本地构建
```bash
# 修改 build-and-push.sh 中的 AWS_ACCOUNT_ID
vim build-and-push.sh

# 执行构建
./build-and-push.sh v1.0.0
```

### 方式 2: 通过 SSM 在 EC2 上构建
```bash
# 修改 ssm-build.sh 中的配置
vim ssm-build.sh

# 执行远程构建
./ssm-build.sh v1.0.0
```

## 部署到 Kubernetes

### 1. 修改配置
编辑 `k8s-deployment.yaml`，替换以下占位符：
- `YOUR_AWS_ACCOUNT_ID` - 你的 AWS 账号 ID
- `YOUR_SECRET_NAME` - Secrets Manager 中的密钥名称
- 确认 RESOURCE_ARN 的集群名称正确

### 2. 部署
```bash
kubectl apply -f k8s-deployment.yaml
```

### 3. 验证部署
```bash
# 检查 Pod 状态
kubectl get pods -l app=mysql-mcp-server

# 检查 Service
kubectl get svc mysql-mcp-server-nlb
kubectl get svc mysql-mcp-server-internal

# 查看日志
kubectl logs -l app=mysql-mcp-server -f
```

## 访问服务

### 外部访问 (NLB)
```bash
# 获取 NLB 地址
NLB_URL=$(kubectl get svc mysql-mcp-server-nlb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "External URL: http://${NLB_URL}"

# 测试连接
curl http://${NLB_URL}/health
```

### 内部访问 (ClusterIP)
```bash
# 在集群内访问
curl http://mysql-mcp-server-internal:8000/health
```

## 环境变量说明

| 变量 | 说明 | 示例 |
|------|------|------|
| RESOURCE_ARN | Aurora 集群 ARN | arn:aws:rds:us-west-2:123456789012:cluster:my-cluster |
| SECRET_ARN | Secrets Manager ARN | arn:aws:secretsmanager:us-west-2:123456789012:secret:my-secret |
| DATABASE | 数据库名称 | new-cost-data |
| AWS_REGION | AWS 区域 | us-west-2 |
| READONLY | 是否只读 | True/False |

## 故障排查

```bash
# 查看 Pod 详情
kubectl describe pod -l app=mysql-mcp-server

# 查看事件
kubectl get events --sort-by='.lastTimestamp'

# 进入容器调试
kubectl exec -it <pod-name> -- sh
```
