; ============================================================
; PotPilot — Inno Setup 6 installer script (Doc 28)
; Compile:  ISCC.exe pc_agent\installer\setup.iss   (cwd = repo root or any)
; Output:   pc_agent\installer\Output\PotPilot_Setup.exe
; Payload:  pc_agent\dist\PotPilotAgent\  (Doc 27 PyInstaller onedir build)
; ============================================================

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\PotPilotAgent"
#endif
#define AppExe "PotPilotAgent.exe"

[Setup]
AppId={{7C3A1E52-9D4B-4C7A-B6E0-5A1F0C2D8E91}
AppName=PotPilot
AppVersion={#AppVersion}
AppPublisher=PotPilot
DefaultDirName={autopf}\PotPilot
DefaultGroupName=PotPilot
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=PotPilot_Setup
Compression=lzma2/max
SolidCompression=yes
CloseApplications=yes
AppMutex=PotPilotAgent
UninstallDisplayIcon={app}\{#AppExe}
WizardStyle=modern
; Shared tray/GUI icon (Doc 27/28 assume it); fall back to the default
; InnoSetup icon when the asset is absent so compilation never blocks.
#if FileExists("..\assets\potpilot_icon.ico")
SetupIconFile=..\assets\potpilot_icon.ico
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startupmenu"; Description: "Create a &Start Menu shortcut"; GroupDescription: "{cm:AdditionalIcons}"
Name: "startup"; Description: "Start PotPilot automatically at Windows sign-in"; GroupDescription: "Startup:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autoprograms}\PotPilot"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Tasks: startupmenu
Name: "{autodesktop}\PotPilot"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Tasks: desktopicon

[Registry]
; Opt-in autostart task; mirrors the Doc 26 in-app tray toggle value so the
; installer task and the in-app toggle never disagree. Removed on uninstall.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "PotPilot"; ValueData: """{app}\{#AppExe}"""; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\{#AppExe}"; Description: "Launch PotPilot"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; End the agent (tray daemon) before files/rules are removed.
Filename: "{sys}\taskkill.exe"; Parameters: "/IM {#AppExe} /F"; Flags: runhidden waituntilterminated

[Code]
const
  FW_RULE_UDP = 'PotPilot Agent - UDP Input (50505)';
  FW_RULE_TCP = 'PotPilot Agent - TCP Input (50506)';

{ netsh invocations executed below (Doc 28 §5 firewall rule table):
    advfirewall firewall add rule name="PotPilot Agent - UDP Input (50505)" dir=in action=allow protocol=UDP localport=50505 remoteip=localsubnet
    advfirewall firewall add rule name="PotPilot Agent - TCP Input (50506)" dir=in action=allow protocol=TCP localport=50506 remoteip=localsubnet
    advfirewall firewall delete rule name="PotPilot Agent - UDP Input (50505)"
    advfirewall firewall delete rule name="PotPilot Agent - TCP Input (50506)"
  No outbound rules are added (Windows default-outbound remains).
  Same-name re-add replaces the rule => idempotent reinstalls. }

function AddFirewallRule(const RuleName, Proto, Port: string): Boolean;
var
  ResultCode: Integer;
  Params: string;
begin
  Result := False;
  Params := 'advfirewall firewall add rule name="' + RuleName +
    '" dir=in action=allow protocol=' + Proto + ' localport=' + Port +
    ' remoteip=localsubnet';
  if Exec(ExpandConstant('{sys}\netsh.exe'), Params, '', SW_HIDE,
     ewWaitUntilTerminated, ResultCode) then
    Result := (ResultCode = 0);
end;

function DeleteFirewallRule(const RuleName: string): Boolean;
var
  ResultCode: Integer;
begin
  Result := False;
  if Exec(ExpandConstant('{sys}\netsh.exe'),
     'advfirewall firewall delete rule name="' + RuleName + '"', '', SW_HIDE,
     ewWaitUntilTerminated, ResultCode) then
    Result := (ResultCode = 0);
  { ignore failure — uninstall continues even if the rule is already gone }
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  UdpOk, TcpOk: Boolean;
begin
  if CurStep = ssPostInstall then
  begin
    UdpOk := AddFirewallRule(FW_RULE_UDP, 'UDP', '50505');
    TcpOk := AddFirewallRule(FW_RULE_TCP, 'TCP', '50506');
    if not (UdpOk and TcpOk) then
      MsgBox('PotPilot installed, but the Windows Firewall rules could not be added.'#13#10 +
        'The agent will run, but your phone will not be able to connect until the rules exist.'#13#10#13#10 +
        'Re-run PotPilot_Setup.exe as administrator, or run these commands from an elevated prompt:'#13#10#13#10 +
        'netsh advfirewall firewall add rule name="PotPilot Agent - UDP Input (50505)" dir=in action=allow protocol=UDP localport=50505 remoteip=localsubnet'#13#10 +
        'netsh advfirewall firewall add rule name="PotPilot Agent - TCP Input (50506)" dir=in action=allow protocol=TCP localport=50506 remoteip=localsubnet',
        mbError, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
  // Doc 28 sketch says "ssUninstall"; the real TUninstallStep enum value is usUninstall.
begin
  if CurUninstallStep = usUninstall then
  begin
    DeleteFirewallRule(FW_RULE_UDP);
    DeleteFirewallRule(FW_RULE_TCP);
    { %APPDATA%\PotPilot (incl. config.json) is deliberately left intact —
      documented user-data policy, Doc 26. }
  end;
end;
