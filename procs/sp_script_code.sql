if objectproperty(object_id('dbo.sp_script_code'), 'IsProcedure') is null begin
    exec('create proc dbo.sp_script_code as')
end
go
--------------------------------------------------------------------------------
-- proc     : sp_script_code
-- author   : mattmc3
-- version  : v0.4.4
-- purpose  : Generates SQL scripts for coded sprocs, functions, and views
-- homepage : https://github.com/mattmc3/sqlgen-procs
-- license  : MIT - https://github.com/mattmc3/sqlgen-procs/blob/master/LICENSE
--------------------------------------------------------------------------------
alter procedure dbo.sp_script_code
    @database_name varchar(128)            -- Script from the database name specified
    ,@object_schema nvarchar(128) = null   -- Script only the schema specified
    ,@object_name nvarchar(128) = null     -- Script only the object name specified
    ,@object_type nvarchar(1) = null       -- Script only the object type specified ('V', 'F', 'P')
    ,@include_timestamps bit = 1           -- Boolean for including timestamps in the script output
    ,@now datetime = null                  -- Override the script generation time
    ,@tab_replacement nvarchar(8) = null   -- Don't like tabs? Replace with this value
    ,@remove_extra_blank_lines bit = 0     -- The generator mimics SSMS, so there are extra blanks you may not want
    ,@create_method_sql nvarchar(100) = null  -- Replace the object creation with 'CREATE', 'ALTER', 'DROP AND CREATE', 'CREATE OR ALTER'
as
begin

set nocount on

-- defaults
select @now = isnull(@now, getdate())

if @object_name is not null
begin
    set @object_schema = isnull(@object_schema, 'dbo')
end

-- check params
if @create_method_sql is not null and
   @create_method_sql not in ('CREATE', 'ALTER', 'DROP AND CREATE', 'CREATE OR ALTER') begin
    raiserror('The @create_method_sql values supported are ''CREATE'', ''ALTER'', ''DROP AND CREATE'', and ''CREATE OR ALTER''', 16, 10)    return
end

if @object_type is not null and @object_type not in ('V', 'F', 'P') begin
    raiserror('The @object_type values supported are ''F'', ''V'', and ''P'' for function, view, or proc.', 16, 10)    return
end

-- vars
declare @strnow nvarchar(50)
      , @sql nvarchar(max)

