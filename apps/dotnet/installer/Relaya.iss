; Установщик Relaya для Windows (Inno Setup 6): ставит в профиль пользователя без прав администратора,
; ярлыки в «Пуск» (и по желанию на рабочем столе), удаление через «Параметры → Приложения».
; Собирается в CI: iscc /DAppVersion=x.y.z /DRelayaLang=ru|en /DSourceDir=<папка сборки> Relaya.iss
; RelayaLang (ADR-002): один язык установщика и суффикс в имени файла; без него — оба языка, как раньше.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\Relaya.Windows\bin\x64\Release\net10.0-windows10.0.19041.0\win-x64"
#endif

[Setup]
AppId={{6C2B7E4A-8D3F-4A61-9F2E-5B7D1C0A9E31}
AppName=Relaya
AppVersion={#AppVersion}
AppVerName=Relaya {#AppVersion}
AppPublisher=Relaya
AppPublisherURL=https://github.com/hvckfy/Relaya
AppSupportURL=https://github.com/hvckfy/Relaya/issues
DefaultDirName={localappdata}\Programs\Relaya
DefaultGroupName=Relaya
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir=..\..\..\build
#ifdef RelayaLang
OutputBaseFilename=Relaya-{#AppVersion}-windows-x64-{#RelayaLang}-setup
#else
OutputBaseFilename=Relaya-{#AppVersion}-windows-x64-setup
#endif
SetupIconFile=..\Relaya.Windows\Assets\Relaya.ico
UninstallDisplayIcon={app}\Relaya.exe
UninstallDisplayName=Relaya
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
LicenseFile=..\..\..\LICENSE

[Languages]
#ifdef RelayaLang
  #if RelayaLang == "ru"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
  #else
Name: "en"; MessagesFile: "compiler:Default.isl"
  #endif
#else
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
#endif

; Тексты страницы «Дополнительные компоненты». Одноязычная сборка — без префикса, двуязычная — с префиксом языка.
#ifdef RelayaLang
  #if RelayaLang == "ru"
    #define RU ""
    #define EN "__skip_en."
  #else
    #define RU "__skip_ru."
    #define EN ""
  #endif
#else
  #define RU "ru."
  #define EN "en."
#endif

[CustomMessages]
#if RU != "__skip_ru."
{#RU}DepsTitle=Дополнительные компоненты
{#RU}DepsDescription=Relaya использует программы Windows. Отметьте, что установить вместе с ней.
{#RU}DepsSsh=OpenSSH Client
{#RU}DepsSshWhy=Нужен для терминала, SFTP, туннелей и ключей.
{#RU}DepsGit=Git for Windows
{#RU}DepsGitWhy=Нужен только для синхронизации через git; синхронизация через папку работает без него.
{#RU}DepsInstalled=уже установлен
{#RU}DepsInstalling=Установка компонента: %1…
{#RU}DepsFailedTitle=Не удалось установить:
{#RU}DepsSshManual=OpenSSH Client — «Параметры → Приложения → Дополнительные компоненты → Добавить компонент → Клиент OpenSSH».
{#RU}DepsGitManual=Git for Windows — скачайте с https://git-scm.com/download/win.
#endif
#if EN != "__skip_en."
{#EN}DepsTitle=Additional components
{#EN}DepsDescription=Relaya uses programs that come with Windows. Choose what to install along with it.
{#EN}DepsSsh=OpenSSH Client
{#EN}DepsSshWhy=Needed for the terminal, SFTP, tunnels and keys.
{#EN}DepsGit=Git for Windows
{#EN}DepsGitWhy=Needed only for sync through git; sync through a folder works without it.
{#EN}DepsInstalled=already installed
{#EN}DepsInstalling=Installing component: %1…
{#EN}DepsFailedTitle=Could not install:
{#EN}DepsSshManual=OpenSSH Client — Settings → Apps → Optional features → Add a feature → OpenSSH Client.
{#EN}DepsGitManual=Git for Windows — download it from https://git-scm.com/download/win.
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Relaya"; Filename: "{app}\Relaya.exe"
Name: "{autodesktop}\Relaya"; Filename: "{app}\Relaya.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Relaya.exe"; Description: "{cm:LaunchProgram,Relaya}"; Flags: nowait postinstall skipifsilent

; Данные пользователя (%APPDATA%\Relaya, ~/.ssh, пароли в диспетчере учётных данных) при удалении не трогаем —
; так же, как на Mac: удаление приложения не стирает ключи и хосты.

[Code]
// «Дополнительные компоненты»: OpenSSH Client и Git for Windows. Уже установленное — неактивно; сбой установки
// компонента не роняет установку Relaya, в конце показываем, что не поставилось и как поставить вручную.
var
  DepsPage: TWizardPage;
  SshBox, GitBox: TNewCheckBox;
  Failed: String;

function SshInstalled: Boolean;
begin
  Result := FileExists(ExpandConstant('{sys}\OpenSSH\ssh.exe'));
end;

function GitInstalled: Boolean;
begin
  Result := FileSearch('git.exe', GetEnv('PATH')) <> '';
end;

procedure AddDep(var Box: TNewCheckBox; var Top: Integer; Caption, Why: String; Installed, Default: Boolean);
var
  Note: TNewStaticText;
begin
  Box := TNewCheckBox.Create(DepsPage);
  Box.Parent := DepsPage.Surface;
  Box.Top := Top;
  Box.Width := DepsPage.SurfaceWidth;
  if Installed then begin
    Box.Caption := Caption + ' (' + CustomMessage('DepsInstalled') + ')';
    Box.Checked := False;
    Box.Enabled := False;
  end else begin
    Box.Caption := Caption;
    Box.Checked := Default;
  end;
  Note := TNewStaticText.Create(DepsPage);
  Note.Parent := DepsPage.Surface;
  Note.Top := Box.Top + Box.Height + ScaleY(2);
  Note.Left := ScaleX(18);
  Note.Width := DepsPage.SurfaceWidth - ScaleX(18);
  Note.AutoSize := True;
  Note.WordWrap := True;
  Note.Caption := Why;
  Top := Note.Top + Note.Height + ScaleY(16);
end;

procedure InitializeWizard;
var
  Top: Integer;
begin
  DepsPage := CreateCustomPage(wpSelectTasks, CustomMessage('DepsTitle'), CustomMessage('DepsDescription'));
  Top := 0;
  AddDep(SshBox, Top, CustomMessage('DepsSsh'), CustomMessage('DepsSshWhy'), SshInstalled, True);
  AddDep(GitBox, Top, CustomMessage('DepsGit'), CustomMessage('DepsGitWhy'), GitInstalled, False);
end;

procedure Status(Name: String);
begin
  WizardForm.StatusLabel.Caption := FmtMessage(CustomMessage('DepsInstalling'), [Name]);
end;

procedure InstallDeps;
var
  Code: Integer;
begin
  Failed := '';
  if SshBox.Enabled and SshBox.Checked then begin
    Status(CustomMessage('DepsSsh'));
    // Add-WindowsCapability требует прав администратора: повышаем только этот шаг (UAC), сама Relaya — без прав.
    ShellExec('runas', 'powershell.exe',
      '-NoProfile -ExecutionPolicy Bypass -Command "Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"',
      '', SW_HIDE, ewWaitUntilTerminated, Code);
    if not SshInstalled then Failed := Failed + #13#10 + CustomMessage('DepsSshManual');
  end;
  if GitBox.Enabled and GitBox.Checked then begin
    Status(CustomMessage('DepsGit'));
    if (FileSearch('winget.exe', GetEnv('PATH')) = '') or
       not Exec('winget.exe', 'install --id Git.Git -e --source winget --silent --accept-source-agreements --accept-package-agreements',
         '', SW_HIDE, ewWaitUntilTerminated, Code) or (Code <> 0) then
      Failed := Failed + #13#10 + CustomMessage('DepsGitManual');
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then InstallDeps;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and (Failed <> '') then
    WizardForm.FinishedLabel.Caption := WizardForm.FinishedLabel.Caption + #13#10#13#10 + CustomMessage('DepsFailedTitle') + Failed;
end;

