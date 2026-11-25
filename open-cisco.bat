@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

set "PATH_DIR=%~dp0"
if "%PATH_DIR:~-1%"=="\" set "PATH_DIR=%PATH_DIR:~0,-1%"
set "PATH_FILE=%PATH_DIR%\cisco_path.txt"
set "REG_PATH=HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
set "PT_EXE="

rem 1. Читаем все сохраненные пути из cisco_path.txt и проверяем их по очереди
if exist "%PATH_FILE%" (
    for /f "usebackq delims=" %%L in ("%PATH_FILE%") do (
        if not defined PT_EXE (
            set "CHECK_PATH=%%~L"
            if exist "!CHECK_PATH!" (
                set "PT_EXE=!CHECK_PATH!"
            )
        )
    )
)

rem 2. Если рабочий путь не найден — ищем стандартные папки в Program Files
if not defined PT_EXE (
    set "COUNT=0"
    for /d %%D in ("C:\Program Files\Cisco Packet Tracer*" "C:\Program Files (x86)\Cisco Packet Tracer*") do (
        if exist "%%~D\bin\PacketTracer.exe" (
            set /a COUNT+=1
            set "FOUND_!COUNT!=%%~D\bin\PacketTracer.exe"
            set "NAME_!COUNT!=%%~nxD"
        )
    )

    if !COUNT! equ 1 (
        set "PT_EXE=!FOUND_1!"
    )

    if !COUNT! gtr 1 (
        echo Found multiple installations:
        echo.
        for /l %%i in (1,1,!COUNT!) do (
            echo   [%%i] !NAME_%%i!
        )
        echo   [0] Select folder manually...
        echo.
        set /p "CHOICE=Enter number: "
        
        if "!CHOICE!"=="0" (
            set "PT_EXE="
        ) else (
            for /l %%i in (1,1,!COUNT!) do (
                if "!CHOICE!"=="%%i" set "PT_EXE=!FOUND_%%i!"
            )
        )
    )
)

rem 3. Выбор папки вручную (подходит как корень Cisco Packet Tracer, так и сама папка bin)
if not defined PT_EXE (
    set "SELECTED_DIR="
    for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.FolderBrowserDialog; if ($f.ShowDialog() -eq 'OK') { $f.SelectedPath }"`) do (
        set "SELECTED_DIR=%%i"
    )

    if defined SELECTED_DIR (
        if "!SELECTED_DIR:~-1!"=="\" set "SELECTED_DIR=!SELECTED_DIR:~0,-1!"
        
        if exist "!SELECTED_DIR!\bin\PacketTracer.exe" (
            set "PT_EXE=!SELECTED_DIR!\bin\PacketTracer.exe"
        ) else if exist "!SELECTED_DIR!\PacketTracer.exe" (
            set "PT_EXE=!SELECTED_DIR!\PacketTracer.exe"
        )
    )
)

rem 4. Дописываем новый найденный путь в cisco_path.txt (без дублирования)
if defined PT_EXE (
    set "CLEAN_PATH=!PT_EXE:"=!"
    set "ALREADY_SAVED=0"
    
    if exist "%PATH_FILE%" (
        for /f "usebackq delims=" %%L in ("%PATH_FILE%") do (
            if /i "%%~L"=="!CLEAN_PATH!" set "ALREADY_SAVED=1"
        )
    )
    
    if "!ALREADY_SAVED!"=="0" (
        >>"%PATH_FILE%" echo !CLEAN_PATH!
    )
) else (
    echo PacketTracer.exe not found.
    pause
    exit /b
)

rem 5. Включаем временный локальный прокси, запускаем и возвращаем сеть
reg add "%REG_PATH%" /v ProxyEnable /t REG_DWORD /d 1 /f >nul
reg add "%REG_PATH%" /v ProxyServer /t REG_SZ /d "127.0.0.1:9999" /f >nul

start "" "!PT_EXE!"

timeout /t 10 /nobreak >nul

reg add "%REG_PATH%" /v ProxyEnable /t REG_DWORD /d 0 /f >nul
