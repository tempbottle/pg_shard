/* pg_shard--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_shard" to load this file. \quit

-- the pgs_distribution_metadata schema stores data distribution information
CREATE SCHEMA pgs_distribution_metadata

	-- shard keeps track of hash value ranges for each shard
	CREATE TABLE shard (
		id bigint primary key,
		relation_id oid not null,
		storage "char" not null,
		min_value text not null,
		max_value text not null
	)

	-- shard_placement records which nodes contain which shards
	CREATE TABLE shard_placement (
		id bigint primary key,
		shard_id bigint not null references shard(id),
		shard_state integer not null,
		node_name text not null,
		node_port integer not null
	)

	-- partition lists a partition key for each distributed table
	CREATE TABLE partition (
		relation_id oid unique not null,
		partition_method "char" not null,
		key text not null
	)

	-- make a few more indexes for fast access
	CREATE INDEX shard_relation_index ON shard (relation_id)
	CREATE INDEX shard_placement_node_name_node_port_index
		ON shard_placement (node_name, node_port)
	CREATE INDEX shard_placement_shard_index ON shard_placement (shard_id)

	-- make sequences for shards and placements
	CREATE SEQUENCE shard_id_sequence MINVALUE 10000 NO CYCLE
	CREATE SEQUENCE shard_placement_id_sequence NO CYCLE;

-- mark each of the above as config tables to have pg_dump preserve them
SELECT pg_catalog.pg_extension_config_dump(
	'pgs_distribution_metadata.shard', '');
SELECT pg_catalog.pg_extension_config_dump(
	'pgs_distribution_metadata.shard_placement', '');
SELECT pg_catalog.pg_extension_config_dump(
	'pgs_distribution_metadata.partition', '');

-- define the table distribution functions
CREATE FUNCTION master_create_distributed_table(table_name text, partition_column text,
												partition_method "char" DEFAULT 'h')
RETURNS void
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION master_create_worker_shards(table_name text, shard_count integer,
											replication_factor integer DEFAULT 2)
RETURNS void
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

-- define the repair functions
CREATE FUNCTION master_copy_shard_placement(shard_id bigint,
											source_node_name text,
											source_node_port integer,
											target_node_name text,
											target_node_port integer)
RETURNS void
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION worker_copy_shard_placement(table_name text, source_node_name text,
											source_node_port integer)
RETURNS void
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION partition_column_to_node_string(table_oid oid)
RETURNS text
AS 'MODULE_PATHNAME'
LANGUAGE C;

COMMENT ON FUNCTION partition_column_to_node_string(oid)
		IS 'return textual form of distributed table''s partition column';

CREATE FUNCTION sync_table_metadata_to_citus(table_name text) RETURNS VOID
AS $sync_table_metadata_to_citus$
	DECLARE
		table_relation_id CONSTANT oid NOT NULL := table_name::regclass::oid;
		dummy_shard_length CONSTANT bigint := 0;
	BEGIN
		-- copy shard placement metadata
		INSERT INTO pg_dist_shard_placement
					(shardid,
					 shardstate,
					 shardlength,
					 nodename,
					 nodeport)
		SELECT shard_id,
			   shard_state,
			   dummy_shard_length,
			   node_name,
			   node_port
		FROM   pgs_distribution_metadata.shard_placement
		WHERE  shard_id IN (SELECT id
							FROM   pgs_distribution_metadata.shard
							WHERE  relation_id = table_relation_id);

		-- copy shard metadata
		INSERT INTO pg_dist_shard
					(shardid,
					 logicalrelid,
					 shardstorage,
					 shardminvalue,
					 shardmaxvalue)
		SELECT id,
			   relation_id,
			   storage,
			   min_value,
			   max_value
		FROM   pgs_distribution_metadata.shard
		WHERE  relation_id = table_relation_id;

		-- copy partition metadata, which also converts the partition column to
		-- a node string representation as expected by CitusDB
		INSERT INTO pg_dist_partition
					(logicalrelid,
					 partmethod,
					 partkey)
		SELECT relation_id,
			   partition_method,
			   partition_column_to_node_string(table_relation_id)
		FROM   pgs_distribution_metadata.partition
		WHERE  relation_id = table_relation_id;
	END;
$sync_table_metadata_to_citus$ LANGUAGE 'plpgsql';

COMMENT ON FUNCTION sync_table_metadata_to_citus(text)
		IS 'synchronize a distributed table''s pg_shard metadata to CitusDB';
