unit uCommon;

{ Спільні типи й допоміжні функції: налаштування завдання, визначення типу інсталятора,
  розбір списку цілей (імена, IP, діапазони, CIDR, шаблони). }

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Generics.Collections;

type
  TInstallerKind = (ikExe, ikMsi, ikMsp, ikCmd, ikPs1);
  TInstallerFlavor = (ifUnknown, ifNsis, ifInno, ifMsi, ifMsp, ifBurn, ifInstallShield, ifScript);
  TDeployMethod = (dmAuto, dmService, dmWmi);

  TJobConfig = record
    InstallerPath: string;
    Kind: TInstallerKind;
    Args: string;
    TimeoutMin: Integer;
    SuccessCodes: TArray<Integer>;
    DetectPath: string;
    Method: TDeployMethod;
    UseCurrentUser: Boolean;
    User: string;
    Password: string;
    LogRoot: string;
    Flavor: TInstallerFlavor;
    InstallDir: string;        // повний шлях, напр. D:\ArtCraft Launcher ('' = за замовчуванням інсталятора)
    InstallDirProp: string;    // ім'я MSI-властивості папки (INSTALLFOLDER, INSTALLDIR, ...)
    AllUsers: Boolean;         // ALLUSERS=1 (MSI), /ALLUSERS (Inno)
    PreUninstall: Boolean;     // спершу видалити цей самий MSI (виправлення минулої установки)
    ShortcutTarget: string;    // повний шлях exe для ярликів усіх користувачів ('' = не створювати)
    ShortcutName: string;
  end;

  TCancelToken = class
  private
    FCancelled: Boolean;
  public
    procedure Cancel;
    property Cancelled: Boolean read FCancelled;
  end;

const
  FlavorNames: array[TInstallerFlavor] of string = (
    'не визначено', 'NSIS', 'Inno Setup', 'MSI', 'MSP (патч)', 'WiX Burn (bootstrapper)',
    'InstallShield', 'скрипт');

function KindFromFile(const Path: string): TInstallerKind;
function KindName(K: TInstallerKind): string;
function DetectFlavor(const Path: string): TInstallerFlavor;
function DefaultArgs(Flavor: TInstallerFlavor; Kind: TInstallerKind): string;
function ComposeArgs(const Cfg: TJobConfig; out Warn: string): string;
function DriveOf(const Path: string): string;
function ParseIntList(const S: string): TArray<Integer>;
function IntListToStr(const A: TArray<Integer>): string;
function IsSuccessCode(Code: Integer; const Codes: TArray<Integer>): Boolean;
function FormatBytes(N: Int64): string;
function SysErrorText(Code: DWORD): string;
function FileProductInfo(const Path: string): string;
function ExpandTargets(const Text: string): TArray<string>;
function SafeFileName(const S: string): string;
function FileSizeOf(const Path: string): Int64;

implementation

function FileSizeOf(const Path: string): Int64;
var
  SR: TSearchRec;
begin
  Result := -1;
  if FindFirst(Path, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    FindClose(SR);
  end;
end;

procedure TCancelToken.Cancel;
begin
  FCancelled := True;
end;

function KindFromFile(const Path: string): TInstallerKind;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(Path));
  if Ext = '.msi' then Result := ikMsi
  else if Ext = '.msp' then Result := ikMsp
  else if (Ext = '.bat') or (Ext = '.cmd') then Result := ikCmd
  else if Ext = '.ps1' then Result := ikPs1
  else Result := ikExe;
end;

function KindName(K: TInstallerKind): string;
begin
  case K of
    ikMsi: Result := 'msi';
    ikMsp: Result := 'msp';
    ikCmd: Result := 'cmd';
    ikPs1: Result := 'ps1';
  else
    Result := 'exe';
  end;
end;

function BytesContain(const Buf: TBytes; Len: Integer; const Pattern: AnsiString): Boolean;
var
  I, J, PL: Integer;
  First: Byte;
begin
  Result := False;
  PL := Length(Pattern);
  if (PL = 0) or (Len < PL) then Exit;
  First := Ord(Pattern[1]);
  for I := 0 to Len - PL do
    if Buf[I] = First then
    begin
      J := 1;
      while (J < PL) and (Buf[I + J] = Ord(Pattern[J + 1])) do Inc(J);
      if J = PL then Exit(True);
    end;
