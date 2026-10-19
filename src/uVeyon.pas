unit uVeyon;

{ Отримання списку комп'ютерів із Veyon 4.x.
  Veyon тут використовується ЛИШЕ як джерело списку ПК (не для передавання файлів).

  Порядок спроб (кожна пише діагностику в журнал):
   1. veyon-cli networkobjects export <файл> format "%location%|%name%|%host%|%mac%"
      (формат не залежить від мови інтерфейсу, файл у UTF-8)
   2. veyon-cli config export <файл.json>  ->  BuiltinDirectory.NetworkObjects
   3. Реєстр HKLM\SOFTWARE\Veyon Solutions\*\BuiltinDirectory\NetworkObjects (@JsonValue(base64))
   4. veyon-cli networkobjects list (локалізований текст; розбір за лапками й відступом) }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Generics.Collections,
  System.JSON, System.Win.Registry, System.NetEncoding, Soap.EncdDecd, uCommon;

type
  TVeyonComputer = record
    Location: string;
    Name: string;
    Host: string;
    Mac: string;
  end;

function FindVeyonCli: string;
function ImportFromVeyon(const CliPath: string; out List: TArray<TVeyonComputer>; Log: TStrings): Boolean;
function ParseVeyonJson(const Json: string): TArray<TVeyonComputer>;
function ParseVeyonLines(const Text: string): TArray<TVeyonComputer>;
function ParseVeyonListOutput(const Text: string): TArray<TVeyonComputer>;
function LoadComputersFromFile(const Path: string): TArray<TVeyonComputer>;
function RunCapture(const CmdLine: string; TimeoutMs: Cardinal; out Output: string; out ExitCode: DWORD): Boolean;

implementation

function RunCapture(const CmdLine: string; TimeoutMs: Cardinal; out Output: string; out ExitCode: DWORD): Boolean;
var
  SA: TSecurityAttributes;
  RdPipe, WrPipe: THandle;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Cmd: string;
  Buf: array[0..4095] of Byte;
  Got, Avail: DWORD;
  Mem: TMemoryStream;
  Deadline: UInt64;
  Done: Boolean;
  Raw: TBytes;
begin
  Result := False;
  Output := '';
  ExitCode := 0;
  FillChar(SA, SizeOf(SA), 0);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  if not CreatePipe(RdPipe, WrPipe, @SA, 0) then Exit;
  try
    SetHandleInformation(RdPipe, HANDLE_FLAG_INHERIT, 0);
    FillChar(SI, SizeOf(SI), 0);
    SI.cb := SizeOf(SI);
    SI.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    SI.wShowWindow := SW_HIDE;
    SI.hStdOutput := WrPipe;
    SI.hStdError := WrPipe;
    SI.hStdInput := GetStdHandle(STD_INPUT_HANDLE);
    Cmd := CmdLine;
    UniqueString(Cmd);
    FillChar(PI, SizeOf(PI), 0);
    if not CreateProcess(nil, PChar(Cmd), nil, nil, True, CREATE_NO_WINDOW, nil, nil, SI, PI) then
    begin
      Output := SysErrorText(GetLastError);
      Exit;
    end;
    CloseHandle(WrPipe);
    WrPipe := 0;
    Mem := TMemoryStream.Create;
    try
      Deadline := GetTickCount64 + TimeoutMs;
      repeat
        Avail := 0;
        while PeekNamedPipe(RdPipe, nil, 0, nil, @Avail, nil) and (Avail > 0) do
        begin
          if ReadFile(RdPipe, Buf, SizeOf(Buf), Got, nil) and (Got > 0) then Mem.Write(Buf, Got) else Break;
        end;
        Done := WaitForSingleObject(PI.hProcess, 50) = WAIT_OBJECT_0;
      until Done or (GetTickCount64 > Deadline);
      if not Done then
      begin
        TerminateProcess(PI.hProcess, 1);
        Output := 'Таймаут виконання команди';
        Exit;
      end;
      // дочитати залишок
      while PeekNamedPipe(RdPipe, nil, 0, nil, @Avail, nil) and (Avail > 0) do
        if ReadFile(RdPipe, Buf, SizeOf(Buf), Got, nil) and (Got > 0) then Mem.Write(Buf, Got) else Break;
      GetExitCodeProcess(PI.hProcess, ExitCode);
      SetLength(Raw, Mem.Size);
      if Mem.Size > 0 then Move(Mem.Memory^, Raw[0], Mem.Size);
      Output := TEncoding.Default.GetString(Raw);
      Result := True;
    finally
      Mem.Free;
      CloseHandle(PI.hThread);
      CloseHandle(PI.hProcess);
    end;
  finally
    CloseHandle(RdPipe);
    if WrPipe <> 0 then CloseHandle(WrPipe);
  end;
