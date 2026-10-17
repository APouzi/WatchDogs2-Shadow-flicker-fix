# Windows installer

The installer packages the existing PowerShell fix in a Windows Forms setup wizard for 64-bit Windows 10 and Windows 11. Its cloud logo uses the exact requested title, "Alexandre's Watch Dogs 2 Shadow Flicker". The generated assets and their built-in image-generation prompts are in [`assets/`](../assets/LOGO-PROMPTS.txt).

## Download and use

Download the versioned ZIP from [GitHub Releases](https://github.com/APouzi/WatchDogs2-Shadow-flicker-fix/releases), extract it, and double-click the setup executable. Approve the Windows administrator prompt, select the desired action, and choose Continue. An optional Game folder field and Browse button are available for moved installations; leave it blank for Steam, Epic, or Ubisoft detection. The result page displays details and a Finish button.

The bar reports actual backend phases: discovery, dependency verification, driver inspection, original-value backup, profile changes, and read-back verification. Cancel requests a cooperative stop at a safe checkpoint before profile changes start. It is disabled during writes and verification. Closing the window during work follows the same rule. The helper is never forcibly terminated during a profile write.

Apply, Undo, and Check Status use the same script and backup directory as standalone PowerShell use. A late cancellation request cannot interrupt a profile write. The final success page requires both a successful process exit and the backend's verified-success report. Failure and cancellation are separate results.

This is a setup wizard that applies the driver-profile fix. It does not install an always-running app or service. Re-run the downloaded executable to undo the fix later. Keep `%LOCALAPPDATA%\WatchDogs2FlickerFix`, which contains the original values and profile snapshots.

## Requirements and packaging

- 64-bit Windows 10 or 11, NVIDIA graphics, .NET Framework 4.8, and the inbox Windows PowerShell 5.1.
- Internet access for the first pinned, checksum-verified community Profile Inspector download.
- Administrator approval to open the installer and save driver-profile settings.

The generated cloud artwork, icon, and PowerShell backend are embedded in the EXE. The release ZIP contains the EXE, README.txt, and SHA256SUMS.txt. Profile Inspector is downloaded from its official community project when needed and is not redistributed in the ZIP.

The executable is unsigned. Windows identifies its publisher as unknown; no signing certificate is bundled. Runtime staging uses a fresh administrator-owned directory under ProgramData with access limited to Administrators and SYSTEM. Only the known files from that run are cleaned up. Installer logs are saved under `%LOCALAPPDATA%\WatchDogs2FlickerFix\InstallerLogs`.

## Build

The build uses the installed .NET Framework C# compiler and 4.8 reference assemblies. The build computer needs the .NET Framework 4.8 Developer Pack; end users need only the runtime. No NuGet packages or additional compiler downloads are used.

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Build-Installer.ps1 -Version 1.1.0
```

The build produces `dist/Alexandres-WatchDogs2-Shadow-Flicker-Setup.exe`, a versioned ZIP, and the ZIP's SHA256 checksum file. The build automatically validates the package without launching its executable. This compiler does not support bit-for-bit deterministic builds; each published artifact has its own SHA256 digest.

## Checks

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-WatchDogs2-FlickerFix.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-InstallerProgress.ps1
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-InstallerUi.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Test-InstallerPackage.ps1 -Version 1.1.0
```

These checks cover 20 original backend cases, 32 progress/cancellation cases, 20 UI cases, and 35 package checks. The UI checks use fixture progress files and never start the backend. Package checks read EXE resources and manifest without launching it. Screens were rendered and visually reviewed in normal and compact windows. A live read-only backend Status check verified that actual profile inspection reaches Succeeded at 100%.

The existing game fix was left applied. The original workaround was user-confirmed on RTX 3080 / driver 610.88. Local validation ran on Windows 10 Home 22H2. A fresh Apply/Undo cycle through the EXE and Windows 11 execution have not been run; build, fixture, rendering, and read-only results are not that evidence.
