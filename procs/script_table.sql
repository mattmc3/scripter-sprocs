if objectproperty(object_id('dbo.script_table'), 'IsProcedure') is null begin
    exec('create proc dbo.script_table as')
end
go
--------------------------------------------------------------------------------
-- proc    : script_table
-- author  : mattmc3
-- version : v1.2.0-20180612
-- purpose : Generates SQL scripts for tables. Mimics SSMS "Script Table as"
--           behavior.
-- license : MIT
--           https://github.com/mattmc3/sqlgen-procs/blob/master/LICENSE
-- params  : @script_type - The type of script to generate. Valid values are
--                          'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'DROP',
--                          'CREATE'
--           @database_name - The name of the database where the table(s) to
--                            script reside. Optional - defaults to current db
--           @table_name - The name of the table to script. Optional - defaults
--                         to all tables in the database.
--           @schema_name - The name of the schema for scripting tables.
--                          Optional - defaults to all schemas, or 'dbo' if
--                          @table_name was specified.
-- todos  : - support 'DROP AND CREATE'
--          - support all features of a table in a 'CREATE'
--              * NOT FOR REPLICATION
--              * Alternate IDENTITY seeds
--              * DEFAULT constraints
--              * TEXTIMAGE_ON
--              * Indexes
--              * Computed columns
--------------------------------------------------------------------------------
alter procedure dbo.script_table
    @script_type nvarchar(128)
    ,@database_name nvarchar(128) = null
    ,@table_name nvarchar(128) = null
    ,@schema_name nvarchar(128) = null
as
begin

set nocount on

-- #DEBUG
-- declare @script_type nvarchar(128) = 'SELECT'
--       , @database_name nvarchar(128) = null
--       , @table_name nvarchar(128) = null
--       , @schema_name nvarchar(128) = null

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

if @script_type not in ('CREATE', 'DROP', 'DELETE', 'INSERT', 'SELECT', 'UPDATE') begin
    raiserror('The @script_type values supported are: (''CREATE'', ''DROP'', ''DELETE'', ''INSERT'', ''SELECT'', and ''UPDATE'')', 16, 10)
    return
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


-- get info_schema tables ======================================================
declare @tbl_info table (
     mssql_object_id   int
    ,table_catalog     nvarchar(128)
    ,table_schema      nvarchar(128)
    ,table_name        nvarchar(128)
    ,quoted_table_name nvarchar(256)
    ,table_type        nvarchar(128)
    ,created_at        datetime
    ,updated_at        datetime
    ,file_group        nvarchar(128)
)

-- based on running `sp_helptext 'information_schema.tables'` in master
set @sql = 'use ' + quotename(@database_name) + ';
    select
        o.object_id     as mssql_object_id
        ,db_name()      as table_catalog
        ,s.name         as table_schema
        ,o.name         as table_name
        ,case o.type
            when ''U'' then ''BASE TABLE''
            when ''V'' then ''VIEW''
        end as table_type
        ,o.create_date as created_at
        ,o.modify_date as updated_at
        ,isnull(filegroup_name(t.filestream_data_space_id), ''PRIMARY'') as file_group
    into ##__tbls__D78CEAA3__
    from sys.objects o
    left join sys.tables t
        on o.object_id = t.object_id
    left join sys.schemas s
        on s.schema_id = o.schema_id
    where o.type in (''U'', ''V'')
'
if object_id('tempdb..##__tbls__D78CEAA3__') is not null drop table ##__tbls__D78CEAA3__
exec sp_executesql @sql

insert into @tbl_info (
     mssql_object_id
    ,table_catalog
    ,table_schema
    ,table_name
    ,quoted_table_name
    ,table_type
    ,created_at
    ,updated_at
    ,file_group
)
select mssql_object_id
     , table_catalog
     , table_schema
     , table_name
     , quotename(table_schema) + '.' + quotename(table_name) as quoted_table_name
     , table_type
     , created_at
     , updated_at
     , file_group
from ##__tbls__D78CEAA3__ t
drop table ##__tbls__D78CEAA3__


-- get info_schema columns =====================================================
declare @col_info table (
     mssql_object_id            int
    ,mssql_column_id            int
    ,table_catalog              nvarchar(128)
    ,table_schema               nvarchar(128)
    ,table_name                 nvarchar(128)
    ,quoted_table_name          nvarchar(256)
    ,table_type                 nvarchar(128)
    ,column_name                nvarchar(128)
    ,quoted_column_name         nvarchar(256)
    ,ordinal_position           int
    ,column_default             nvarchar(4000)
    ,is_nullable                bit
    ,data_type                  nvarchar(128)
    ,user_data_type             nvarchar(128)
    ,sql_full_data_type         nvarchar(128)
    ,data_type_size             nvarchar(128)
    ,character_maximum_length   int
    ,numeric_precision          int
    ,numeric_scale              int
    ,datetime_precision         int
    ,is_computed                bit
    ,computed_column_definition nvarchar(max)
    ,is_identity                bit
    ,is_modifiable              bit
)