end;

function FindVeyonCli: string;
var
  Cand: array[0..3] of string;
  Dir: string;
  I: Integer;
  Buf: array[0..MAX_PATH] of Char;
  FilePart: PChar;
begin
  Result := '';
  Cand[0] := GetEnvironmentVariable('ProgramW6432');
  Cand[1] := GetEnvironmentVariable('ProgramFiles');
  Cand[2] := GetEnvironmentVariable('ProgramFiles(x86)');
  Cand[3] := 'C:\Program Files';
  for I := 0 to High(Cand) do
  begin
    if Cand[I] = '' then Continue;
    Dir := IncludeTrailingPathDelimiter(Cand[I]) + 'Veyon\veyon-cli.exe';
    if FileExists(Dir) then Exit(Dir);
  end;
  if SearchPath(nil, 'veyon-cli.exe', nil, MAX_PATH, Buf, FilePart) > 0 then Result := Buf;
end;

{ ---------- розбір ---------- }

function DecodeJsonValueString(const S: string): string;
var
  P1, P2: Integer;
  B64: string;
  Bytes: TBytes;
begin
  // "@JsonValue(<base64>)"
  Result := '';
  P1 := Pos('@JsonValue(', S);
  if P1 = 0 then Exit;
  P1 := P1 + Length('@JsonValue(');
  P2 := LastDelimiter(')', S);
  if P2 <= P1 then Exit;
  B64 := Copy(S, P1, P2 - P1);
  Bytes := DecodeBase64(AnsiString(B64));
  Result := TEncoding.UTF8.GetString(Bytes);
end;

function FindKey(V: TJSONValue; const Key: string): TJSONValue;
var
  O: TJSONObject;
  Pair: TJSONPair;
  A: TJSONArray;
  I: Integer;
begin
  Result := nil;
  if V is TJSONObject then
  begin
    O := TJSONObject(V);
    for Pair in O do
    begin
      if SameText(Pair.JsonString.Value, Key) then Exit(Pair.JsonValue);
      Result := FindKey(Pair.JsonValue, Key);
      if Result <> nil then Exit;
    end;
  end
  else if V is TJSONArray then
  begin
    A := TJSONArray(V);
    for I := 0 to A.Count - 1 do
    begin
      Result := FindKey(A.Items[I], Key);
      if Result <> nil then Exit;
    end;
  end;
end;

function ObjStr(O: TJSONObject; const Key: string): string;
var
  V: TJSONValue;
begin
  V := O.GetValue(Key);
  if V = nil then Result := '' else Result := V.Value;
end;

procedure CollectObjects(Arr: TJSONArray; Dest: TList<TVeyonComputer>);
var
  Locs: TDictionary<string, string>;
  I: Integer;
  O: TJSONObject;
  T: Integer;
  C: TVeyonComputer;
  Uid, Parent: string;
begin
  Locs := TDictionary<string, string>.Create;
  try
    for I := 0 to Arr.Count - 1 do
      if Arr.Items[I] is TJSONObject then
      begin
        O := TJSONObject(Arr.Items[I]);
        if StrToIntDef(ObjStr(O, 'Type'), 0) = 2 then
          Locs.AddOrSetValue(LowerCase(ObjStr(O, 'Uid')), ObjStr(O, 'Name'));
      end;
    for I := 0 to Arr.Count - 1 do
      if Arr.Items[I] is TJSONObject then
      begin
        O := TJSONObject(Arr.Items[I]);
        T := StrToIntDef(ObjStr(O, 'Type'), 0);
        if T <> 3 then Continue; // 3 = комп'ютер
        C.Name := ObjStr(O, 'Name');
        C.Host := ObjStr(O, 'HostAddress');
        if C.Host = '' then C.Host := C.Name;
        C.Mac := ObjStr(O, 'MacAddress');
        Parent := LowerCase(ObjStr(O, 'ParentUid'));
        Uid := '';
        if not Locs.TryGetValue(Parent, Uid) then Uid := '';
        C.Location := Uid;
        if C.Host <> '' then Dest.Add(C);
      end;
  finally
    Locs.Free;
  end;
