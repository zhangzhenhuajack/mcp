# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""awslabs mysql MCP Server implementation."""

import argparse
import asyncio
import sys
from awslabs.mysql_mcp_server.connection import DBConnectionSingleton
from awslabs.mysql_mcp_server.connection.asyncmy_pool_connection import AsyncmyPoolConnection
from awslabs.mysql_mcp_server.mutable_sql_detector import (
    check_sql_injection_risk,
    detect_mutating_keywords,
)
from botocore.exceptions import ClientError
from loguru import logger
from fastmcp import Context, FastMCP
from pydantic import Field
from typing import Annotated, Any, Dict, List, Optional


client_error_code_key = 'run_query ClientError code'
unexpected_error_key = 'run_query unexpected error'
write_query_prohibited_key = 'Your MCP tool only allows readonly query. If you want to write, change the MCP configuration per README.md'
query_injection_risk_key = 'Your query contains risky injection patterns'


class DummyCtx:
    """A dummy context class for error handling in MCP tools."""

    async def error(self, message):
        """Raise a runtime error with the given message.

        Args:
            message: The error message to include in the runtime error
        """
        # Do nothing
        pass


def extract_cell(cell: dict):
    """Extracts the scalar or array value from a single cell."""
    if cell.get('isNull'):
        return None
    for key in (
        'stringValue',
        'longValue',
        'doubleValue',
        'booleanValue',
        'blobValue',
        'arrayValue',
    ):
        if key in cell:
            return cell[key]
    return None


def parse_execute_response(response: dict) -> list[dict]:
    """Convert RDS Data API execute_statement response to list of rows."""
    columns = [col['label'] for col in response.get('columnMetadata', [])]
    records = []

    for row in response.get('records', []):
        row_data = {col: extract_cell(cell) for col, cell in zip(columns, row)}
        records.append(row_data)

    return records


mcp = FastMCP(
    'awslabs.mysql-mcp-server',
    instructions='You are an expert MySQL assistant. Use run_query and get_table_schema to interfact with the database.',
    dependencies=['loguru', 'boto3', 'pydantic'],
)


# Internal helper function for executing queries
async def _execute_query_internal(
    sql: str,
    ctx: Context,
    db_connection=None,
    query_parameters: Optional[List[Dict[str, Any]]] = None,
) -> list[dict]:
    """Internal function to execute SQL queries."""
    global client_error_code_key, unexpected_error_key, write_query_prohibited_key

    if db_connection is None:
        db_connection = DBConnectionSingleton.get().db_connection

    if db_connection is None:
        raise AssertionError('db_connection should never be None')

    if db_connection.readonly_query:
        matches = detect_mutating_keywords(sql)
        if (bool)(matches):
            logger.info(f'query rejected: readonly only. keywords: {matches}')
            await ctx.error(write_query_prohibited_key)
            return [{'error': write_query_prohibited_key}]

    issues = check_sql_injection_risk(sql)
    if issues:
        logger.info(f'query rejected: risky pattern. reasons: {issues}')
        await ctx.error(str({'message': 'Query parameter contains suspicious pattern', 'details': issues}))
        return [{'error': query_injection_risk_key}]

    try:
        logger.info(f'run_query: readonly:{db_connection.readonly_query}, SQL:{sql}')
        response = await db_connection.execute_query(sql, query_parameters)
        logger.success('run_query successfully executed')
        return parse_execute_response(response)
    except ClientError as e:
        logger.exception(client_error_code_key)
        await ctx.error(str({'code': e.response['Error']['Code'], 'message': e.response['Error']['Message']}))
        return [{'error': client_error_code_key}]
    except Exception as e:
        logger.exception(unexpected_error_key)
        await ctx.error(str({'message': f'{type(e).__name__}: {str(e)}'}))
        return [{'error': unexpected_error_key}]


@mcp.tool(name='run_query', description='Run a SQL query against a MySQL database')
async def run_query(
    sql: Annotated[str, Field(description='The SQL query to run')],
    ctx: Context,
    db_connection=None,
    query_parameters: Annotated[
        Optional[List[Dict[str, Any]]], Field(description='Parameters for the SQL query')
    ] = None,
) -> list[dict]:
    """Run a SQL query against a MySQL database."""
    return await _execute_query_internal(sql, ctx, db_connection, query_parameters)


