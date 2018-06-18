if objectproperty(object_id('dbo.script_indexes'), 'IsProcedure') is null begin
    exec('create proc dbo.script_indexes as')
end
go
--------------------------------------------------------------------------------
-- proc    : script_indexes
-- author  : mattmc3
-- version : v0.2.0-20180612
-- purpose : Generates index scripts for tables.
-- license : MIT
--           https://github.com/mattmc3/sqlgen-procs/blob/master/LICENSE
-- params  : @database_name - The name of the database where the table(s) to
--                            script reside. Optional - defaults to current db
--           @table_name - The name of the table to script. Optional - defaults
--                         to all tables in the database.
--           @schema_name - The name of the schema for scripting table indexes.
--                          Optional - defaults to all schemas, or 'dbo' if
--                          @table_name was specified.
--           @index_name - The name of the index to script. Optional - returns
--                         all indexes if not specified.
-- todos  : All the things
--------------------------------------------------------------------------------
alter procedure dbo.script_indexes
     @database_name nvarchar(128) = null
    ,@table_name nvarchar(128) = null
    ,@schema_name nvarchar(128) = null
    ,@index_name nvarchar(128) = null
as
begin

set nocount on

-- #DEBUG
-- declare @database_name nvarchar(128) = null
--       , @table_name nvarchar(128) = null
--       , @schema_name nvarchar(128) = null
--       , @index_name nvarchar(128) = null

-- vars
declare @sql nvarchar(max)
      , @now datetime = getdate()
      , @strnow nvarchar(50)
      , @CRLF nvarchar(2) = nchar(13) + nchar(10)

-- don't rely on FORMAT() since early SQL Server is missing it
select @strnow = cast(datepart(month, @now) as nvarchar(2)) + '/' +
                 cast(datepart(day, @now) as nvarchar(2)) + '/' +
                 cast(datepart(year, @now) as nvarchar(4)) + ' ' +
                 cast(datepart(hour, @now) % 12 as nvarchar(2)) + ':' +
                 right('0' + cast(datepart(minute, @now) as nvarchar(2)), 2) + ':' +
                 right('0' + cast(datepart(second, @now) as nvarchar(2)), 2) + ' ' +
                 case when datepart(hour, @now) < 12 then 'AM' else 'PM' end

-- defaults
select @database_name = isnull(@database_name, db_name())
if @table_name is not null begin
    select @schema_name = isnull(@schema_name, 'dbo')
end

-- make helper table of 20 numbers (0-19)
declare @nums table (num int)
;with numbers as (
    select 0 as num
    union all
    select num + 1
    from numbers
    where num <= 20
)
insert into @nums
select num
from numbers n


-- get index metadata ==========================================================
declare @idx table (
     mssql_object_id      int
    ,table_catalog        nvarchar(128)
    ,table_schema         nvarchar(128)
    ,table_name           nvarchar(128)
    ,index_name           nvarchar(128)
    ,table_type           varchar(10)
    ,is_ms_shipped        bit
    ,file_group           nvarchar(128)
    ,index_id             int
    ,[type]               tinyint
    ,[type_desc]          nvarchar(60)
    ,is_unique            bit
    ,data_space_id        int
    ,[ignore_dup_key]     bit
    ,is_primary_key       bit
    ,is_unique_constraint bit
    ,fill_factor          tinyint
    ,is_padded            bit
    ,is_disabled          bit
    ,is_hypothetical      bit
    ,[allow_row_locks]    bit
    ,[allow_page_locks]   bit
    ,has_filter           bit
    ,filter_definition    nvarchar(max)
    ,[compression_delay]  int
)

set @sql = 'use ' + quotename(@database_name) + ';
    select o.object_id as mssql_object_id
         , db_name()   as table_catalog
         , s.name      as table_schema
         , o.name      as table_name
         , i.name      as index_name
         , case o.type
                when ''U'' then ''BASE TABLE''
                when ''V'' then ''VIEW''
            end as table_type
         , t.is_ms_shipped
         , isnull(filegroup_name(t.filestream_data_space_id), ''PRIMARY'') as file_group
         , i.index_id
         , i.type
         , i.type_desc
         , i.is_unique
         , i.data_space_id
         , i.ignore_dup_key
         , i.is_primary_key
         , i.is_unique_constraint
         , i.fill_factor
         , i.is_padded
         , i.is_disabled
         , i.is_hypothetical
         , i.allow_row_locks
         , i.allow_page_locks
         , i.has_filter
         , i.filter_definition
         , i.compression_delay
    from sys.indexes i
    join sys.objects o  on i.object_id = o.object_id
    join sys.tables t   on o.object_id = t.object_id
    join sys.schemas s  on s.schema_id = o.schema_id
    where o.type in (''U'', ''V'')
    order by 2, 3, 4, 5
'
if object_id('tempdb..##__idx__23D182FE__') is not null drop table ##__idx__23D182FE__
exec sp_executesql @sql

insert into @idx select * from ##__idx__23D182FE__ t
drop table ##__idx__23D182FE__


