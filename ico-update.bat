@echo off
chcp 65001 >nul
set "DRIVE=%~d0"

powershell -NoProfile -Sta -Command ^
  "Add-Type -AssemblyName System.Windows.Forms; " ^
  "$dlgFile = New-Object System.Windows.Forms.OpenFileDialog; " ^
  "$dlgFile.Title = 'Select target file'; " ^
  "$dlgFile.InitialDirectory = '%DRIVE%\'; " ^
  "$dlgFile.Filter = 'All files (*.*)|*.*|Executables and scripts (*.exe;*.bat;*.cmd)|*.exe;*.bat;*.cmd'; " ^
  "if ($dlgFile.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Write-Host 'Cancelled.'; exit 2 }; " ^
  "$target = $dlgFile.FileName; " ^
  "$dlgIco = New-Object System.Windows.Forms.OpenFileDialog; " ^
  "$dlgIco.Title = 'Select icon file (.ico)'; " ^
  "$dlgIco.InitialDirectory = '%DRIVE%\'; " ^
  "$dlgIco.Filter = 'Icon files (*.ico)|*.ico|All files (*.*)|*.*'; " ^
  "if ($dlgIco.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { Write-Host 'Icon selection cancelled.'; exit 2 }; " ^
  "$icon = $dlgIco.FileName; " ^
  "$baseName = [System.IO.Path]::GetFileNameWithoutExtension($target); " ^
  "$lnkPath = '%DRIVE%\' + $baseName + '.lnk'; " ^
  "$ws = New-Object -ComObject WScript.Shell; " ^
  "$sc = $ws.CreateShortcut($lnkPath); " ^
  "$sc.TargetPath = $target; " ^
  "$sc.WorkingDirectory = [System.IO.Path]::GetDirectoryName($target); " ^
  "$sc.IconLocation = $icon + ',0'; " ^
  "$sc.Save(); " ^
  "Write-Host ('Shortcut created: ' + $lnkPath); " ^
  "Write-Host ('Target:           ' + $target); " ^
  "Write-Host ('Icon:             ' + $icon)"

echo.
echo Done! Drive: %DRIVE%
timeout /t 3 >nul
