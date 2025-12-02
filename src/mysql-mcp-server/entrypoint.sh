#!/bin/sh
set -e

export FASTMCP_HOST=0.0.0.0
export FASTMCP_PORT=8000

if [ -n "${HOSTNAME}" ]; then
    exec awslabs.mysql-mcp-server \
        --hostname "${HOSTNAME}" \
        --db-port "${DB_PORT:-3306}" \
        --secret_arn "${SECRET_ARN}" \
        --database "${DATABASE}" \
        --region "${AWS_REGION}" \
        --readonly "${READONLY:-True}" \
        --transport "sse"
else
    exec awslabs.mysql-mcp-server \
        --resource_arn "${RESOURCE_ARN}" \
        --secret_arn "${SECRET_ARN}" \
        --database "${DATABASE}" \
        --region "${AWS_REGION}" \
        --readonly "${READONLY:-True}" \
        --transport "sse"
fi
