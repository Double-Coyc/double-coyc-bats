<# : batch
@echo off
chcp 65001 >nul
setlocal EnableExtensions

:: === 1. Самоперезапуск из %TEMP%, чтобы не держать флешку ===
if /I "%~dp0"=="%TEMP%\" goto :MAIN
copy /Y "%~f0" "%TEMP%\eject_worker.bat" >nul 2>&1
start "" /D "%TEMP%" /min cmd /c ""%TEMP%\eject_worker.bat" "%~d0""
exit /b

:MAIN
set "TARGET_DRIVE=%~1"
if "%TARGET_DRIVE%"=="" set "TARGET_DRIVE=%~d0"

:: === 2. Запускаем PowerShell-логику, встроенную ниже ===
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "& ([scriptblock]::Create((Get-Content -LiteralPath '%~f0' -Raw -Encoding UTF8))) '%TARGET_DRIVE%'"
set "RC=%errorlevel%"

:: === 3. Самоудаление и закрытие терминала ===
del /f /q "%~f0" >nul 2>&1
exit /b %RC%
#>

# ==================== PowerShell-часть ====================
param([string]$DriveLetter)

$ErrorActionPreference = 'SilentlyContinue'

# Защита от пустого/некорректного аргумента
if (-not $DriveLetter -or $DriveLetter.Length -lt 1) { exit 1 }
$letter = $DriveLetter.Substring(0,1).ToUpper()
$driveRoot = "${letter}:\"

# ---------- Вспомогательный C# ----------
$code = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class SafeEject {
    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Locate_DevNodeW(out uint pdnDevInst, string pDeviceID, int ulFlags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Get_Parent(out uint pdnDevInst, uint dnDevInst, int ulFlags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)]
    static extern int CM_Request_Device_EjectW(uint dnDevInst, out int pVetoType, StringBuilder pszVetoName, int ulNameLength, int ulFlags);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);

    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, IntPtr rgApplications, uint nServices, string[] rgsServiceNames);

    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS {
        public int dwProcessId;
        public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string strServiceShortName;
        public int  ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }

    public static bool TryEject(string pnpId) {
        if (string.IsNullOrEmpty(pnpId)) return false;
        uint devInst;
        if (CM_Locate_DevNodeW(out devInst, pnpId, 0) != 0) return false;
        uint parentInst;
        if (CM_Get_Parent(out parentInst, devInst, 0) == 0) devInst = parentInst;
        int vetoType;
        StringBuilder vetoName = new StringBuilder(256);
        return CM_Request_Device_EjectW(devInst, out vetoType, vetoName, 256, 0) == 0;
    }

    public static int[] GetLockingPids(string[] filePaths) {
        List<int> pids = new List<int>();
        if (filePaths == null || filePaths.Length == 0) return pids.ToArray();
        uint handle;
        string key = Guid.NewGuid().ToString();
        if (RmStartSession(out handle, 0, key) != 0) return pids.ToArray();
        try {
            if (RmRegisterResources(handle, (uint)filePaths.Length, filePaths, 0, IntPtr.Zero, 0, null) == 0) {
                uint needed = 0, count = 0, reasons = 0;
                int res = RmGetList(handle, out needed, ref count, null, ref reasons);
                if (res == 234 && needed > 0) {
                    RM_PROCESS_INFO[] info = new RM_PROCESS_INFO[needed];
                    count = needed;
                    if (RmGetList(handle, out needed, ref count, info, ref reasons) == 0) {
                        for (int i = 0; i < count; i++) pids.Add(info[i].Process.dwProcessId);
                    }
                }
            }
        } finally { RmEndSession(handle); }
        return pids.ToArray();
    }
}
"@
Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue

# ---------- Определяем PNPDeviceID диска ----------
$logDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${letter}:'" -ErrorAction SilentlyContinue
if (-not $logDisk) { exit 0 }   # флешки уже нет — всё ок

# Берём первый диск (на случай нескольких разделов/объектов)
$disk = $logDisk |
    Get-CimAssociatedInstance -ResultClassName Win32_DiskPartition |
    Get-CimAssociatedInstance -ResultClassName Win32_DiskDrive |
    Select-Object -First 1
if (-not $disk -or -not $disk.PNPDeviceID) { exit 1 }

# ---------- Попытка 1: штатное извлечение ----------
if ([SafeEject]::TryEject($disk.PNPDeviceID)) { exit 0 }

