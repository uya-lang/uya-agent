@echo off
setlocal
set HOME=
set USERPROFILE=C:\uya-verify\home
if not exist C:\uya-verify md C:\uya-verify
if not exist C:\uya-verify\home md C:\uya-verify\home
copy /Y \\host.lan\Data\uya-agent.exe C:\uya-verify\uya-agent.exe >nul
copy /Y \\host.lan\Data\cap.exe C:\uya-verify\cap.exe >nul
del /Q \\host.lan\Data\w_ps.txt \\host.lan\Data\w_ps.timeout \\host.lan\Data\case_done.txt >nul 2>&1
taskkill /F /IM cap.exe >nul 2>&1
start /b C:\uya-verify\cap.exe \\host.lan\Data\w_ps.txt keep C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -Command "C:\uya-verify\uya-agent.exe --print-config"
set /a n=0
:w
ping -n 2 127.0.0.1 >nul
set /a n+=1
tasklist /FI "IMAGENAME eq cap.exe" | find /I "cap.exe" >nul || goto ok
if %n% GEQ 40 goto to
goto w
:to
echo TIMEOUT > \\host.lan\Data\w_ps.timeout
taskkill /F /IM cap.exe >nul 2>&1
taskkill /F /IM uya-agent.exe >nul 2>&1
:ok
taskkill /F /IM uya-agent.exe >nul 2>&1
echo DONE > \\host.lan\Data\case_done.txt
exit /b 0
