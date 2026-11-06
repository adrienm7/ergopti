@echo off
rem tools/build/windows_keyboard_layout_package/install.cmd
rem Installs the Ergopti keyboard layout from this folder. Windows asks for
rem administrator rights; the installer is not signed, so it may also warn
rem that the publisher is unknown. Then log out and back in if the layout is
rem not offered right away.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_package.ps1"
if errorlevel 1 pause
