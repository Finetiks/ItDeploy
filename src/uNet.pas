unit uNet;

{ Мережеві утиліти: DNS, перевірка TCP-портів із таймаутом, ICMP-пінг, сканування ПК. }

interface

uses
  Winapi.Windows, Winapi.Winsock2, System.SysUtils, System.Classes;

const
  PORT_SMB = 445;
  PORT_RPC = 135;
  PORT_VEYON = 11100;

type
  TScanResult = record
    Resolved: Boolean;
    IP: string;
    HostName: string;
    Ping: Boolean;
    Smb: Boolean;
    Rpc: Boolean;
    Veyon: Boolean;
    function Online: Boolean;
    function Summary: string;
  end;

function IsIPv4(const S: string): Boolean;
function ResolveIPv4(const Host: string; out IP: string): Boolean;
function ReverseLookup(const IP: string): string;
function TcpPortOpen(const IP: string; Port: Word; TimeoutMs: Integer): Boolean;
function PingHost(const IP: string; TimeoutMs: Integer): Boolean;
function ScanHost(const Host: string): TScanResult;
function IsLocalTarget(const Host: string): Boolean;
function LocalComputerName: string;

implementation

const
  FionbioCmd: Cardinal = $8004667E; // FIONBIO (константа з RTL не вміщається в Longint)

function IcmpCreateFile: THandle; stdcall; external 'iphlpapi.dll';
function IcmpCloseHandle(H: THandle): BOOL; stdcall; external 'iphlpapi.dll';
function IcmpSendEcho(H: THandle; Dest: DWORD; ReqData: Pointer; ReqSize: Word; ReqOpts: Pointer;
  Reply: Pointer; ReplySize, Timeout: DWORD): DWORD; stdcall; external 'iphlpapi.dll';

type
  TIcmpEchoReplyHead = record
    Address: DWORD;
    Status: DWORD;
    RoundTripTime: DWORD;
  end;

function TScanResult.Online: Boolean;
begin
  Result := Resolved and (Ping or Smb or Rpc or Veyon);
end;

function TScanResult.Summary: string;
begin
  if not Resolved then Result := 'не знайдено в DNS'
  else if Smb then Result := 'доступний'
  else if Online then Result := 'онлайн, SMB закритий'
  else Result := 'не відповідає';
end;

function IsIPv4(const S: string): Boolean;
var
  P: TArray<string>;
  I, V: Integer;
begin
  Result := False;
  P := S.Split(['.']);
  if Length(P) <> 4 then Exit;
  for I := 0 to 3 do
    if (P[I] = '') or not TryStrToInt(P[I], V) or (V < 0) or (V > 255) then Exit;
  Result := True;
end;

function ResolveIPv4(const Host: string; out IP: string): Boolean;
var
  H: PHostEnt;
  A: PInAddr;
  Name: AnsiString;
begin
  IP := '';
  Result := False;
  if Host = '' then Exit;
  if IsIPv4(Host) then
  begin
    IP := Host;
    Exit(True);
  end;
  Name := AnsiString(Host);
  H := gethostbyname(MarshaledAString(PAnsiChar(Name)));
  if (H = nil) or (H.h_addrtype <> AF_INET) or (H.h_addr_list = nil) or (H.h_addr_list^ = nil) then Exit;
  A := PInAddr(H.h_addr_list^);
  IP := string(inet_ntoa(A^));
  Result := IP <> '';
end;

function ReverseLookup(const IP: string): string;
var
  Addr: u_long;
  H: PHostEnt;
  S: AnsiString;
begin
  Result := '';
  S := AnsiString(IP);
  Addr := inet_addr(MarshaledAString(PAnsiChar(S)));
  if Addr = u_long(INADDR_NONE) then Exit;
  H := gethostbyaddr(MarshaledAString(@Addr), SizeOf(Addr), AF_INET);
  if (H <> nil) and (H.h_name <> nil) then Result := string(AnsiString(H.h_name));
end;

function TcpPortOpen(const IP: string; Port: Word; TimeoutMs: Integer): Boolean;
var
  S: TSocket;
  Addr: TSockAddrIn;
  Mode: u_long;
  FW, FE: TFdSet;
  TV: TTimeVal;
  A: AnsiString;
