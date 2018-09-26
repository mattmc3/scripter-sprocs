if objectproperty(object_id('dbo.sp_script_jobs'), 'IsProcedure') is null begin
    exec('create proc dbo.sp_script_jobs as')
end
go
--------------------------------------------------------------------------------
-- proc     : sp_script_jobs
-- author   : mattmc3
-- version  : v0.4.4
-- purpose  : Generates SQL scripts for SQL Agent jobs
-- homepage : https://github.com/mattmc3/sqlgen-procs
-- license  : MIT - https://github.com/mattmc3/sqlgen-procs/blob/master/LICENSE
--------------------------------------------------------------------------------
alter procedure dbo.sp_script_jobs
     @job_name nvarchar(512) = null  -- Script only the job specified
    ,@include_timestamps bit = 1     -- Boolean for including timestamps in the script output
    ,@now datetime = null            -- Override the script generation time
    ,@indent nvarchar(8) = null      -- Defaults to spaces, but could also use tab (char(9))
as
begin

-- DEBUG
/*
declare @include_timestamps bit = 1
      , @indent nvarchar(8) = null
      , @now datetime = null
      , @job_name nvarchar(512) = null
*/
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
    job_id uniqueidentifier
    ,job_name nvarchar(512)
    ,sql_category nvarchar(128)
    ,sql_subcategory bigint
    ,sql_text nvarchar(max)
)

-- SQL that appears once per job
;with jobs as (
    select sj.*
         , sj.name as job_name
         , suser_sname(sj.owner_sid) as owner_login_name
         , sc.name as category_name
         , sc.category_class
         , sc.category_type
         , so_email.name as notify_email_operator_name
         , so_pager.name as notify_page_operator_name
         , so_netsend.name as notify_netsend_operator_name
      from msdb.dbo.sysjobs sj
      join msdb.dbo.syscategories sc
        on sj.category_id = sc.category_id
      left join msdb.dbo.sysoperators so_email
        on sj.notify_email_operator_id = so_email.id
      left join msdb.dbo.sysoperators so_pager
        on sj.notify_page_operator_id = so_pager.id
      left join msdb.dbo.sysoperators so_netsend
        on sj.notify_netsend_operator_id = so_netsend.id
     where sj.name = isnull(@job_name, sj.name)
)
insert into #sql_parts
select j.job_id
     , j.job_name
     , N'header' as sql_category
     , null as sql_subcategory
     , N'/****** Object:  Job [' + replace(j.job_name, @APOS, @APOS + @APOS) + N']' + case when @include_timestamps = 1 then N'    Script Date: ' + @strnow else '' end + N' ******/' + @NL +
       N'BEGIN TRANSACTION' + @NL +
       N'DECLARE @ReturnCode INT' + @NL +
       N'SELECT @ReturnCode = 0'
from jobs j
union all
select j.job_id
     , j.job_name
     , N'sp_add_category' as sql_category
     , null as sql_subcategory
     , N'/****** Object:  JobCategory [' + replace(j.category_name, @APOS, @APOS + @APOS) + N']    Script Date: ' + @strnow + N' ******/' + @NL +
       N'IF NOT EXISTS (SELECT name FROM msdb.dbo.syscategories WHERE name=N''' + replace(j.category_name, @APOS, @APOS + @APOS) + ''' AND category_class=' + cast(j.category_class as nvarchar) + N')' + @NL +
       N'BEGIN' + @NL +
       N'EXEC @ReturnCode = msdb.dbo.sp_add_category @class=N''JOB'', @type=N''LOCAL'', @name=N''' + replace(j.category_name, @APOS, @APOS + @APOS) + @APOS + @NL +
       N'IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback' + @NL + @NL +
       N'END' + @NL
