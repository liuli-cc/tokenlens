$ErrorActionPreference = "Stop"

$project = Join-Path $PSScriptRoot "TokenLens.Windows\TokenLens.Windows.csproj"
$installDir = Join-Path $env:LOCALAPPDATA "TokenLens"
$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "TokenLens.lnk"

dotnet publish $project -c Release -r win-x64 --self-contained false -o $installDir

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $installDir "TokenLens.Windows.exe"
$shortcut.WorkingDirectory = $installDir
$shortcut.Description = "TokenLens Codex usage companion"
$shortcut.Save()

Write-Host "Installed TokenLens to $installDir"
Write-Host "Startup shortcut: $shortcutPath"