end;

function DetectFlavor(const Path: string): TInstallerFlavor;
const
  HeadSize = 6 * 1024 * 1024;
var
  K: TInstallerKind;
  FS: TFileStream;
  Buf: TBytes;
  N: Integer;
begin
  K := KindFromFile(Path);
  case K of
    ikMsi: Exit(ifMsi);
    ikMsp: Exit(ifMsp);
    ikCmd, ikPs1: Exit(ifScript);
  end;
  Result := ifUnknown;
  try
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      N := HeadSize;
      if FS.Size < N then N := Integer(FS.Size);
      SetLength(Buf, N);
      if N > 0 then N := FS.Read(Buf[0], N);
    finally
      FS.Free;
    end;
  except
    Exit;
  end;
  // Порядок важливий: Inno й NSIS мають унікальні рядки; Burn має секцію .wixburn.
  if BytesContain(Buf, N, 'Inno Setup') or BytesContain(Buf, N, 'InnoSetupLdrWindow') then Exit(ifInno);
  if BytesContain(Buf, N, 'Nullsoft Install System') or BytesContain(Buf, N, 'NullsoftInst') then Exit(ifNsis);
  if BytesContain(Buf, N, '.wixburn') or BytesContain(Buf, N, 'WixBundleManifest') then Exit(ifBurn);
  if BytesContain(Buf, N, 'InstallShield') then Exit(ifInstallShield);
end;

function DefaultArgs(Flavor: TInstallerFlavor; Kind: TInstallerKind): string;
begin
  case Flavor of
    ifNsis: Result := '/S';
    ifInno: Result := '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-';
    ifMsi: Result := '/qn /norestart REBOOT=ReallySuppress MSIRESTARTMANAGERCONTROL=Disable';
    ifMsp: Result := '/qn /norestart REBOOT=ReallySuppress';
    ifBurn: Result := '/quiet /norestart';
    ifInstallShield: Result := '/s /v"/qn REBOOT=ReallySuppress"';
  else
    Result := '';
  end;
end;

function DriveOf(const Path: string): string;
begin
  // 'D:\Soft\X' -> 'D:'
  if (Length(Path) >= 2) and (Path[2] = ':') then Result := UpperCase(Copy(Path, 1, 2)) else Result := '';
end;

function ComposeArgs(const Cfg: TJobConfig; out Warn: string): string;
var
  Dir, Prop: string;
begin
  // Підсумкові параметри = базові параметри + (ALLUSERS) + (папка) залежно від типу інсталятора.
  Warn := '';
  Result := Trim(Cfg.Args);
  Dir := Trim(Cfg.InstallDir);
  if (Length(Dir) > 3) then Dir := ExcludeTrailingPathDelimiter(Dir);
  Prop := Trim(Cfg.InstallDirProp);
  if Prop = '' then Prop := 'INSTALLFOLDER';

  case Cfg.Kind of
    ikMsi:
      begin
        if Cfg.AllUsers then Result := Trim(Result + ' ALLUSERS=1');
        if Dir <> '' then Result := Trim(Result + ' ' + Prop + '="' + Dir + '"');
      end;
    ikMsp:
      if Dir <> '' then Warn := 'для патча MSP папка не застосовується';
    ikExe:
      case Cfg.Flavor of
        ifNsis:
          begin
            // NSIS: /D= має бути ОСТАННІМ параметром, без лапок (навіть із пробілами в шляху)
            if Dir <> '' then Result := Trim(Result + ' /D=' + Dir);
            if Cfg.AllUsers then Warn := 'NSIS: режим "для всіх" задається самим інсталятором (параметр /allusers залежить від сценарію)';
          end;
        ifInno:
          begin
            if Cfg.AllUsers then Result := Trim(Result + ' /ALLUSERS');
            if Dir <> '' then Result := Trim(Result + ' /DIR="' + Dir + '"');
          end;
      else
        if (Dir <> '') or Cfg.AllUsers then
          Warn := 'для цього типу інсталятора папку/режим "для всіх" не підставляю автоматично - вкажіть у параметрах вручну';
      end;
  else
    if Dir <> '' then Warn := 'для скриптів папку не підставляю';
  end;
