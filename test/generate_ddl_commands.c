/*-------------------------------------------------------------------------
 *
 * test/generate_ddl_commands.c
 *
 * This file contains functions to exercise DDL generation functionality
 * within pg_shard.
 *
 * Copyright (c) 2014, Citus Data, Inc.
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"
#include "fmgr.h"
#include "postgres_ext.h"

#include "ddl_commands.h"
#include "test/test_helper_functions.h" /* IWYU pragma: keep */

#include <stddef.h>

#include "catalog/pg_type.h"
#include "lib/stringinfo.h"
#include "nodes/makefuncs.h"
#include "nodes/nodes.h"
#include "nodes/parsenodes.h"
#include "nodes/pg_list.h"
#include "nodes/value.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/palloc.h"


/* declarations for dynamic loading */
PG_FUNCTION_INFO_V1(table_ddl_command_array);
PG_FUNCTION_INFO_V1(alter_server_host_and_port_command);


/*
 * table_ddl_command_array returns an array of strings, each of which is a DDL
 * command required to recreate a table (specified by OID).
 */
Datum
table_ddl_command_array(PG_FUNCTION_ARGS)
{
	Oid distributedTableId = PG_GETARG_OID(0);
	ArrayType *ddlCommandArrayType = NULL;
	List *ddlCommandList = TableDDLCommandList(distributedTableId);
	int ddlCommandCount = list_length(ddlCommandList);
	Datum *ddlCommandDatumArray = palloc0(ddlCommandCount * sizeof(Datum));

	ListCell *ddlCommandCell = NULL;
	int ddlCommandIndex = 0;
	Oid ddlCommandTypeId = TEXTOID;

	foreach(ddlCommandCell, ddlCommandList)
	{
		char *ddlCommand = (char *) lfirst(ddlCommandCell);
		Datum ddlCommandDatum = CStringGetTextDatum(ddlCommand);

		ddlCommandDatumArray[ddlCommandIndex] = ddlCommandDatum;
		ddlCommandIndex++;
	}

	ddlCommandArrayType = DatumArrayToArrayType(ddlCommandDatumArray, ddlCommandCount,
												ddlCommandTypeId);

	PG_RETURN_ARRAYTYPE_P(ddlCommandArrayType);
}


/*
 * alter_server_host_and_port_command is used to test foreign server OPTION
 * generation. When provided with a foreign server name, hostname and port,
 * the function will return an ALTER SERVER command to set the server's host
 * and port options to the provided values.
 */
Datum
alter_server_host_and_port_command(PG_FUNCTION_ARGS)
{
	char *serverName = PG_GETARG_CSTRING(0);
	char *newHost = PG_GETARG_CSTRING(1);
	char *newPort = PG_GETARG_CSTRING(2);
	StringInfo alterCommand = makeStringInfo();

	DefElem *hostElem = makeDefElem("host", (Node *) makeString(newHost));
	DefElem *portElem = makeDefElem("port", (Node *) makeString(newPort));

	appendStringInfo(alterCommand, "ALTER SERVER %s", quote_identifier(serverName));
	AppendOptionListToString(alterCommand, list_make2(hostElem, portElem));

	PG_RETURN_TEXT_P(CStringGetTextDatum(alterCommand->data));
}
