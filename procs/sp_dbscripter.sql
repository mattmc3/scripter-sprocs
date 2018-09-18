-- #DEBUG
 declare @script_type nvarchar(128) = 'select'
       , @db_name nvarchar(128) = 'outcomes_mart'
       , @object_name nvarchar(128) = null --'dim_date'
       , @schema_name nvarchar(128) = 'admin'

/*
if objectproperty(object_id('dbo.sp_dbscripter'), 'IsProcedure') is null begin
    exec('create proc dbo.sp_dbscripter as')
end
go
--------------------------------------------------------------------------------
-- proc    : sp_dbscripter
-- author  : mattmc3
-- version : v0.4.0-20180917
-- purpose : Generates SQL scripts for tables. Mimics SSMS "Script object as"
--           behavior, and serves as a replacement for SQL DMO.
-- license : MIT
--           https://github.com/mattmc3/dbscripter-sproc/blob/master/LICENSE
-- params  :
--
-- @script_type
--   The type of script to generate. Valid values are:
--   'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'DROP', 'CREATE'
--
-- @db_name
--   The name of the database where the table(s) to script reside.
--   Optional - defaults to current db
--
-- @object_name
--   The name of the table to script. Optional - defaults to all tables in the
--   database.
--
--  @schema_name
--    The name of the schema for scripting tables.
--    Optional - defaults to all schemas, or 'dbo' if @object_name was
--    specified.
--
-- todos  : - support 'DROP AND CREATE'
--          - Custom SQL
--              * No comments
--              * No extra newlines
--              * SQL formatting
--          - support for create view?
--          - support all features of a table in a 'CREATE'
--              * NOT FOR REPLICATION
--              * Alternate IDENTITY seeds
--              * DEFAULT constraints
--              * TEXTIMAGE_ON
--              * Indexes
--              * Computed columns
--              * Foreign keys
--------------------------------------------------------------------------------
alter procedure dbo.sp_dbscripter
    @script_type nvarchar(128)
    ,@db_name nvarchar(128) = null
    ,@object_name nvarchar(128) = null
    ,@schema_name nvarchar(128) = null
as
begin

set nocount on
*/