@mcp.tool(
    name='get_table_schema',
    description='Fetch table schema from the MySQL database',
)
async def get_table_schema(
    table_name: Annotated[str, Field(description='name of the table')],
    database_name: Annotated[str, Field(description='name of the database')],
    ctx: Context,
) -> list[dict]:
    """Get a table's schema information given the table name."""
    logger.info(f'get_table_schema: {table_name}')

    sql = """
        SELECT
            COLUMN_NAME,
            COLUMN_TYPE,
            IS_NULLABLE,
            COLUMN_DEFAULT,
            EXTRA,
            COLUMN_KEY,
            COLUMN_COMMENT
        FROM
            information_schema.columns
        WHERE
            table_schema = %s
            AND table_name = %s
        ORDER BY
            ORDINAL_POSITION
    """
    
    params = [
        {'name': 'database_name', 'value': {'stringValue': database_name}},
        {'name': 'table_name', 'value': {'stringValue': table_name}},
    ]
    
    # Call internal helper function
    return await _execute_query_internal(sql=sql, ctx=ctx, query_parameters=params)


def main():
    """Main entry point for the MCP server application."""
    global client_error_code_key

    """Run the MCP server with CLI argument support."""
    parser = argparse.ArgumentParser(
        description='An AWS Labs Model Context Protocol (MCP) server for MySQL'
    )

    # Connection method 1: RDS Data API for Aurora MySQL
    parser.add_argument('--resource_arn', help='ARN of the Aurora MySQL cluster')

    # Connection method 2: asyncmy for RDS MySQL and RDS MariaDB
    parser.add_argument('--hostname', help='RDS MySQL Database hostname')
    parser.add_argument('--db-port', type=int, default=3306, help='Database port (default: 3306)')

    parser.add_argument(
        '--secret_arn',
        required=True,
        help='ARN of the Secrets Manager secret for database credentials',
    )
    parser.add_argument('--database', required=True, help='Database name')
    parser.add_argument('--region', required=True, help='AWS region')
    parser.add_argument(
        '--readonly', required=True, help='Enforce NL to SQL to only allow readonly sql statement'
    )
    parser.add_argument(
        '--transport',
        choices=['stdio', 'http'],
        default='stdio',
        help='Transport protocol: stdio (default) or http',
    )
    args = parser.parse_args()

    # Validate connection parameters
    if not args.resource_arn and not args.hostname:
        parser.error('Either --resource_arn or --hostname must be provided')

    if args.resource_arn and args.hostname:
        parser.error(
            'Cannot specify both --resource_arn and --hostname. Choose one connection method.'
        )

    if args.resource_arn:
        logger.info(
            f'MySQL MCP init with RDS Data API: CONNECTION_TARGET:{args.resource_arn}, SECRET_ARN:{args.secret_arn}, REGION:{args.region}, DATABASE:{args.database}, READONLY:{args.readonly}'
        )
    else:
        logger.info(
            f'MySQL/MariaDB MCP init with asyncmy: CONNECTION_TARGET:{args.hostname}, PORT:{args.db_port}, DATABASE:{args.database}, READONLY:{args.readonly}'
        )

    # Create the appropriate database connection based on the provided parameters
    try:
        if args.resource_arn:
            # Use RDS Data API with singleton pattern
            DBConnectionSingleton.initialize(
                resource_arn=args.resource_arn,
                secret_arn=args.secret_arn,
                database=args.database,
                region=args.region,
                readonly=args.readonly.lower(),
            )

            # Test database connection
            db_connection = DBConnectionSingleton.get().db_connection
            ctx = DummyCtx()
            response = asyncio.run(run_query('SELECT 1', ctx, db_connection))

            if (
                isinstance(response, list)
                and len(response) == 1
                and isinstance(response[0], dict)
                and 'error' in response[0]
            ):
                logger.error(
                    'Failed to validate database connection to MySQL. Exit the MCP server'
                )
                sys.exit(1)

            logger.success('Successfully validated database connection to MySQL')
        else:
            # Use direct MySQL connection singleton with asyncmy
            # note: asyncmy pools are tied to their event loop, so testing DB connection must run inside MCP's loop.
            DBConnectionSingleton.initialize(
                secret_arn=args.secret_arn,
                database=args.database,
                region=args.region,
                readonly=args.readonly.lower(),
                hostname=args.hostname,
                port=args.db_port,
            )
    except Exception as e:
        logger.exception(f'Failed to create MySQL connection: {str(e)}')
        sys.exit(1)

    # Run server with appropriate transport
    if args.transport == 'stdio':
        logger.info('Starting MySQL MCP server with stdio transport')
        mcp.run()
    else:  # http
        logger.info(f'Starting MySQL MCP server with HTTP transport (stateless) on 0.0.0.0:8000')
        mcp.run(transport="http", host="0.0.0.0", port=8000, stateless_http=True)


if __name__ == '__main__':
    main()
