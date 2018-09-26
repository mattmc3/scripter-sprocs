if objectproperty(object_id('dbo.sp_script_logins'), 'IsProcedure') is null begin
    exec('create proc dbo.sp_script_logins as')
end
go
--------------------------------------------------------------------------------
-- proc     : sp_script_logins
-- author   : mattmc3
-- version  : v0.4.4
-- purpose  : Generates SQL scripts for SQL Agent logins
-- homepage : https://github.com/mattmc3/sqlgen-procs
-- license  : MIT - https://github.com/mattmc3/sqlgen-procs/blob/master/LICENSE
--------------------------------------------------------------------------------
alter procedure dbo.sp_script_logins
     @login_name nvarchar(128) = null  -- Script only the specified login
    ,@include_timestamps bit = 1       -- Boolean for including timestamps in the script output
    ,@now datetime = null              -- Override the script generation time
as
begin

set nocount on

-- defaults
select @now = isnull(@now, getdate())

-- vars
declare @strnow nvarchar(50)
      , @sql nvarchar(max)
      , @param_defs nvarchar(1000)

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
if object_id('tempdb..#syslogins') is not null drop table #syslogins
create table #syslogins (
    principal_id int
    ,sid varbinary(85)
    ,login_name nvarchar(128)
    ,type char(1)
    ,type_desc nvarchar(60)
    ,password_hash varbinary(256)
    ,default_database_name nvarchar(128)
    ,default_language_name nvarchar(128)
    ,is_expiration_checked bit
    ,is_policy_checked bit
    ,is_disabled bit
    ,denylogin int
    ,hasaccess int
)

set @sql = '
insert into #syslogins
select sp.principal_id
     , sp.sid
     , sp.name as login_name
     , sp.type
     , sp.type_desc
     , sl.password_hash
     , sp.default_database_name
     , sp.default_language_name
     , sl.is_expiration_checked
     , sl.is_policy_checked
     , sp.is_disabled
     , ssl.denylogin
     , ssl.hasaccess
from sys.server_principals sp
left join sys.sql_logins sl on sp.name = sl.name
left join sys.syslogins ssl on sp.name = ssl.name
where sp.type in (''S'', ''U'', ''G'')
and sp.name = isnull(@login_name, sp.name)
and sp.name <> ''sa''
order by sp.name
'
set @param_defs='@login_name nvarchar(128)'
exec sp_executesql @sql, @param_defs, @login_name=@login_name
-- =============================================================================

-- SQL results
if object_id('tempdb..#results') is not null drop table #results
create table #results (
    login_name nvarchar(128)
    ,sql_category nvarchar(128)
    ,sql_subcategory int
    ,seq int
    ,sql_text nvarchar(max)
)

insert into #results
select
    a.login_name
    ,a.type_desc
    ,a.principal_id
    ,100000000 + n.num
    ,case n.num
     when 0
     then N'/****** Object:  Login ' +
          replace(a.login_name, @APOS, @APOS + @APOS) +
          case when @include_timestamps = 1 then N'    Script Date: ' + @strnow
               else ''
          end + N' ******/'
     when 1
     then N'CREATE LOGIN ' + quotename(a.login_name) + N' ' +
          case a.type
          when 'S'
          then N'WITH PASSWORD=' + convert(nvarchar(1000), a.password_hash, 1) + N' HASHED, ' +
               N'SID=' + convert(nvarchar(1000), a.sid, 1) + N', ' +
               N'DEFAULT_DATABASE=' + quotename(a.default_database_name) + N', ' +
               N'DEFAULT_LANGUAGE=' + quotename(a.default_language_name) + N', ' +
               N'CHECK_EXPIRATION=' + case when a.is_expiration_checked = 1 then N'YES' else N'NO' end + N', ' +
               N'CHECK_POLICY=' + case when a.is_policy_checked = 1 then N'YES' else N'NO' end
          else N'FROM WINDOWS WITH DEFAULT_DATABASE=' + quotename(a.default_database_name)
          end
     when 2 then case 
                 when a.denylogin = 1
                 then N'DENY CONNECT SQL TO ' + quotename(a.login_name)
                 when a.hasaccess = 0
                 then N'REVOKE CONNECT SQL TO ' + quotename(a.login_name)
                 else null
                 end
     when 3 then case 
                 when a.is_disabled = 1
                 then N'ALTER LOGIN ' + quotename(a.login_name) + N' DISABLE'
                 else null
                 end
     when 4 then N''
     end
from #syslogins a
cross apply @numbers n
where n.num < 5

-- return results
select *
from #results r
where r.sql_text is not null
order by r.login_name, r.seq

-- cleanup
if object_id('tempdb..#syslogins') is not null drop table #syslogins
if object_id('tempdb..#results') is not null drop table #results

end
go
