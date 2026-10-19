@echo off
rem ITDeploy build script: Delphi 10.4 (RAD Studio 21.0). Output: bin\ITDeploy.exe (single file, agents embedded).
setlocal
set "BDS=C:\Program Files (x86)\Embarcadero\Studio\21.0\bin"
if not exist "%BDS%\dcc32.exe" goto :nodelphi
cd /d "%~dp0"
if not exist obj mkdir obj
if not exist bin mkdir bin
if not exist agent\out32 mkdir agent\out32
if not exist agent\out64 mkdir agent\out64

echo [1/5] Agent Win32
"%BDS%\dcc32.exe" -Q -B -E"agent\out32" -N0"agent\out32" agent\ITDeployAgent.dpr || goto :fail
echo [2/5] Agent Win64
"%BDS%\dcc64.exe" -Q -B -E"agent\out64" -N0"agent\out64" agent\ITDeployAgent.dpr || goto :fail
echo [3/5] Resources
"%BDS%\brcc32.exe" -fo"Agents.res" Agents.rc || goto :fail
"%BDS%\brcc32.exe" -fo"ITDeploy.res" ITDeploy.rc || goto :fail
echo [4/5] Application
"%BDS%\dcc32.exe" -Q -B -E"bin" -N0"obj" -U"src" -R"." -NSWinapi;System.Win;Data.Win;Vcl;System;Xml;Data ITDeploy.dpr || goto :fail
echo [5/5] Done: %~dp0bin\ITDeploy.exe
exit /b 0
:nodelphi
echo Delphi not found. Edit the BDS path at the top of build.bat
exit /b 1
:fail
echo BUILD FAILED
exit /b 1
