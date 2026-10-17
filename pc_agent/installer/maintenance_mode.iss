// ============================================================
// maintenance_mode.iss — repair / upgrade selection for existing installs
// (Doc 28 addendum, 2026-10-17)
//
// Included from setup.iss inside the [Code] section (before the firewall
// helpers so every function is declared before use).  When a previous
// install is detected, a wizard page right after Welcome offers:
//   * Upgrade — install the new version over the existing one (default)
//   * Repair  — re-copy all files, restore shortcuts, re-add firewall rules
// Neither mode uninstalls anything and %APPDATA%\PotPilot is never touched.
// Command line: /REPAIR, -REPAIR or --REPAIR preselects repair, e.g.
//   PotPilot_Setup.exe /SILENT /REPAIR
// ============================================================

var
  MaintPage: TWizardPage;
  RadioUpgrade: TRadioButton;
  RadioRepair: TRadioButton;
  GPrevDir: String;
  GRepairRequested: Boolean;

// Registry uninstall key of the previous install — must match the AppId in
// setup.iss (see the AppGuid define there; the GUID is never changed).
function PreviousInstallDir(): String;
var
  S: String;
begin
  Result := '';
  if RegQueryStringValue(HKLM,
      'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppGuid}_is1',
      'InstallLocation', S) then
    Result := S
  else if RegQueryStringValue(HKCU,
      'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppGuid}_is1',
      'InstallLocation', S) then
    Result := S;
end;

// True when /REPAIR, -REPAIR or --REPAIR appears on the command line.
function CmdLineFlag(const Name: String): Boolean;
var
  I: Integer;
  P: String;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    P := UpperCase(ParamStr(I));
    if (P = '/' + Name) or (P = '-' + Name) or (P = '--' + Name) then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function InitializeSetup(): Boolean;
begin
  GPrevDir := PreviousInstallDir();
  GRepairRequested := CmdLineFlag('REPAIR');
  Result := True;
end;

procedure InitializeWizard();
var
  InfoLabel: TNewStaticText;
begin
  MaintPage := nil;
  RadioUpgrade := nil;
  RadioRepair := nil;
  if GPrevDir = '' then
    Exit; // fresh install — no maintenance page

  MaintPage := CreateCustomPage(wpWelcome, 'Existing Installation Found',
    'Choose an in-place upgrade or a repair. Neither option uninstalls '
    + 'PotPilot, and your configuration in %APPDATA%\PotPilot is kept.');

  InfoLabel := TNewStaticText.Create(MaintPage);
  InfoLabel.Parent := MaintPage.Surface;
  InfoLabel.WordWrap := True;
  InfoLabel.AutoSize := True;
  InfoLabel.Width := MaintPage.SurfaceWidth;
  InfoLabel.Caption := 'Current install: ' + GPrevDir + #13#10 +
    'This installer: version {#AppVersion}';

  RadioUpgrade := TRadioButton.Create(MaintPage);
  RadioUpgrade.Parent := MaintPage.Surface;
  RadioUpgrade.Top := InfoLabel.Top + InfoLabel.Height + ScaleY(16);
  RadioUpgrade.Width := MaintPage.SurfaceWidth;
  RadioUpgrade.Checked := not GRepairRequested;
  RadioUpgrade.Caption := 'Upgrade — install version {#AppVersion} over the '
    + 'existing installation (recommended). Keeps config, shortcuts and settings.';

  RadioRepair := TRadioButton.Create(MaintPage);
  RadioRepair.Parent := MaintPage.Surface;
  RadioRepair.Top := RadioUpgrade.Top + RadioUpgrade.Height + ScaleY(10);
  RadioRepair.Width := MaintPage.SurfaceWidth;
  RadioRepair.Checked := GRepairRequested;
  RadioRepair.Caption := 'Repair — re-copy all program files, restore desktop '
    + 'and Start Menu shortcuts, and re-create the Windows Firewall rules.';
end;

// True when the user (or /REPAIR) chose repair mode.
function RepairMode(): Boolean;
begin
  Result := GRepairRequested or ((RadioRepair <> nil) and RadioRepair.Checked);
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (MaintPage <> nil) and (CurPageID = MaintPage.ID) and GRepairRequested then
  begin
    RadioRepair.Checked := True;
    RadioUpgrade.Checked := False;
  end;
  if (CurPageID = wpSelectTasks) and RepairMode() then
  begin
    // Repair restores the shortcuts; indices follow the [Tasks] order:
    // 0 = desktopicon, 1 = startupmenu (startup stays user opt-in).
    WizardForm.TasksList.Checked[0] := True;
    WizardForm.TasksList.Checked[1] := True;
  end;
end;

// Runs before [Files] copies: a live agent locks PotPilotAgent.exe and would
// make an in-place upgrade/repair fail.  taskkill of a non-running image is
// a harmless no-op, so this is unconditional.
procedure KillAgent();
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM {#AppExe} /F', '', SW_HIDE,
    ewWaitUntilTerminated, ResultCode);
end;
