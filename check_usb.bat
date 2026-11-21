<# :
@echo off
chcp 65001 >nul
setlocal

if "%~1"=="" (
    copy /y "%~f0" "%TEMP%\usb_diag.bat" >nul
    start "" /d "%TEMP%" cmd /k ""%TEMP%\usb_diag.bat" %~d0"
    exit
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Get-Content -LiteralPath '%~f0' -Raw -Encoding UTF8))) '%~1'"
echo.
echo === ДИАГНОСТИКА ЗАВЕРШЕНА ===
pause
del /f /q "%~f0" >nul 2>&1
exit
#>

$target = $args[0]
$letter = $target.Substring(0, 1)

Write-Host "=== 1. ИНФОРМАЦИЯ О ТОМЕ И ДИСКЕ ($($letter):) ===" -ForegroundColor Cyan
$logDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($letter):'"
if (-not $logDisk) { Write-Host "Том $($letter): не найден!" -ForegroundColor Red; exit }
Write-Host "DriveType (2=Съемный, 3=Локальный): $($logDisk.DriveType) | ФС: $($logDisk.FileSystem)"

$part = $logDisk | Get-CimAssociatedInstance -ResultClassName Win32_DiskPartition
$disk = $part | Get-CimAssociatedInstance -ResultClassName Win32_DiskDrive
if ($disk) {
    Write-Host "Модель: $($disk.Model)"
    Write-Host "Интерфейс: $($disk.InterfaceType) | Тип носителя: $($disk.MediaType)"
    Write-Host "PNPDeviceID: $($disk.PNPDeviceID)"
} else {
    Write-Host "Физический диск через WMI не найден!" -ForegroundColor Red
}

Write-Host "`n=== 2. ПРОВЕРКА ВОЗМОЖНОСТИ ИЗВЛЕЧЕНИЯ (PnP) ===" -ForegroundColor Cyan
if ($disk.PNPDeviceID) {
    $pnp = Get-PnpDevice -InstanceId $disk.PNPDeviceID -ErrorAction SilentlyContinue
    if ($pnp) {
        $caps = (Get-PnpDeviceProperty -InstanceId $pnp.InstanceId -KeyName 'DEVPKEY_Device_Capabilities' -ErrorAction SilentlyContinue).Data
        $parent = (Get-PnpDeviceProperty -InstanceId $pnp.InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
        Write-Host "Статус PnP: $($pnp.Status) | Capabilities (флаги): $caps"
        Write-Host "Родительское устройство: $parent"
        if ($parent) {
            $pCaps = (Get-PnpDeviceProperty -InstanceId $parent -KeyName 'DEVPKEY_Device_Capabilities' -ErrorAction SilentlyContinue).Data
            Write-Host "Флаги родителя: $pCaps"
        }
    }
}

Write-Host "`n=== 3. ПОПЫТКА ИЗВЛЕЧЕНИЯ И ПЕРЕХВАТ VETO ===" -ForegroundColor Cyan
$code = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class DiagEject {
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Locate_DevNodeW(out uint pdnDevInst, string pDeviceID, int ulFlags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_Parent(out uint pdnDevInst, uint dnDevInst, int ulFlags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Request_Device_EjectW(uint dnDevInst, out int pVetoType, StringBuilder pszVetoName, int ulNameLength, int ulFlags);

    public static void Test(string pnpId) {
        uint devInst;
        int locRes = CM_Locate_DevNodeW(out devInst, pnpId, 0);
        Console.WriteLine("CM_Locate_DevNodeW code: " + locRes);
        if (locRes != 0) return;

        uint parentInst;
        if (CM_Get_Parent(out parentInst, devInst, 0) == 0) {
            Console.WriteLine("Перешли на родительский узел USB.");
            devInst = parentInst;
        }

        int vetoType;
        StringBuilder vetoName = new StringBuilder(256);
        int res = CM_Request_Device_EjectW(devInst, out vetoType, vetoName, 256, 0);
        Console.WriteLine("Результат Eject -> Code: " + res + " | VetoType: " + vetoType + " | Blocker: '" + vetoName.ToString() + "'");
    }
}
"@
Add-Type -TypeDefinition $code
if ($disk.PNPDeviceID) { [DiagEject]::Test($disk.PNPDeviceID) }

Write-Host "`n=== 4. ПРОЦЕССЫ, РАБОТАЮЩИЕ С ДИСКОМ $($letter): ===" -ForegroundColor Cyan
$procs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "$($letter):\\" -or $_.ExecutablePath -match "^$($letter):" }
if ($procs) {
    $procs | ForEach-Object { Write-Host "PID $($_.ProcessId): $($_.Name) -> $($_.CommandLine)" -ForegroundColor Yellow }
} else {
    Write-Host "Процессов, запущенных прямо с $($letter):, не найдено."
}

Write-Host "`n=== 5. ПОСЛЕДНИЕ СОБЫТИЯ БЛОКИРОВКИ ИЗВЛЕЧЕНИЯ В ЖУРНАЛЕ WINDOWS ===" -ForegroundColor Cyan
$events = Get-WinEvent -FilterHashtable @{LogName='System'; Id=225} -MaxEvents 3 -ErrorAction SilentlyContinue
if ($events) {
    $events | ForEach-Object { Write-Host "[$($_.TimeCreated)] $($_.Message)" -ForegroundColor Yellow }
} else {
    Write-Host "Событий Event ID 225 в журнале System не найдено."
}
