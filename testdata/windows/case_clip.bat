@echo off
setlocal
set HOME=
set USERPROFILE=C:\uya-verify\home
if not exist C:\uya-verify md C:\uya-verify
if not exist C:\uya-verify\home md C:\uya-verify\home
copy /Y \\host.lan\Data\uya-agent.exe C:\uya-verify\uya-agent.exe >nul
copy /Y \\host.lan\Data\kbd.exe C:\uya-verify\kbd.exe >nul
copy /Y \\host.lan\Data\clipset.ps1 C:\uya-verify\clipset.ps1 >nul
set UYA_AGENT_API_KEY=sk-test-not-used
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\uya-verify\clipset.ps1
del /Q \\host.lan\Data\w_clip.txt \\host.lan\Data\w_clip.timeout \\host.lan\Data\case_done.txt >nul 2>&1
taskkill /F /IM kbd.exe >nul 2>&1
start /b C:\uya-verify\kbd.exe \\host.lan\Data\w_clip.txt keep "/,p,a,s,t,e,CR,c,t,r,l,+,c" C:\uya-verify\uya-agent.exe --no-tui --no-save
set /a n=0
:w
ping -n 2 127.0.0.1 >nul
set /a n+=1
tasklist /FI "IMAGENAME eq kbd.exe" | find /I "kbd.exe" >nul || goto ok
if %n% GEQ 40 goto to
goto w
:to
echo TIMEOUT > \\host.lan\Data\w_clip.timeout
taskkill /F /IM kbd.exe >nul 2>&1
taskkill /F /IM uya-agent.exe >nul 2>&1
:ok
taskkill /F /IM uya-agent.exe >nul 2>&1
echo DONE > \\host.lan\Data\case_done.txt
exit /b 0