from jobs j
union all
select j.job_id
     , j.job_name
     , N'sp_add_job' as sql_category
     , null as sql_subcategory
     , N'DECLARE @jobId BINARY(16)' +
       @NL + N'EXEC @ReturnCode =  msdb.dbo.sp_add_job @job_name=N''' + replace(j.name, @APOS, @APOS + @APOS) + N'''' +
       case when j.enabled                      is null then N'' else N', ' + @NL + @indent2 + N'@enabled=' + cast(j.enabled as nvarchar) end +
       case when j.notify_level_eventlog        is null then N'' else N', ' + @NL + @indent2 + N'@notify_level_eventlog='           + cast(j.notify_level_eventlog as nvarchar) end +
       case when j.notify_level_email           is null then N'' else N', ' + @NL + @indent2 + N'@notify_level_email='              + cast(j.notify_level_email as nvarchar) end +
       case when j.notify_level_netsend         is null then N'' else N', ' + @NL + @indent2 + N'@notify_level_netsend='            + cast(j.notify_level_netsend as nvarchar) end +
       case when j.notify_level_page            is null then N'' else N', ' + @NL + @indent2 + N'@notify_level_page='               + cast(j.notify_level_page as nvarchar) end +
       case when j.delete_level                 is null then N'' else N', ' + @NL + @indent2 + N'@delete_level='                    + cast(j.delete_level as nvarchar) end +
       case when j.description                  is null then N'' else N', ' + @NL + @indent2 + N'@description=N'''                  + replace(j.description, @APOS, @APOS + @APOS) + @APOS end +
       case when j.category_name                is null then N'' else N', ' + @NL + @indent2 + N'@category_name=N'''                + replace(j.category_name, @APOS, @APOS + @APOS) + @APOS end +
       case when j.owner_login_name             is null then N'' else N', ' + @NL + @indent2 + N'@owner_login_name=N'''             + replace(j.owner_login_name, @APOS, @APOS + @APOS) + @APOS end +
       case when j.notify_email_operator_name   is null then N'' else N', ' + @NL + @indent2 + N'@notify_email_operator_name=N'''   + replace(j.notify_email_operator_name, @APOS, @APOS + @APOS) + @APOS end +
       case when j.notify_netsend_operator_name is null then N'' else N', ' + @NL + @indent2 + N'@notify_netsend_operator_name=N''' + replace(j.notify_netsend_operator_name, @APOS, @APOS + @APOS) + @APOS end +
       case when j.notify_page_operator_name    is null then N'' else N', ' + @NL + @indent2 + N'@notify_page_operator_name=N'''    + replace(j.notify_page_operator_name, @APOS, @APOS + @APOS) + @APOS end +
       N', @job_id = @jobId OUTPUT' + @NL +
       N'IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback' as sql_text
from jobs j
union all
select j.job_id
     , j.job_name
     , N'sp_update_job' as sql_category
     , null as sql_subcategory
     , N'EXEC @ReturnCode = msdb.dbo.sp_update_job @job_id = @jobId, @start_step_id = ' + cast(j.start_step_id as nvarchar) + @NL +
       N'IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback'
from jobs j
union all
select j.job_id
     , j.job_name
     , N'sp_add_jobserver' as sql_category
     , null as sql_subcategory
     , N'EXEC @ReturnCode = msdb.dbo.sp_add_jobserver @job_id = @jobId, @server_name = N''(local)''' + @NL +
       N'IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback'
from jobs j
union all
select j.job_id
     , j.job_name
     , N'footer' as sql_category
     , null as sql_subcategory
     , N'COMMIT TRANSACTION' + @NL +
       N'GOTO EndSave' + @NL +
       N'QuitWithRollback:' + @NL +
       @indent + N'IF (@@TRANCOUNT > 0) ROLLBACK TRANSACTION' + @NL +
       N'EndSave:' + @NL + @NL +
       N'GO' + @NL
from jobs j


