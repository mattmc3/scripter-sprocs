if objectproperty(object_id('dbo.sp_script_dml'), 'IsProcedure') is null begin
    exec('create proc dbo.sp_script_dml as')
end
go
--------------------------------------------------------------------------------
-- proc     : sp_script_dml
-- author   : mattmc3
-- version  : v0.4.5
-- purpose  : Generates SQL scripts for basic SELECT, INSERT, UPDATE, DELETE
--            operations
-- homepage : https://github.com/mattmc3/sqlgen-procs
-- license  : MIT - https://github.com/mattmc3/sqlgen-procs/blob/master/LICENSE
--------------------------------------------------------------------------------
alter procedure dbo.sp_script_dml
    @database_name nvarchar(128)         -- Script from the database name specified
    ,@table_schema nvarchar(128) = null  -- Script only the schema specified
    ,@table_name nvarchar(128) = null    -- Script only the table specified
    ,@dml_type nvarchar(1000) = null     -- Script only the DML type specified
    ,@include_timestamps bit = 1         -- Boolean for including timestamps in the script output
    ,@now datetime = null                -- Override the script generation time
as
begin

set nocount on

-- defaults
select @now = isnull(@now, getdate())

if @table_name is not null and @table_schema is null
begin
    set @table_schema = isnull(@table_schema, 'dbo')
end

-- check params
if @dml_type is not null and
   @dml_type not in ('SELECT', 'INSERT', 'UPDATE', 'DELETE') begin
    raiserror('The @dml_type values supported are "SELECT", "INSERT", "UPDATE", or "DELETE".', 16, 10)    return
end

-- vars
declare @strnow nvarchar(50) = format(@now, 'M/d/yyyy h:mm:ss tt')
      , @sql nvarchar(max)
      , @param_defs nvarchar(1000)
      , @modifiable_cols int
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
set @param_defs='@table_schema nvarchar(128), @table_name nvarchar(128), @object_id int output'
set @sql = 'use ' + quotename(@database_name) + '
select @object_id = object_id(quotename(@table_schema) + ''.'' + quotename(@table_name))'
exec sp_executesql @sql, @param_defs, @table_schema=@table_schema, @table_name=@table_name, @object_id=@object_id output

if object_id('tempdb..#ist') is not null drop table #ist
select top 0 cast(null as int) as object_id, * into #ist from information_schema.tables
set @sql = '
use ' + quotename(@database_name) + '
insert into #ist
select object_id(quotename(ist.table_schema) + ''.'' + quotename(ist.table_name)) as object_id
     , ist.*
  from information_schema.tables ist
 where @object_id is null
    or @object_id = object_id(quotename(ist.table_schema) + ''.'' + quotename(ist.table_name))
'
set @param_defs='@object_id int'
exec sp_executesql @sql, @param_defs, @object_id=@object_id

if object_id('tempdb..#isc') is not null drop table #isc
select top 0 cast(null as int) as object_id, cast(null as int) as column_id, *
into #isc
from information_schema.columns
set @sql = '
use ' + quotename(@database_name) + '
insert into #isc
select sc.object_id as object_id
     , sc.column_id
     , isc.*
  from information_schema.columns isc
  join sys.columns sc
    on sc.object_id = object_id(quotename(isc.table_schema) + ''.'' + quotename(isc.table_name))
   and sc.name = isc.column_name
 where sc.object_id = isnull(@object_id, sc.object_id)
'
set @param_defs='@object_id int'
exec sp_executesql @sql, @param_defs, @object_id=@object_id

if object_id('tempdb..#pks') is not null drop table #pks
create table #pks (object_id int, column_id int, is_primary_key bit)
set @sql = '
use ' + quotename(@database_name) + '
insert into #pks
select sic.object_id, sic.column_id, si.is_primary_key
  from sys.indexes si
  join sys.index_columns sic
    on sic.object_id = si.object_id
   and si.index_id = sic.index_id
 where si.is_primary_key = 1
 and si.object_id = isnull(@object_id, si.object_id)
'
set @param_defs='@object_id int'
exec sp_executesql @sql, @param_defs, @object_id=@object_id

