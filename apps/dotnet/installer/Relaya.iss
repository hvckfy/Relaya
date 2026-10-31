; Установщик Relaya для Windows (Inno Setup 6): ставит в профиль пользователя без прав администратора,
; ярлыки в «Пуск» (и по желанию на рабочем столе), удаление через «Параметры → Приложения».
; Собирается в CI: iscc /DAppVersion=x.y.z /DSourceDir=<папка сборки> Relaya.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\Relaya.Windows\bin\x64\Release\net8.0-windows10.0.19041.0\win-x64"
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
OutputBaseFilename=Relaya-{#AppVersion}-windows-x64-setup
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
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

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
