@echo off
chcp 65001 >nul
title Fix Folder Permissions for Windows Services (Happ / Inno Setup)

:: 1. Автоматический запрос прав администратора
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [INFO] Запрос прав администратора...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ============================================================================
echo  Настройка безопасных прав доступа (ACL) для установки фоновых служб Windows
echo  Исправляет ошибки:
echo   - "Owner is outside the trusted system principals"
echo   - "Access control entry grants rights outside the trusted system principals"
echo ============================================================================
echo.
set /p "TARGET_DIR=Введите или перетащите сюда путь к папке установки (например, D:\Programs\Happ): "

:: Убираем возможные кавычки вокруг пути
set "TARGET_DIR=%TARGET_DIR:"=%"

if "%TARGET_DIR%"=="" (
    echo [ERROR] Путь не указан.
    pause
    exit /b 1
)

:: Определяем родительскую папку и корень диска
for %%I in ("%TARGET_DIR%") do (
    set "PARENT_DIR=%%~dpI"
    set "DRIVE_ROOT=%%~dI\"
)
:: Убираем завершающий слэш у родительской папки
if "%PARENT_DIR:~-1%"=="\" set "PARENT_DIR=%PARENT_DIR:~0,-1%"

echo.
echo [1/3] Настройка владельца для корня диска (%DRIVE_ROOT%)...
takeown /F "%DRIVE_ROOT%" /A >nul 2>&1

if /i not "%PARENT_DIR%"=="%DRIVE_ROOT:~0,-1%" (
    echo [2/3] Настройка строгих системных прав для родительской папки (%PARENT_DIR%)...
    echo       (Вложенные файлы и соседние программы НЕ затрагиваются)
    takeown /F "%PARENT_DIR%" /A >nul 2>&1
    icacls "%PARENT_DIR%" /inheritance:r /Q
    icacls "%PARENT_DIR%" /grant "*S-1-5-18:(OI)(CI)F" /Q
    icacls "%PARENT_DIR%" /grant "*S-1-5-32-544:(OI)(CI)F" /Q
    icacls "%PARENT_DIR%" /grant "*S-1-5-32-545:(OI)(CI)RX" /Q
)

if exist "%TARGET_DIR%" (
    echo [3/3] Сброс и наследование чистых прав для целевой папки (%TARGET_DIR%)...
    takeown /F "%TARGET_DIR%" /A /R /D Y >nul 2>&1
    icacls "%TARGET_DIR%" /reset /T /C /Q
) else (
    echo [3/3] Целевая папка еще не создана — она унаследует правильные права при установке.
)

echo.
echo [SUCCESS] Готово! Теперь можно запускать установщик программы.
pause
