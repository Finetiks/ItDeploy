{ ITDeployAgent - маленький агент, який копіюється на цільовий ПК і запускає там інсталятор.

  Режими запуску:
    ITDeployAgent.exe service <ім'я_служби>   - працює як служба Windows (SCM, від SYSTEM)
    ITDeployAgent.exe run                     - виконує завдання напряму (WMI / відладка)

  Агент читає job.ini зі своєї папки, запускає інсталятор невидимо, пише:
    status.txt  - стан (Starting / Running / Done / Failed), код виходу
    agent.log   - журнал агента
    output.log  - stdout/stderr інсталятора
    msi.log     - докладний журнал MSI (для .msi/.msp)
  Паролі в job.ini та журнали не записуються. }

program ITDeployAgent;

{$APPTYPE CONSOLE}
{$WEAKLINKRTTI ON}
{$RTTI EXPLICIT METHODS([]) PROPERTIES([]) FIELDS([])}

uses
  Winapi.Windows,
  Winapi.WinSvc,
  Winapi.ActiveX,
  Winapi.ShlObj,
  System.SysUtils,
  System.Classes,
  System.Win.ComObj;

const
  SVC_NAME = 'ITDeployAgent';
  ERR_TIMEOUT = 1460;     // ERROR_TIMEOUT
  ERR_CANCELLED = 1223;   // ERROR_CANCELLED
  DELETE_RIGHT = $00010000;

var
  GDir: string;
  GSvcName: string;
  GStatusHandle: SERVICE_STATUS_HANDLE;
  GSvcStatus: TServiceStatus;
  GStopEvent: THandle;
  GLog: TFileStream;
  GCheckPoint: DWORD;

function NowStr: string;
begin
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);
end;

procedure Log(const S: string);
var
  B: TBytes;
