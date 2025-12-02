# MySQL MCP Server - HTTP Deployment Guide

基于 FastMCP 2.x 的 MySQL MCP Server HTTP 部署指南

## 概述

本项目提供了一个通过 HTTP 访问的 MySQL MCP Server，支持远程访问和多客户端连接。使用 FastMCP 2.13.2 框架，部署在 Kubernetes 上，通过 AWS Network Load Balancer 对外提供服务。

## 特性

- ✅ **Stateless HTTP Transport**: 无需 session 管理，支持多客户端并发访问
- ✅ **FastMCP 2.x**: 使用最新的 FastMCP 框架
- ✅ **AWS RDS 集成**: 支持 Aurora MySQL 和 RDS MySQL
- ✅ **只读模式**: 默认只允许 SELECT 查询，保护数据安全
- ✅ **Kubernetes 部署**: 高可用、可扩展的容器化部署
- ✅ **IAM 认证**: 使用 IRSA 访问 AWS Secrets Manager

## 可用工具

### 1. run_query
执行 SQL 查询

```json
{
  "name": "run_query",
  "arguments": {
    "sql": "SELECT * FROM table_name LIMIT 10"
  }
}
```

### 2. get_table_schema
获取表结构

```json
{
  "name": "get_table_schema",
  "arguments": {
    "database_name": "your_database",
    "table_name": "your_table"
  }
}
```

## 客户端配置

### Dify

在 Dify 的 MCP 配置中添加：

```json
{
  "mysql-mcp-server": {
    "transport": "sse",
    "url": "http://XXXXXX/mcp",
    "timeout": 50,
    "sse_read_timeout": 50
  }
}
```

### Claude Desktop / Cursor

```json
{
  "mcpServers": {
    "mysql-mcp-server": {
      "url": "http://XXXXXX/mcp"
    }
  }
}
```

### Amazon Q Developer CLI

编辑 `~/.aws/amazonq/mcp.json`:

```json
{
  "mcpServers": {
    "mysql-mcp-server": {
      "url": "http://XXXXXX/mcp"
    }
  }
}
```

## 部署架构

```
Client (Dify/Claude/Cursor)
    ↓ HTTP
Network Load Balancer (NLB)
    ↓
Kubernetes Service (ClusterIP)
    ↓
Pods (2 replicas)
    ↓
RDS MySQL / Aurora MySQL
```

## 快速部署

### 前置条件

1. Kubernetes 集群（EKS）
2. AWS CLI 配置
3. kubectl 配置
4. ECR 仓库
5. RDS MySQL 实例
6. Secrets Manager 中的数据库凭证

### 部署步骤

#### 1. 构建 Docker 镜像

```bash
# 打包代码
cd /path/to/mysql-mcp-server
tar -czf /tmp/mysql-mcp-server.tar.gz --exclude='.venv' --exclude='.git' --exclude='__pycache__' .

# 上传到 S3
aws s3 cp /tmp/mysql-mcp-server.tar.gz s3://your-bucket/ --region us-west-2

# 通过 SSM 在 EC2 上构建（如果本地没有 Docker）
aws ssm send-command \
  --instance-ids i-xxxxxxxxx \
  --region us-west-2 \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=[
    "cd /tmp/mysql-mcp-server",
    "aws s3 cp s3://your-bucket/mysql-mcp-server.tar.gz .",
    "tar -xzf mysql-mcp-server.tar.gz",
    "docker build -f Dockerfile.fastmcp -t your-account.dkr.ecr.us-west-2.amazonaws.com/rds-mysql-mcp-server:v1.0 .",
    "aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin your-account.dkr.ecr.us-west-2.amazonaws.com",
    "docker push your-account.dkr.ecr.us-west-2.amazonaws.com/rds-mysql-mcp-server:v1.0"
  ]'
```

#### 2. 配置 Kubernetes 资源

编辑 `k8s-deployment.yaml`，更新以下配置：

