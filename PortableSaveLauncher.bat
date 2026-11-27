@echo off
chcp 65001 > nul
setlocal EnableDelayedExpansion

set "ScriptDir=%~dp0"
set "ScriptDir=%ScriptDir:~0,-1%"
set "ConfigFile=%ScriptDir%\config.ini"

if /i "%~1"=="--setup" goto :Setup
if not exist "%ConfigFile%" goto :Setup

for /f "usebackq tokens=1,* delims==" %%A in ("%ConfigFile%") do (
    if /i "%%A"=="GameExe" set "AppPath=%%B"
    if /i "%%A"=="SystemSaveDir" set "DestDir=%%B"
    if /i "%%A"=="PortableSaveDir" set "SourceDir=%%B"
    if /i "%%A"=="BackupDir" set "BackupRoot=%%B"
)

if not defined AppPath goto :Setup
if not defined DestDir goto :Setup
if not defined SourceDir goto :Setup
goto :RunGame

:Setup
echo [НАСТРОЙКА] Открываются окна выбора путей...

for /f "delims=" %%I in ('powershell -NoProfile -Sta -Command "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; Add-Type -AssemblyName System.Windows.Forms; $f=New-Object System.Windows.Forms.OpenFileDialog; $f.Title='Шаг 1 из 3: Выберите файл игры (.exe)'; $f.Filter='Исполняемые файлы (*.exe)|*.exe|Все файлы (*.*)|*.*'; $f.InitialDirectory='%ScriptDir%'; if($f.ShowDialog() -eq 'OK'){$f.FileName}"') do set "AppPath=%%I"

if not defined AppPath (
    echo [ОТМЕНА] Файл игры не выбран.
    pause
    exit /b 1
)

for /f "delims=" %%I in ('powershell -NoProfile -Sta -Command "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; Add-Type -AssemblyName System.Windows.Forms; $d=New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description='Шаг 2 из 3: Выберите СИСТЕМНУЮ папку сохранений'; $d.SelectedPath=[Environment]::GetFolderPath('LocalApplicationData'); if($d.ShowDialog() -eq 'OK'){$d.SelectedPath}"') do set "DestDir=%%I"

if not defined DestDir (
    echo [ОТМЕНА] Системная папка сохранений не выбрана.
    pause
    exit /b 1
)

for /f "delims=" %%I in ('powershell -NoProfile -Sta -Command "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; Add-Type -AssemblyName System.Windows.Forms; $d=New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description='Шаг 3 из 3: Выберите ПОРТАТИВНУЮ папку сохранений'; $d.SelectedPath='%ScriptDir%'; if($d.ShowDialog() -eq 'OK'){$d.SelectedPath}"') do set "SourceDir=%%I"

if not defined SourceDir (
    echo [ОТМЕНА] Портативная папка сохранений не выбрана.
    pause
    exit /b 1
)

if not defined BackupRoot set "BackupRoot=%SourceDir%_Backups"

powershell -NoProfile -Command "$lines=@(\"GameExe=$env:AppPath\",\"SystemSaveDir=$env:DestDir\",\"PortableSaveDir=$env:SourceDir\",\"BackupDir=$env:BackupRoot\"); $lines | Set-Content -LiteralPath '%ConfigFile%' -Encoding UTF8"

echo [ОК] Настройки сохранены в "%ConfigFile%".

:RunGame
if not exist "%AppPath%" (
    echo [ОШИБКА] Не найден файл игры: "%AppPath%"
    echo Удалите config.ini или запустите с параметром --setup.
    pause
    exit /b 1
)

if not exist "%SourceDir%" mkdir "%SourceDir%"
if not exist "%BackupRoot%" mkdir "%BackupRoot%"

dir /b "%SourceDir%" 2>nul | findstr "^" > nul
if not errorlevel 1 (
    for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'"') do set "Stamp=%%I"
    set "CurrentBackup=%BackupRoot%\Backup_!Stamp!"
    echo Создание резервной копии в "!CurrentBackup!"...
    robocopy "%SourceDir%" "!CurrentBackup!" /e /unicode /r:3 /w:5 /nfl /ndl /njh /njs
    if errorlevel 8 (
        echo [ОШИБКА] Не удалось создать резервную копию.
        pause
        exit /b 1
    )
)

if not exist "%DestDir%" mkdir "%DestDir%"
echo Копирование сохранений в системную папку...
robocopy "%SourceDir%" "%DestDir%" /e /unicode /r:3 /w:5 /nfl /ndl /njh /njs

echo Запуск игры...
start "" /wait "%AppPath%"

echo Синхронизация обновлённых сохранений...
robocopy "%DestDir%" "%SourceDir%" /e /unicode /r:3 /w:5 /nfl /ndl /njh /njs

if defined DestDir if exist "%DestDir%" (
    echo Очистка системной папки сохранений...
    rd /s /q "%DestDir%"
)

echo Готово!
pause
endlocal
