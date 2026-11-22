@echo off
:: Add-FideBookOS-to-Windows-BootMenu.bat
:: Automatically registers FideBookOS in the Windows Boot Manager menu.
:: Run this file as Administrator inside Windows after installing FideBookOS in Dual-Boot mode.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo ==========================================================
    echo  ERROR: Administrator privileges required!
    echo  Please right-click this file and select 'Run as administrator'
    echo ==========================================================
    echo.
    pause
    exit /b 1
)

echo.
echo ==========================================================
echo  Adding FideBookOS to Windows Boot Manager...
echo ==========================================================
echo.

for /f "tokens=2 delims={}" %%g in ('bcdedit /copy {bootmgr} /d "FideBookOS"') do (
    set ENTRY_GUID={%%g}
)

if "%ENTRY_GUID%"=="" (
    echo FAILED: Could not create boot entry in Windows BCD.
    pause
    exit /b 1
)

echo Created boot entry %ENTRY_GUID%
bcdedit /set %ENTRY_GUID% path \EFI\fidebookos\BOOTX64.EFI
bcdedit /displayorder %ENTRY_GUID% /addlast
bcdedit /timeout 10

echo.
echo ==========================================================
echo  SUCCESS! FideBookOS was added to the Windows boot menu.
echo  When you turn on or restart your laptop, you can choose
echo  between Windows and FideBookOS.
echo ==========================================================
echo.
pause