end;

function ParseIntList(const S: string): TArray<Integer>;
var
  Parts: TArray<string>;
  L: TList<Integer>;
  P: string;
  V: Integer;
begin
  L := TList<Integer>.Create;
  try
    Parts := S.Split([',', ';', ' ']);
    for P in Parts do
      if (Trim(P) <> '') and TryStrToInt(Trim(P), V) then L.Add(V);
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function IntListToStr(const A: TArray<Integer>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do
  begin
    if I > 0 then Result := Result + ',';
    Result := Result + IntToStr(A[I]);
  end;
end;

function IsSuccessCode(Code: Integer; const Codes: TArray<Integer>): Boolean;
var
  C: Integer;
begin
  for C in Codes do
    if C = Code then Exit(True);
  Result := False;
end;

function FormatBytes(N: Int64): string;
begin
  if N >= 1024 * 1024 * 1024 then Result := FormatFloat('0.00', N / (1024 * 1024 * 1024)) + ' ГБ'
  else if N >= 1024 * 1024 then Result := FormatFloat('0.0', N / (1024 * 1024)) + ' МБ'
  else if N >= 1024 then Result := FormatFloat('0', N / 1024) + ' КБ'
  else Result := IntToStr(N) + ' Б';
end;

function SysErrorText(Code: DWORD): string;
begin
  Result := Trim(SysErrorMessage(Code)) + ' (код ' + IntToStr(Code) + ')';
end;

function FileProductInfo(const Path: string): string;
var
  Dummy, Size: DWORD;
  Data: TBytes;
  Trans: Pointer;
  TLen: UINT;
  Lang, Prod, Ver: string;

  function Query(const Name: string): string;
  var
    P: Pointer;
    L: UINT;
  begin
    Result := '';
    if VerQueryValue(@Data[0], PChar('\StringFileInfo\' + Lang + '\' + Name), P, L) and (L > 0) then
      Result := Trim(PChar(P));
  end;

begin
  Result := '';
  Size := GetFileVersionInfoSize(PChar(Path), Dummy);
  if Size = 0 then Exit;
  SetLength(Data, Size);
  if not GetFileVersionInfo(PChar(Path), 0, Size, @Data[0]) then Exit;
  if not VerQueryValue(@Data[0], '\VarFileInfo\Translation', Trans, TLen) or (TLen < 4) then Exit;
  Lang := IntToHex(PWord(Trans)^, 4) + IntToHex(PWord(PByte(Trans) + 2)^, 4);
  Prod := Query('ProductName');
  Ver := Query('ProductVersion');
  if Ver = '' then Ver := Query('FileVersion');
  Result := Trim(Prod + ' ' + Ver);
end;

function SafeFileName(const S: string): string;
var
  C: Char;
begin
  Result := '';
  for C in S do
    if CharInSet(C, ['\', '/', ':', '*', '?', '"', '<', '>', '|']) then Result := Result + '_'
    else Result := Result + C;
end;

{ ---- розбір цілей ---- }

function TryParseIPv4(const S: string; out A: Cardinal): Boolean;
var
  P: TArray<string>;
  I, V: Integer;
begin
  Result := False;
  P := S.Split(['.']);
  if Length(P) <> 4 then Exit;
  A := 0;
  for I := 0 to 3 do
  begin
    if (P[I] = '') or (Length(P[I]) > 3) or not TryStrToInt(P[I], V) or (V < 0) or (V > 255) then Exit;
    A := (A shl 8) or Cardinal(V);
  end;
  Result := True;
end;

function IPv4ToStr(A: Cardinal): string;
begin
  Result := Format('%d.%d.%d.%d', [(A shr 24) and 255, (A shr 16) and 255, (A shr 8) and 255, A and 255]);
end;

procedure ExpandPattern(const Token: string; Dest: TList<string>);
var
  P1, P2, Dash: Integer;
  Inner, FromS, ToS, Prefix, Suffix, Num: string;
  F, T, I, Width: Integer;
begin
  P1 := Pos('{', Token);
  P2 := Pos('}', Token);
  if (P1 = 0) or (P2 < P1) then
  begin
    Dest.Add(Token);
    Exit;
  end;
  Inner := Copy(Token, P1 + 1, P2 - P1 - 1);
  Prefix := Copy(Token, 1, P1 - 1);
  Suffix := Copy(Token, P2 + 1, MaxInt);
  Dash := Pos('-', Inner);
  if Dash = 0 then raise Exception.CreateFmt('Шаблон "%s": очікується {від-до}', [Token]);
  FromS := Trim(Copy(Inner, 1, Dash - 1));
  ToS := Trim(Copy(Inner, Dash + 1, MaxInt));
  if not (TryStrToInt(FromS, F) and TryStrToInt(ToS, T)) or (T < F) then
    raise Exception.CreateFmt('Шаблон "%s": некоректний діапазон', [Token]);
  if T - F > 4096 then raise Exception.Create('Занадто великий діапазон у шаблоні');
  Width := 0;
  if (Length(FromS) > 1) and (FromS[1] = '0') then Width := Length(FromS);
  for I := F to T do
  begin
    Num := IntToStr(I);
    while Length(Num) < Width do Num := '0' + Num;
    ExpandPattern(Prefix + Num + Suffix, Dest);
  end;
end;

function ExpandTargets(const Text: string): TArray<string>;
var
  Res: TList<string>;
  Seen: TDictionary<string, Boolean>;
  Tokens: TArray<string>;
  Tok, Line, Lo, Hi, Item: string;
  Slash, Dash, Bits, I: Integer;
  A, B, Mask, Net, Cnt: Cardinal;
  Tmp: TList<string>;
  Lines: TStringList;
begin
  Res := TList<string>.Create;
  Seen := TDictionary<string, Boolean>.Create;
  Tmp := TList<string>.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for Line in Lines do
    begin
      if (Trim(Line) = '') or (Trim(Line)[1] = '#') then Continue;
      Tokens := Trim(Line).Split([',', ';', ' ', #9], TStringSplitOptions.ExcludeEmpty);
      for Tok in Tokens do
      begin
        Tmp.Clear;
        Slash := Pos('/', Tok);
        Dash := Pos('-', Tok);
        if (Slash > 0) and TryParseIPv4(Copy(Tok, 1, Slash - 1), A) and TryStrToInt(Copy(Tok, Slash + 1, MaxInt), Bits) then
        begin
          if (Bits < 16) or (Bits > 32) then raise Exception.CreateFmt('"%s": підтримується маска від /16 до /32', [Tok]);
          if Bits = 32 then Mask := $FFFFFFFF else Mask := not (Cardinal($FFFFFFFF) shr Bits);
          Net := A and Mask;
          Cnt := (not Mask);
          if Cnt > 1 then
            for I := 1 to Integer(Cnt) - 1 do Tmp.Add(IPv4ToStr(Net + Cardinal(I)))
          else
            Tmp.Add(IPv4ToStr(Net));
        end
        else if (Dash > 0) and (Pos('{', Tok) = 0) and TryParseIPv4(Copy(Tok, 1, Dash - 1), A) then
        begin
          Hi := Copy(Tok, Dash + 1, MaxInt);
          if Pos('.', Hi) > 0 then
          begin
            if not TryParseIPv4(Hi, B) then raise Exception.CreateFmt('"%s": некоректний діапазон IP', [Tok]);
          end
          else
          begin
            if not TryStrToInt(Hi, I) or (I < 0) or (I > 255) then raise Exception.CreateFmt('"%s": некоректний діапазон IP', [Tok]);
            B := (A and $FFFFFF00) or Cardinal(I);
          end;
          if (B < A) or (B - A > 4096) then raise Exception.CreateFmt('"%s": діапазон порожній або понад 4096 адрес', [Tok]);
          Lo := '';
          for Cnt := A to B do Tmp.Add(IPv4ToStr(Cnt));
        end
        else
          ExpandPattern(Tok, Tmp);
        for Item in Tmp do
          if not Seen.ContainsKey(LowerCase(Item)) then
          begin
            Seen.Add(LowerCase(Item), True);
            Res.Add(Item);
          end;
        if Res.Count > 8192 then raise Exception.Create('Занадто багато адрес (понад 8192)');
      end;
    end;
    Result := Res.ToArray;
  finally
    Lines.Free;
    Tmp.Free;
    Seen.Free;
    Res.Free;
  end;
end;

end.
