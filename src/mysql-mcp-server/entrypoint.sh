#!/bin/sh
set -e

if [ -n "${HOSTNAME}" ]; then
    exec awslabs.mysql-mcp-server \
        --hostname "${HOSTNAME}" \
        --db-port "${DB_PORT:-3306}" \
        --secret_arn "${SECRET_ARN}" \
        --database "${DATABASE}" \
        --region "${AWS_REGION}" \
        --readonly "${READONLY:-True}" \
        --transport "http"
else
    exec awslabs.mysql-mcp-server \
        --resource_arn "${RESOURCE_ARN}" \
        --secret_arn "${SECRET_ARN}" \
        --database "${DATABASE}" \
        --region "${AWS_REGION}" \
        --readonly "${READONLY:-True}" \
        --transport "http"
fi