# ---------- Собираем "держателей" (проводник НЕ трогаем) ----------
$targetPids = New-Object System.Collections.Generic.HashSet[int]
$currentPid = $PID

# А) через Restart Manager — ОДНА сессия на все файлы
$files = Get-ChildItem -LiteralPath $driveRoot -Recurse -File -ErrorAction SilentlyContinue |
         Select-Object -First 300 -ExpandProperty FullName
if ($files) {
    foreach ($p in [SafeEject]::GetLockingPids($files)) { [void]$targetPids.Add($p) }
}

# Б) процессы, запущенные с флешки (explorer явно исключаем)
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -ne 'explorer.exe' -and (
        ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($driveRoot, [StringComparison]::OrdinalIgnoreCase)) -or
        ($_.CommandLine   -and $_.CommandLine.IndexOf($driveRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    )
} | ForEach-Object { [void]$targetPids.Add([int]$_.ProcessId) }

# ---------- Закрываем аккуратно: мягко → при необходимости Force ----------
$protected = @('explorer','winlogon','csrss','services','lsass','svchost','dwm')
foreach ($procId in @($targetPids)) {
    if ($procId -le 4 -or $procId -eq $currentPid) { continue }
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $p) { continue }
    if ($protected -contains $p.ProcessName) { continue }

    # Оконные приложения — вежливое закрытие (может спросить «Сохранить?»)
    if ($p.MainWindowHandle -ne 0) {
        try { $p.CloseMainWindow() | Out-Null } catch {}
    }
}
Start-Sleep -Milliseconds 800

# Безоконные процессы, которые реально держат файлы, — завершаем
foreach ($procId in @($targetPids)) {
    if ($procId -le 4 -or $procId -eq $currentPid) { continue }
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $p) { continue }   # уже завершился
    if ($protected -contains $p.ProcessName) { continue }
    if ($p.MainWindowHandle -eq 0) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Milliseconds 600

# ---------- Попытка 2: извлечение после закрытия ----------
if ([SafeEject]::TryEject($disk.PNPDeviceID)) { exit 0 }

# ---------- Попытка 3: размонтирование тома + извлечение ----------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class VolOps {
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sa, uint c, uint f, IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(IntPtr h, uint code, IntPtr inB, uint inS, IntPtr outB, uint outS, out uint br, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool FlushFileBuffers(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);
    public static bool Dismount(string letter) {
        IntPtr h = CreateFileW(@"\\.\" + letter, 0x80000000|0x40000000, 1|2, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == new IntPtr(-1)) return false;
        FlushFileBuffers(h);
        uint br;
        DeviceIoControl(h, 0x00090018, IntPtr.Zero, 0, IntPtr.Zero, 0, out br, IntPtr.Zero); // LOCK
        bool ok = DeviceIoControl(h, 0x00090020, IntPtr.Zero, 0, IntPtr.Zero, 0, out br, IntPtr.Zero); // DISMOUNT
        CloseHandle(h);
        return ok;
    }
}
"@ -ErrorAction SilentlyContinue
[void][VolOps]::Dismount("${letter}:")
Start-Sleep -Milliseconds 500
if ([SafeEject]::TryEject($disk.PNPDeviceID)) { exit 0 }

# ---------- Не получилось: MessageBox с авто-закрытием через 10 сек ----------
Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue

$title = "Безопасное извлечение"
$msg = "Не удалось безопасно извлечь диск ${letter}:`n`nВозможно, файл удерживается системной службой или программой, запущенной от имени администратора.`n`nЗакройте такие программы и повторите."

# MessageBox в отдельном runspace — основной поток не блокируется
$ps = [PowerShell]::Create()
[void]$ps.AddScript({
    param($m, $t)
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show($m, $t, "OK", "Warning") | Out-Null
}).AddArgument($msg).AddArgument($title)

$async = $ps.BeginInvoke()

# Ждём появления окна (до 5 сек), затем через 10 сек шлём WM_CLOSE
$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt 50; $i++) {
    Start-Sleep -Milliseconds 100
    $hwnd = [SafeEject]::FindWindow($null, $title)
    if ($hwnd -ne [IntPtr]::Zero) { break }
}

if ($hwnd -ne [IntPtr]::Zero) {
    Start-Sleep -Seconds 10
    [void][SafeEject]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE
}

try { $ps.EndInvoke($async) } catch {}
$ps.Dispose()

exit 1