-- get index column metadata ===================================================
declare @idx_cols table (
     mssql_object_id    int
    ,table_catalog      nvarchar(128)
    ,table_schema       nvarchar(128)
    ,table_name         nvarchar(128)
    ,index_name         nvarchar(128)
    ,table_type         varchar(10)
    ,column_id          int
    ,column_name        nvarchar(128)
    ,index_id           int
    ,index_column_id    int
    ,key_ordinal        tinyint
    ,partition_ordinal  tinyint
    ,is_descending_key  bit
    ,is_included_column bit
)

set @sql = 'use ' + quotename(@database_name) + ';
    select o.object_id as mssql_object_id
         , db_name()   as table_catalog
         , s.name      as table_schema
         , o.name      as table_name
         , i.name      as index_name
         , case o.type
                when ''U'' then ''BASE TABLE''
                when ''V'' then ''VIEW''
            end as table_type
        , c.column_id
        , c.name as column_name
        , ic.index_id
        , ic.index_column_id
        , ic.key_ordinal
        , ic.partition_ordinal
        , ic.is_descending_key
        , ic.is_included_column
    from sys.index_columns ic
    join sys.indexes i  on ic.object_id = i.object_id
                       and ic.index_id = i.index_id
    join sys.objects o  on i.object_id = o.object_id
    join sys.schemas s  on s.schema_id = o.schema_id
    join sys.columns c  on ic.object_id = c.object_id
                       and ic.column_id = c.column_id
    where o.type in (''U'', ''V'')
    order by 2, 3, 4, 5, ic.index_id, ic.key_ordinal
'
if object_id('tempdb..##__idx_cols__23D182FE__') is not null drop table ##__idx_cols__23D182FE__
exec sp_executesql @sql

insert into @idx_cols select * from ##__idx_cols__23D182FE__ t
drop table ##__idx_cols__23D182FE__


-- assemble result =============================================================
declare @result table (
     table_catalog nvarchar(128)
    ,table_schema nvarchar(128)
    ,table_name nvarchar(128)
    ,table_type varchar(10)
    ,seq bigint
    ,sql_stmt nvarchar(1000)
)


-- USE =========================================================================
insert into @result
select ti.table_catalog
     , ti.table_schema
     , ti.table_name
     , ti.table_type
     , 100000000 + n.num as seq
     , case n.num
         when 0 then 'USE ' + quotename(ti.table_catalog)
         when 1 then 'GO'
         when 2 then ''
       end as sql_stmt
  from @tbl_info ti
 cross apply (select * from @nums x where x.num < 3) n


-- comment =====================================================================
if @script_type in ('DROP', 'CREATE') begin
    insert into @result
    select ti.table_catalog
         , ti.table_schema
         , ti.table_name
         , ti.table_type
         , 200000000 as seq
         , '/****** Object:' + space(2) +
           case when ti.table_type = 'VIEW' then 'View'
                else 'Table'
           end + ' ' + ti.quoted_table_name + space(4) + 'Script Date: ' + @strnow + ' ******/' as sql_stmt
    from @tbl_info ti
end


-- CREATE ======================================================================
if @script_type in ('CREATE') begin
    insert into @result
    select ti.table_catalog
         , ti.table_schema
         , ti.table_name
         , ti.table_type
         , 250000000 + n.num as seq
         , case n.num
             when 0 then 'SET ANSI_NULLS ON'
             when 1 then 'GO'
             when 2 then ''
             when 3 then 'SET QUOTED_IDENTIFIER ON'
             when 4 then 'GO'
             when 5 then ''
           end as sql_stmt
      from @tbl_info ti
     cross apply (select * from @nums x where x.num < 6) n

    insert into @result
    select ti.table_catalog
         , ti.table_schema
         , ti.table_name
         , ti.table_type
         , 350000000 as seq
         , 'CREATE TABLE ' + ti.quoted_table_name + '(' as sql_stmt
    from @tbl_info ti

    insert into @result
    select ci.table_catalog
         , ci.table_schema
         , ci.table_name
         , ci.table_type
         , 400000000 + ci.ordinal_position as seq
         , space(4) + ci.quoted_column_name + ' ' +
           quotename(ci.user_data_type) +
           case when ci.user_data_type = ci.data_type then isnull('(' + ci.data_type_size + ')', '') else '' end +
           case when ci.is_identity = 1 then ' IDENTITY(1,1)' else '' end +
           case when ci.is_nullable = 0 then ' NOT' else '' end + ' NULL,' as sql_stmt
     from @col_info ci

    insert into @result
    select ti.table_catalog
         , ti.table_schema
         , ti.table_name
         , ti.table_type
         , 800000000 as seq
         , ') ON ' + quotename(ti.file_group) as sql_stmt
    from @tbl_info ti

end


-- DELETE ======================================================================
if @script_type in ('DELETE') begin
    insert into @result
    select ti.table_catalog
         , ti.table_schema
         , ti.table_name
         , ti.table_type
         , 300000000 as seq
         , 'DELETE FROM ' + ti.quoted_table_name as sql_stmt
    from @tbl_info ti

    insert into @result
    select ti.table_catalog
         , ti.table_schema
         , ti.table_name
         , ti.table_type
         , 400000000 as seq
         , space(6) + 'WHERE <Search Conditions,,>' as sql_stmt
    from @tbl_info ti
