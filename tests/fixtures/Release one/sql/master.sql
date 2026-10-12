-- Calls in comments, output and strings must not count.
-- start commented.pb
REM start commented.pb
REMARK @commented.pb
REMA @@commented.pb
/* start commented.pb
   @@commented.pb */
PROMPT start prompt_only.pb and @prompt_only.pb
PRO Here's a quote that should not hide later calls: '
spool call_log.txt
select 'start string_only.pb' from dual;
select 'multiline literal:
@string_only.pb
escaped quote '' and -- text' from dual;
select q'[alternate literal:
@string_only.pb
]' from dual;
start py_post.pb
START PY_POST.PB -- repeated, case-insensitive
  sta py_post.ps
star create_tables
@@subfolder\post_install.sql
start "subfolder\script with spaces.pb" argument1 "argument two"
start 'subfolder\single quoted.pb' argument1
start "subfolder\quoted--name.pb" -- real comment
start "subfolder\semi;colon.pb"
start unique.DATA
start dup.pb
@same.sql;
@wrong\py_post.pb
@missing.sql
@&release_script
/* leading comment */ start MiXeD.PKS
@nested.sql
@same.sql
start "subfolder\Bob's file.pb" 'trailing argument'
spool off