begin
  Result := False;
  S := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if S = INVALID_SOCKET then Exit;
  try
    Mode := 1;
    ioctlsocket(S, Longint(FionbioCmd), Mode);
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    Addr.sin_port := htons(Port);
    A := AnsiString(IP);
    Addr.sin_addr.S_addr := inet_addr(MarshaledAString(PAnsiChar(A)));
    if Addr.sin_addr.S_addr = u_long(INADDR_NONE) then Exit;
    connect(S, TSockAddr(Addr), SizeOf(Addr));
    FD_ZERO(FW);
    FD_ZERO(FE);
    FW.fd_count := 1;
    FW.fd_array[0] := S;
    FE.fd_count := 1;
    FE.fd_array[0] := S;
    TV.tv_sec := TimeoutMs div 1000;
    TV.tv_usec := (TimeoutMs mod 1000) * 1000;
    if select(0, nil, @FW, @FE, @TV) > 0 then
      Result := FD_ISSET(S, FW) and not FD_ISSET(S, FE);
  finally
    closesocket(S);
  end;
end;

function PingHost(const IP: string; TimeoutMs: Integer): Boolean;
var
  H: THandle;
  A: AnsiString;
  Dest: u_long;
  Buf: array[0..255] of Byte;
  Payload: array[0..31] of Byte;
  N: DWORD;
begin
  Result := False;
  A := AnsiString(IP);
  Dest := inet_addr(MarshaledAString(PAnsiChar(A)));
  if Dest = u_long(INADDR_NONE) then Exit;
  H := IcmpCreateFile;
  if H = INVALID_HANDLE_VALUE then Exit;
  try
    FillChar(Payload, SizeOf(Payload), Ord('a'));
    N := IcmpSendEcho(H, Dest, @Payload, SizeOf(Payload), nil, @Buf, SizeOf(Buf), TimeoutMs);
    Result := (N > 0) and (TIcmpEchoReplyHead(Pointer(@Buf)^).Status = 0);
  finally
    IcmpCloseHandle(H);
  end;
end;

function ScanHost(const Host: string): TScanResult;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.IP := '';
  Result.HostName := '';
  Result.Resolved := ResolveIPv4(Host, Result.IP);
  if not Result.Resolved then Exit;
  Result.Smb := TcpPortOpen(Result.IP, PORT_SMB, 900);
  Result.Veyon := TcpPortOpen(Result.IP, PORT_VEYON, 700);
  if not (Result.Smb or Result.Veyon) then
  begin
    Result.Rpc := TcpPortOpen(Result.IP, PORT_RPC, 700);
    Result.Ping := PingHost(Result.IP, 700);
  end
  else
    Result.Ping := True; // відповів на TCP - вважаємо живим
  if IsIPv4(Host) and Result.Online then
    Result.HostName := ReverseLookup(Result.IP);
end;

function LocalComputerName: string;
var
  Buf: array[0..MAX_COMPUTERNAME_LENGTH] of Char;
  Len: DWORD;
begin
  Len := Length(Buf);
  if GetComputerName(Buf, Len) then Result := Buf else Result := '';
end;

function IsLocalTarget(const Host: string): Boolean;
var
  H, Own, IP: string;
  E: PHostEnt;
  P: PPAnsiChar;
  A: PInAddr;
  OwnA: AnsiString;
begin
  Result := False;
  H := LowerCase(Trim(Host));
  Own := LowerCase(LocalComputerName);
  if (H = '') then Exit;
  if (H = 'localhost') or (H = Own) or (H = '::1') or (Copy(H, 1, 4) = '127.') then Exit(True);
  // решта (FQDN власного ПК, IP) - порівнюємо через адреси
  if not ResolveIPv4(H, IP) then Exit;
  if Copy(IP, 1, 4) = '127.' then Exit(True);
  OwnA := AnsiString(Own);
  E := gethostbyname(MarshaledAString(PAnsiChar(OwnA)));
  if (E = nil) or (E.h_addr_list = nil) then Exit;
  P := PPAnsiChar(E.h_addr_list);
  while P^ <> nil do
  begin
    A := PInAddr(P^);
    if string(inet_ntoa(A^)) = IP then Exit(True);
    Inc(P);
  end;
end;

var
  WSA: TWSAData;

initialization
  WSAStartup($0202, WSA);

finalization
  WSACleanup;

end.