-- vars
declare @sql nvarchar(max)
      , @now datetime = getdate()
      , @strnow nvarchar(50)
      , @CRLF nvarchar(2) = nchar(13) + nchar(10)
      , @TICK nvarchar(1) = ''''

-- don't rely on FORMAT() since early SQL Server is missing it
select @strnow = cast(datepart(month, @now) as nvarchar(2)) + '/' +
                 cast(datepart(day, @now) as nvarchar(2)) + '/' +
                 cast(datepart(year, @now) as nvarchar(4)) + ' ' +
                 cast(datepart(hour, @now) % 12 as nvarchar(2)) + ':' +
                 right('0' + cast(datepart(minute, @now) as nvarchar(2)), 2) + ':' +
                 right('0' + cast(datepart(second, @now) as nvarchar(2)), 2) + ' ' +
                 case when datepart(hour, @now) < 12 then 'AM' else 'PM' end

-- defaults
select @db_name = isnull(@db_name, db_name())
if @object_name is not null begin
    select @schema_name = isnull(@schema_name, 'dbo')
end

if @script_type not in ('CREATE', 'DROP', 'DELETE', 'INSERT', 'SELECT', 'UPDATE') begin
    raiserror('The @script_type values supported are: (''CREATE'', ''DROP'', ''DELETE'', ''INSERT'', ''SELECT'', and ''UPDATE'')', 16, 10)
    return
end

-- make helper table of 100 numbers (0-99)
declare @nums table (num int)
;with numbers as (
    select 0 as num
    union all
    select num + 1
    from numbers
    where num + 1 <= 99
)
insert into @nums
select num
from numbers n
option (maxrecursion 100)


-- Get metadata ===============================================================
-- one row per table
-- based on running `sp_helptext 'information_schema.tables'` in master
if object_id('tempdb..##tbl_info_D78CEAA3') is not null drop table ##tbl_info_D78CEAA3
create table ##tbl_info_D78CEAA3 (
     mssql_object_id   int
    ,database_name     nvarchar(128)
    ,object_schema     nvarchar(128)
    ,object_name       nvarchar(128)
    ,object_type       nvarchar(128)
    ,created_at        datetime
    ,updated_at        datetime
    ,file_group        nvarchar(128)
)

-- global temp table trick...
set @sql = N'
use ' + quotename(@db_name) + ';
insert into ##tbl_info_D78CEAA3
select
    o.object_id as mssql_object_id
    ,db_name() as database_name
    ,s.name as object_schema
    ,o.name as object_name
    ,case o.type
        when ''U'' then ''TABLE''
        when ''V'' then ''VIEW''
    end as object_type
    ,o.create_date as created_at
    ,o.modify_date as updated_at
    ,isnull(filegroup_name(t.filestream_data_space_id), ''PRIMARY'') as file_group
from sys.objects o
left join sys.tables t
    on o.object_id = t.object_id
left join sys.schemas s
    on s.schema_id = o.schema_id
where o.type in (''U'', ''V'')
and o.name = isnull(@object_name, o.name)
and s.name = isnull(@schema_name, s.name)
'
exec sp_executesql @sql
                 , N'@object_name nvarchar(128),@schema_name nvarchar(128)'
                 , @object_name=@object_name
                 , @schema_name=@schema_name

if object_id('tempdb..#tbl_info') is not null drop table #tbl_info
select *
     , quotename(t.object_schema) + '.' + quotename(t.object_name) as quoted_object_name
into #tbl_info
from ##tbl_info_D78CEAA3 t

if object_id('tempdb..##tbl_info_D78CEAA3') is not null drop table ##tbl_info_D78CEAA3


-- Get column info
-- one row per column
-- based on running `sp_helptext 'information_schema.columns'` in master
if object_id('tempdb..##col_info_D78CEAA3') is not null drop table ##col_info_D78CEAA3
create table ##col_info_D78CEAA3 (
     mssql_object_id            int
    ,mssql_column_id            int
    ,database_name              nvarchar(128)
    ,object_schema              nvarchar(128)
    ,object_name                nvarchar(128)
    ,object_type                nvarchar(128)
    ,column_name                nvarchar(128)
    ,ordinal_position           int
    ,column_default             nvarchar(4000)
    ,is_nullable                bit
    ,system_data_type           nvarchar(128)
    ,user_data_type             nvarchar(128)
    ,character_maximum_length   int
    ,numeric_precision          int
    ,numeric_scale              int
    ,datetime_precision         int
    ,is_computed                bit
    ,computed_column_definition nvarchar(max)
    ,is_identity                bit
)

set @sql = N'
use ' + quotename(@db_name) + ';
insert into ##col_info_D78CEAA3
select
    o.object_id as mssql_object_id
    ,c.column_id as mssql_column_id
    ,db_name() as database_name
    ,s.name as object_schema
    ,o.name as object_name
    ,case o.type
        when ''U'' then ''TABLE''
        when ''V'' then ''VIEW''
    end as object_type
    ,c.name as column_name
    ,columnproperty(c.object_id, c.name, ''ordinal'') as ordinal_position
    ,convert(nvarchar(4000), object_definition(c.default_object_id)) as column_default
    ,c.is_nullable as is_nullable
    ,type_name(c.system_type_id) as system_data_type
    ,type_name(c.user_type_id) as user_data_type
    ,columnproperty(c.object_id, c.name, ''charmaxlen'') as character_maximum_length
    ,convert(tinyint,
        case
            -- int/decimal/numeric/real/float/money
            when c.system_type_id in (48, 52, 56, 59, 60, 62, 106, 108, 122, 127)
            then c.precision
        end) as numeric_precision
    ,convert(int,
        case
            -- datetime/smalldatetime
            when c.system_type_id in (40, 41, 42, 43, 58, 61) then null
            else odbcscale(c.system_type_id, c.scale)
        end) as numeric_scale
    ,convert(smallint,
        case
            -- datetime/smalldatetime
            when c.system_type_id in (40, 41, 42, 43, 58, 61)
            then odbcscale(c.system_type_id, c.scale)
        end) as datetime_precision
    ,c.is_computed as is_computed
    ,cc.definition as computed_column_definition
    ,c.is_identity as is_identity
from sys.objects o
left join sys.schemas s
  on s.schema_id = o.schema_id
join sys.columns c
  on c.object_id = o.object_id
left join sys.computed_columns cc
  on cc.object_id = o.object_id
 and cc.column_id = c.column_id
where o.type in (''U'', ''V'')
and o.name = isnull(@object_name, o.name)
and s.name = isnull(@schema_name, s.name)
'
exec sp_executesql @sql
                 , N'@object_name nvarchar(128),@schema_name nvarchar(128)'
                 , @object_name=@object_name
                 , @schema_name=@schema_name

if object_id('tempdb..#col_info') is not null drop table #col_info
select *
     , quotename(t.column_name) as quoted_column_name
     , cast(null as nvarchar(255)) as sql_full_data_type
     , case when t.system_data_type in ('binary', 'char', 'nchar', 'nvarchar', 'varbinary', 'varchar')
           then isnull(nullif(cast(t.character_maximum_length as varchar(4)), '-1'), 'max')
           when t.system_data_type in ('decimal', 'numeric')
           then cast(t.numeric_precision as varchar(10)) + ',' + cast(t.numeric_scale as varchar(10))
           when t.system_data_type in ('datetime2', 'datetimeoffset', 'time')
           then cast(t.datetime_precision as varchar(10))
           else null
       end as data_type_size
     , case when is_identity = 1 or is_computed = 1 or system_data_type = 'timestamp' then 0
            else 1
       end as is_modifiable
into #col_info
from ##col_info_D78CEAA3 t

if object_id('tempdb..##col_info_D78CEAA3') is not null drop table ##col_info_D78CEAA3

update #col_info
   set sql_full_data_type =
       case when user_data_type <> system_data_type then quotename(user_data_type)
            else quotename(system_data_type) + isnull('(' + data_type_size + ')', '')
       end


-- get sys.extended_properties
-- make a temp table with the correct structure from current db
if object_id('tempdb..#sys_extended_properties') is not null drop table #sys_extended_properties
select top 0 * into #sys_extended_properties from sys.extended_properties
if @script_type in ('CREATE') begin
    if object_id('tempdb..##__sys_extended_properties_D78CEAA3__') is not null drop table ##__sys_extended_properties_D78CEAA3__
    select top 0 * into ##__sys_extended_properties_D78CEAA3__ from #sys_extended_properties
    set @sql = N'use ' + quotename(@db_name) + ';' + @CRLF +
               N'insert into ##__sys_extended_properties_D78CEAA3__ select * from sys.extended_properties'
    exec sp_executesql @sql

    insert into #sys_extended_properties select * from ##__sys_extended_properties_D78CEAA3__

    if object_id('tempdb..##__sys_extended_properties_D78CEAA3__') is not null drop table ##__sys_extended_properties_D78CEAA3__
end

-- get sys.indexes
-- make a temp table with the correct structure from current db
if object_id('tempdb..#sys_indexes') is not null drop table #sys_indexes
select top 0 * into #sys_indexes from sys.indexes
if @script_type in ('CREATE') begin
    if object_id('tempdb..##__sys_indexes_D78CEAA3__') is not null drop table ##__sys_indexes_D78CEAA3__
    select top 0 * into ##__sys_indexes_D78CEAA3__ from #sys_indexes
    set @sql = N'use ' + quotename(@db_name) + ';' + @CRLF +
               N'insert into ##__sys_indexes_D78CEAA3__ select * from sys.indexes'
    exec sp_executesql @sql

    insert into #sys_indexes select * from ##__sys_indexes_D78CEAA3__

    if object_id('tempdb..##__sys_indexes_D78CEAA3__') is not null drop table ##__sys_indexes_D78CEAA3__
end

-- get sys.index_columns
-- make a temp table with the correct structure from current db
if object_id('tempdb..#sys_index_columns') is not null drop table #sys_index_columns
select top 0 * into #sys_index_columns from sys.index_columns
if @script_type in ('CREATE') begin
    if object_id('tempdb..##__sys_index_columns_D78CEAA3__') is not null drop table ##__sys_index_columns_D78CEAA3__
    select top 0 * into ##__sys_index_columns_D78CEAA3__ from #sys_index_columns
    set @sql = N'use ' + quotename(@db_name) + ';' + @CRLF +
               N'insert into ##__sys_index_columns_D78CEAA3__ select * from sys.index_columns'
    exec sp_executesql @sql

    insert into #sys_index_columns select * from ##__sys_index_columns_D78CEAA3__

    if object_id('tempdb..##__sys_index_columns_D78CEAA3__') is not null drop table ##__sys_index_columns_D78CEAA3__
end


-- assemble result =============================================================
declare @result table (
     database_name nvarchar(128)
    ,object_schema nvarchar(128)
    ,object_name nvarchar(128)
    ,object_type varchar(10)
    ,seq bigint
    ,sql_stmt nvarchar(max)
)


-- USE
insert into @result
select @db_name as database_name
     , null as object_schema
     , null as object_name
     , null as object_type
     , n.num as seq
     , case n.num
         when 0 then 'USE ' + quotename(@db_name)
         when 1 then 'GO'
         when 2 then ''
       end as sql_stmt
  from @nums n
 where n.num < 3


-- comment
if @script_type in ('DROP', 'CREATE') begin
    insert into @result
    select ti.database_name
         , ti.object_schema
         , ti.object_name
         , ti.object_type
         , 200000000 as seq
         , '/****** Object:' + space(2) +
           case when ti.object_type = 'VIEW' then 'View'
                else 'Table'
           end + ' ' + ti.quoted_object_name + space(4) + 'Script Date: ' + @strnow + ' ******/' as sql_stmt
    from #tbl_info ti
end


-- CREATE
if @script_type in ('CREATE') begin
    insert into @result
    select ti.database_name
         , ti.object_schema
         , ti.object_name
         , ti.object_type
         , 250000000 + n.num as seq
         , case n.num
             when 0 then 'SET ANSI_NULLS ON'
             when 1 then 'GO'
             when 2 then ''
             when 3 then 'SET QUOTED_IDENTIFIER ON'
             when 4 then 'GO'
             when 5 then ''
           end as sql_stmt
      from #tbl_info ti
     cross apply (select * from @nums x where x.num < 6) n
     where ti.object_type = 'TABLE'

    insert into @result
    select ti.database_name
         , ti.object_schema
         , ti.object_name
         , ti.object_type
         , 320000000 as seq
         , 'CREATE TABLE ' + ti.quoted_object_name + '(' as sql_stmt
    from #tbl_info ti
    where ti.object_type = 'TABLE'

    insert into @result
    select ci.database_name
         , ci.object_schema
         , ci.object_name
         , ci.object_type
         , 340000000 + ci.ordinal_position as seq
         , space(4) + ci.quoted_column_name + ' ' +
           quotename(ci.user_data_type) + ci.sql_full_data_type +
           case when ci.is_identity = 1 then ' IDENTITY(1,1)' else '' end +
           case when ci.is_nullable = 0 then ' NOT' else '' end + ' NULL,' as sql_stmt
     from #col_info ci
    where ci.object_type = 'TABLE'

    insert into @result
    select ti.database_name
         , ti.object_schema
         , ti.object_name
         , ti.object_type
         , 360000000 as seq
         , ') ON ' + quotename(ti.file_group) as sql_stmt
     from #tbl_info ti
    where ti.object_type = 'TABLE'

    insert into @result
    select ti.database_name
        , ti.object_schema
        , ti.object_name
        , ti.object_type
        , 380000000 + n.num as seq
        , case n.num
               when 0 then 'GO'
               when 1 then ''
          end as sql_stmt
     from #tbl_info ti
    cross apply (select * from @nums x where x.num < 2) n
    where ti.object_type = 'TABLE'

    -- make index helpers
    if object_id('tempdb..#idx_info') is not null drop table #idx_info
    select ti.database_name
         , ti.object_schema
         , ti.object_name
         , ti.object_type
         , ti.quoted_object_name
         , si.*
         , row_number() over (partition by si.object_id order by si.index_id) as index_ordinal
    into #idx_info
    from #tbl_info ti
    join #sys_indexes si
      on si.object_id = ti.mssql_object_id
    where si.type <> 0  -- no HEAPs
      and si.is_hypothetical = 0
      and si.is_disabled = 0
      and si.is_primary_key = 0
      and si.is_unique_constraint = 0

    if object_id('tempdb..#idx_col_info') is not null drop table #idx_col_info
    select ci.database_name
         , ci.object_schema
         , ci.object_name
         , ci.object_type
         , ci.quoted_column_name
         , sic.*
    into #idx_col_info
    from #col_info ci
    join #sys_index_columns sic
      on ci.mssql_object_id = sic.object_id
     and ci.mssql_column_id = sic.column_id
    join #idx_info ii
      on sic.object_id = ii.object_id
     and sic.index_id = ii.index_id

    insert into @result
    select ii.database_name
         , ii.object_schema
         , ii.object_name
         , ii.object_type
         , 400000000 + (ii.index_ordinal * 100000) as seq
         , '/****** Object:  Index ' + quotename(ii.name) + space(4) +
           'Script Date: ' + @strnow + ' ******/' as sql_stmt
    from #idx_info ii

    insert into @result
    select ii.database_name
         , ii.object_schema
         , ii.object_name
         , ii.object_type
         , 400000000 + (ii.index_ordinal * 100000) +
           case when n.num < 2 then n.num
                when n.num = 2 then 4000
                when n.num = 3 then 6000
            end as seq
         , case when n.num = 0
                then 'CREATE ' + ii.type_desc + ' INDEX ' + quotename(ii.name) + ii.quoted_object_name
                when n.num = 1 then '('
                when n.num = 2 then ')'
                else 'GO'
           end as sql_stmt
    from #idx_info ii
    cross apply (select * from @nums x where x.num < 4) n

    --insert into @result
    --select ici.database_name
    --     , ici.object_schema
    --     , ici.object_name
    --     , ici.object_type
    --     , 420000000 + n.num as seq
    --     , case when n.num = 0
    --            then 'CREATE ' + ii.type_desc + ' INDEX ' + quotename(ii.name) + ii.quoted_object_name
    --            when n.num = 1 then '('
    --            when n.num = 2 then ')'
    --            else 'GO'
    --       end as sql_stmt
    --from #idx_col_info ici
    --cross apply (select * from @nums x where x.num < 4) n

      /****** Object:  Index [idxN_t_RequestTouches_2]    Script Date: 7/9/2018 3:36:36 PM ******/
/*
CREATE NONCLUSTERED INDEX [idxN_t_RequestTouches_2] ON [dbo].[T_RequestTouches]
(
	[request_id] ASC
)
INCLUDE ( 	[user_id],
	[touch_type],
	[time]) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
*/

    -- extended properties: column descriptions
    insert into @result
    select ci.database_name
         , ci.object_schema
         , ci.object_name
         , ci.object_type
         , 600000000 + (sep.minor_id * 1000) + n.num as seq
         , case when n.num = 0
                then 'EXEC sys.sp_addextendedproperty @name=N''MS_Description'', @value=N''' +
                     replace(cast(sep.value as nvarchar(max)), @TICK, @TICK + @TICK) + ''' , ' +
                     '@level0type=N''SCHEMA'','+
                     '@level0name=N''' + ci.object_schema + ''', ' +
                     '@level1type=N''TABLE'',' +
                     '@level1name=N''' + ci.object_name + ''', ' +
                     '@level2type=N''COLUMN'',' +
                     '@level2name=N''' + ci.column_name + ''''
                when n.num = 1 then 'GO'
                else ''
           end as sql_stmt
    from #col_info ci
    join #sys_extended_properties sep
      on ci.mssql_object_id = sep.major_id
     and ci.mssql_column_id = sep.minor_id
     and sep.name = 'MS_Description'
   cross apply (select * from @nums x where x.num < 3) n

    -- extended properties: table descriptions
    insert into @result
    select ti.database_name
         , ti.object_schema
         , ti.object_name
         , ti.object_type
         , 610000000 + n.num as seq
         , case when n.num = 0
                then 'EXEC sys.sp_addextendedproperty @name=N''MS_Description'', @value=N''' +
                     replace(cast(sep.value as nvarchar(max)), @TICK, @TICK + @TICK) + ''' , ' +
                     '@level0type=N''SCHEMA'','+
                     '@level0name=N''' + ti.object_schema + ''', ' +
                     '@level1type=N''TABLE'',' +
                     '@level1name=N''' + ti.object_name + ''''
                when n.num = 1 then 'GO'
                else ''
           end as sql_stmt
    from #tbl_info ti
    join #sys_extended_properties sep
      on ti.mssql_object_id = sep.major_id
     and sep.minor_id = 0
     and sep.name = 'MS_Description'
   cross apply (select * from @nums x where x.num < 3) n
end


-- DELETE
if @script_type in ('DELETE') begin
    insert into @result
    select ti.database_name
         , ti.object_schema
         , ti.object_name
         , ti.object_type
         , 300000000 as seq
         , 'DELETE FROM ' + ti.quoted_object_name as sql_stmt
    from #tbl_info ti

    insert into @result
    select ti.database_name
         , ti.object_schema
         , ti.object_name
         , ti.object_type
         , 400000000 as seq
         , space(6) + 'WHERE <Search Conditions,,>' as sql_stmt
    from #tbl_info ti
end


-- DROP
if @script_type in ('DROP', 'DROP AND CREATE') begin
    insert into @result
    select ti.database_name
         , ti.object_schema
         , ti.object_name
         , ti.object_type
         , 300000000 as seq
         , 'DROP ' +
           case when ti.object_type = 'VIEW'
                then 'VIEW'
                else 'TABLE'
           end + ' ' + ti.quoted_object_name as sql_stmt
    from #tbl_info ti
end


-- INSERT
if @script_type in ('INSERT') begin
    insert into @result
    select ti.database_name
         , ti.object_schema
         , ti.object_name
         , ti.object_type
         , 300000000 as seq
         , 'INSERT INTO ' + ti.quoted_object_name as sql_stmt
    from #tbl_info ti

    insert into @result
    select ci.database_name
         , ci.object_schema
         , ci.object_name
         , ci.object_type
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
               from #col_info x
              where x.is_modifiable = 1
          ) ci

    insert into @result
    select ti.database_name
         , ti.object_schema
         , ti.object_name
         , ti.object_type
         , 500000000 as seq
         , space(5) + 'VALUES' as sql_stmt
    from #tbl_info ti

    insert into @result
    select ci.database_name
         , ci.object_schema
         , ci.object_name
         , ci.object_type
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
               from #col_info x
              where x.is_modifiable = 1
          ) ci
end


-- SELECT
if @script_type in ('SELECT') begin
    insert into @result
    select ci.database_name
         , ci.object_schema
         , ci.object_name
         , ci.object_type
         , 400000000 + ci.ordinal_position as seq
         , case when ci.ordinal_position = 1 then 'SELECT '
                else space(6) + ','
           end + ci.quoted_column_name as sql_stmt
     from #col_info ci

    insert into @result
    select ti.database_name
         , ti.object_schema
         , ti.object_name
         , ti.object_type
         , 500000000 as seq
         , space(2) + 'FROM ' + ti.quoted_object_name as sql_stmt
     from #tbl_info ti
end


-- UPDATE
if @script_type in ('UPDATE') begin
    insert into @result
    select ti.database_name
         , ti.object_schema
         , ti.object_name
         , ti.object_type
         , 300000000 as seq
         , 'UPDATE ' + ti.quoted_object_name as sql_stmt
    from #tbl_info ti

    insert into @result
    select ci.database_name
         , ci.object_schema
         , ci.object_name
         , ci.object_type
         , 400000000 + ci.ordinal_position as seq
         , space(3) +
           case when ci.ordinal_rank = 1 then 'SET '
                else space(3) + ','
           end +
           ci.quoted_column_name + ' = ' + '<' + ci.column_name + ', ' + sql_full_data_type + ',>' as sql_stmt
     from (select *
                , row_number() over (partition by x.mssql_object_id
                                     order by x.ordinal_position) as ordinal_rank
            from #col_info x
           where x.is_modifiable = 1
          ) ci
end


-- END GO
if @script_type in ('DELETE', 'INSERT', 'SELECT', 'UPDATE') begin
    insert into @result
    select ti.database_name
        , ti.object_schema
        , ti.object_name
        , ti.object_type
        , 900000000 + n.num as seq
        , case n.num
               when 0 then 'GO'
               when 1 then ''
          end as sql_stmt
    from #tbl_info ti
    cross apply (select * from @nums x where x.num < 2) n
end

-- return result ===============================================================
select
    row_number() over (order by r.database_name, r.object_schema, r.object_name, r.seq) as line_num
    ,r.seq
    ,r.database_name
    ,r.object_schema
    ,r.object_name
    ,r.object_type
    ,r.sql_stmt
from @result r
where (r.object_name is null or r.object_name = isnull(@object_name, r.object_name))
and (r.object_schema is null or r.object_schema = isnull(@schema_name, r.object_schema))
order by 1

-- clean up
if object_id('tempdb..#tbl_info') is not null drop table #tbl_info
if object_id('tempdb..#col_info') is not null drop table #col_info
if object_id('tempdb..#sys_extended_properties') is not null drop table #sys_extended_properties
if object_id('tempdb..#idx_info') is not null drop table #idx_info
if object_id('tempdb..#idx_col_info') is not null drop table #idx_col_info

/*
end
go
*/

-- #DEBUG
--select * from #tbl_info
--select * from #col_info
