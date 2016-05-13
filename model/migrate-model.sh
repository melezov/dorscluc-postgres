#!/bin/bash
MODULE=dorscluc
SRC=temp/DSL-Platform/model/REVENJ_JAVA

PWD=$(pwd)
cd compiler

function error {
    echo 'An error has occurred, aborting!'
    exit 1
}

mkdir -p temp

echo Compiling model ...
java \
  -jar dsl-clc.jar \
  download \
  dependencies=temp \
  dsl=../dsl \
  "namespace=${MODULE}" \
  "revenj.java=../../libs/${MODULE}-model.jar" \
  manual-json \
  "postgres=localhost:5432/${MODULE}_db?user=${MODULE}_user&password=${MODULE}_pass" \
  sql=../sql \
  apply

exit 0

if [ $? -eq 1 ]; then error ; fi

rm -rf "$SRC/compile-revenj"

# Format SQL script and Java sources
echo Running code formatter ...
java \
  -Dsql-clean.regex=sql-clean.regex \
  -jar dsl-clc-formatter.jar \
  ../sql \
  "$SRC"

if [ $? -eq 1 ]; then error ; fi