end


-- DROP ========================================================================
if @script_type in ('DROP', 'DROP AND CREATE') begin
    insert into @result
    select ti.table_catalog
         , ti.table_schema
         , ti.table_name
         , ti.table_type
         , 300000000 as seq
         , 'DROP ' +
           case when ti.table_type = 'VIEW'
                then 'VIEW'
                else 'TABLE'
           end + ' ' + ti.quoted_table_name as sql_stmt
    from @tbl_info ti
end


-- INSERT ======================================================================
if @script_type in ('INSERT') begin
    insert into @result
    select ti.table_catalog
         , ti.table_schema
         , ti.table_name
         , ti.table_type
         , 300000000 as seq
         , 'INSERT INTO ' + ti.quoted_table_name as sql_stmt
    from @tbl_info ti

    insert into @result
    select ci.table_catalog
         , ci.table_schema
         , ci.table_name
         , ci.table_type
         , 400000000 + ci.ordinal_position as seq
         , space(11) +
           case when ci.ordinal_rank = 1 then '('
                else ','
           end + ci.quoted_column_name +
           case when ci.ordinal_rank_desc = 1 then ')'
                else ''
           end as sql_stmt
     from (select *
                , row_number() over (partition by x.mssql_object_id
                                         order by x.ordinal_position) as ordinal_rank
                , row_number() over (partition by x.mssql_object_id
                                         order by x.ordinal_position desc) as ordinal_rank_desc
               from @col_info x
              where x.is_modifiable = 1
          ) ci

    insert into @result
    select ti.table_catalog
         , ti.table_schema
         , ti.table_name
         , ti.table_type
         , 500000000 as seq
         , space(5) + 'VALUES' as sql_stmt
    from @tbl_info ti

    insert into @result
    select ci.table_catalog
         , ci.table_schema
         , ci.table_name
         , ci.table_type
         , 600000000 + ci.ordinal_position as seq
         , space(11) +
           case when ci.ordinal_rank = 1 then '(<'
                else ',<'
           end +
           ci.column_name + ', ' + ci.sql_full_data_type + ',>' +
           case when ci.ordinal_rank_desc = 1 then ')'
                else ''
           end as sql_stmt
     from (select *
                , row_number() over (partition by x.mssql_object_id
                                         order by x.ordinal_position) as ordinal_rank
                , row_number() over (partition by x.mssql_object_id
                                         order by x.ordinal_position desc) as ordinal_rank_desc
               from @col_info x
              where x.is_modifiable = 1
          ) ci
end


-- SELECT ======================================================================
if @script_type in ('SELECT') begin
    insert into @result
    select ci.table_catalog
         , ci.table_schema
         , ci.table_name
         , ci.table_type
         , 400000000 + ci.ordinal_position as seq
         , case when ci.ordinal_position = 1 then 'SELECT '
                else space(6) + ','
           end + ci.quoted_column_name as sql_stmt
     from @col_info ci

    insert into @result
    select ti.table_catalog
         , ti.table_schema
         , ti.table_name
         , ti.table_type
         , 500000000 as seq
         , space(2) + 'FROM ' + ti.quoted_table_name as sql_stmt
     from @tbl_info ti
end


-- UPDATE ======================================================================
if @script_type in ('UPDATE') begin
    insert into @result
    select ti.table_catalog
         , ti.table_schema
         , ti.table_name
         , ti.table_type
         , 300000000 as seq
         , 'UPDATE ' + ti.quoted_table_name as sql_stmt
    from @tbl_info ti

    insert into @result
    select ci.table_catalog
         , ci.table_schema
         , ci.table_name
         , ci.table_type
         , 400000000 + ci.ordinal_position as seq
         , space(3) +
           case when ci.ordinal_rank = 1 then 'SET '
                else space(3) + ','
           end +
           ci.quoted_column_name + ' = ' + '<' + ci.column_name + ', ' + sql_full_data_type + ',>' as sql_stmt
     from (select *
                , row_number() over (partition by x.mssql_object_id
                                     order by x.ordinal_position) as ordinal_rank
            from @col_info x
           where x.is_modifiable = 1
          ) ci
end


-- END GO ======================================================================
insert into @result
select ti.table_catalog
    , ti.table_schema
    , ti.table_name
    , ti.table_type
    , 900000000 + n.num as seq
    , case n.num
           when 0 then 'GO'
           when 1 then ''
      end as sql_stmt
from @tbl_info ti
cross apply (select * from @nums x where x.num < 2) n


-- return result ===============================================================
select *
from @result r
where (@table_name is null or r.table_name = @table_name)
and (@schema_name is null or r.table_schema = @schema_name)
order by 1, 2, 3, 4, 5


-- #DEBUG
--select * from @tbl_info
--select * from @col_info
end
go