-- SQL that appears once per job schedule
;with sch as (
    select j.job_id
         , j.name as job_name
         , ssch.name as schedule_name
         , ssch.*
    from msdb.dbo.sysjobs j
    join msdb.dbo.sysjobschedules jsch
      on j.job_id = jsch.job_id
    join msdb.dbo.sysschedules ssch
      on jsch.schedule_id = ssch.schedule_id
   where j.name = isnull(@job_name, j.name)
)
insert into #sql_parts
select t.job_id
     , t.job_name
     , N'sp_add_jobschedule' as sql_category
     , t.schedule_id as sql_subcategory
     , N'EXEC @ReturnCode = msdb.dbo.sp_add_jobschedule @job_id=@jobId, @name=N''' + replace(t.schedule_name, @APOS, @APOS + @APOS) + @APOS +
       case when t.enabled                is null then '' else N', ' + @NL + @indent2 + '@enabled='                + cast(t.enabled as nvarchar) end +
       case when t.freq_type              is null then '' else N', ' + @NL + @indent2 + '@freq_type='              + cast(t.freq_type as nvarchar) end +
       case when t.freq_interval          is null then '' else N', ' + @NL + @indent2 + '@freq_interval='          + cast(t.freq_interval as nvarchar) end +
       case when t.freq_subday_type       is null then '' else N', ' + @NL + @indent2 + '@freq_subday_type='       + cast(t.freq_subday_type as nvarchar) end +
       case when t.freq_subday_interval   is null then '' else N', ' + @NL + @indent2 + '@freq_subday_interval='   + cast(t.freq_subday_interval as nvarchar) end +
       case when t.freq_relative_interval is null then '' else N', ' + @NL + @indent2 + '@freq_relative_interval=' + cast(t.freq_relative_interval as nvarchar) end +
       case when t.freq_recurrence_factor is null then '' else N', ' + @NL + @indent2 + '@freq_recurrence_factor=' + cast(t.freq_recurrence_factor as nvarchar) end +
       case when t.active_start_date      is null then '' else N', ' + @NL + @indent2 + '@active_start_date='      + cast(t.active_start_date as nvarchar) end +
       case when t.active_end_date        is null then '' else N', ' + @NL + @indent2 + '@active_end_date='        + cast(t.active_end_date as nvarchar) end +
       case when t.active_start_time      is null then '' else N', ' + @NL + @indent2 + '@active_start_time='      + cast(t.active_start_time as nvarchar) end +
       case when t.active_end_time        is null then '' else N', ' + @NL + @indent2 + '@active_end_time='        + cast(t.active_end_time as nvarchar) end +
       case when t.schedule_uid           is null then '' else N', ' + @NL + @indent2 + '@schedule_uid=N'''        + lower(cast(t.schedule_uid as nvarchar(40))) + @APOS end +
       @NL + N'IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback' as sql_text
from sch t

