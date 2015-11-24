@echo off

rdmd --build-only -Irabcdasm -g main
if errorlevel 1 exit /b 1

rdmd --build-only -J. swfmerge
if errorlevel 1 exit /b 1
