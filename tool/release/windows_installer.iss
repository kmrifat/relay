; Relay for Windows (M10-04): a per-user installer, no admin rights.
; Installs to %LOCALAPPDATA%\Programs\Relay with relayd in helpers\.
; Build: iscc /DAppVersion=0.1.0 /DSourceDir=<Release dir> windows_installer.iss
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\apps\relay\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6E3C0D9A-6A5B-4C58-9B47-8D0F7E4B2A11}
AppName=Relay
AppVersion={#AppVersion}
AppPublisher=binarycastle
AppPublisherURL=https://github.com/kmrifat/relay
DefaultDirName={localappdata}\Programs\Relay
DefaultGroupName=Relay
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputBaseFilename=relay-windows-x64-setup
OutputDir=.
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\relay.exe
MinVersion=10.0.17763
LicenseFile=..\..\LICENSE

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{userprograms}\Relay"; Filename: "{app}\relay.exe"
Name: "{userdesktop}\Relay"; Filename: "{app}\relay.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Run]
Filename: "{app}\relay.exe"; Description: "Open Relay"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Stop relayd so its files can be removed; the data folder (%APPDATA%\Relay) stays.
Filename: "{sys}\taskkill.exe"; Parameters: "/IM relay.exe /T /F"; Flags: runhidden; RunOnceId: "StopRelay"

[Registry]
; Start at login is the app's own switch (Settings → This computer); remove it on uninstall.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "RelayDaemon"; Flags: uninsdeletevalue dontcreatekey
