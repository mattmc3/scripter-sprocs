if objectproperty(object_id('dbo.script_object_definition'), 'IsProcedure') is null begin
    exec('create proc dbo.script_object_definition as')
end
go
--------------------------------------------------------------------------------
-- proc    : script_object_definition
-- author  : mattmc3
-- version : v0.3.0-20180709
-- purpose : Generates SQL scripts for objects with SQL definitions.
--           Specifically views, sprocs, and user defined funcs.
--           Mimics SSMS scripting behavior.
-- license : MIT
--           https://github.com/mattmc3/sqlgen-procs/blob/master/LICENSE
-- params  : @database_name nvarchar(128): Name of the database
--           @object_type nvarchar(100): The type of script to generate:
--                  - ALL (<NULL>)
--                  - VIEW
--                  - PROCEDURE
--                  - FUNCTION
--           @create_or_alter_header nvarchar(100): The header syntax:
--                  - CREATE
--                  - ALTER
--                  - DROP
--                  - DROP AND CREATE
--                  - CREATE OR ALTER
-- todos  : None
--------------------------------------------------------------------------------
create or alter procedure [dbo].[script_object_definition]
    @database_name nvarchar(128)
    ,@object_type nvarchar(100) = null
    ,@create_or_alter_header nvarchar(100) = 'CREATE OR ALTER'
    ,@object_schema nvarchar(128) = null
    ,@object_name nvarchar(128) = null
    ,@use_statement_per_object bit = 1
    ,@extra_line_breaks bit = 0
    ,@include_header_comment bit = 1
    ,@tab_replacement varchar(10) = null
as
begin

set nocount on

-- Temporarily uncomment for inline testing
--declare @database_name nvarchar(128) = 'master'
--      , @create_or_alter_header nvarchar(100) = 'drop and create'
--      , @object_schema nvarchar(128) = null
--      , @object_name nvarchar(128) = null

set @create_or_alter_header = isnull(@create_or_alter_header, 'CREATE')
set @object_type = isnull(@object_type, 'ALL')

if @create_or_alter_header not in ('CREATE', 'DROP', 'DROP AND CREATE', 'CREATE OR ALTER') begin
    raiserror('The @create_or_alter_header values supported are ''CREATE'', ''DROP'', ''DROP AND CREATE'', and ''CREATE OR ALTER''', 16, 10)
    return
end

set @tab_replacement = isnull(@tab_replacement, char(9))

declare @sql nvarchar(max)
      , @has_drop bit = 0
      , @has_definition bit = 1
      , @now datetime = getdate()
      , @strnow nvarchar(50)

-- don't rely on FORMAT() since early SQL Server is missing it
select @strnow = cast(datepart(month, @now) as nvarchar(2)) + '/' +
                 cast(datepart(day, @now) as nvarchar(2)) + '/' +
                 cast(datepart(year, @now) as nvarchar(4)) + ' ' +
                 cast(datepart(hour, @now) % 12 as nvarchar(2)) + ':' +
                 right('0' + cast(datepart(minute, @now) as nvarchar(2)), 2) + ':' +
                 right('0' + cast(datepart(second, @now) as nvarchar(2)), 2) + ' ' +
                 case when datepart(hour, @now) < 12 then 'AM' else 'PM' end

if @object_name is not null begin
    set @object_schema = isnull(@object_schema, 'dbo')
end

if @create_or_alter_header in ('drop', 'drop and create') begin
    set @has_drop = 1
end

if @create_or_alter_header in ('drop') begin
    set @has_definition = 0  -- false
end


-- get definitions ============================================================
declare @defs table (
    object_id int not null
    ,object_catalog nvarchar(128) not null
    ,object_schema nvarchar(128) not null
    ,object_name nvarchar(128) not null
    ,quoted_name nvarchar(500) not null
    ,object_definition nvarchar(max) null
    ,uses_ansi_nulls bit null
    ,uses_quoted_identifier bit null
    ,is_schema_bound bit null
    ,object_type_code char(2) null
    ,object_type varchar(10) not null
    ,object_language varchar(10) not null
)

declare @c cursor
      , @dbname nvarchar(128)
set @c = cursor local fast_forward for
    select d.name
    from sys.databases d
    where d.name = @database_name
    or (
        @database_name is null
        and d.name not in (
            'master'
            ,'tempdb'
            ,'model'
            ,'msdb'
            ,'DWDiagnostics'
            ,'DWConfiguration'
            ,'DWQueue'
        )
    )

