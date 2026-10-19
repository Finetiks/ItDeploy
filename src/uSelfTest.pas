unit uSelfTest;

{ Режим перевірки без вікна:  ITDeploy.exe --selftest <файл_звіту> [інсталятор] [--deploy-local]
  Перевіряє розбір цілей, розбір даних Veyon, визначення типу інсталятора, мережевий шар і вбудованих агентів.
  З ключем --deploy-local виконує справжнє розгортання тестового .cmd на ЦЬОМУ ПК (потрібні права адміністратора). }

interface

function RunSelfTest(const ReportFile, InstallerPath, Flag: string): Integer;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils, Soap.EncdDecd, uCommon, uNet, uVeyon, uDeploy;

var
  Rep: TStringList;
  Fails: Integer;

function IfThenStr(Cond: Boolean; const A: string; const B: string = ''): string;
begin
  if Cond then Result := A else Result := B;
end;

procedure Check(const Name: string; Cond: Boolean; const Extra: string = '');
begin
  if Cond then Rep.Add('OK    ' + Name + IfThenStr(Extra <> '', ' [' + Extra + ']', ''))
  else
  begin
    Inc(Fails);
    Rep.Add('FAIL  ' + Name + IfThenStr(Extra <> '', ' [' + Extra + ']', ''));
  end;
end;

function Join(const A: TArray<string>): string;
var
  S: string;
begin
  Result := '';
  for S in A do Result := Result + IfThenStr(Result <> '', ',', '') + S;
end;

procedure TestTargets;
var
  A: TArray<string>;