```yaml
# 镜像地址
image: your-account.dkr.ecr.us-west-2.amazonaws.com/rds-mysql-mcp-server:v1.0

# 环境变量
- name: HOSTNAME
  value: "your-rds-endpoint.rds.amazonaws.com"
- name: SECRET_ARN
  value: "arn:aws:secretsmanager:region:account:secret:your-secret"
- name: DATABASE
  value: "your_database"
- name: AWS_REGION
  value: "us-west-2"
- name: READONLY
  value: "True"
```

#### 3. 部署到 Kubernetes

```bash
# 应用配置
kubectl apply -f k8s-deployment.yaml

# 检查部署状态
kubectl rollout status deployment rds-mysql-mcp-server

# 查看 pods
kubectl get pods -l app=rds-mysql-mcp-server

# 查看服务
kubectl get svc rds-mysql-mcp-server-nlb
```

#### 4. 获取访问地址

```bash
# 获取 NLB 地址
kubectl get svc rds-mysql-mcp-server-nlb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

## 测试

### 测试连接

```bash
# 测试 MCP 端点
curl -v http://your-nlb-address/mcp

# 应该返回 406 Not Acceptable（正常，需要正确的 headers）
```

### 测试工具列表

```bash
curl -X POST \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  http://your-nlb-address/mcp
```

### 测试查询

```bash
curl -X POST \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run_query","arguments":{"sql":"SHOW TABLES"}}}' \
  http://your-nlb-address/mcp
```

### 测试表结构

```bash
curl -X POST \
  -H "Accept: application/json, text/event-stream" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_table_schema","arguments":{"database_name":"your_db","table_name":"your_table"}}}' \
  http://your-nlb-address/mcp
```

## 故障排查

### Pod 无法启动

```bash
# 查看 pod 日志
kubectl logs -l app=rds-mysql-mcp-server --tail=50

# 查看 pod 事件
kubectl describe pod -l app=rds-mysql-mcp-server
```

### 连接数据库失败

检查：
1. Secret ARN 是否正确
2. IAM Role 是否有 Secrets Manager 权限
3. RDS 安全组是否允许 EKS 访问
4. 数据库凭证是否正确

### 工具调用失败

```bash
# 查看实时日志
kubectl logs -f -l app=rds-mysql-mcp-server
```

## 配置说明

### 环境变量

| 变量 | 说明 | 必需 | 默认值 |
|------|------|------|--------|
| HOSTNAME | RDS 端点地址 | 是 | - |
| DB_PORT | 数据库端口 | 否 | 3306 |
| SECRET_ARN | Secrets Manager ARN | 是 | - |
| DATABASE | 数据库名称 | 是 | - |
| AWS_REGION | AWS 区域 | 是 | - |
| READONLY | 只读模式 | 是 | True |
| FASTMCP_LOG_LEVEL | 日志级别 | 否 | ERROR |

### 资源配置

当前配置（可根据负载调整）：

```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "250m"
  limits:
    memory: "512Mi"
    cpu: "500m"
```

### 副本数

```yaml
replicas: 2  # 高可用配置
```

## 技术栈

- **FastMCP**: 2.13.2
- **Python**: 3.13
- **Transport**: HTTP (Stateless)
- **Database Driver**: asyncmy
- **Container**: Alpine Linux
- **Orchestration**: Kubernetes

## 安全注意事项

1. **只读模式**: 默认启用，防止数据修改
2. **IAM 认证**: 使用 IRSA 访问 AWS 资源
3. **网络隔离**: 通过 NLB 和安全组控制访问
4. **凭证管理**: 数据库密码存储在 Secrets Manager

## 支持

如有问题，请检查：
1. Pod 日志：`kubectl logs -l app=rds-mysql-mcp-server`
2. 服务状态：`kubectl get svc,pods -l app=rds-mysql-mcp-server`
3. NLB 健康检查：AWS Console → EC2 → Load Balancers

## 参考资料

- [FastMCP 文档](https://gofastmcp.com)
- [MCP 协议规范](https://modelcontextprotocol.io)
- [AWS EKS 文档](https://docs.aws.amazon.com/eks/)