open @c
fetch next from @c into @dbname
while @@fetch_status = 0 begin
    set @sql = 'use ' + quotename(@dbname) + ';
    select so.object_id as object_id
         , db_name() as object_catalog
         , schema_name(so.schema_id) as object_schema
         , so.name as object_name
         , quotename(schema_name(so.schema_id)) + ''.'' + quotename(so.name) as quoted_name
         , sm.definition as object_definition
         , sm.uses_ansi_nulls
         , sm.uses_quoted_identifier
         , sm.is_schema_bound
         , so.type as object_type_code
         , case when so.type in (''V'') then ''VIEW''
                when so.type in (''P'', ''PC'') then ''PROCEDURE''
                else ''FUNCTION''
           end as object_type
         , case when so.type in (''V'', ''P'', ''FN'', ''TF'', ''IF'') then ''SQL''
                else ''EXTERNAL''
           end as object_language
    into ##__script_object_definition__39609F__
    from sys.objects so
    left join sys.sql_modules sm
      on sm.object_id = so.object_id
    where so.type in (''V'', ''P'', ''FN'', ''TF'', ''IF'', ''AF'', ''FT'', ''IS'', ''PC'', ''FS'')
    and so.is_ms_shipped = 0
    and so.name not in (''fn_diagramobjects'', ''sp_alterdiagram'', ''sp_creatediagram'', ''sp_dropdiagram'', ''sp_helpdiagramdefinition'', ''sp_helpdiagrams'', ''sp_renamediagram'', ''sp_upgraddiagrams'', ''sysdiagrams'')
    order by 1, 2, 3
    '

    -- Really hate to use a global temp table here, but an INSERT-EXEC cannot be
    -- nested, which means that whomever calls this proc is not going to be able
    -- to use that technique, and that is too handy to waste doing it here.
    drop table if exists ##__script_object_definition__39609F__
    exec sp_executesql @sql
    insert into @defs
    select * from ##__script_object_definition__39609F__
    drop table if exists ##__script_object_definition__39609F__

    -- whittle down
    delete from @defs
    where (@object_schema is not null and object_schema <> @object_schema)
    or (@object_name is not null and object_name <> @object_name)

    fetch next from @c into @dbname
end

-- Clean up cursor
close @c
deallocate @c

-- standardize on newlines for split
update @defs
set object_definition = replace(object_definition, char(13) + char(10), char(10))

-- standardize tabs
if @tab_replacement <> char(9) begin
    update @defs
    set object_definition = replace(object_definition, char(9), @tab_replacement)
end

-- result ======================================================================
declare @result table (
    object_catalog nvarchar(128)
    ,object_schema nvarchar(128)
    ,object_name nvarchar(128)
    ,object_type nvarchar(128)
    ,seq int
    ,sql_stmt nvarchar(max)
)


-- header ======================================================================
if @use_statement_per_object = 0 begin
    -- just one database
    insert into @result (
        object_catalog
        ,object_schema
        ,object_name
        ,object_type
        ,seq
        ,sql_stmt
    )
    select
        a.object_catalog
        ,'' as object_schema
        ,'' as object_name
        ,'' as object_type
        ,0
        ,case b.seq
            when 1 then 'USE ' + quotename(a.object_catalog)
            when 2 then 'GO'
        end as sql_stmt
    from (select distinct object_catalog from @defs) a
    cross apply (select 1 as seq union
                 select 2) b
end
else begin
    insert into @result (
        object_catalog
        ,object_schema
        ,object_name
        ,object_type
        ,seq
        ,sql_stmt
    )
    select
        a.object_catalog
        ,a.object_schema
        ,a.object_name
        ,a.object_type
        ,100000000 + b.seq
        ,case b.seq
            when 1 then 'USE ' + quotename(a.object_catalog)
            when 2 then 'GO'
            when 3 then ''
        end as sql_stmt
    from @defs a
    cross apply (select 1 as seq union
                 select 2 union
                 select 3) b
end


-- drops =======================================================================
if @has_drop = 1 begin
    insert into @result (
        object_catalog
        ,object_schema
        ,object_name
        ,object_type
        ,seq
        ,sql_stmt
    )
    select
        a.object_catalog
        ,a.object_schema
        ,a.object_name
        ,a.object_type
        ,200000000 + b.seq
        ,case
            when b.seq = 1 and @include_header_comment = 1 then '/****** Object:  ' +
                case a.object_type
                    when 'VIEW' then 'View'
                    when 'PROCEDURE' then 'StoredProcedure'
                    when 'FUNCTION' then 'UserDefinedFunction'
                    else ''
                end + ' ' + a.quoted_name + space(4) + 'Script Date: ' + @strnow + ' ******/'
            when b.seq = 2 then 'DROP ' + a.object_type + ' ' + a.quoted_name
            when b.seq = 3 then 'GO'
            when b.seq = 4 then ''
            else null
        end as sql_stmt
    from @defs a
    cross apply (select 1 as seq union
                 select 2 union
                 select 3 union
                 select 4) b