begin
  if GLog = nil then Exit;
  try
    B := TEncoding.UTF8.GetBytes(NowStr + ' ' + S + #13#10);
    GLog.WriteBuffer(B[0], Length(B));
    FlushFileBuffers(GLog.Handle);
  except
  end;
end;

procedure WriteStatus(const State: string; ExitCode: Integer; const Msg: string);
var
  L: TStringList;
  Tmp, Fin: string;
  I: Integer;
begin
  L := TStringList.Create;
  try
    L.Add('State=' + State);
    L.Add('ExitCode=' + IntToStr(ExitCode));
    L.Add('Message=' + StringReplace(StringReplace(Msg, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]));
    L.Add('Time=' + NowStr);
    L.Add('Pid=' + IntToStr(GetCurrentProcessId));
    Tmp := GDir + 'status.tmp';
    Fin := GDir + 'status.txt';
    try
      L.SaveToFile(Tmp, TEncoding.UTF8);
      // Контролер може читати файл у цей момент - кілька спроб.
      for I := 1 to 5 do
        if MoveFileEx(PChar(Tmp), PChar(Fin), MOVEFILE_REPLACE_EXISTING or 8) then Break
        else Sleep(100);
    except
    end;
  finally
    L.Free;
  end;
end;

procedure DisableFsRedirection;
type
  TWow64Disable = function(var OldValue: Pointer): BOOL; stdcall;
var
  K: HMODULE;
  F: TWow64Disable;
  Old: Pointer;
begin
  // 32-бітний агент на 64-бітній Windows: щоб дочірні процеси бачили справжній System32.
  K := GetModuleHandle('kernel32.dll');
  if K = 0 then Exit;
  F := TWow64Disable(GetProcAddress(K, 'Wow64DisableWow64FsRedirection'));
  if Assigned(F) then F(Old);
end;

function WinDir: string;
var
  Buf: array[0..MAX_PATH] of Char;
begin
  GetWindowsDirectory(Buf, MAX_PATH);
  Result := IncludeTrailingPathDelimiter(Buf);
end;

function BuildCommandLine(const Kind, Payload, Args: string): string;
var
  Sys: string;
begin
  Sys := WinDir + 'System32\';
  if Kind = 'msi' then
    Result := '"' + Sys + 'msiexec.exe" /i "' + Payload + '" ' + Args + ' /L*v "' + GDir + 'msi.log"'
  else if Kind = 'msp' then
    Result := '"' + Sys + 'msiexec.exe" /p "' + Payload + '" ' + Args + ' /L*v "' + GDir + 'msi.log"'
  else if Kind = 'cmd' then
    Result := '"' + Sys + 'cmd.exe" /d /c ""' + Payload + '" ' + Args + '"'
  else if Kind = 'ps1' then
    Result := '"' + Sys + 'WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
      Payload + '" ' + Args
  else
    Result := '"' + Payload + '" ' + Args;
end;

function RunProcess(const CmdLine: string; TimeoutSec: Cardinal; out ExitCodeOut: Integer; out Err: string): Boolean;
var
  SA: TSecurityAttributes;
  hOut, hIn, hJob: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: string;
  Handles: array[0..1] of THandle;
  W: DWORD;
  Deadline: UInt64;
  Code: DWORD;
begin
  Result := False;
  ExitCodeOut := 1;
  Err := '';
  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  hOut := CreateFile(PChar(GDir + 'output.log'), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, @SA,
    CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  hIn := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, @SA, OPEN_EXISTING, 0, 0);
  try
    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    SI.dwFlags := STARTF_USESHOWWINDOW;
    SI.wShowWindow := SW_HIDE;
    if (hOut <> INVALID_HANDLE_VALUE) and (hIn <> INVALID_HANDLE_VALUE) then
    begin
      SI.dwFlags := SI.dwFlags or STARTF_USESTDHANDLES;
      SI.hStdInput := hIn;
      SI.hStdOutput := hOut;
      SI.hStdError := hOut;
    end;
    Cmd := CmdLine;
    UniqueString(Cmd);
    FillChar(PI, SizeOf(PI), 0);
    if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW or CREATE_UNICODE_ENVIRONMENT,
      nil, PChar(ExcludeTrailingPathDelimiter(GDir)), SI, PI) then
    begin
      Err := 'CreateProcess: ' + SysErrorMessage(GetLastError) + ' (' + IntToStr(GetLastError) + ')';
      Exit;
    end;
    try
      hJob := CreateJobObject(nil, nil);
      if hJob <> 0 then AssignProcessToJobObject(hJob, PI.hProcess);
      Log('Процес запущено, PID ' + IntToStr(PI.dwProcessId));
      Handles[0] := PI.hProcess;
      Handles[1] := GStopEvent;
      Deadline := GetTickCount64 + UInt64(TimeoutSec) * 1000;
      repeat
        W := WaitForMultipleObjects(2, @Handles, False, 5000);
        if W = WAIT_OBJECT_0 then
        begin
          GetExitCodeProcess(PI.hProcess, Code);
          ExitCodeOut := Integer(Code);
          Result := True;
          Break;
        end
        else if W = WAIT_OBJECT_0 + 1 then
        begin
          if hJob <> 0 then TerminateJobObject(hJob, ERR_CANCELLED) else TerminateProcess(PI.hProcess, ERR_CANCELLED);
          ExitCodeOut := ERR_CANCELLED;
          Err := 'Скасовано контролером';
          Break;
        end
        else if W = WAIT_TIMEOUT then
        begin
          WriteStatus('Running', 0, 'Установка триває');
          if GetTickCount64 > Deadline then
          begin
            if hJob <> 0 then TerminateJobObject(hJob, ERR_TIMEOUT) else TerminateProcess(PI.hProcess, ERR_TIMEOUT);
            ExitCodeOut := ERR_TIMEOUT;
            Err := 'Перевищено час очікування (' + IntToStr(TimeoutSec) + ' c), процес зупинено';
            Break;
          end;
        end
        else
        begin
          Err := 'WaitForMultipleObjects: ' + SysErrorMessage(GetLastError);
          Break;
        end;
      until False;
      if hJob <> 0 then CloseHandle(hJob);
    finally
      CloseHandle(PI.hThread);
      CloseHandle(PI.hProcess);
    end;
  finally
    if hOut <> INVALID_HANDLE_VALUE then CloseHandle(hOut);
    if hIn <> INVALID_HANDLE_VALUE then CloseHandle(hIn);
  end;
end;

function CommonFolder(Csidl: Integer): string;
var
  Buf: array[0..MAX_PATH] of Char;
begin
  Result := '';
  if SHGetFolderPath(0, Csidl, 0, 0, Buf) = S_OK then Result := IncludeTrailingPathDelimiter(Buf);
end;

procedure CreateLnk(const LnkPath, Target, Desc: string);
var
  SL: IShellLink;
  PF: IPersistFile;
begin
  SL := CreateComObject(CLSID_ShellLink) as IShellLink;
  OleCheck(SL.SetPath(PChar(Target)));
  SL.SetWorkingDirectory(PChar(ExtractFilePath(Target)));
  SL.SetDescription(PChar(Desc));
  SL.SetIconLocation(PChar(Target), 0);
  PF := SL as IPersistFile;
  OleCheck(PF.Save(PChar(LnkPath), True));