if object_id('tempdb..#syscols') is not null drop table #syscols
select top 0 * into #syscols from sys.columns
set @sql = '
insert into #syscols
select *
from ' + quotename(@database_name) + '.sys.columns sc
where sc.object_id = isnull(@object_id, sc.object_id)'
set @param_defs='@object_id int'
exec sp_executesql @sql, @param_defs, @object_id=@object_id

if object_id('tempdb..#systypes') is not null drop table #systypes
select top 0 * into #systypes from sys.types
set @sql = 'insert into #systypes select * from ' + quotename(@database_name) + '.sys.types'
exec sp_executesql @sql
-- =============================================================================

if object_id('tempdb..#tables') is not null drop table #tables
select ist.*
     , quotename(ist.table_schema) + '.' + quotename(ist.table_name) as quoted_table_name
into #tables
from #ist ist

if object_id('tempdb..#columns') is not null drop table #columns
select isc.*
     , ist.table_type
     , quotename(isc.table_schema) + '.' + quotename(isc.table_name) as quoted_table_name
     , sc.is_identity
     , sc.is_rowguidcol
     , sc.is_computed
     , isnull(p.is_primary_key, 0) as is_primary_key
     , row_number() over (partition by isc.object_id
                          order by isc.ordinal_position desc) as ordinal_position_desc
     , case
       when sc.user_type_id <> sc.system_type_id
       then ut.name -- if we have a user defined type, use that
       else
           isc.data_type +
           case
           when isc.data_type in ('binary', 'char', 'nchar', 'nvarchar', 'varbinary', 'varchar')
           then '(' + isnull(nullif(cast(isc.character_maximum_length as nvarchar), '-1'), 'max') + ')'
           when isc.data_type in ('decimal', 'numeric')
           then '(' + cast(isc.numeric_precision as nvarchar) + ',' + cast(isc.numeric_scale as nvarchar) + ')'
           when isc.data_type in ('datetime2', 'datetimeoffset', 'time')
           then '(' + cast(isc.datetime_precision as nvarchar) + ')'
           else ''
           end
       end as sql_datatype
  into #columns
  from #isc isc
  join #ist ist     on isc.object_id = ist.object_id
  join #syscols sc  on sc.object_id = isc.object_id
                   and sc.column_id = isc.column_id
  join #systypes st on sc.system_type_id = st.user_type_id
  join #systypes ut on sc.user_type_id = ut.user_type_id
  left join #pks p  on sc.object_id = p.object_id
                   and sc.column_id = p.column_id

if object_id('tempdb..#mod_cols') is not null drop table #mod_cols
select c.*
     , row_number() over (partition by c.object_id
                          order by c.ordinal_position) as ord
     , row_number() over (partition by c.object_id
                          order by c.ordinal_position desc) as ord_desc
  into #mod_cols
  from #columns c
 where c.is_identity <> 1
   and c.is_rowguidcol <> 1

select @modifiable_cols = count(*) from #mod_cols

-- get the SQL DML ===========================================================
if object_id('tempdb..#results') is not null drop table #results
create table #results (
     [db_name] nvarchar(128)
    ,table_schema nvarchar(128)
    ,table_name nvarchar(128)
    ,sql_category nvarchar(128)
    ,seq int
    ,sql_text nvarchar(max)
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
-- delete ====================================================================
select t.table_catalog
     , t.table_schema
     , t.table_name
     , N'delete' as sql_category
     , n.num as seq
     , case n.num
       when 0 then N'DELETE FROM ' + t.quoted_table_name
       when 1 then N'      WHERE <Search Conditions,,>'
       when 2 then N'GO'
       else N''
       end as sql_text
from #tables t
cross apply @numbers n
where n.num < 5

-- insert ====================================================================
union all
select t.table_catalog
     , t.table_schema
     , t.table_name
     , N'insert' as sql_category
     , 1 as seq
     , N'INSERT INTO ' + t.quoted_table_name as sql_text
from #tables t
where @modifiable_cols > 0
union all
select c.table_catalog
     , c.table_schema
     , c.table_name
     , N'insert' as sql_category
     , 1 + c.ord
     , replicate(' ', 11) +
       case when c.ord = 1 then N'(' else N',' end +
       quotename(c.column_name) +
       case when c.ord_desc = 1 then N')' else N'' end
       as sql_text
