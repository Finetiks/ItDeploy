unit uDeploy;

{ Двигун віддаленого встановлення.

  Схема для одного ПК (нічого, окрім SMB/445, не потрібно):
   1. WNetAddConnection2 до \\ПК\IPC$ з вказаними обліковими даними (пароль лишається в пам'яті процесу)
   2. Створення захищеної папки \\ПК\ADMIN$\ITDeploy\<id> (доступ лише SYSTEM + Адміністратори)
   3. Копіювання агента (ITDeployAgent.exe із ресурсів), job.ini та інсталятора
   4. Створення й запуск служби через SCM (як PsExec), служба працює від SYSTEM
      (запасний варіант: WMI Win32_Process.Create)
   5. Очікування status.txt (Done/Failed), код виходу, копіювання журналів
   6. Видалення служби й папки на цільовому ПК

  Планувальник завдань (RPC) НЕ використовується: у вашій мережі він падає з 0x80070032. }

interface

uses
  Winapi.Windows, Winapi.WinSvc, Winapi.ActiveX, System.SysUtils, System.Classes, System.IOUtils,
  System.StrUtils, System.Variants, System.Win.ComObj, uCommon, uNet;

type
  TProgressProc = reference to procedure(const Stage: string; Percent: Integer);

  TDeployResult = record
    Ok: Boolean;
    Skipped: Boolean;
    HasExitCode: Boolean;
    ExitCode: Integer;
    Msg: string;
    Method: string;
  end;

function DeployToHost(const Host: string; const Cfg: TJobConfig; Cancel: TCancelToken;
  const Progress: TProgressProc): TDeployResult;
function CheckAccess(const Host: string; const Cfg: TJobConfig; out Msg: string): Boolean;
function ExplainExitCode(Code: Integer): string;

implementation

const
  SDDL_PRIVATE = 'D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)';
  DELETE_RIGHT = $00010000;
  ERR_SERVICE_MARKED_FOR_DELETE = 1072;

type
  EDeploy = class(Exception)
  public
    Code: DWORD;
    constructor CreateCode(ACode: DWORD; const Msg: string);
  end;

  ECancelled = class(Exception);

  TStatusInfo = record
    State: string;
    ExitCode: Integer;
    Msg: string;
    Time: string;
  end;

  TCopyCtx = class
  public
    Cancel: TCancelToken;
    Progress: TProgressProc;
    LastPct: Integer;
    CancelFlag: BOOL;
  end;

function ConvertSddl(Sddl: PWideChar; Rev: DWORD; var SD: Pointer; Size: PDWORD): BOOL; stdcall;
  external 'advapi32.dll' name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';

function CopyFileExW(Src, Dst: PWideChar; Callback: Pointer; Data: Pointer; Cancel: PBOOL; Flags: DWORD): BOOL; stdcall;
  external kernel32 name 'CopyFileExW';

constructor EDeploy.CreateCode(ACode: DWORD; const Msg: string);
begin
  inherited Create(Msg);
  Code := ACode;
end;

function ExplainExitCode(Code: Integer): string;
begin
  case Code of
    0: Result := 'успішно';
    3010: Result := 'успішно, потрібне перезавантаження';
    1641: Result := 'успішно, ініційовано перезавантаження';
    1602: Result := 'скасовано користувачем (1602)';
    1603: Result := 'критична помилка під час установки (1603) - див. журнал msi.log';
    1618: Result := 'уже виконується інша установка (1618) - повторіть пізніше';
    1619: Result := 'не вдалося відкрити пакет (1619)';
    1620: Result := 'пакет пошкоджено (1620)';
    1625: Result := 'установку заборонено політикою (1625)';
    1633: Result := 'платформа не підтримується (1633)';
    1638: Result := 'інша версія вже встановлена (1638)';
    1460: Result := 'перевищено час очікування (1460)';
    1223: Result := 'скасовано (1223)';
    5: Result := 'відмовлено в доступі (5)';
    2: Result := 'файл не знайдено (2)';
    740: Result := 'потрібні підвищені права (740)';
  else
    Result := 'код ' + IntToStr(Code);
  end;
end;

{ ---------------- допоміжні ---------------- }

procedure CheckCancel(C: TCancelToken);
begin
  if (C <> nil) and C.Cancelled then raise ECancelled.Create('Скасовано користувачем');
end;

function LocalWinDir: string;
var
  Buf: array[0..MAX_PATH] of Char;
begin
  GetWindowsDirectory(Buf, MAX_PATH);
  Result := IncludeTrailingPathDelimiter(Buf);
end;

function NewJobId: string;
begin
  Result := FormatDateTime('yymmdd_hhnnss', Now) + '_' + IntToHex(Random($10000), 4);
end;

function ReadSmallFile(const Path: string; out Text: string): Boolean;
var
  H: THandle;
  Size, Got: DWORD;
  Bytes: TBytes;
begin
  Result := False;
  Text := '';
  H := CreateFile(PChar(Path), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if H = INVALID_HANDLE_VALUE then Exit;
  try
    Size := GetFileSize(H, nil);
    if (Size = INVALID_FILE_SIZE) or (Size > 4 * 1024 * 1024) then Exit;
    SetLength(Bytes, Size);
    if Size > 0 then
    begin
      if not ReadFile(H, Bytes[0], Size, Got, nil) then Exit;
      SetLength(Bytes, Got);
    end;
  finally
    CloseHandle(H);
  end;
  if (Length(Bytes) >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and (Bytes[2] = $BF) then
    Text := TEncoding.UTF8.GetString(Bytes, 3, Length(Bytes) - 3)
  else
    Text := TEncoding.UTF8.GetString(Bytes);
  Result := True;
end;

function ReadStatus(const Path: string; out S: TStatusInfo): Boolean;
var
  Txt: string;
  L: TStringList;
begin
  Result := False;
  S.State := '';
  S.ExitCode := 0;
  S.Msg := '';
  S.Time := '';
  if not ReadSmallFile(Path, Txt) then Exit;
  L := TStringList.Create;
  try
    L.Text := Txt;
    S.State := Trim(L.Values['State']);
    S.ExitCode := StrToIntDef(Trim(L.Values['ExitCode']), 0);
    S.Msg := Trim(L.Values['Message']);
    S.Time := Trim(L.Values['Time']);
    Result := S.State <> '';
  finally
    L.Free;
  end;
end;

function CreateSecureDir(const Path: string; out ErrCode: DWORD): Boolean;
var
  SD: Pointer;
  SA: TSecurityAttributes;
begin
  ErrCode := 0;
  SD := nil;
  if not ConvertSddl(SDDL_PRIVATE, 1, SD, nil) then
  begin
    ErrCode := GetLastError;
    Exit(False);
  end;
  try
    FillChar(SA, SizeOf(SA), 0);
    SA.nLength := SizeOf(SA);
    SA.lpSecurityDescriptor := SD;
    SA.bInheritHandle := False;
    Result := CreateDirectory(PChar(Path), @SA);
    if not Result then
    begin
      ErrCode := GetLastError;
      if ErrCode = ERROR_ALREADY_EXISTS then Result := True;
    end;
  finally
    LocalFree(HLOCAL(SD));
  end;
end;

function CopyCallback(TotalSize, Transferred, StreamSize, StreamTransferred: Int64; StreamNo, Reason: DWORD;
  hSrc, hDst: THandle; Data: Pointer): DWORD; stdcall;
var
  Ctx: TCopyCtx;
  Pct: Integer;
begin
  Ctx := TCopyCtx(Data);
  if (Ctx.Cancel <> nil) and Ctx.Cancel.Cancelled then Exit(1); // PROGRESS_CANCEL
  if (TotalSize > 0) and Assigned(Ctx.Progress) then
  begin
    Pct := Integer((Transferred * 100) div TotalSize);
    if Pct <> Ctx.LastPct then
    begin
      Ctx.LastPct := Pct;
      Ctx.Progress('Копіювання інсталятора', Pct);
    end;
  end;
  Result := 0; // PROGRESS_CONTINUE
end;

procedure CopyInstaller(const Src, Dst: string; Cancel: TCancelToken; const Progress: TProgressProc);
var
  Ctx: TCopyCtx;
  Err: DWORD;
begin
  Ctx := TCopyCtx.Create;
  try
    Ctx.Cancel := Cancel;
    Ctx.Progress := Progress;
    Ctx.LastPct := -1;
    Ctx.CancelFlag := False;
    if not CopyFileExW(PChar(Src), PChar(Dst), @CopyCallback, Ctx, @Ctx.CancelFlag, 0) then
    begin
      Err := GetLastError;
      if (Err = ERROR_REQUEST_ABORTED) or ((Cancel <> nil) and Cancel.Cancelled) then
        raise ECancelled.Create('Скасовано користувачем');
      raise EDeploy.CreateCode(Err, 'Не вдалося скопіювати інсталятор: ' + SysErrorText(Err));
    end;
  finally
    Ctx.Free;
  end;
end;

procedure WriteAgentExe(const Dest: string; Is64: Boolean);
var
  RS: TResourceStream;
  FS: TFileStream;
  ResName: string;
begin
  if Is64 then ResName := 'AGENT64' else ResName := 'AGENT32';
  RS := TResourceStream.Create(HInstance, ResName, RT_RCDATA);
  try
    FS := TFileStream.Create(Dest, fmCreate);
    try
      FS.CopyFrom(RS, 0);
    finally
      FS.Free;
    end;
  finally
    RS.Free;
  end;
end;

procedure RemoveDirRetry(const Path: string; Tries: Integer);
var
  I: Integer;
begin
  for I := 1 to Tries do
  begin
    try
      if TDirectory.Exists(Path) then TDirectory.Delete(Path, True);
      Exit;
    except
      Sleep(800);
    end;
  end;
end;

{ ---------------- підключення до цілі ---------------- }

type
  TTarget = class
  private
    FConnName: string;
  public
    Host: string;
    Local: Boolean;
    Server: string;     // '\\ім'я' або '' для локального ПК
    WinShare: string;   // '\\ім'я\ADMIN$\' або 'C:\Windows\'
    Is64: Boolean;
    constructor Create(const AHost: string);
    destructor Destroy; override;
    procedure Connect(const Cfg: TJobConfig);
    function MapPath(const P: string): string;
  end;

constructor TTarget.Create(const AHost: string);
begin
  inherited Create;
  Host := Trim(AHost);
end;

destructor TTarget.Destroy;
begin
  if FConnName <> '' then WNetCancelConnection2(PChar(FConnName), 0, True);
  inherited;
end;

function ConnectErrorHint(Code: DWORD): string;
begin
  case Code of
    5, 1326, 1327, 1330, 1331, 1909, 2202, 86:
      Result := 'Перевірте логін (ДОМЕН\логін) і пароль адміністратора цільового ПК.';
    53, 67, 1203:
      Result := 'ПК вимкнено, неправильне ім''я або заблоковано SMB (TCP 445) / "Спільний доступ до файлів і принтерів".';
    1219:
      Result := 'З цим ПК уже є SMB-з''єднання під іншим обліковим записом (наприклад, відкрито \\ПК\C$ у Провіднику). ' +
        'Закрийте його (команда "net use \\ПК\IPC$ /delete") і повторіть.';
    1312, 1385:
      Result := 'Обліковому запису заборонено віддалений вхід на цьому ПК.';
  else
    Result := '';
  end;
end;

procedure TTarget.Connect(const Cfg: TJobConfig);
var
  Names: array of string;
  IP, Name, Hint: string;
  I: Integer;
  NR: TNetResource;
  Err: DWORD;
  Attr: DWORD;
begin
  Local := IsLocalTarget(Host);
  if Local then
  begin
    Server := '';
    WinShare := LocalWinDir;
    Is64 := DirectoryExists(WinShare + 'SysWOW64');
    Exit;
  end;

  if (not IsIPv4(Host)) and ResolveIPv4(Host, IP) then
  begin
    SetLength(Names, 2);
    Names[0] := Host;
    Names[1] := IP;
  end
  else
  begin
    SetLength(Names, 1);
    Names[0] := Host;
  end;

  Err := 0;
  for I := 0 to High(Names) do
  begin
    Name := Names[I];
    Server := '\\' + Name;
    Err := 0;
    if not Cfg.UseCurrentUser then
    begin
      FillChar(NR, SizeOf(NR), 0);
      NR.dwType := RESOURCETYPE_ANY;
      NR.lpRemoteName := PChar(Server + '\IPC$');
      Err := WNetAddConnection2(NR, PChar(Cfg.Password), PChar(Cfg.User), 0);
      if Err = NO_ERROR then FConnName := Server + '\IPC$';
    end;
    if Err = NO_ERROR then
    begin
      WinShare := Server + '\ADMIN$\';
      Attr := GetFileAttributes(PChar(WinShare));
      if Attr <> INVALID_FILE_ATTRIBUTES then Break;
      Err := GetLastError;
      if FConnName <> '' then
      begin
        WNetCancelConnection2(PChar(FConnName), 0, True);
        FConnName := '';
      end;
    end;
    // 1219 / 53 / 67 -> спробуємо ще й за IP-адресою (інша "назва сервера" = окрема SMB-сесія)
    if I = High(Names) then Break;
  end;
  if (Err <> NO_ERROR) then
  begin
    Hint := ConnectErrorHint(Err);
    if Hint <> '' then Hint := ' ' + Hint;
    raise EDeploy.CreateCode(Err, 'Не вдалося підключитись до ' + Server + '\ADMIN$: ' + SysErrorText(Err) + '.' + Hint);
  end;
  Is64 := DirectoryExists(WinShare + 'SysWOW64');
end;

function TTarget.MapPath(const P: string): string;
var
  S: string;
begin
  S := P;
  S := StringReplace(S, '%ProgramFiles(x86)%', 'C:\Program Files (x86)', [rfReplaceAll, rfIgnoreCase]);
  S := StringReplace(S, '%ProgramFiles%', 'C:\Program Files', [rfReplaceAll, rfIgnoreCase]);
  S := StringReplace(S, '%SystemDrive%', 'C:', [rfReplaceAll, rfIgnoreCase]);
  S := StringReplace(S, '%windir%', 'C:\Windows', [rfReplaceAll, rfIgnoreCase]);
  S := StringReplace(S, '%SystemRoot%', 'C:\Windows', [rfReplaceAll, rfIgnoreCase]);
  if Local or (Length(S) < 3) or (S[2] <> ':') then
    Result := S
  else
    Result := Server + '\' + S[1] + '$' + Copy(S, 3, MaxInt);
end;

{ ---------------- запуск ---------------- }

procedure LaunchService(T: TTarget; const SvcName, BinPath: string; out Scm, Svc: SC_HANDLE);
var
  Machine: PChar;
  Dummy: LPCWSTR;
  Err: DWORD;
begin
  Scm := 0;
  Svc := 0;
  if T.Local then Machine := nil else Machine := PChar(T.Server);
  Scm := OpenSCManager(Machine, nil, SC_MANAGER_CONNECT or SC_MANAGER_CREATE_SERVICE);
  if Scm = 0 then
  begin
    Err := GetLastError;
    raise EDeploy.CreateCode(Err, 'Не вдалося відкрити диспетчер служб (SCM): ' + SysErrorText(Err));
  end;
  Svc := CreateService(Scm, PChar(SvcName), PChar('IT Deploy ' + SvcName), SERVICE_ALL_ACCESS,
    SERVICE_WIN32_OWN_PROCESS, SERVICE_DEMAND_START, SERVICE_ERROR_IGNORE, PChar(BinPath), nil, nil, nil, nil, nil);
  if Svc = 0 then
  begin
    Err := GetLastError;
    CloseServiceHandle(Scm);
    Scm := 0;
    raise EDeploy.CreateCode(Err, 'Не вдалося створити службу: ' + SysErrorText(Err));
  end;
  Dummy := nil;
  if not StartService(Svc, 0, Dummy) then
  begin
    Err := GetLastError;
    DeleteService(Svc);
    CloseServiceHandle(Svc);
    CloseServiceHandle(Scm);
    Svc := 0;
    Scm := 0;
    raise EDeploy.CreateCode(Err, 'Не вдалося запустити службу: ' + SysErrorText(Err));
  end;
end;

procedure LaunchWmi(T: TTarget; const Cfg: TJobConfig; const RelDir: string);
var
  Loc, Svc, Share, Cls, InP, OutP: OleVariant;
  WinPath, Dir, Cmd: string;
  Rc: Integer;
begin
  CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    try
      Loc := CreateOleObject('WbemScripting.SWbemLocator');
      if Cfg.UseCurrentUser then
        Svc := Loc.ConnectServer(T.Host, 'root\cimv2')
      else
        Svc := Loc.ConnectServer(T.Host, 'root\cimv2', Cfg.User, Cfg.Password);
      Svc.Security_.ImpersonationLevel := 3;
      Share := Svc.Get('Win32_Share.Name="ADMIN$"');
      WinPath := ExcludeTrailingPathDelimiter(string(Share.Path));
      Dir := WinPath + '\' + RelDir;
      Cmd := '"' + Dir + '\agent.exe" run';
      Cls := Svc.Get('Win32_Process');
      InP := Cls.Methods_.Item('Create').InParameters.SpawnInstance_;
      InP.CommandLine := Cmd;
      InP.CurrentDirectory := Dir;
      OutP := Svc.ExecMethod('Win32_Process', 'Create', InP);
      Rc := OutP.ReturnValue;
      if Rc <> 0 then
        raise EDeploy.CreateCode(Rc, 'WMI Win32_Process.Create повернув код ' + IntToStr(Rc));
    except
      on E: EDeploy do raise;
      on E: Exception do
        raise EDeploy.CreateCode(GetLastError, 'WMI: ' + E.Message);
    end;
  finally
    Loc := Unassigned;
    Svc := Unassigned;
    Share := Unassigned;
    Cls := Unassigned;
    InP := Unassigned;
    OutP := Unassigned;
    CoUninitialize;
  end;
end;

procedure StopServiceWait(Svc: SC_HANDLE; Seconds: Integer);
var
  SS: TServiceStatus;
  I: Integer;
begin
  if Svc = 0 then Exit;
  for I := 1 to Seconds * 2 do
  begin
    if not QueryServiceStatus(Svc, SS) then Exit;
    if SS.dwCurrentState = SERVICE_STOPPED then Exit;
    Sleep(500);
  end;
end;

function FmtElapsed(StartTick: UInt64): string;
var
  Sec: UInt64;
begin
  Sec := (GetTickCount64 - StartTick) div 1000;
  Result := Format('%.2d:%.2d', [Sec div 60, Sec mod 60]);
end;

function DeployToHost(const Host: string; const Cfg: TJobConfig; Cancel: TCancelToken;
  const Progress: TProgressProc): TDeployResult;
var
  T: TTarget;
  Stage, Id, RelDir, DirUnc, SvcName, BinPath, Ext, PayloadName, LogDest, S, Detect: string;
  Drv, FinalArgs, ArgWarn: string;
  Scm, Svc: SC_HANDLE;
  Job: TStringList;
  Err: DWORD;
  St: TStatusInfo;
  HaveStatus, Launched, JobFinished, StopSent, WmiMode, DirCreated, LeaveFiles: Boolean;
  Start: UInt64;
  Deadline: UInt64;
  SS: TServiceStatus;
  LastTime: string;
  LastChange: UInt64;
  FinalFile: string;

  procedure Report(const AStage: string; Pct: Integer = -1);
  begin
    if Assigned(Progress) then Progress(AStage, Pct);
  end;

  procedure CopyLogs;
  var
    Name: string;
  begin
    try
      LogDest := IncludeTrailingPathDelimiter(Cfg.LogRoot) + SafeFileName(Host);
      ForceDirectories(LogDest);
      for Name in ['agent.log', 'output.log', 'msi.log', 'uninstall.log', 'status.txt'] do
        if FileExists(DirUnc + Name) then
          CopyFile(PChar(DirUnc + Name), PChar(LogDest + '\' + Name), False);
    except
    end;
  end;

begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Msg := '';
  T := TTarget.Create(Host);
  Scm := 0;
  Svc := 0;
  Launched := False;
  DirCreated := False;
  LeaveFiles := False;
  WmiMode := False;
  DirUnc := '';
  Stage := 'підключення';
  try
    try
      Report('Підключення…');
      T.Connect(Cfg);
      CheckCancel(Cancel);

      // --- пропуск, якщо вже встановлено ---
      if Trim(Cfg.DetectPath) <> '' then
      begin
        Stage := 'перевірка наявності';
        Detect := T.MapPath(Trim(Cfg.DetectPath));
        if FileExists(Detect) or DirectoryExists(Detect) then
        begin
          Result.Ok := True;
          Result.Skipped := True;
          Result.Msg := 'Пропущено: вже встановлено (знайдено ' + Cfg.DetectPath + ')';
          Exit;
        end;
      end;

      // --- диск для установки існує? (до копіювання великого файлу) ---
      if Trim(Cfg.InstallDir) <> '' then
      begin
        Stage := 'перевірка диска';
        Drv := DriveOf(Trim(Cfg.InstallDir));
        if (Drv <> '') and (not DirectoryExists(T.MapPath(Drv + '\'))) then
          raise EDeploy.Create('На ПК немає диска ' + Drv + ' (недоступна адмін-шара ' + Copy(Drv, 1, 1) +
            '$). Оберіть інший диск або папку на C:');
      end;

      // --- папка завдання ---
      Stage := 'створення папки на ПК';
      Id := NewJobId;
      RelDir := 'ITDeploy\' + Id;
      // батьківська папка (якщо вже існує - це не помилка), потім папка завдання
      if not CreateSecureDir(T.WinShare + 'ITDeploy', Err) then
        raise EDeploy.CreateCode(Err, 'Не вдалося створити папку ' + T.WinShare + 'ITDeploy: ' + SysErrorText(Err) +
          IfThen(T.Local and (Err = ERROR_ACCESS_DENIED), '. Для встановлення на цей ПК запустіть програму від імені адміністратора.', ''));
      if not CreateSecureDir(T.WinShare + RelDir, Err) then
        raise EDeploy.CreateCode(Err, 'Не вдалося створити папку ' + T.WinShare + RelDir + ': ' + SysErrorText(Err) +
          IfThen(T.Local and (Err = ERROR_ACCESS_DENIED), '. Для встановлення на цей ПК запустіть програму від імені адміністратора.', ''));
      DirCreated := True;
      DirUnc := T.WinShare + RelDir + '\';

      // --- копіювання ---
      Stage := 'копіювання агента';
      Report('Копіювання агента…');
      WriteAgentExe(DirUnc + 'agent.exe', T.Is64);
      CheckCancel(Cancel);

      Ext := LowerCase(ExtractFileExt(Cfg.InstallerPath));
      if Ext = '' then Ext := '.exe';
      PayloadName := 'payload' + Ext;

      Job := TStringList.Create;
      try
        FinalArgs := ComposeArgs(Cfg, ArgWarn);
        Job.Add('Kind=' + KindName(Cfg.Kind));
        Job.Add('File=' + PayloadName);
        Job.Add('Args=' + FinalArgs);
        Job.Add('TimeoutSec=' + IntToStr(Cfg.TimeoutMin * 60));
        Job.Add('Origin=' + ExtractFileName(Cfg.InstallerPath));
        Job.Add('SuccessCodes=' + IntListToStr(Cfg.SuccessCodes));
        if Cfg.PreUninstall and (Cfg.Kind = ikMsi) then Job.Add('PreUninstall=1');
        if Trim(Cfg.ShortcutTarget) <> '' then
        begin
          Job.Add('ShortcutTarget=' + Trim(Cfg.ShortcutTarget));
          Job.Add('ShortcutName=' + Trim(Cfg.ShortcutName));
        end;
        Job.SaveToFile(DirUnc + 'job.ini', TEncoding.UTF8);
      finally
        Job.Free;
      end;

      Stage := 'копіювання інсталятора';
      CopyInstaller(Cfg.InstallerPath, DirUnc + PayloadName, Cancel, Progress);
      if FileSizeOf(DirUnc + PayloadName) <> FileSizeOf(Cfg.InstallerPath) then
        raise EDeploy.Create('Розмір скопійованого файлу не збігається з оригіналом');
      CheckCancel(Cancel);

      // --- запуск ---
      Stage := 'запуск';
      SvcName := 'ITDeploy_' + StringReplace(Id, '_', '', [rfReplaceAll]);
      if T.Local then
        BinPath := '"' + DirUnc + 'agent.exe" service ' + SvcName
      else
        BinPath := '"%SystemRoot%\' + RelDir + '\agent.exe" service ' + SvcName;

      if Cfg.Method in [dmAuto, dmService] then
      begin
        try
          Report('Запуск служби…');
          LaunchService(T, SvcName, BinPath, Scm, Svc);
          Launched := True;
          Result.Method := 'служба (SMB)';
        except
          on E: EDeploy do
          begin
            // у режимі "Авто" пробуємо WMI, якщо проблема не в правах доступу
            if (Cfg.Method = dmAuto) and (not T.Local) and (E.Code <> ERROR_ACCESS_DENIED) then
            begin
              Report('Служба недоступна, пробую WMI…');
              Result.Msg := E.Message + ' -> WMI. ';
            end
            else
              raise;
          end;
        end;
      end;
      if not Launched then
      begin
        if T.Local then raise EDeploy.Create('Запуск на цьому ПК можливий лише через службу');
        Stage := 'запуск через WMI';
        WmiMode := True;
        LaunchWmi(T, Cfg, RelDir);
        Launched := True;
        Result.Method := 'WMI';
      end;

      // --- очікування результату ---
      Stage := 'виконання на ПК';
      Start := GetTickCount64;
      Deadline := Start + UInt64(Cfg.TimeoutMin) * 60000 + 180000;
      JobFinished := False;
      StopSent := False;
      LastTime := '';
      LastChange := GetTickCount64;
      HaveStatus := False;
      FinalFile := DirUnc + 'status.txt';
      repeat
        Sleep(1500);
        if (Cancel <> nil) and Cancel.Cancelled and (not StopSent) then
        begin
          StopSent := True;
          Report('Скасування…');
          if (Svc <> 0) then ControlService(Svc, SERVICE_CONTROL_STOP, SS);
          if WmiMode then
          begin
            LeaveFiles := True;
            raise ECancelled.Create('Скасовано (процес на ПК, можливо, ще працює)');
          end;
          Deadline := GetTickCount64 + 60000;
        end;
        HaveStatus := ReadStatus(FinalFile, St);
        if HaveStatus then
        begin
          if (St.State = 'Done') or (St.State = 'Failed') then
          begin
            JobFinished := True;
            Break;
          end;
          if St.Time <> LastTime then
          begin
            LastTime := St.Time;
            LastChange := GetTickCount64;
          end;
        end;
        if (Svc <> 0) and QueryServiceStatus(Svc, SS) and (SS.dwCurrentState = SERVICE_STOPPED) then
        begin
          Sleep(700);
          HaveStatus := ReadStatus(FinalFile, St);
          JobFinished := HaveStatus and ((St.State = 'Done') or (St.State = 'Failed'));
          if not JobFinished then
          begin
            HaveStatus := False;
            Break;
          end;
          Break;
        end;
        if WmiMode and HaveStatus and (St.State = 'Running') and (GetTickCount64 - LastChange > 180000) then
        begin
          LeaveFiles := True;
          raise EDeploy.Create('Агент перестав подавати ознаки життя (немає оновлень статусу 3 хв)');
        end;
        Report('Встановлення на ПК… ' + FmtElapsed(Start));
      until GetTickCount64 > Deadline;

      if not JobFinished then
      begin
        if (Svc <> 0) and QueryServiceStatus(Svc, SS) and (SS.dwCurrentState <> SERVICE_STOPPED) then
        begin
          LeaveFiles := True;
          raise EDeploy.Create('Час очікування вичерпано, служба ще працює. Файли залишено на ПК: ' + DirUnc);
        end;
        CopyLogs;
        raise EDeploy.Create('Агент завершився без результату. Журнали: ' + LogDest);
      end;

      // --- результат ---
      Stage := 'збирання результату';
      Report('Збір журналів…');
      CopyLogs;
      Result.HasExitCode := True;
      Result.ExitCode := St.ExitCode;
      if St.State = 'Done' then
        Result.Ok := IsSuccessCode(St.ExitCode, Cfg.SuccessCodes)
      else
        Result.Ok := False;
      S := ExplainExitCode(St.ExitCode);
      if Result.Ok then
      begin
        Result.Msg := 'Успішно: ' + S;
        if St.Msg <> '' then Result.Msg := Result.Msg + '; ' + St.Msg;
        if Trim(Cfg.InstallDir) <> '' then Result.Msg := Result.Msg + '; папка ' + Trim(Cfg.InstallDir);
      end
      else if St.Msg <> '' then
        Result.Msg := 'Помилка: ' + St.Msg + ' (' + S + ')'
      else
        Result.Msg := 'Помилка: ' + S;
      if Result.Method <> '' then Result.Msg := Result.Msg + ' [' + Result.Method + ']';
    except
      on E: ECancelled do
      begin
        Result.Ok := False;
        Result.Msg := E.Message;
      end;
      on E: Exception do
      begin
        Result.Ok := False;
        Result.Msg := Trim(Result.Msg + 'Етап "' + Stage + '": ' + E.Message);
      end;
    end;
  finally
    // --- прибирання ---
    try
      if Svc <> 0 then
      begin
        StopServiceWait(Svc, 20);
        DeleteService(Svc);
        CloseServiceHandle(Svc);
      end;
      if Scm <> 0 then CloseServiceHandle(Scm);
      if DirCreated and (not LeaveFiles) and (DirUnc <> '') then
      begin
        Sleep(300);
        RemoveDirRetry(ExcludeTrailingPathDelimiter(DirUnc), 6);
      end;
    except
    end;
    T.Free;
  end;
end;

function CheckAccess(const Host: string; const Cfg: TJobConfig; out Msg: string): Boolean;
var
  T: TTarget;
  Scm: SC_HANDLE;
  Machine: PChar;
begin
  Result := False;
  T := TTarget.Create(Host);
  try
    try
      T.Connect(Cfg);
      if T.Local then Machine := nil else Machine := PChar(T.Server);
      Scm := OpenSCManager(Machine, nil, SC_MANAGER_CONNECT or SC_MANAGER_CREATE_SERVICE);
      if Scm = 0 then
      begin
        Msg := 'SMB працює (ADMIN$ доступний), але керування службами недоступне: ' + SysErrorText(GetLastError);
        Exit;
      end;
      CloseServiceHandle(Scm);
      Msg := 'Доступ є: ADMIN$ і керування службами (' + IfThen(T.Is64, 'Windows x64', 'Windows x86') + ')';
      Result := True;
    except
      on E: Exception do Msg := E.Message;
    end;
  finally
    T.Free;
  end;
end;

initialization
  Randomize;

end.
