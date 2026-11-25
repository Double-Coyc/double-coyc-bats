<# :
@echo off
chcp 65001 >nul
setlocal

if "%~1"=="" (
    copy /y "%~f0" "%TEMP%\eject_safe.bat" >nul
    start "" /d "%TEMP%" /min cmd /c ""%TEMP%\eject_safe.bat" %~d0"
    exit
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((Get-Content -LiteralPath '%~f0' -Raw -Encoding UTF8))) '%~1'"
del /f /q "%~f0" >nul 2>&1
exit
#>

$letter = $args.Substring(0, 1)
$driveRoot = "$($letter):\"

$logDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($letter):'" -ErrorAction SilentlyContinue
if (-not $logDisk) { exit }

$disk = $logDisk | Get-CimAssociatedInstance -ResultClassName Win32_DiskPartition | Get-CimAssociatedInstance -ResultClassName Win32_DiskDrive
if (-not $disk.PNPDeviceID) { exit }

$code = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class SafeUsb {
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
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    public static bool TryEject(string pnpId) {
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
        uint handle;
        string key = Guid.NewGuid().ToString();
        if (RmStartSession(out handle, 0, key) != 0) return pids.ToArray();

        try {
            if (RmRegisterResources(handle, (uint)filePaths.Length, filePaths, 0, IntPtr.Zero, 0, null) == 0) {
                uint pnProcInfoNeeded = 0, pnProcInfo = 0, lpdwRebootReasons = 0;
                int res = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, null, ref lpdwRebootReasons);
                if (res == 234 && pnProcInfoNeeded > 0) {
                    RM_PROCESS_INFO[] processInfo = new RM_PROCESS_INFO[pnProcInfoNeeded];
                    pnProcInfo = pnProcInfoNeeded;
                    if (RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, processInfo, ref lpdwRebootReasons) == 0) {
                        for (int i = 0; i < pnProcInfo; i++) {
                            pids.Add(processInfo[i].Process.dwProcessId);
                        }
                    }
                }
            }
        } finally {
            RmEndSession(handle);
        }
        return pids.ToArray();
    }
}
"@

Add-Type -TypeDefinition $code
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# 1. Первая попытка — штатное извлечение
if ([SafeUsb]::TryEject($disk.PNPDeviceID)) { exit }

# 2. Собираем процессы, которые держат диск/файлы
$targetPids = New-Object System.Collections.Generic.HashSet[int]

# Способ А: через Restart Manager
$allFiles = Get-ChildItem -Path $driveRoot -Recurse -File -ErrorAction SilentlyContinue |
    Select-Object -First 300 -ExpandProperty FullName

if ($allFiles) {
    foreach ($file in $allFiles) {
        $pids = [SafeUsb]::GetLockingPids(@($file))
        foreach ($p in $pids) { [void]$targetPids.Add($p) }
    }
}

# Способ Б: через командную строку процессов
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -match [regex]::Escape($driveRoot) -or $_.ExecutablePath -match "^$([regex]::Escape($driveRoot))"
} | ForEach-Object {
    [void]$targetPids.Add([int]$_.ProcessId)
}

# 3. Закрываем процессы без сохранения
$currentPid = $PID
foreach ($procId in $targetPids) {
    if ($procId -eq $currentPid -or $procId -le 4) { continue }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -ne 'explorer') {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
}

Start-Sleep -Milliseconds 600

# 4. Финальное извлечение (с авто-закрытием окна)
if (-not [SafeUsb]::TryEject($disk.PNPDeviceID)) {
    $title = "Ошибка извлечения USB"
    
    # Запускаем MessageBox в отдельном runspace, чтобы основной поток не блокировался
    $ps = [PowerShell]::Create()
    $ps.AddScript({
        param($msg, $title)
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show($msg, $title, "OK", "Warning") | Out-Null
    }).AddArgument("Не удалось извлечь диск $($letter):`nВозможно, файл удерживается системной службой или программой от имени администратора.").AddArgument($title) | Out-Null
    
    $async = $ps.BeginInvoke()
    
    # Ждем, пока окно появится, и закрываем его через 10 секунд
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 100
        $hwnd = [SafeUsb]::FindWindow($null, $title)
        if ($hwnd -ne [IntPtr]::Zero) { break }
    }
    
    if ($hwnd -ne [IntPtr]::Zero) {
        Start-Sleep -Seconds 10
        [SafeUsb]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    }
    
    $ps.EndInvoke($async)
    $ps.Dispose()
}