# TokenLens for Windows

This folder contains the Windows companion built with WPF and .NET 8. It is intentionally independent from the native Swift macOS target while sharing the same local Codex log format and product behavior.

## Build and install

Requirements: Windows 10/11, .NET 8 SDK, and ChatGPT for Windows.

```powershell
dotnet restore .\TokenLens.Windows\TokenLens.Windows.csproj
dotnet build .\TokenLens.Windows\TokenLens.Windows.csproj -c Release
.\install.ps1
```

The installer publishes to `%LOCALAPPDATA%\TokenLens` and creates a Startup shortcut. The island hides when the `ChatGPT` process is not running and reappears when ChatGPT is launched.

The first Windows port reads `%USERPROFILE%\.codex\sessions\**\*.jsonl` and keeps the same black-and-white top-center interaction. CC Switch database integration is isolated behind the Windows scanner so it can evolve without changing the macOS target.
