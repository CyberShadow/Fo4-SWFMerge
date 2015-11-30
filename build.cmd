@echo off

rdmd --build-only -Irabcdasm -Ilibgit2\source -Idlibgit\src -g main
if errorlevel 1 exit /b 1

rdmd --build-only -J. swfmerge
if errorlevel 1 exit /b 1

7z a -tzip -mx=9 swfmerge.zip swfmerge.exe
