if objectproperty(object_id('dbo.sp_script_indexes'), 'IsProcedure') is null begin
    exec('create proc dbo.sp_script_indexes as')
end
go
--------------------------------------------------------------------------------
-- proc     : sp_script_indexes
-- author   : mattmc3
-- version  : v0.4.5
-- purpose  : Generates SQL scripts for basic SELECT, INSERT, UPDATE, DELETE
--            operations
-- homepage : https://github.com/mattmc3/sqlgen-procs
-- license  : MIT - https://github.com/mattmc3/sqlgen-procs/blob/master/LICENSE
--------------------------------------------------------------------------------
alter procedure dbo.sp_script_indexes
    @database_name nvarchar(256)         -- Script from the database name specified
    ,@table_schema nvarchar(256) = null  -- Script only the schema specified
    ,@table_name nvarchar(256) = null    -- Script only the table specified
    ,@index_name nvarchar(256) = null    -- Script only the index specified
    ,@include_timestamps bit = 1         -- Boolean for including timestamps in the script output
    ,@now datetime = null                -- Override the script generation time
as
begin

set nocount on

-- TODO: Handle disabled indexes

-- defaults
select @now = isnull(@now, getdate())

if @table_schema is null and @table_name is not null
begin
    set @table_schema = isnull(@table_schema, 'dbo')
end

-- vars
declare @strnow nvarchar(50) = format(@now, 'M/d/yyyy h:mm:ss tt')
      , @indent nvarchar(8) = replicate(' ', 4)
      , @sql nvarchar(max)
      , @param_defs nvarchar(1000)
      , @object_id int

