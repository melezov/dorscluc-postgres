@echo off
setlocal
pushd "%~dp0\compiler"

set MODULE=dorscluc

echo Compiling model ...
java ^
  -jar dsl-clc.jar ^
  download ^
  dsl=..\dsl ^
  namespace=%MODULE% ^
  revenj.java=..\..\libs\%MODULE%-model.jar ^
  manual-json ^
  "postgres=localhost:5432/%MODULE%_db?user=%MODULE%_user&password=%MODULE%_pass" ^
  sql=..\sql ^
  apply
IF ERRORLEVEL 1 goto :error

set SRC=%TEMP%\DSL-Platform\model\REVENJ_JAVA

rmdir /S /Q "%SRC%\compile-revenj"

:: Format SQL script and Java sources
echo Running code formatter ...
java ^
  -Dsql-clean.regex=sql-clean.regex ^
  -jar dsl-clc-formatter.jar ^
  ..\sql ^
  "%SRC%
IF ERRORLEVEL 1 goto :error

echo Archiving sources ...
jar cfM ..\..\libs\%MODULE%-model-sources.jar -C "%SRC%" .
IF ERRORLEVEL 1 goto :error

echo Done^!
:exit
popd
pause
goto :EOF

:error
echo An error has occurred, aborting^!
goto :exit