-- const
declare @APOS nvarchar(1) = N''''
      , @NL nvarchar(1) = char(10)

-- don't rely on FORMAT() since early SQL Server is missing it
select @strnow = cast(datepart(month, @now) as nvarchar(2)) + '/' +
                 cast(datepart(day, @now) as nvarchar(2)) + '/' +
                 cast(datepart(year, @now) as nvarchar(4)) + ' ' +
                 cast(datepart(hour, @now) % 12 as nvarchar(2)) + ':' +
                 right('0' + cast(datepart(minute, @now) as nvarchar(2)), 2) + ':' +
                 right('0' + cast(datepart(second, @now) as nvarchar(2)), 2) + ' ' +
                 case when datepart(hour, @now) < 12 then 'AM' else 'PM' end

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
if object_id('tempdb..#schemas') is not null drop table #schemas
select top 0 * into #schemas from sys.schemas
set @sql = 'insert into #schemas select * from ' + quotename(@database_name) + '.sys.schemas'
exec sp_executesql @sql

if object_id('tempdb..#sql_modules') is not null drop table #sql_modules
select top 0 * into #sql_modules from sys.sql_modules
set @sql = 'insert into #sql_modules select * from ' + quotename(@database_name) + '.sys.sql_modules'
exec sp_executesql @sql

if object_id('tempdb..#objects') is not null drop table #objects
select top 0 * into #objects from sys.objects
set @sql = 'insert into #objects select * from ' + quotename(@database_name) + '.sys.objects'
exec sp_executesql @sql
-- =============================================================================

if object_id('tempdb..#code') is not null drop table #code
select o.object_id as object_id
    ,@database_name as object_catalog
    ,sch.name as object_schema
    ,o.name as object_name
    ,quotename(sch.name) + '.' + quotename(o.name) as quoted_name
    ,sm.definition as object_definition
    ,sm.uses_ansi_nulls
    ,sm.uses_quoted_identifier
    ,sm.is_schema_bound
    ,o.type as object_type_code
    ,case
        when o.type in ('V') then 'VIEW'
        when o.type in ('P', 'PC') then 'PROCEDURE'
        else 'FUNCTION'
    end as object_type
    ,case
        when o.type in ('V', 'P', 'FN', 'TF', 'IF') then 'SQL'
        else 'EXTERNAL'
    end as object_language
into #code
from #objects o
join #schemas sch on o.schema_id = sch.schema_id
join #sql_modules sm
  on sm.object_id = o.object_id
where o.type in ('V', 'P', 'FN', 'TF', 'IF', 'AF', 'FT', 'IS', 'PC', 'FS')
and o.is_ms_shipped = 0
and o.name not in (
    'fn_diagramobjects'
    ,'sp_alterdiagram'
    ,'sp_creatediagram'
    ,'sp_dropdiagram'
    ,'sp_helpdiagramdefinition'
    ,'sp_helpdiagrams'
    ,'sp_renamediagram'
    ,'sp_upgraddiagrams'
    ,'sysdiagrams'
)
and sch.name = isnull(@object_schema, sch.name)
and o.name = isnull(@object_name, o.name)
and (
    @object_type is null
    or (o.[type] = 'V' and @object_type = 'V')
    or (o.[type] in ('P', 'PC') and @object_type = 'P')
    or (o.[type] not in ('V', 'P', 'PC') and @object_type = 'F')
)

-- standardize on newlines for split
update #code
set object_definition = replace(object_definition, char(13) + char(10), char(10))

-- standardize tabs
if @tab_replacement is not null and @tab_replacement <> char(9) begin
    update #code
    set object_definition = replace(object_definition, char(9), @tab_replacement)
end

-- build parser instructions
if object_id('tempdb..#sql_parse') is not null drop table #sql_parse
create table #sql_parse (
    object_id int
    ,seq int
    ,start_idx int
    ,end_idx int
)

declare @rc int = -1
declare @seq int = 1
while @rc <> 0 begin
    insert into #sql_parse (
        object_id
        ,seq
        ,start_idx
        ,end_idx
    )
    select
        d.object_id
        ,@seq as seq
        ,isnull(p.end_idx, 0) + 1 as start_idx
        ,isnull(nullif(charindex(char(10), d.object_definition, isnull(p.end_idx, 0) + 1), 0), len(d.object_definition) + 1) as end_idx
    from #code d
    left join #sql_parse p
        on d.object_id = p.object_id
        and p.seq = @seq - 1
    where @seq = 1
        or p.end_idx <= len(d.object_definition)

    set @rc = @@rowcount
    set @seq = @seq + 1
end

-- Construct results ===========================================================
if object_id('tempdb..#results') is not null drop table #results
create table #results (
    object_catalog nvarchar(128)
    ,object_schema nvarchar(128)
    ,object_name nvarchar(128)
    ,object_type nvarchar(128)
    ,seq int
    ,sql_text nvarchar(max)
)

insert into #results (
    object_catalog
    ,object_schema
    ,object_name
    ,object_type
    ,seq
    ,sql_text
)
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
    a.object_catalog
    ,a.object_schema
    ,a.object_name
    ,a.object_type
    ,200000000 + n.num
    ,case n.num
     when 0 then N'/****** Object:  ' +
                 case a.object_type
                 when 'VIEW' then 'View'
                 when 'PROCEDURE' then 'StoredProcedure'
                 when 'FUNCTION' then 'UserDefinedFunction'
                 else ''
                 end + ' ' +
                 replace(a.quoted_name, @APOS, @APOS + @APOS) +
                 case when @include_timestamps = 1 then N'    Script Date: ' + @strnow
                      else ''
                 end + N' ******/'
    when 1 then N'SET ANSI_NULLS ON'
    when 2 then N'GO'
    when 3 then N''
    when 4 then N'SET QUOTED_IDENTIFIER ON'
    when 5 then N'GO'
    when 6 then N''
    end
from #code a
cross apply @numbers n
where n.num < 7
and (a.uses_ansi_nulls = 1 or n.num not between 1 and 3)
and (a.uses_quoted_identifier = 1 or n.num not between 4 and 6)

insert into #results (
    object_catalog
    ,object_schema
    ,object_name
    ,object_type
    ,seq
    ,sql_text
)
select d.object_catalog
     , d.object_schema
     , d.object_name
     , d.object_type
     , p.seq + 400000000  -- start with a high sequence so that we can add sql around it
     , substring(d.object_definition, p.start_idx, p.end_idx - p.start_idx) as sql_text
from #code d
join #sql_parse p
        on d.object_id = p.object_id
order by d.object_id, p.seq

-- Clean up the SQL ============================================================
-- handle replacement of create/alter
if @create_method_sql is not null begin
    ;with cte as (
        select *
             , row_number() over (partition by object_schema, object_name
                                  order by seq) as rn
        from (
            select *
                 , patindex('%create%' +
                   case when object_type = 'PROCEDURE' then 'PROC'
                        else object_type
                   end + '%' + object_schema + '%.%' + object_name + '%', sql_text) as create_idx
            from #results
        ) a
        where create_idx > 0
    )
    update cte
    set sql_text = replace(case when ascii(left(ltrim(substring(sql_text, create_idx + 6, 8000)), 1)) between 97 and 122
                                then lower(@create_method_sql)
                                else @create_method_sql
                           end + ' ' + ltrim(substring(sql_text, create_idx + 6, 8000))
                           ,object_schema + '.' + object_name
                           ,quotename(object_schema) + '.' + quotename(object_name))
    where rn = 1
end

-- Clean up based on formatting
if @remove_extra_blank_lines = 1 begin
    -- remove blank lines
    delete from #results
    where seq / 100000000 <> 4 -- skip the actual SQL
    and sql_text = ''
end

-- return results
select *
from #results r
order by 1, 2, 3, 5

-- cleanup
if object_id('tempdb..#objects') is not null drop table #objects
if object_id('tempdb..#results') is not null drop table #results
if object_id('tempdb..#schemas') is not null drop table #schemas
if object_id('tempdb..#sql_modules') is not null drop table #sql_modules

end
go