-- const
declare @APOS nvarchar(1) = N''''
      , @NL nvarchar(1) = char(10)

-- make helper table of 100 numbers (0-99)
declare @numbers table (num int)
;with numbers as (
    select 0 as num
    union all
    select num + 1
    from numbers
    where num + 1 <= 99
)
insert into @numbers
select num
from numbers n
option (maxrecursion 100)

-- Pull system tables from other DB ============================================
-- get object_id for the desired SQL object
set @param_defs='@table_schema nvarchar(256), @table_name nvarchar(256), @object_id int output'
set @sql = 'use ' + quotename(@database_name) + '
select @object_id = object_id(quotename(@table_schema) + ''.'' + quotename(@table_name))'
exec sp_executesql @sql, @param_defs, @table_schema=@table_schema, @table_name=@table_name, @object_id=@object_id output

-- sys.indexes
if object_id('tempdb..#sysindexes') is not null drop table #sysindexes
select top 0
    cast(null as nvarchar(256)) as table_schema
    ,cast(null as nvarchar(256)) as table_name
    ,cast(null as nvarchar(256)) as data_space_name
    ,*
into #sysindexes
from sys.indexes
set @sql = '
use ' + quotename(@database_name) + '
insert into #sysindexes
select ss.name as table_schema, so.name as table_name, sds.name as data_space_name, si.*
from sys.indexes si
join sys.objects so      on si.object_id = so.object_id
join sys.schemas ss      on so.schema_id = ss.schema_id
join sys.data_spaces sds on si.data_space_id = sds.data_space_id
where si.object_id = isnull(@object_id, si.object_id)
and so.is_ms_shipped = 0
and si.is_hypothetical = 0
and si.is_primary_key = 0
and si.name = isnull(@index_name, si.name)'
set @param_defs='@object_id int, @index_name nvarchar(256)'
exec sp_executesql @sql, @param_defs, @object_id=@object_id, @index_name=@index_name

-- sys.index_columns
if object_id('tempdb..#sysidxcols') is not null drop table #sysidxcols
select top 0 cast(null as nvarchar(256)) as column_name, * into #sysidxcols from sys.index_columns
set @sql = '
use ' + quotename(@database_name) + '
insert into #sysidxcols
select sc.name as column_name
     , sic.*
from sys.index_columns sic
join sys.indexes si on sic.object_id = si.object_id
                   and sic.index_id = si.index_id
join sys.columns sc on sic.object_id = sc.object_id
                   and sic.column_id = sc.column_id
join sys.objects so on si.object_id = so.object_id
where sic.object_id = isnull(@object_id, sic.object_id)
and so.is_ms_shipped = 0
and si.is_hypothetical = 0
and si.is_primary_key = 0
and si.name = isnull(@index_name, si.name)'
set @param_defs='@object_id int, @index_name nvarchar(256)'
exec sp_executesql @sql, @param_defs, @object_id=@object_id, @index_name=@index_name

-- sys.partition_schemes
if object_id('tempdb..#sys_partition_schemes') is not null drop table #sys_partition_schemes
create table #sys_partition_schemes (
    object_id int
    ,data_space_id int
    ,table_name nvarchar(256)
    ,partitioning_column_id int
    ,partitioning_column_name nvarchar(256)
    ,partitioning_scheme_name nvarchar(256)
)
set @sql = '
use ' + quotename(@database_name) + '
insert into #sys_partition_schemes
select t.object_id
     , ps.data_space_id
     , t.name as table_name
     , ic.column_id as partitioning_column_id
     , c.name as partitioning_column_name
     , ps.name as partitioning_scheme_name
from sys.tables t
join sys.indexes i            on t.[object_id] = i.[object_id]
                             and i.[type] <= 1 -- clustered index or a heap
join sys.partition_schemes ps on ps.data_space_id = i.data_space_id
join sys.index_columns ic     on ic.[object_id] = i.[object_id]
                             and ic.index_id = i.index_id
                             and ic.partition_ordinal >= 1 -- because 0 = non-partitioning column
join sys.columns as c         on t.[object_id] = c.[object_id]
                             and ic.column_id = c.column_id
'
exec sp_executesql @sql
-- =============================================================================

-- generate results
if object_id('tempdb..#results') is not null drop table #results
create table #results (
     table_schema nvarchar(256)
    ,table_name nvarchar(256)
    ,index_name nvarchar(256)
    ,sql_category nvarchar(256)
    ,seq int
    ,sql_text nvarchar(max)
)

if object_id('tempdb..#idxcols') is not null drop table #idxcols
select si.table_schema
     , si.table_name
     , si.name as index_name
     , si.type_desc
     , sic.*
     , row_number() over (partition by sic.object_id, sic.index_id, sic.is_included_column
                          order by sic.key_ordinal, sic.index_column_id) as ord
     , row_number() over (partition by sic.object_id, sic.index_id, sic.is_included_column
                          order by sic.key_ordinal desc, sic.index_column_id desc) as ord_desc
into #idxcols
from #sysidxcols sic
join #sysindexes si on sic.object_id = si.object_id
                    and sic.index_id = si.index_id
where sic.key_ordinal > 0
or sic.is_included_column = 1

;with idx as (
    select si.*
         , quotename(si.table_schema) + '.' + quotename(si.table_name) as quoted_table_name
         , ps.partitioning_column_name
    from #sysindexes si
    left join #sys_partition_schemes ps on si.data_space_id = ps.data_space_id
), idxcols as (
    select *
    from #idxcols
), incl_last_col as (
    select ic.*
    from #idxcols ic
    where ic.is_included_column = 1
    and ic.ord_desc = 1
)
insert into #results
select null, null, null, null
     , n.num as seq
     , case n.num
       when 0 then 'USE ' + quotename(@database_name)
       when 1 then 'GO'
       when 2 then ''
       end as sql_text
from @numbers n
where n.num < 3
union all
select
    a.table_schema
    ,a.table_name
    ,a.name as index_name
    ,a.type_desc as sql_category
    ,(100000000 * case when n.num < 3 then 1 else 5 end) + n.num
    ,case n.num
     when 0
     then N'/****** Object:  Index ' +
          quotename(replace(a.name, @APOS, @APOS + @APOS)) +
          case when @include_timestamps = 1 then N'    Script Date: ' + @strnow
               else ''
          end + N' ******/'
     when 1
     then N'CREATE ' + case when a.is_unique = 1 and a.[type] = 2 then N'UNIQUE ' else '' end +
          a.type_desc + N' INDEX ' + quotename(a.name) + N' ON ' + a.quoted_table_name
     when 2
     then N'('
     when 3
     then isnull(
            case when inc.ord = inc.ord_desc then N'INCLUDE (' else N'' end +
            @indent + quotename(inc.column_name) + ') '
          , ')') +
          N'WITH (PAD_INDEX = ' + case when a.is_padded = 1 then N'ON, ' else N'OFF, ' end +
          N'STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, ' +
          case when a.is_unique = 1 and a.[type] = 2
               then N'IGNORE_DUP_KEY = ' + case when a.ignore_dup_key = 1 then N'ON' else N'OFF' end + N', '
               else N''
          end +
          N'DROP_EXISTING = OFF, ONLINE = OFF, ' +
          N'ALLOW_ROW_LOCKS = ' + case when a.allow_row_locks = 1 then N'ON' else N'OFF' end + N', ' +
          N'ALLOW_PAGE_LOCKS = ' + case when a.allow_page_locks = 1 then N'ON' else N'OFF' end + N') ' +
          N'ON ' + quotename(a.data_space_name) +
          case when a.partitioning_column_name is not null
               then '(' + quotename(a.partitioning_column_name) + ')'
               else ''
          end
     end
from idx a
left join incl_last_col inc on a.object_id = inc.object_id
                           and a.index_id = inc.index_id
cross apply @numbers n
where n.num < 4
-- add the index columns
union all
select
    a.table_schema
    ,a.table_name
    ,a.index_name
    ,a.type_desc as sql_category
    ,200000000 + (a.key_ordinal * 100000) + a.index_column_id
    ,@indent + quotename(a.column_name) +
     case when a.is_descending_key = 1 then N' DESC' else N' ASC' end +
     case when a.ord_desc = 1 then N'' else N',' end
from idxcols a
where a.is_included_column = 0
-- add the sql when there is a single include column
union all
select
    a.table_schema
    ,a.table_name
    ,a.index_name
    ,a.type_desc as sql_category
    ,300000000
    ,')'
from idxcols a
where a.is_included_column = 1
and a.ord = 1
-- add the sql when are multiple include columns
union all
select
    a.table_schema
    ,a.table_name
    ,a.index_name
    ,a.type_desc as sql_category
    ,400000000 + a.index_column_id
    ,case when a.ord = 1 then N'INCLUDE (' else N'' end +
     @indent + quotename(a.column_name) + N','
from idxcols a
where a.is_included_column = 1
and a.ord_desc <> 1
-- footer
union all
select
    a.table_schema
    ,a.table_name
    ,a.name
    ,a.type_desc as sql_category
    ,800000000 + n.num
    ,case n.num
     when 0 then 'GO'
     when 1 then ''
     end
from idx a
cross apply @numbers n
where n.num < 2

-- return results
select *
from #results
order by 1, 2, 4, 3, 5

-- clean up
if object_id('tempdb..#sysindexes') is not null drop table #sysindexes
if object_id('tempdb..#sysidxcols') is not null drop table #sysidxcols
if object_id('tempdb..#sys_partition_schemes') is not null drop table #sys_partition_schemes
if object_id('tempdb..#idxcols') is not null drop table #idxcols
if object_id('tempdb..#results') is not null drop table #results

end
go