end;

// Ярлики на ЗАГАЛЬНОМУ робочому столі та в загальному меню "Пуск" (видимі всім профілям).
function MakeShortcuts(const Target, Name, TestFolder: string): string;
var
  Desk, Prog, Nm: string;
begin
  Result := '';
  if not FileExists(Target) then
  begin
    Result := 'УВАГА: ярлики не створено - не знайдено ' + Target;
    Log(Result);
    Exit;
  end;
  Nm := Name;
  if Nm = '' then Nm := ChangeFileExt(ExtractFileName(Target), '');
  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    try
      if TestFolder <> '' then
      begin
        ForceDirectories(TestFolder);
        CreateLnk(IncludeTrailingPathDelimiter(TestFolder) + Nm + '.lnk', Target, Nm);
        Log('Ярлик (тест): ' + IncludeTrailingPathDelimiter(TestFolder) + Nm + '.lnk');
      end
      else
      begin
        Desk := CommonFolder(CSIDL_COMMON_DESKTOPDIRECTORY);
        Prog := CommonFolder(CSIDL_COMMON_PROGRAMS);
        if Desk <> '' then
        begin
          CreateLnk(Desk + Nm + '.lnk', Target, Nm);
          Log('Ярлик: ' + Desk + Nm + '.lnk');
        end;
        if Prog <> '' then
        begin
          CreateLnk(Prog + Nm + '.lnk', Target, Nm);
          Log('Ярлик: ' + Prog + Nm + '.lnk');
        end;
      end;
      Result := 'ярлики для всіх користувачів створено';
    except
      on E: Exception do
      begin
        Result := 'УВАГА: ярлики не створено: ' + E.Message;
        Log(Result);
      end;
    end;
  finally
    CoUninitialize;
  end;
end;

function CodeInList(Code: Integer; const List: string): Boolean;
var
  P: TArray<string>;
  S: string;
  V: Integer;
begin
  Result := False;
  P := List.Split([',', ';', ' ']);
  for S in P do
    if TryStrToInt(Trim(S), V) and (V = Code) then Exit(True);
end;

function RunJob: Integer;
var
  Job: TStringList;
  Kind, FileName, Args, Payload, Cmd, Err, Note, Un, Codes: string;
  Timeout: Integer;
  Code, UnCode: Integer;