end;

function ParseVeyonJson(const Json: string): TArray<TVeyonComputer>;
var
  Root, Found, Inner: TJSONValue;
  Arr: TJSONArray;
  Res: TList<TVeyonComputer>;
  Txt: string;
  Owned: TJSONValue;
begin
  SetLength(Result, 0);
  Res := TList<TVeyonComputer>.Create;
  Owned := nil;
  Root := TJSONObject.ParseJSONValue(Json);
  try
    if Root = nil then Exit;
    Found := FindKey(Root, 'NetworkObjects');
    if Found = nil then
    begin
      // можливо, це вже сам вміст {"a":[...]} або масив
      Found := Root;
    end;
    Arr := nil;
    if Found is TJSONArray then Arr := TJSONArray(Found)
    else if Found is TJSONObject then
    begin
      Inner := TJSONObject(Found).GetValue('JsonStoreArray');
      if Inner = nil then Inner := TJSONObject(Found).GetValue('a');
      if Inner is TJSONArray then Arr := TJSONArray(Inner);
    end
    else if Found is TJSONString then
    begin
      Txt := DecodeJsonValueString(Found.Value);
      if Txt = '' then Txt := Found.Value;
      Owned := TJSONObject.ParseJSONValue(Txt);
      if Owned is TJSONObject then
      begin
        Inner := TJSONObject(Owned).GetValue('a');
        if Inner is TJSONArray then Arr := TJSONArray(Inner);
      end
      else if Owned is TJSONArray then Arr := TJSONArray(Owned);
    end;
    if Arr <> nil then CollectObjects(Arr, Res);
    Result := Res.ToArray;
  finally
    Owned.Free;
    Root.Free;
    Res.Free;
  end;
end;