end

-- Parse DDL into one record per line ==========================================
-- I could use string_split but the documentation does not specify that order is
-- preserved, and that is crucial to this parse. Also, string_split is 2016+.
if @has_definition = 1 begin
    declare @ddl_parse table (
        object_id int
        ,seq int
        ,start_idx int
        ,end_idx int
    )

    declare @rc int = -1
    declare @seq int = 1
    while @rc <> 0 begin
        insert into @ddl_parse (
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
        from @defs d
        left join @ddl_parse p
            on d.object_id = p.object_id
            and p.seq = @seq - 1
        where @seq = 1
           or p.end_idx <= len(d.object_definition)

        set @rc = @@rowcount
        set @seq = @seq + 1
    end

    -- Add DDL lines to result =================================================
    insert into @result (
        object_catalog
        ,object_schema
        ,object_name
        ,object_type
        ,seq
        ,sql_stmt
    )
    select d.object_catalog
         , d.object_schema
         , d.object_name
         , d.object_type
         , p.seq + 500000000  -- start with a high sequence so that we can add header/footer sql
         , substring(d.object_definition, p.start_idx, p.end_idx - p.start_idx) as sql_stmt
    from @defs d
    join @ddl_parse p
            on d.object_id = p.object_id
    order by d.object_id, p.seq

    -- Wrap the SQL statements with boiler plate ===============================
    insert into @result (
        object_catalog
        ,object_schema
        ,object_name
        ,object_type
        ,seq
        ,sql_stmt
    )
    select
        a.object_catalog
        ,a.object_schema
        ,a.object_name
        ,a.object_type
        ,300000000 + b.seq
        ,case
            when b.seq = 1 and @include_header_comment = 1 then '/****** Object:  ' +
                case a.object_type
                    when 'VIEW' then 'View'
                    when 'PROCEDURE' then 'StoredProcedure'
                    when 'FUNCTION' then 'UserDefinedFunction'
                    else ''
                end + ' ' + a.quoted_name + space(4) + 'Script Date: ' + @strnow + ' ******/'
            when b.seq = 2 then 'SET ANSI_NULLS ' + case when a.uses_ansi_nulls = 1 then 'ON' else 'OFF' end
            when b.seq = 3 then 'GO'
            when b.seq = 4 then ''
            when b.seq = 5 then 'SET QUOTED_IDENTIFIER ' + case when a.uses_quoted_identifier = 1 then 'ON' else 'OFF' end
            when b.seq = 6 then 'GO'
            when b.seq = 7 then ''
            else null
        end as sql_stmt
        from @defs a
        cross apply (select 1 as seq union
                     select 2 union
                     select 3 union
                     select 4 union
                     select 5 union
                     select 6 union
                     select 7) b

        insert into @result (
            object_catalog
            ,object_schema
            ,object_name
            ,object_type
            ,seq
            ,sql_stmt
        )
        select
            a.object_catalog
            ,a.object_schema
            ,a.object_name
            ,a.object_type
            ,800000000 + b.seq
            ,case b.seq
                when 1 then 'GO'
                when 2 then ''
            end as sql_stmt
        from @defs a
        cross apply (select 1 as seq union
                     select 2) b
end

-- Fix the create statement ====================================================
if @create_or_alter_header in ('create', 'alter', 'create or alter') begin
    ;with cte as (
        select *
             , row_number() over (partition by object_schema, object_name
                                  order by seq) as rn
        from (
            select *
                 , patindex('%create%' +
                   case when object_type = 'PROCEDURE' then 'PROC'
                        else object_type
                   end + '%' + object_schema + '%.%' + object_name + '%', sql_stmt) as create_idx
            from @result
        ) a
        where create_idx > 0
    )
    update cte
    set sql_stmt = replace(case when ascii(left(ltrim(substring(sql_stmt, create_idx + 6, 8000)), 1)) between 97 and 122
                                then lower(@create_or_alter_header)
                                else @create_or_alter_header
                           end + ' ' + ltrim(substring(sql_stmt, create_idx + 6, 8000))
                           ,object_schema + '.' + object_name
                           ,quotename(object_schema) + '.' + quotename(object_name))
    where rn = 1
end


-- Clean up based on formatting
if @extra_line_breaks = 0 begin
    -- remove blank lines
    delete from @result
    where seq / 100000000 <> 5
    and sql_stmt = ''
end

-- Return the result data ======================================================
delete from @result
where sql_stmt is null

select *
from @result r
where r.object_type = @object_type
or @object_type = 'ALL'
order by 4, 1, 2, 3, 5

end
go