-- SQL that appears once per step
;with steps as (
    select sj.name as job_name
         , sjs.*
    from msdb.dbo.sysjobsteps sjs
    join msdb.dbo.sysjobs sj
      on sjs.job_id = sj.job_id
   where sj.name = isnull(@job_name, sj.name)
)
insert into #sql_parts
select s.job_id
     , s.job_name
     , 'sp_add_jobstep' as sql_category
     , s.step_id as sql_subcategory
     , '/****** Object:  Step [' + replace(s.step_name, @APOS, @APOS + @APOS) + ']    Script Date: ' + @strnow + ' ******/' +
       @NL + 'EXEC @ReturnCode = msdb.dbo.sp_add_jobstep @job_id=@jobId, @step_name=N''' + replace(s.step_name, @APOS, @APOS + @APOS) + @APOS +
       case when s.step_id              is null then '' else N', ' + @NL + @indent2 + '@step_id='              + cast(s.step_id as nvarchar) end +
       case when s.cmdexec_success_code is null then '' else N', ' + @NL + @indent2 + '@cmdexec_success_code=' + cast(s.cmdexec_success_code as nvarchar) end +
       case when s.on_success_action    is null then '' else N', ' + @NL + @indent2 + '@on_success_action='    + cast(s.on_success_action as nvarchar) end +
       case when s.on_success_step_id   is null then '' else N', ' + @NL + @indent2 + '@on_success_step_id='   + cast(s.on_success_step_id as nvarchar) end +
       case when s.on_fail_action       is null then '' else N', ' + @NL + @indent2 + '@on_fail_action='       + cast(s.on_fail_action as nvarchar) end +
       case when s.on_fail_step_id      is null then '' else N', ' + @NL + @indent2 + '@on_fail_step_id='      + cast(s.on_fail_step_id as nvarchar) end +
       case when s.retry_attempts       is null then '' else N', ' + @NL + @indent2 + '@retry_attempts='       + cast(s.retry_attempts as nvarchar) end +
       case when s.retry_interval       is null then '' else N', ' + @NL + @indent2 + '@retry_interval='       + cast(s.retry_interval as nvarchar) end +
       case when s.os_run_priority      is null then '' else N', ' + @NL + @indent2 + '@os_run_priority='      + cast(s.os_run_priority as nvarchar) end +
       case when s.subsystem            is null then '' else N', '                 + '@subsystem=N'''         + replace(s.subsystem, @APOS, @APOS + @APOS) + @APOS end +
       case when s.command              is null then '' else N', ' + @NL + @indent2 + '@command=N'''           + replace(s.command, @APOS, @APOS + @APOS) + @APOS end +
       case when s.server               is null then '' else N', ' + @NL + @indent2 + '@server=N'''            + replace(s.server, @APOS, @APOS + @APOS) + @APOS end +
       case when s.database_name        is null then '' else N', ' + @NL + @indent2 + '@database_name=N'''     + replace(s.database_name, @APOS, @APOS + @APOS) + @APOS end +
       case when s.output_file_name     is null then '' else N', ' + @NL + @indent2 + '@output_file_name=N'''  + replace(s.output_file_name, @APOS, @APOS + @APOS) + @APOS end +
       case when s.flags                is null then '' else N', ' + @NL + @indent2 + '@flags='                + cast(s.flags as nvarchar) end +
       @NL + 'IF (@@ERROR <> 0 OR @ReturnCode <> 0) GOTO QuitWithRollback' as sql_text
from steps s

-- SQL results
if object_id('tempdb..#results') is not null drop table #results
create table #results (
    id int identity(1, 1)
    ,job_id uniqueidentifier
    ,job_name nvarchar(512)
    ,sql_category nvarchar(128)
    ,sql_subcategory bigint
    ,seq int
    ,sql_text nvarchar(max)
)

insert into #results (
    job_id
    ,job_name
    ,sql_category
    ,sql_subcategory
    ,seq
    ,sql_text
)
select null, null, null, null, null
     , case n.num
       when 0 then 'USE [msdb]'
       when 1 then 'GO'
       when 2 then ''
       end
from @numbers n
where n.num < 3

insert into #results (
    job_id
    ,job_name
    ,sql_category
    ,sql_subcategory
    ,seq
    ,sql_text
)
select s.job_id
     , s.job_name
     , s.sql_category
     , s.sql_subcategory
     , row_number() over(partition by s.job_name, s.sql_category, s.sql_subcategory
                         order by t.x) as seq
     , isnull(t.x.value('text()[1]', 'nvarchar(max)'), '') as sql_text
from (
    select x.job_id
         , x.job_name
         , x.sql_category
         , x.sql_subcategory
         ,  cast('<rows><row>' +
                 replace(replace(replace(x.sql_text, '&', '&amp;'), '<', '&lt;'), @NL, '</row><row>') +
                 '</row></rows>' as xml) as x
    from #sql_parts x
) s
cross apply s.x.nodes('/rows/row') as t(x)
order by s.job_name
       , case s.sql_category
         when N'header' then 1
         when N'sp_add_category' then 2
         when N'sp_add_job' then 3
         when N'sp_add_jobstep' then 4
         when N'sp_update_job' then 5
         when N'sp_add_jobschedule' then 6
         when N'sp_add_jobserver' then 7
         when N'footer' then 8
         else 99
         end
       , s.sql_subcategory
       , seq

select *
from #results t
order by 1

-- clean up
if object_id('tempdb..#sql_parts') is not null drop table #sql_parts
if object_id('tempdb..#results') is not null drop table #results

end
go