function DetectDelimiter(const Line: string): Char;
begin
  if Pos('|', Line) > 0 then Result := '|'
  else if Pos(';', Line) > 0 then Result := ';'
  else if Pos(#9, Line) > 0 then Result := #9
  else if Pos(',', Line) > 0 then Result := ','
  else Result := #0;
end;

function ParseVeyonLines(const Text: string): TArray<TVeyonComputer>;
var
  Lines: TStringList;
  Res: TList<TVeyonComputer>;
  Line: string;
  D: Char;
  F: TArray<string>;
  C: TVeyonComputer;
begin
  Res := TList<TVeyonComputer>.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for Line in Lines do
    begin
      if Trim(Line) = '' then Continue;
      D := DetectDelimiter(Line);
      if D = #0 then
      begin
        C.Location := '';
        C.Name := Trim(Line);
        C.Host := C.Name;
        C.Mac := '';
        Res.Add(C);
        Continue;
      end;
      F := Line.Split([D]);
      if Length(F) >= 4 then
      begin
        C.Location := Trim(F[0]);
        C.Name := Trim(F[1]);
        C.Host := Trim(F[2]);
        C.Mac := Trim(F[3]);
      end
      else if Length(F) = 3 then
      begin
        C.Location := Trim(F[0]);
        C.Name := Trim(F[1]);
        C.Host := Trim(F[2]);
        C.Mac := '';
      end
      else
      begin
        C.Location := '';
        C.Name := Trim(F[0]);
        C.Host := Trim(F[1]);
        C.Mac := '';
      end;
      if C.Host = '' then C.Host := C.Name;
      if C.Host <> '' then Res.Add(C);
    end;
    Result := Res.ToArray;
  finally
    Lines.Free;
    Res.Free;
  end;
end;

function Quoted(const Line: string): TArray<string>;
var
  L: TList<string>;
  I, Start: Integer;
begin
  L := TList<string>.Create;
  try
    I := 1;
    while I <= Length(Line) do
    begin
      if Line[I] = '"' then
      begin
        Start := I + 1;
        Inc(I);
        while (I <= Length(Line)) and (Line[I] <> '"') do Inc(I);
        L.Add(Copy(Line, Start, I - Start));
      end;
      Inc(I);
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function ParseVeyonListOutput(const Text: string): TArray<TVeyonComputer>;
var
  Lines: TStringList;
  Res: TList<TVeyonComputer>;
  Line, CurLoc: string;
  Q: TArray<string>;
  C: TVeyonComputer;
begin
  // Вивід локалізований, тому покладаємось на структуру: рядки з відступом (TAB) - комп'ютери,
  // перший рядок у лапках без відступу - розташування; у комп'ютера лапки: ім'я, адреса, MAC.
  Res := TList<TVeyonComputer>.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    CurLoc := '';
    for Line in Lines do
    begin
      if Trim(Line) = '' then Continue;
      Q := Quoted(Line);
      if Length(Q) = 0 then Continue;
      if (Line[1] = #9) or (Line[1] = ' ') then
      begin
        C.Location := CurLoc;
        C.Name := Q[0];
        if Length(Q) > 1 then C.Host := Q[1] else C.Host := Q[0];
        if Length(Q) > 2 then C.Mac := Q[2] else C.Mac := '';
        if C.Host = '' then C.Host := C.Name;
        Res.Add(C);
      end
      else
        CurLoc := Q[0];
    end;
    Result := Res.ToArray;
  finally
    Lines.Free;
    Res.Free;
  end;
end;

function RegReadNetworkObjects(Log: TStrings): string;
var
  Reg: TRegistry;
  Orgs: TStringList;
  Org, Key, Grp: string;
  Groups: array[0..1] of string;
  I: Integer;
begin
  Result := '';
  Groups[0] := 'BuiltinDirectory';
  Groups[1] := 'LocalData';
  Reg := TRegistry.Create(KEY_READ or KEY_WOW64_64KEY);
  Orgs := TStringList.Create;
  try
    Reg.RootKey := HKEY_LOCAL_MACHINE;
    if not Reg.OpenKeyReadOnly('SOFTWARE\Veyon Solutions') then
    begin
      Log.Add('  реєстр: розділ HKLM\SOFTWARE\Veyon Solutions не знайдено');
      Exit;
    end;
    Reg.GetKeyNames(Orgs);
    Reg.CloseKey;
    for Org in Orgs do
      for I := 0 to 1 do
      begin
        Grp := Groups[I];
        Key := 'SOFTWARE\Veyon Solutions\' + Org + '\' + Grp;
        if Reg.OpenKeyReadOnly(Key) then
        try
          if Reg.ValueExists('NetworkObjects') then
          begin
            Result := Reg.ReadString('NetworkObjects');
            Log.Add('  реєстр: знайдено ' + Key + '\NetworkObjects');
            if Result <> '' then Exit;
          end;
        finally
          Reg.CloseKey;
        end;
      end;
  finally
    Orgs.Free;
    Reg.Free;
  end;
end;

function TempFile(const Ext: string): string;
var
  Buf: array[0..MAX_PATH] of Char;
begin
  GetTempPath(MAX_PATH, Buf);
  Result := IncludeTrailingPathDelimiter(Buf) + 'itdeploy_veyon_' + IntToStr(GetCurrentProcessId) + '_' +
    IntToStr(GetTickCount) + Ext;
end;

function ReadUtf8File(const Path: string): string;
var
  Bytes: TBytes;
  FS: TFileStream;
begin
  FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Bytes, FS.Size);
    if FS.Size > 0 then FS.ReadBuffer(Bytes[0], FS.Size);
  finally
    FS.Free;
  end;
  if (Length(Bytes) >= 3) and (Bytes[0] = $EF) and (Bytes[1] = $BB) and (Bytes[2] = $BF) then
    Result := TEncoding.UTF8.GetString(Bytes, 3, Length(Bytes) - 3)
  else
    Result := TEncoding.UTF8.GetString(Bytes);
end;

function ImportFromVeyon(const CliPath: string; out List: TArray<TVeyonComputer>; Log: TStrings): Boolean;
var
  Cmd, Output, Tmp, Txt: string;
  Code: DWORD;
begin
  SetLength(List, 0);
  Result := False;

  if (CliPath <> '') and FileExists(CliPath) then
  begin
    // 1) networkobjects export з форматом
    Tmp := TempFile('.txt');
    try
      Cmd := '"' + CliPath + '" networkobjects export "' + Tmp + '" format "%location%|%name%|%host%|%mac%"';
      Log.Add('Veyon: ' + Cmd);
      if RunCapture(Cmd, 30000, Output, Code) then
      begin
        if Trim(Output) <> '' then Log.Add('  вивід: ' + Trim(Output));
        Log.Add('  код виходу: ' + IntToStr(Code));
        if FileExists(Tmp) then
        begin
          Txt := ReadUtf8File(Tmp);
          List := ParseVeyonLines(Txt);
          Log.Add('  розібрано комп''ютерів: ' + IntToStr(Length(List)));
          if Length(List) > 0 then Exit(True);
        end;
      end
      else
        Log.Add('  не вдалося виконати: ' + Output);
    finally
      DeleteFile(PChar(Tmp));
    end;

    // 2) config export (JSON)
    Tmp := TempFile('.json');
    try
      Cmd := '"' + CliPath + '" config export "' + Tmp + '"';
      Log.Add('Veyon: ' + Cmd);
      if RunCapture(Cmd, 30000, Output, Code) then
      begin
        if Trim(Output) <> '' then Log.Add('  вивід: ' + Trim(Output));
        Log.Add('  код виходу: ' + IntToStr(Code));
        if FileExists(Tmp) then
        begin
          List := ParseVeyonJson(ReadUtf8File(Tmp));
          Log.Add('  розібрано комп''ютерів: ' + IntToStr(Length(List)));
          if Length(List) > 0 then Exit(True);
        end;
      end
      else
        Log.Add('  не вдалося виконати: ' + Output);
    finally
      DeleteFile(PChar(Tmp));
    end;
  end
  else
    Log.Add('veyon-cli.exe не знайдено - пропускаю CLI.');

  // 3) реєстр
  Log.Add('Veyon: читаю список із реєстру');
  Txt := RegReadNetworkObjects(Log);
  if Txt <> '' then
  begin
    List := ParseVeyonJson('{"NetworkObjects":' + '"' + StringReplace(Txt, '"', '\"', [rfReplaceAll]) + '"}');
    Log.Add('  розібрано комп''ютерів: ' + IntToStr(Length(List)));
    if Length(List) > 0 then Exit(True);
  end;

  // 4) networkobjects list
  if (CliPath <> '') and FileExists(CliPath) then
  begin
    Cmd := '"' + CliPath + '" networkobjects list';
    Log.Add('Veyon: ' + Cmd);
    if RunCapture(Cmd, 30000, Output, Code) then
    begin
      List := ParseVeyonListOutput(Output);
      Log.Add('  розібрано комп''ютерів: ' + IntToStr(Length(List)));
      if Length(List) > 0 then Exit(True);
      if Trim(Output) <> '' then Log.Add('  вивід: ' + Copy(Trim(Output), 1, 500));
    end;
  end;

  Log.Add('Veyon: список порожній. Якщо у Veyon Master використовується LDAP/AD, а не вбудований каталог, ' +
    'скористайтеся "Додати…" (імена, діапазон IP або шаблон ADMIN{1-250}.домен).');
end;

function LoadComputersFromFile(const Path: string): TArray<TVeyonComputer>;
var
  Txt, T: string;
  Targets: TArray<string>;
  Res: TList<TVeyonComputer>;
  C: TVeyonComputer;
  Delims, I: Integer;
  Line: string;
  Lines: TStringList;
  Looks: Boolean;
begin
  Txt := ReadUtf8File(Path);
  T := TrimLeft(Txt);
  if (T <> '') and CharInSet(T[1], ['{', '[']) then
    Exit(ParseVeyonJson(Txt));

  // Формат експорту Veyon: розташування|ім'я|адреса|mac
  Looks := False;
  Lines := TStringList.Create;
  try
    Lines.Text := Txt;
    for Line in Lines do
      if Trim(Line) <> '' then
      begin
        Delims := 0;
        for I := 1 to Length(Line) do
          if Line[I] = '|' then Inc(Delims);
        Looks := Delims >= 2;
        Break;
      end;
  finally
    Lines.Free;
  end;
  if Looks then Exit(ParseVeyonLines(Txt));

  Targets := ExpandTargets(Txt);
  Res := TList<TVeyonComputer>.Create;
  try
    for T in Targets do
    begin
      C.Location := '';
      C.Name := T;
      C.Host := T;
      C.Mac := '';
      Res.Add(C);
    end;
    Result := Res.ToArray;
  finally
    Res.Free;
  end;
end;

end.