from #mod_cols c
where @modifiable_cols > 0
union all
select t.table_catalog
     , t.table_schema
     , t.table_name
     , N'insert' as sql_category
     , 1000 as seq
     , replicate(' ', 5) + N'VALUES' as sql_text
from #tables t
where @modifiable_cols > 0
union all
select c.table_catalog
     , c.table_schema
     , c.table_name
     , N'insert' as sql_category
     , 1000 + c.ord
     , replicate(' ', 11) +
       case when c.ord = 1 then N'(' else N',' end +
       N'<' + c.column_name + N', ' + c.sql_datatype + N',>' +
       case when c.ord_desc = 1 then N')' else N'' end
       as sql_text
from #mod_cols c
where @modifiable_cols > 0
union all
select t.table_catalog
     , t.table_schema
     , t.table_name
     , N'insert' as sql_category
     , 20000 + n.num as seq
     , case when n.num = 0 then N'GO' else N'' end as sql_text
from #tables t
cross apply @numbers n
where n.num < 3
and @modifiable_cols > 0
union all
select t.table_catalog
     , t.table_schema
     , t.table_name
     , N'insert' as sql_category
     , 20000 + n.num as seq
     , case n.num
       when 0 then N'-- ' + t.quoted_table_name + N' contains no columns that can be inserted.'
       when 1 then N'GO'
       else N''
       end as sql_text
from #tables t
cross apply @numbers n
where n.num < 4
and @modifiable_cols = 0

-- select ====================================================================
union all
select c.table_catalog
     , c.table_schema
     , c.table_name
     , N'select' as sql_category
     , c.ordinal_position
     , case when c.ordinal_position = 1 then N'SELECT ' else N'      ,' end +
       quotename(c.column_name)
       as sql_text
from #columns c
union all
select t.table_catalog
     , t.table_schema
     , t.table_name
     , N'select' as sql_category
     , 9999 as seq
     , N'  FROM ' + t.quoted_table_name as sql_text
from #tables t
union all
select t.table_catalog
     , t.table_schema
     , t.table_name
     , N'select' as sql_category
     , 10000 + n.num as seq
     , case when n.num = 0 then N'GO' else N'' end as sql_text
from #tables t
cross apply @numbers n
where n.num < 3

-- update ====================================================================
union all
select t.table_catalog
     , t.table_schema
     , t.table_name
     , N'update' as sql_category
     , 1 as seq
     , N'UPDATE ' + t.quoted_table_name as sql_text
from #tables t
where @modifiable_cols > 0
union all
select c.table_catalog
     , c.table_schema
     , c.table_name
     , N'update' as sql_category
     , 1 + c.ord
     , case when c.ord = 1 then N'   SET ' else N'      ,' end +
       quotename(c.column_name) + N' = <' + c.column_name + N', ' + c.sql_datatype + N',>'
       as sql_text
from #mod_cols c
where @modifiable_cols > 0
union all
select t.table_catalog
     , t.table_schema
     , t.table_name
     , N'update' as sql_category
     , 10000 + n.num as seq
     , case
       when n.num = 0 then N' WHERE <Search Conditions,,>'
       when n.num = 1 then N'GO'
       else N''
       end as sql_text
from #tables t
cross apply @numbers n
where n.num < 4
and @modifiable_cols > 0
union all
select t.table_catalog
     , t.table_schema
     , t.table_name
     , N'update' as sql_category
     , 20000 + n.num as seq
     , case n.num
       when 0 then N'-- ' + t.quoted_table_name + N' contains no columns that can be updated.'
       when 1 then N'GO'
       else N''
       end as sql_text
from #tables t
cross apply @numbers n
where n.num < 4
and @modifiable_cols = 0

-- return results ==============================================================
select *
from #results
order by 1, 2, 3, 4, 5

-- cleanup
if object_id('tempdb..#ist') is not null drop table #ist
if object_id('tempdb..#isc') is not null drop table #isc
if object_id('tempdb..#syscolumns') is not null drop table #syscolumns
if object_id('tempdb..#systypes') is not null drop table #systypes
if object_id('tempdb..#tables') is not null drop table #tables
if object_id('tempdb..#columns') is not null drop table #columns
if object_id('tempdb..#mod_cols') is not null drop table #mod_cols
if object_id('tempdb..#results') is not null drop table #results

end
go
