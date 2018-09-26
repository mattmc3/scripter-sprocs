if objectproperty(object_id('dbo.sp_script_operators'), 'IsProcedure') is null begin
    exec('create proc dbo.sp_script_operators as')
end
go
--------------------------------------------------------------------------------
-- proc     : sp_script_operators
-- author   : mattmc3
-- version  : v0.4.3
-- purpose  : Generates SQL scripts for SQL Server operators
-- homepage : https://github.com/mattmc3/sqlgen-procs
-- license  : MIT - https://github.com/mattmc3/sqlgen-procs/blob/master/LICENSE
--------------------------------------------------------------------------------
alter procedure dbo.sp_script_operators
     @operator_name nvarchar(512) = null  -- Script only the operator specified
    ,@include_timestamps bit = 1          -- Boolean for including timestamps in the script output
    ,@now datetime = null                 -- Override the script generation time
    ,@indent nvarchar(8) = null           -- Defaults to spaces, but could also use tab (char(9))
as
begin

set nocount on

select @now = isnull(@now, getdate())
     , @indent = isnull(@indent, replicate(' ', 4))

declare @strnow nvarchar(50)
      , @indent2 nvarchar(16) = replicate(@indent, 2)

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

-- ===========================================================================

if object_id('tempdb..#sql_parts') is not null drop table #sql_parts
create table #sql_parts (
    operator_id int
    ,operator_name nvarchar(512)
    ,sql_category nvarchar(128)
    ,sql_text nvarchar(max)
)

-- SQL that appears once per operator schedule
;with operators as (
    select xso.*
         , xsc.name as category_name
      from msdb.dbo.sysoperators xso
      join msdb.dbo.syscategories xsc
        on xso.category_id = xsc.category_id
     where xso.name = isnull(@operator_name, xso.name)
)
insert into #sql_parts
select t.id
     , t.name
     , N'sp_add_operator' as sql_category
     , N'/****** Object:  Operator [' + replace(t.name, @APOS, @APOS + @APOS) + N']' + case when @include_timestamps = 1 then N'    Script Date: ' + @strnow else '' end + N' ******/' + @NL +
       N'EXEC msdb.dbo.sp_add_operator @name=N''' + replace(t.name, @APOS, @APOS + @APOS) + @APOS +
       case when t.enabled                   is null then '' else N',' + @NL + @indent2 + '@enabled='                   + cast(t.enabled as nvarchar) end +
       case when t.weekday_pager_start_time  is null then '' else N',' + @NL + @indent2 + '@weekday_pager_start_time='  + cast(t.weekday_pager_start_time as nvarchar) end +
       case when t.weekday_pager_end_time    is null then '' else N',' + @NL + @indent2 + '@weekday_pager_end_time='    + cast(t.weekday_pager_end_time as nvarchar) end +
       case when t.saturday_pager_start_time is null then '' else N',' + @NL + @indent2 + '@saturday_pager_start_time=' + cast(t.saturday_pager_start_time as nvarchar) end +
       case when t.saturday_pager_end_time   is null then '' else N',' + @NL + @indent2 + '@saturday_pager_end_time='   + cast(t.saturday_pager_end_time as nvarchar) end +
       case when t.sunday_pager_start_time   is null then '' else N',' + @NL + @indent2 + '@sunday_pager_start_time='   + cast(t.sunday_pager_start_time as nvarchar) end +
       case when t.sunday_pager_end_time     is null then '' else N',' + @NL + @indent2 + '@sunday_pager_end_time='     + cast(t.sunday_pager_end_time as nvarchar) end +
       case when t.pager_days                is null then '' else N',' + @NL + @indent2 + '@pager_days='                + cast(t.pager_days as nvarchar) end +
       case when t.email_address             is null then '' else N',' + @NL + @indent2 + '@email_address=N'''          + cast(t.email_address as nvarchar(40)) + @APOS end +
       case when t.netsend_address           is null then '' else N',' + @NL + @indent2 + '@netsend_address=N'''        + cast(t.netsend_address as nvarchar(40)) + @APOS end +
       case when t.pager_address             is null then '' else N',' + @NL + @indent2 + '@pager_address=N'''          + cast(t.pager_address as nvarchar(40)) + @APOS end +
       case when t.category_name             is null then '' else N',' + @NL + @indent2 + '@category_name=N'''          + cast(t.category_name as nvarchar(40)) + @APOS end +
       @NL + N'GO' + @NL as sql_text
from operators t

-- SQL results
if object_id('tempdb..#results') is not null drop table #results
create table #results (
    id int identity(1, 1)
    ,operator_id int
    ,operator_name nvarchar(512)
    ,sql_category nvarchar(128)
    ,seq int
    ,sql_text nvarchar(max)
)

insert into #results (
    operator_id
    ,operator_name
    ,sql_category
    ,seq
    ,sql_text
)
select null, null, null, null
     , case n.num
       when 0 then 'USE [msdb]'
       when 1 then 'GO'
       when 2 then ''
       end
from @numbers n
where n.num < 3

insert into #results (
    operator_id
    ,operator_name
    ,sql_category
    ,seq
    ,sql_text
)
select s.operator_id
     , s.operator_name
     , s.sql_category
     , row_number() over(partition by s.operator_name, s.sql_category
                         order by t.x) as seq
     , isnull(t.x.value('text()[1]', 'nvarchar(max)'), '') as sql_text
from (
    select x.operator_id
         , x.operator_name
         , x.sql_category
         ,  cast('<rows><row>' +
                 replace(replace(replace(x.sql_text, '&', '&amp;'), '<', '&lt;'), @NL, '</row><row>') +
                 '</row></rows>' as xml) as x
    from #sql_parts x
) s
cross apply s.x.nodes('/rows/row') as t(x)
order by s.operator_name
       , s.sql_category
       , seq

select *
from #results t
order by 1

-- clean up
if object_id('tempdb..#sql_parts') is not null drop table #sql_parts
if object_id('tempdb..#results') is not null drop table #results

end
go