begin
  A := ExpandTargets('ADMIN{1-3}.ITStepZT.local');
  Check('шаблон {1-3}', (Length(A) = 3) and (A[0] = 'ADMIN1.ITStepZT.local') and (A[2] = 'ADMIN3.ITStepZT.local'), Join(A));
  A := ExpandTargets('PC-{01-03}');
  Check('шаблон з нулями', (Length(A) = 3) and (A[0] = 'PC-01') and (A[2] = 'PC-03'), Join(A));
  A := ExpandTargets('10.0.0.1-3');
  Check('діапазон 10.0.0.1-3', (Length(A) = 3) and (A[2] = '10.0.0.3'), Join(A));
  A := ExpandTargets('10.0.0.250-10.0.1.2');
  Check('діапазон через октет', (Length(A) = 9) and (A[8] = '10.0.1.2'), IntToStr(Length(A)));
  A := ExpandTargets('192.168.5.0/30');
  Check('CIDR /30', (Length(A) = 2) and (A[0] = '192.168.5.1') and (A[1] = '192.168.5.2'), Join(A));
  A := ExpandTargets('192.168.5.0/24');
  Check('CIDR /24 = 254 робочі адреси', Length(A) = 254, IntToStr(Length(A)));
  A := ExpandTargets('pc1, pc2;pc1' + #13#10 + '# коментар' + #13#10 + 'pc3');
  Check('імена, дублікати, коментарі', (Length(A) = 3) and (A[2] = 'pc3'), Join(A));
  try
    ExpandTargets('host{5-1}');
    Check('некоректний шаблон дає помилку', False);
  except
    Check('некоректний шаблон дає помилку', True);
  end;
end;

procedure TestVeyonParsing;
var
  L: TArray<TVeyonComputer>;
  Json, B64, Registry: string;
begin
  Json := '{"BuiltinDirectory":{"NetworkObjects":{"JsonStoreArray":[' +
    '{"Type":2,"Uid":"{11111111-1111-1111-1111-111111111111}","Name":"Клас 1"},' +
    '{"Type":3,"Uid":"{22222222-2222-2222-2222-222222222222}","Name":"ADMIN125","HostAddress":"ADMIN125.ITStepZT.local",' +
    '"MacAddress":"aa:bb:cc:dd:ee:ff","ParentUid":"{11111111-1111-1111-1111-111111111111}"},' +
    '{"Type":3,"Uid":"{33333333-3333-3333-3333-333333333333}","Name":"10.0.0.7"}]}}}';
  L := ParseVeyonJson(Json);
  Check('Veyon config export (JsonStoreArray)', (Length(L) = 2) and (L[0].Host = 'ADMIN125.ITStepZT.local') and
    (L[0].Location = 'Клас 1') and (L[1].Host = '10.0.0.7'), IntToStr(Length(L)));

  // формат реєстру: @JsonValue(base64 від {"a":[...]})
  B64 := string(EncodeBase64(Pointer(TEncoding.UTF8.GetBytes('{"a":[{"Type":3,"Uid":"x","Name":"REG1","HostAddress":"reg1.local"}]}')),
    Length(TEncoding.UTF8.GetBytes('{"a":[{"Type":3,"Uid":"x","Name":"REG1","HostAddress":"reg1.local"}]}'))));
  Registry := '{"NetworkObjects":"@JsonValue(' + B64 + ')"}';
  L := ParseVeyonJson(Registry);
  Check('Veyon реєстр (@JsonValue base64)', (Length(L) = 1) and (L[0].Host = 'reg1.local'), IntToStr(Length(L)));

  L := ParseVeyonLines('Клас 1|ADMIN125|ADMIN125.ITStepZT.local|aa:bb' + #10 + '|PC7||' + #10);
  Check('Veyon export format (loc|name|host|mac)', (Length(L) = 2) and (L[0].Location = 'Клас 1') and
    (L[0].Host = 'ADMIN125.ITStepZT.local') and (L[1].Host = 'PC7'), IntToStr(Length(L)));

  L := ParseVeyonListOutput('Location "Клас 1"' + #13#10 +
    #9 + 'Computer "ADMIN125" (host address: "10.0.0.5" MAC address: "aa:bb")' + #13#10 +
    #9 + 'Computer "ADMIN126" (host address: "10.0.0.6" MAC address: "")' + #13#10);
  Check('Veyon list (локалізований вивід)', (Length(L) = 2) and (L[1].Host = '10.0.0.6') and (L[0].Location = 'Клас 1'),
    IntToStr(Length(L)));
end;

procedure TestInstaller(const Path: string);
var
  F: TInstallerFlavor;
begin
  Check('KindFromFile .msi', KindFromFile('a.msi') = ikMsi);
  Check('KindFromFile .exe', KindFromFile('a.EXE') = ikExe);
  Check('IsSuccessCode', IsSuccessCode(3010, [0, 3010]) and not IsSuccessCode(1603, [0, 3010]));
  if (Path <> '') and FileExists(Path) then
  begin
    F := DetectFlavor(Path);
    Rep.Add('INFO  тип ' + Path + ' -> ' + FlavorNames[F] + '; параметри: "' + DefaultArgs(F, KindFromFile(Path)) + '"; ' +
      FileProductInfo(Path));
    Check('тип інсталятора визначено', F <> ifUnknown);
  end;
end;

procedure TestNet;
var
  R: TScanResult;
  IP: string;
begin
  Check('ResolveIPv4(localhost)', ResolveIPv4('localhost', IP) and (IP = '127.0.0.1'), IP);
  Check('IsLocalTarget(localhost)', IsLocalTarget('localhost'));
  Check('IsLocalTarget(ім''я ПК)', IsLocalTarget(LocalComputerName), LocalComputerName);
  Check('IsLocalTarget(8.8.8.8) = false', not IsLocalTarget('8.8.8.8'));
  Check('IsLocalTarget(Недіснуюче.ім''я) = false', not IsLocalTarget('no-such-host-xyz.invalid'));
  R := ScanHost('127.0.0.1');
  Check('ScanHost(127.0.0.1) онлайн', R.Resolved and R.Online, R.Summary + '; SMB=' + BoolToStr(R.Smb, True));
  R := ScanHost('no-such-host-xyz.invalid');
  Check('ScanHost(неіснуючий) = не знайдено', not R.Resolved, R.Summary);
  R := ScanHost('192.0.2.1'); // TEST-NET-1: не відповідає
  Check('ScanHost(192.0.2.1) не відповідає', R.Resolved and not R.Online, R.Summary);
end;

procedure TestCompose;
var
  Cfg: TJobConfig;
  W, S: string;
begin
  Cfg := Default(TJobConfig);
  Cfg.Kind := ikMsi;
  Cfg.Args := '/qn /norestart';
  Cfg.InstallDir := 'D:\ArtCraft Launcher';
  Cfg.InstallDirProp := 'INSTALLFOLDER';
  Cfg.AllUsers := True;
  S := ComposeArgs(Cfg, W);
  Check('MSI: ALLUSERS + INSTALLFOLDER', S = '/qn /norestart ALLUSERS=1 INSTALLFOLDER="D:\ArtCraft Launcher"', S);

  Cfg.InstallDir := 'D:\ArtCraft Launcher\';
  S := ComposeArgs(Cfg, W);
  Check('MSI: кінцевий "\" прибирається (інакше ламає лапки)', Pos('Launcher\"', S) = 0, S);

  Cfg.Kind := ikExe;
  Cfg.Flavor := ifNsis;
  Cfg.Args := '/S';
  Cfg.AllUsers := False;
  Cfg.InstallDir := 'D:\Krita (x64)';
  S := ComposeArgs(Cfg, W);
  Check('NSIS: /D= в кінці без лапок', S = '/S /D=D:\Krita (x64)', S);

  Cfg.Flavor := ifInno;
  Cfg.Args := '/VERYSILENT /NORESTART';
  Cfg.AllUsers := True;
  S := ComposeArgs(Cfg, W);
  Check('Inno: /ALLUSERS + /DIR=', S = '/VERYSILENT /NORESTART /ALLUSERS /DIR="D:\Krita (x64)"', S);

  Cfg.Flavor := ifBurn;
  S := ComposeArgs(Cfg, W);
  Check('Burn: параметри не змінюються, є попередження', (S = '/VERYSILENT /NORESTART') and (W <> ''), W);

  Cfg.Flavor := ifNsis;
  Cfg.InstallDir := '';
  Cfg.Args := '/S';
  S := ComposeArgs(Cfg, W);
  Check('без папки параметри не чіпаються', S = '/S', S);
  Check('DriveOf', (DriveOf('d:\x') = 'D:') and (DriveOf('\\srv\x') = ''));
end;

procedure TestAgentRun;
var
  RS: TResourceStream;
  FS: TFileStream;
  Dir, Out, Status, Lnk: string;
  Code: DWORD;
  L: TStringList;
begin
  // справжній прогін вбудованого агента (режим run) без прав адміністратора:
  // .cmd-завдання повертає 3010, ярлик створюється в тестову папку
  Dir := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) + 'ITDeploy_agenttest';
  if DirectoryExists(Dir) then
    try TDirectory.Delete(Dir, True); except end;
  ForceDirectories(Dir);
  RS := TResourceStream.Create(HInstance, 'AGENT64', RT_RCDATA);
  try
    FS := TFileStream.Create(Dir + '\agent.exe', fmCreate);
    try
      FS.CopyFrom(RS, 0);
    finally
      FS.Free;
    end;
  finally
    RS.Free;
  end;
  L := TStringList.Create;
  try
    L.Add('@echo off');
    L.Add('echo args=%*');
    L.Add('exit /b 3010');
    L.SaveToFile(Dir + '\payload.cmd');
    L.Clear;
    L.Add('Kind=cmd');
    L.Add('File=payload.cmd');
    L.Add('Args=/S /D=D:\Test App');
    L.Add('TimeoutSec=30');
    L.Add('SuccessCodes=0,3010');
    L.Add('ShortcutTarget=' + GetEnvironmentVariable('SystemRoot') + '\System32\notepad.exe');
    L.Add('ShortcutName=ITDeploy Test App');
    L.Add('ShortcutFolder=' + Dir + '\lnk');
    L.SaveToFile(Dir + '\job.ini', TEncoding.UTF8);
    RunCapture('"' + Dir + '\agent.exe" run', 60000, Out, Code);
    Check('агент (вбудований) повернув код завдання', Integer(Code) = 3010, IntToStr(Integer(Code)));
    L.Clear;
    L.LoadFromFile(Dir + '\status.txt');
    Status := StringReplace(Trim(L.Text), sLineBreak, ' | ', [rfReplaceAll]);
    Check('status.txt: Done і ExitCode=3010', (L.Values['State'] = 'Done') and (L.Values['ExitCode'] = '3010'), Status);
    Check('status.txt: повідомлення про ярлики', Pos('ярлики', L.Values['Message']) > 0, L.Values['Message']);
    Lnk := Dir + '\lnk\ITDeploy Test App.lnk';
    Check('ярлик .lnk створено', FileExists(Lnk) and (FileSizeOf(Lnk) > 100), Lnk);
    L.Clear;
    L.LoadFromFile(Dir + '\output.log');
    Check('агент передав параметри завдання', Pos('args=/S /D=D:\Test App', L.Text) > 0, Trim(L.Text));
  finally
    L.Free;
  end;
  try TDirectory.Delete(Dir, True); except end;
end;

procedure TestResources;
var
  RS: TResourceStream;
  Name: string;
begin
  for Name in ['AGENT32', 'AGENT64'] do
  begin
    try
      RS := TResourceStream.Create(HInstance, Name, RT_RCDATA);
      try
        Check('ресурс ' + Name, RS.Size > 100000, IntToStr(RS.Size) + ' байт');
      finally
        RS.Free;
      end;
    except
      on E: Exception do Check('ресурс ' + Name, False, E.Message);
    end;
  end;
end;

procedure TestDeployLocal;
var
  Cfg: TJobConfig;
  Dir, Cmd: string;
  Res: TDeployResult;
  L: TStringList;
begin
  Dir := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) + 'ITDeploy_selftest';
  ForceDirectories(Dir);
  Cmd := Dir + '\selftest_payload.cmd';
  L := TStringList.Create;
  try
    L.Add('@echo off');
    L.Add('echo ITDeploy selftest args=%* > "' + Dir + '\proof.txt"');
    L.Add('whoami >> "' + Dir + '\proof.txt"');
    L.Add('exit /b 3010');
    L.SaveToFile(Cmd);
  finally
    L.Free;
  end;
  FillChar(Cfg, SizeOf(Cfg), 0);
  Cfg.InstallerPath := Cmd;
  Cfg.Kind := ikCmd;
  Cfg.Args := '/S /test';
  Cfg.TimeoutMin := 2;
  Cfg.SuccessCodes := [0, 3010];
  Cfg.Method := dmService;
  Cfg.UseCurrentUser := True;
  Cfg.LogRoot := Dir + '\logs';
  Res := DeployToHost(LocalComputerName, Cfg, nil,
    procedure(const Stage: string; Pct: Integer)
    begin
      Rep.Add('  .. ' + Stage + IfThenStr(Pct >= 0, ' ' + IntToStr(Pct) + '%', ''));
    end);
  Check('DeployToHost(локально) успішно', Res.Ok and Res.HasExitCode and (Res.ExitCode = 3010), Res.Msg);
  if FileExists(Dir + '\proof.txt') then
  begin
    L := TStringList.Create;
    try
      L.LoadFromFile(Dir + '\proof.txt');
      Rep.Add('  proof.txt: ' + StringReplace(Trim(L.Text), sLineBreak, ' | ', [rfReplaceAll]));
      Check('завдання виконалось від SYSTEM', Pos('nt authority\system', LowerCase(L.Text)) > 0);
    finally
      L.Free;
    end;
  end
  else
    Check('proof.txt створено', False);
end;

function RunSelfTest(const ReportFile, InstallerPath, Flag: string): Integer;
var
  Inst, Opt: string;
begin
  // порожні параметри командного рядка Delphi відкидає, тому прапорець може бути на місці інсталятора
  Inst := InstallerPath;
  Opt := Flag;
  if SameText(Inst, '--deploy-local') then
  begin
    Opt := Inst;
    Inst := '';
  end;
  Rep := TStringList.Create;
  try
    Fails := 0;
    Rep.Add('ITDeploy selftest ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    try
      TestTargets;
      TestVeyonParsing;
      TestInstaller(Inst);
      TestNet;
      TestResources;
      TestCompose;
      TestAgentRun;
      if SameText(Opt, '--deploy-local') then TestDeployLocal;
    except
      on E: Exception do
      begin
        Inc(Fails);
        Rep.Add('FAIL  виняток: ' + E.ClassName + ': ' + E.Message);
      end;
    end;
    Rep.Add('Підсумок: помилок ' + IntToStr(Fails));
    if ReportFile <> '' then Rep.SaveToFile(ReportFile, TEncoding.UTF8);
    Result := Fails;
  finally
    Rep.Free;
  end;
end;

end.