begin
  Result := 1;
  try
    GLog := TFileStream.Create(GDir + 'agent.log', fmCreate or fmShareDenyNone);
  except
    GLog := nil;
  end;
  try
    DisableFsRedirection;
    Log('ITDeployAgent запущено (' + {$IFDEF WIN64}'x64'{$ELSE}'x86'{$ENDIF} + '), папка: ' + GDir);
    WriteStatus('Starting', 0, '');
    Job := TStringList.Create;
    try
      try
        Job.LoadFromFile(GDir + 'job.ini', TEncoding.UTF8);
        Kind := LowerCase(Trim(Job.Values['Kind']));
        FileName := Trim(Job.Values['File']);
        Args := Job.Values['Args'];
        Timeout := StrToIntDef(Trim(Job.Values['TimeoutSec']), 3600);
        if (FileName = '') or (Pos('\', FileName) > 0) or (Pos('/', FileName) > 0) or (Pos('..', FileName) > 0) then
          raise Exception.Create('job.ini: некоректне поле File');
        Payload := GDir + FileName;
        if not FileExists(Payload) then
          raise Exception.Create('Файл інсталятора не знайдено: ' + Payload);
        Cmd := BuildCommandLine(Kind, Payload, Args);
        Codes := Trim(Job.Values['SuccessCodes']);
        if Codes = '' then Codes := '0,3010';
        // Попереднє видалення цього ж MSI (наприклад, минулої установки в профіль SYSTEM)
        if (Kind = 'msi') and (Trim(Job.Values['PreUninstall']) = '1') then
        begin
          WriteStatus('Running', 0, 'Видалення попередньої установки');
          Un := '"' + WinDir + 'System32\msiexec.exe" /x "' + Payload +
            '" /qn /norestart REBOOT=ReallySuppress /L*v "' + GDir + 'uninstall.log"';
          Log('Попереднє видалення: ' + Un);
          if RunProcess(Un, 900, UnCode, Err) then
            Log('Код видалення: ' + IntToStr(UnCode) + ' (1605 = не було встановлено, це нормально)')
          else
            Log('Видалення не завершилось: ' + Err);
        end;
        Log('Команда: ' + Cmd);
        WriteStatus('Running', 0, 'Установку розпочато');
        if RunProcess(Cmd, Timeout, Code, Err) then
        begin
          Log('Код виходу: ' + IntToStr(Code));
          Note := '';
          if CodeInList(Code, Codes) and (Trim(Job.Values['ShortcutTarget']) <> '') then
            Note := MakeShortcuts(Trim(Job.Values['ShortcutTarget']), Trim(Job.Values['ShortcutName']),
              Trim(Job.Values['ShortcutFolder']));
          WriteStatus('Done', Code, Note);
          Result := Code;
        end
        else
        begin
          Log('Помилка: ' + Err);
          if Code = 1 then Code := 1;
          WriteStatus('Failed', Code, Err);
          Result := Code;
        end;
      except
        on E: Exception do
        begin
          Log('ВИНЯТОК: ' + E.Message);
          WriteStatus('Failed', 1, E.Message);
          Result := 1;
        end;
      end;
    finally
      Job.Free;
    end;
  finally
    FreeAndNil(GLog);
  end;
end;

procedure ReportState(State, Win32Exit, WaitHint: DWORD);
begin
  GSvcStatus.dwServiceType := SERVICE_WIN32_OWN_PROCESS;
  GSvcStatus.dwCurrentState := State;
  if State = SERVICE_START_PENDING then
    GSvcStatus.dwControlsAccepted := 0
  else
    GSvcStatus.dwControlsAccepted := SERVICE_ACCEPT_STOP or SERVICE_ACCEPT_SHUTDOWN;
  GSvcStatus.dwWin32ExitCode := Win32Exit;
  GSvcStatus.dwServiceSpecificExitCode := 0;
  GSvcStatus.dwWaitHint := WaitHint;
  if (State = SERVICE_RUNNING) or (State = SERVICE_STOPPED) then
    GSvcStatus.dwCheckPoint := 0
  else
  begin
    Inc(GCheckPoint);
    GSvcStatus.dwCheckPoint := GCheckPoint;
  end;
  SetServiceStatus(GStatusHandle, GSvcStatus);
end;

procedure DeleteSelfService;
var
  Scm, Svc: SC_HANDLE;
begin
  if GSvcName = '' then Exit;
  Scm := OpenSCManager(nil, nil, SC_MANAGER_CONNECT);
  if Scm = 0 then Exit;
  try
    Svc := OpenService(Scm, PChar(GSvcName), DELETE_RIGHT);
    if Svc <> 0 then
    try
      DeleteService(Svc);
    finally
      CloseServiceHandle(Svc);
    end;
  finally
    CloseServiceHandle(Scm);
  end;
end;

procedure ServiceCtrlHandler(Ctrl: DWORD); stdcall;
begin
  case Ctrl of
    SERVICE_CONTROL_STOP, SERVICE_CONTROL_SHUTDOWN:
      begin
        ReportState(SERVICE_STOP_PENDING, NO_ERROR, 15000);
        SetEvent(GStopEvent);
      end;
  else
    SetServiceStatus(GStatusHandle, GSvcStatus);
  end;
end;

procedure ServiceMain(Argc: DWORD; Argv: PLPWSTR); stdcall;
begin
  GStatusHandle := RegisterServiceCtrlHandler(SVC_NAME, ServiceCtrlHandler);
  if GStatusHandle = 0 then Exit;
  ReportState(SERVICE_START_PENDING, NO_ERROR, 10000);
  ReportState(SERVICE_RUNNING, NO_ERROR, 0);
  RunJob;
  DeleteSelfService;
  // Справжній результат - у status.txt; SCM завжди отримує NO_ERROR.
  ReportState(SERVICE_STOPPED, NO_ERROR, 0);
end;

var
  Mode: string;
  Table: array[0..1] of TServiceTableEntry;
begin
  GDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  GStopEvent := CreateEvent(nil, True, False, nil);
  Mode := LowerCase(ParamStr(1));
  if Mode = 'service' then
  begin
    GSvcName := ParamStr(2);
    Table[0].lpServiceName := SVC_NAME;
    Table[0].lpServiceProc := ServiceMain;
    Table[1].lpServiceName := nil;
    Table[1].lpServiceProc := nil;
    if not StartServiceCtrlDispatcher(Table[0]) then
      ExitCode := Integer(GetLastError);
  end
  else if Mode = 'run' then
    ExitCode := RunJob
  else
  begin
    Writeln('ITDeployAgent: service <name> | run');
    ExitCode := 2;
  end;
end.