-- based on running `sp_helptext 'information_schema.columns'` in master
set @sql = 'use ' + quotename(@database_name) + ';
    select
        o.object_id as mssql_object_id
        ,c.column_id as mssql_column_id
        ,db_name() as table_catalog
        ,schema_name(o.schema_id) as table_schema
        ,o.name as table_name
        ,case o.type
            when ''U'' then ''BASE TABLE''
            when ''V'' then ''VIEW''
        end as table_type
        ,c.name as column_name
        ,columnproperty(c.object_id, c.name, ''ordinal'') as ordinal_position
        ,convert(nvarchar(4000), object_definition(c.default_object_id)) as column_default
        ,c.is_nullable as is_nullable
        ,isnull(type_name(c.system_type_id), t.name) as data_type
        ,isnull(type_name(c.user_type_id), t.name) as user_data_type
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
    into ##__cols__D78CEAA3__
    from sys.objects o
    join sys.columns c                on c.object_id = o.object_id
    left join sys.types t             on c.user_type_id = t.user_type_id
    left join sys.computed_columns cc on cc.object_id = o.object_id
                                     and cc.column_id = c.column_id
    where o.type in (''U'', ''V'')
'
if object_id('tempdb..##__cols__D78CEAA3__') is not null drop table ##__cols__D78CEAA3__
exec sp_executesql @sql

insert into @col_info (
     mssql_object_id
    ,mssql_column_id
    ,table_catalog
    ,table_schema
    ,table_name
    ,quoted_table_name
    ,table_type
    ,column_name
    ,quoted_column_name
    ,ordinal_position
    ,column_default
    ,is_nullable
    ,data_type
    ,user_data_type
    ,sql_full_data_type
    ,data_type_size
    ,character_maximum_length
    ,numeric_precision
    ,numeric_scale
    ,datetime_precision
    ,is_computed
    ,computed_column_definition
    ,is_identity
    ,is_modifiable
)
select mssql_object_id
     , mssql_column_id
     , table_catalog
     , table_schema
     , table_name
     , quotename(table_schema) + '.' + quotename(table_name) as quoted_table_name
     , table_type
     , column_name
     , quotename(column_name) as quoted_column_name
     , ordinal_position
     , column_default
     , is_nullable
     , data_type
     , user_data_type
     , null as sql_full_data_type
     , case when t.data_type in ('binary', 'char', 'nchar', 'nvarchar', 'varbinary', 'varchar')
           then isnull(nullif(cast(t.character_maximum_length as varchar(4)), '-1'), 'max')
           when t.data_type in ('decimal', 'numeric')
           then cast(t.numeric_precision as varchar(10)) + ',' + cast(t.numeric_scale as varchar(10))
           when t.data_type in ('datetime2', 'datetimeoffset', 'time')
           then cast(t.datetime_precision as varchar(10))
           else null
       end as data_type_size
     , character_maximum_length
     , numeric_precision
     , numeric_scale
     , datetime_precision
     , is_computed
     , computed_column_definition
     , is_identity
     , case when is_identity = 1 or is_computed = 1 or data_type = 'timestamp' then 0
            else 1
       end as is_modifiable
from ##__cols__D78CEAA3__ t
drop table ##__cols__D78CEAA3__

update @col_info
   set sql_full_data_type =
       case when user_data_type <> data_type then user_data_type
            else data_type + isnull('(' + data_type_size + ')', '')
       end


-- get sys.extended_propertied =================================================
declare @ext_prop table (
     [class] tinyint
    ,[class_desc] nvarchar(60)
    ,[major_id] int
    ,[minor_id] int
    ,[name] nvarchar(128)
    ,[value] sql_variant
)

-- based on running `sp_helptext 'information_schema.tables'` in master
if @script_type in ('CREATE') begin
    set @sql = 'use ' + quotename(@database_name) + ';
        select [class]
             , [class_desc]
             , [major_id]
             , [minor_id]
             , [name]
             , [value]
          into ##__ext_prop__D78CEAA3__
          from sys.extended_properties ep
    '
    if object_id('tempdb..##__ext_prop__D78CEAA3__') is not null drop table ##__ext_prop__D78CEAA3__
    exec sp_executesql @sql

    insert into @ext_prop (
        [class]
        ,[class_desc]
        ,[major_id]
        ,[minor_id]
        ,[name]
        ,[value]
    )
    select [class]
        , [class_desc]
        , [major_id]
        , [minor_id]
        , [name]
        , [value]
    from ##__ext_prop__D78CEAA3__ t
    drop table ##__ext_prop__D78CEAA3__
end

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
