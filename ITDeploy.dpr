program ITDeploy;

{ ITDeploy - масове встановлення програм на комп'ютери мережі (SMB + служба, без WinRM і Планувальника). }

uses
  Vcl.Forms,
  Winapi.Windows,
  System.SysUtils,
  uCommon in 'src\uCommon.pas',
  uNet in 'src\uNet.pas',
  uVeyon in 'src\uVeyon.pas',
  uDeploy in 'src\uDeploy.pas',
  uSelfTest in 'src\uSelfTest.pas',
  uMain in 'src\uMain.pas';

{$R ITDeploy.res}
{$R Agents.res}

begin
  if (ParamCount >= 1) and SameText(ParamStr(1), '--selftest') then
  begin
    ExitCode := RunSelfTest(ParamStr(2), ParamStr(3), ParamStr(4));
    Exit;
  end;
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.Title := 'Масове встановлення програм';
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
