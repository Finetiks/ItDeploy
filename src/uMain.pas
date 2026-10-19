unit uMain;

{ Головне вікно: список ПК, сканування, імпорт із Veyon, вибір інсталятора, запуск розгортання. }

interface

uses
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI, System.SysUtils, System.Classes, System.IniFiles,
  System.Generics.Collections, System.Math, System.IOUtils, System.SyncObjs, System.StrUtils,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  Vcl.Samples.Spin, uCommon, uNet, uVeyon, uDeploy;

type
  THostRec = class
  public
    Host: string;
    IP: string;
    Location: string;
    Mac: string;
    ScanText: string;
    Stage: string;
    ResultText: string;
    Scanned: Boolean;
    Online: Boolean;
    Smb: Boolean;
    Veyon: Boolean;
    Done: Boolean;
    Ok: Boolean;
    Skipped: Boolean;
    Item: TListItem;
  end;

  TIndexProc = reference to procedure(Index: Integer);

  TPoolState = class
  public
    Next: Integer;
    Active: Integer;
  end;

  TMainForm = class(TForm)
  private
    FHosts: TList<THostRec>;
    FBusy: Boolean;
    FCancel: TCancelToken;
    FVeyonCli: string;
    FLastFlavor: TInstallerFlavor;
    FDoneCount: Integer;
    FOkCount: Integer;
    FFailCount: Integer;
    FSkipCount: Integer;
    FLogRoot: string;
    FTotal: Integer;
    // елементи керування
    gbInstaller: TGroupBox;
    edtFile: TEdit;
    btnBrowse: TButton;
    lblInfo: TLabel;
    edtArgs: TEdit;
    edtCodes: TEdit;
    spnTimeout: TSpinEdit;
    edtDetect: TEdit;
    cmbDrive: TComboBox;
    edtFolder: TEdit;
    edtMsiProp: TEdit;
    chkAllUsers: TCheckBox;
    chkReinstall: TCheckBox;
    chkShortcut: TCheckBox;
    edtShortcutExe: TEdit;
    edtShortcutName: TEdit;
    lblPreview: TLabel;
    FLastPath: string;
    gbHosts: TGroupBox;
    pnlTools: TFlowPanel;
    lvHosts: TListView;
    gbAccess: TGroupBox;
    chkCurrent: TCheckBox;
    edtUser: TEdit;
    edtPass: TEdit;
    spnParallel: TSpinEdit;
    cmbMethod: TComboBox;
    btnStart: TButton;
    btnStop: TButton;
    btnLogs: TButton;
    pbOverall: TProgressBar;
    lblSummary: TLabel;
    memoLog: TMemo;
    btnVeyon, btnAdd, btnLoad, btnScan, btnCheckAll, btnCheckOnline, btnUncheck,
      btnPrune, btnRemove, btnClear, btnAccess: TButton;
    procedure BuildUI;
    function MakeButton(AParent: TWinControl; const ACaption: string; AHandler: TNotifyEvent;
      AWidth: Integer = 110): TButton;
    function MakeLabel(AParent: TWinControl; const ACaption: string; X, Y: Integer): TLabel;
    procedure SetBusy(Value: Boolean);
    procedure Log(const S: string);
    procedure LogAsync(const S: string);
    procedure SetInstaller(const Path: string; KeepArgs: Boolean = False);
    function AddHost(const Host, Location, Mac: string): THostRec;
    procedure UpdateRow(Rec: THostRec);
    procedure RunPool(Count, Workers: Integer; const Proc: TIndexProc; const Done: TProc);
    procedure StartScan(const Recs: TArray<THostRec>);
    function CheckedRecs: TArray<THostRec>;
    function BuildConfig(out Cfg: TJobConfig): Boolean;
    procedure WriteReport;
    procedure LoadSettings;
    procedure SaveSettings;
    function SettingsPath: string;
    procedure UpdatePreview;
    procedure OptionChange(Sender: TObject);
    function ComputeInstallDir: string;
    procedure ImportComputers(const List: TArray<TVeyonComputer>);
    // обробники
    procedure BrowseClick(Sender: TObject);
    procedure FileExit(Sender: TObject);
    procedure VeyonClick(Sender: TObject);
    procedure AddClick(Sender: TObject);
    procedure LoadClick(Sender: TObject);
    procedure ScanClick(Sender: TObject);
    procedure CheckAllClick(Sender: TObject);
    procedure CheckOnlineClick(Sender: TObject);
    procedure UncheckClick(Sender: TObject);
    procedure PruneClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure ClearClick(Sender: TObject);
    procedure AccessClick(Sender: TObject);
    procedure StartClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure LogsClick(Sender: TObject);
    procedure CurrentUserClick(Sender: TObject);
    procedure HostsCustomDrawSubItem(Sender: TCustomListView; Item: TListItem; SubItem: Integer;
      State: TCustomDrawState; var DefaultDraw: Boolean);
    procedure HostsChange(Sender: TObject; Item: TListItem; Change: TItemChange);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
  protected
    procedure CreateWnd; override;
    procedure WMDropFiles(var Msg: TWMDropFiles); message WM_DROPFILES;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MainForm: TMainForm;

implementation

const
  COL_IP = 0;
  COL_LOC = 1;
  COL_SCAN = 2;
  COL_VEYON = 3;
  COL_SMB = 4;
  COL_RESULT = 5;

{ ---------- діалог "Додати" ---------- }

function InputTargets(Owner: TForm; out Text: string): Boolean;
var
  F: TForm;
  M: TMemo;
  L: TLabel;
  B1, B2: TButton;
begin
  Result := False;
  F := TForm.CreateNew(Owner);
  try
    F.Caption := 'Додати комп''ютери';
    F.Position := poOwnerFormCenter;
    F.BorderStyle := bsDialog;
    F.ClientWidth := 560;
    F.ClientHeight := 330;
    F.Font.Name := 'Segoe UI';
    F.Font.Size := 9;
    L := TLabel.Create(F);
    L.Parent := F;
    L.SetBounds(12, 10, 536, 90);
    L.AutoSize := False;
    L.WordWrap := True;
    L.Caption := 'Кожен запис з нового рядка (або через кому):' + sLineBreak +
      '  •  ім''я або IP:   ADMIN125.ITStepZT.local   |   192.168.1.15' + sLineBreak +
      '  •  діапазон IP:   192.168.1.10-192.168.1.50   |   192.168.1.10-50   |   192.168.1.0/24' + sLineBreak +
      '  •  шаблон імені:   ADMIN{1-250}.ITStepZT.local   |   PC-{01-30}' + sLineBreak +
      'Недоступні адреси можна потім прибрати кнопкою "Прибрати недоступні".';
    M := TMemo.Create(F);
    M.Parent := F;
    M.SetBounds(12, 104, 536, 176);
    M.ScrollBars := ssVertical;
    M.Font.Name := 'Consolas';
    B1 := TButton.Create(F);
    B1.Parent := F;
    B1.SetBounds(372, 292, 84, 28);
    B1.Caption := 'Додати';
    B1.ModalResult := mrOk;
    B1.Default := True;
    B2 := TButton.Create(F);
    B2.Parent := F;
    B2.SetBounds(464, 292, 84, 28);
    B2.Caption := 'Скасувати';
    B2.ModalResult := mrCancel;
    B2.Cancel := True;
    if F.ShowModal = mrOk then
    begin
      Text := M.Text;
      Result := Trim(Text) <> '';
    end;
  finally
    F.Free;
  end;
end;

{ ---------- TMainForm ---------- }

constructor TMainForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  FHosts := TList<THostRec>.Create;
  Caption := 'Масове встановлення програм (ITDeploy)';
  Width := 1120;
  Height := 900;
  Position := poScreenCenter;
  Font.Name := 'Segoe UI';
  Font.Size := 9;
  Constraints.MinWidth := 960;
  Constraints.MinHeight := 760;
  OnCloseQuery := FormCloseQuery;
  OnClose := FormClose;
  BuildUI;
  FVeyonCli := FindVeyonCli;
  LoadSettings;
  // файл інсталятора, перетягнутий на ITDeploy.exe або переданий параметром
  if (ParamCount >= 1) and FileExists(ParamStr(1)) then SetInstaller(ParamStr(1));
  if FVeyonCli <> '' then Log('Знайдено Veyon CLI: ' + FVeyonCli)
  else Log('Veyon CLI не знайдено - можна вказати вручну при імпорті або додати ПК вручну.');
  Log('Готово. 1) оберіть інсталятор  2) імпортуйте/додайте ПК і скануйте  3) вкажіть адміністратора  4) "Встановити".');
end;

destructor TMainForm.Destroy;
var
  R: THostRec;
begin
  for R in FHosts do R.Free;
  FHosts.Free;
  FCancel.Free;
  inherited;
end;

procedure TMainForm.CreateWnd;
begin
  inherited;
  DragAcceptFiles(Handle, True);
end;

procedure TMainForm.WMDropFiles(var Msg: TWMDropFiles);
var
  Buf: array[0..MAX_PATH] of Char;
begin
  try
    if DragQueryFile(Msg.Drop, 0, Buf, MAX_PATH) > 0 then
      if not FBusy then SetInstaller(Buf);
  finally
    DragFinish(Msg.Drop);
  end;
  Msg.Result := 0;
end;

function TMainForm.MakeButton(AParent: TWinControl; const ACaption: string; AHandler: TNotifyEvent;
  AWidth: Integer): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Width := AWidth;
  Result.Height := 28;
  Result.OnClick := AHandler;
end;

function TMainForm.MakeLabel(AParent: TWinControl; const ACaption: string; X, Y: Integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Left := X;
  Result.Top := Y;
end;

procedure TMainForm.BuildUI;
var
  Col: TListColumn;
  W: Integer;
begin
  // --- журнал (внизу) ---
  memoLog := TMemo.Create(Self);
  memoLog.Parent := Self;
  memoLog.Align := alBottom;
  memoLog.Height := 150;
  memoLog.ReadOnly := True;
  memoLog.ScrollBars := ssBoth;
  memoLog.Font.Name := 'Consolas';
  memoLog.Font.Size := 9;
  memoLog.WordWrap := False;

  // --- загальний прогрес ---
  lblSummary := TLabel.Create(Self);
  lblSummary.Parent := Self;
  lblSummary.Align := alBottom;
  lblSummary.Caption := ' ';
  lblSummary.AlignWithMargins := True;
  lblSummary.Margins.SetBounds(8, 2, 8, 2);

  pbOverall := TProgressBar.Create(Self);
  pbOverall.Parent := Self;
  pbOverall.Align := alBottom;
  pbOverall.Height := 14;
  pbOverall.AlignWithMargins := True;
  pbOverall.Margins.SetBounds(8, 4, 8, 0);

  // --- блок 3: доступ і запуск ---
  gbAccess := TGroupBox.Create(Self);
  gbAccess.Parent := Self;
  gbAccess.Align := alBottom;
  gbAccess.Height := 96;
  gbAccess.Caption := ' 3. Обліковий запис адміністратора та запуск ';
  gbAccess.AlignWithMargins := True;
  gbAccess.Margins.SetBounds(8, 4, 8, 4);

  chkCurrent := TCheckBox.Create(Self);
  chkCurrent.Parent := gbAccess;
  chkCurrent.SetBounds(12, 22, 300, 20);
  chkCurrent.Caption := 'Поточний користувач Windows (без пароля)';
  chkCurrent.OnClick := CurrentUserClick;

  MakeLabel(gbAccess, 'Користувач:', 330, 24);
  edtUser := TEdit.Create(Self);
  edtUser.Parent := gbAccess;
  edtUser.SetBounds(410, 20, 230, 24);
  edtUser.TextHint := 'ДОМЕН\логін';

  MakeLabel(gbAccess, 'Пароль:', 655, 24);
  edtPass := TEdit.Create(Self);
  edtPass.Parent := gbAccess;
  edtPass.SetBounds(715, 20, 170, 24);
  edtPass.PasswordChar := '*';
  edtPass.TextHint := 'не зберігається';

  MakeLabel(gbAccess, 'Паралельно ПК:', 12, 62);
  spnParallel := TSpinEdit.Create(Self);
  spnParallel.Parent := gbAccess;
  spnParallel.SetBounds(112, 58, 56, 24);
  spnParallel.MinValue := 1;
  spnParallel.MaxValue := 32;
  spnParallel.Value := 4;

  MakeLabel(gbAccess, 'Метод запуску:', 188, 62);
  cmbMethod := TComboBox.Create(Self);
  cmbMethod.Parent := gbAccess;
  cmbMethod.SetBounds(278, 58, 230, 24);
  cmbMethod.Style := csDropDownList;
  cmbMethod.Items.Add('Авто (служба SMB, потім WMI)');
  cmbMethod.Items.Add('Лише служба SMB (як PsExec)');
  cmbMethod.Items.Add('Лише WMI');
  cmbMethod.ItemIndex := 0;

  btnStart := MakeButton(gbAccess, 'Встановити на позначені ПК', StartClick, 210);
  btnStart.SetBounds(0, 52, 210, 32);
  btnStart.Anchors := [akTop, akRight];
  btnStart.Font.Style := [fsBold];
  btnStop := MakeButton(gbAccess, 'Зупинити', StopClick, 90);
  btnStop.SetBounds(0, 52, 90, 32);
  btnStop.Anchors := [akTop, akRight];
  btnStop.Enabled := False;
  btnLogs := MakeButton(gbAccess, 'Журнали…', LogsClick, 90);
  btnLogs.SetBounds(0, 52, 90, 32);
  btnLogs.Anchors := [akTop, akRight];

  // --- блок 1: інсталятор (вгорі) ---
  gbInstaller := TGroupBox.Create(Self);
  gbInstaller.Parent := Self;
  gbInstaller.Align := alTop;
  gbInstaller.Height := 272;
  gbInstaller.Caption := ' 1. Програма для встановлення (можна перетягнути файл у вікно) ';
  gbInstaller.AlignWithMargins := True;
  gbInstaller.Margins.SetBounds(8, 6, 8, 2);

  MakeLabel(gbInstaller, 'Файл (.exe .msi .msp .bat .ps1):', 12, 24);
  edtFile := TEdit.Create(Self);
  edtFile.Parent := gbInstaller;
  edtFile.SetBounds(200, 20, 600, 24);
  edtFile.Anchors := [akLeft, akTop, akRight];
  edtFile.OnExit := FileExit;
  btnBrowse := MakeButton(gbInstaller, 'Огляд…', BrowseClick, 90);
  btnBrowse.SetBounds(0, 18, 90, 28);
  btnBrowse.Anchors := [akTop, akRight];

  lblInfo := MakeLabel(gbInstaller, '', 200, 48);
  lblInfo.Anchors := [akLeft, akTop, akRight];

  MakeLabel(gbInstaller, 'Параметри тихої установки:', 12, 76);
  edtArgs := TEdit.Create(Self);
  edtArgs.Parent := gbInstaller;
  edtArgs.SetBounds(200, 72, 330, 24);
  edtArgs.OnChange := OptionChange;

  MakeLabel(gbInstaller, 'Коди успіху:', 548, 76);
  edtCodes := TEdit.Create(Self);
  edtCodes.Parent := gbInstaller;
  edtCodes.SetBounds(626, 72, 90, 24);
  edtCodes.Text := '0,3010';

  MakeLabel(gbInstaller, 'Таймаут, хв:', 734, 76);
  spnTimeout := TSpinEdit.Create(Self);
  spnTimeout.Parent := gbInstaller;
  spnTimeout.SetBounds(810, 72, 64, 24);
  spnTimeout.MinValue := 1;
  spnTimeout.MaxValue := 600;
  spnTimeout.Value := 60;

  // --- куди встановити ---
  MakeLabel(gbInstaller, 'Куди встановити:', 12, 108);
  cmbDrive := TComboBox.Create(Self);
  cmbDrive.Parent := gbInstaller;
  cmbDrive.SetBounds(200, 104, 150, 24);
  cmbDrive.Style := csDropDownList;
  cmbDrive.Items.Add('за замовчуванням');
  cmbDrive.Items.Add('диск C:');
  cmbDrive.Items.Add('диск D:');
  cmbDrive.Items.Add('диск E:');
  cmbDrive.Items.Add('диск F:');
  cmbDrive.Items.Add('диск G:');
  cmbDrive.ItemIndex := 0;
  cmbDrive.OnChange := OptionChange;
  cmbDrive.Hint := 'Диск, на який інсталятор поставить програму. Якщо на ПК немає цього диска - ПК буде пропущено з помилкою.';
  cmbDrive.ShowHint := True;

  MakeLabel(gbInstaller, 'Папка:', 366, 108);
  edtFolder := TEdit.Create(Self);
  edtFolder.Parent := gbInstaller;
  edtFolder.SetBounds(412, 104, 270, 24);
  edtFolder.TextHint := 'назва папки, напр. ArtCraft Launcher';
  edtFolder.OnChange := OptionChange;
  edtFolder.Hint := 'Назва папки на обраному диску. Можна ввести і повний шлях (D:\Soft\Програма) - тоді диск зі списку ігнорується.';
  edtFolder.ShowHint := True;

  MakeLabel(gbInstaller, 'MSI-властивість:', 700, 108);
  edtMsiProp := TEdit.Create(Self);
  edtMsiProp.Parent := gbInstaller;
  edtMsiProp.SetBounds(800, 104, 130, 24);
  edtMsiProp.Text := 'INSTALLFOLDER';
  edtMsiProp.OnChange := OptionChange;
  edtMsiProp.Hint := 'Ім''я властивості MSI для папки (INSTALLFOLDER, INSTALLDIR, TARGETDIR...). Див. msi.log: рядок "Adding ... property".';
  edtMsiProp.ShowHint := True;

  chkAllUsers := TCheckBox.Create(Self);
  chkAllUsers.Parent := gbInstaller;
  chkAllUsers.SetBounds(200, 134, 330, 20);
  chkAllUsers.Caption := 'Для всіх користувачів (ALLUSERS=1 / Inno /ALLUSERS)';
  chkAllUsers.Checked := True;
  chkAllUsers.OnClick := OptionChange;

  chkReinstall := TCheckBox.Create(Self);
  chkReinstall.Parent := gbInstaller;
  chkReinstall.SetBounds(548, 134, 400, 20);
  chkReinstall.Caption := 'Спершу видалити попередню установку цього MSI';
  chkReinstall.OnClick := OptionChange;
  chkReinstall.Hint := 'Прибирає минулу установку (наприклад, у профіль SYSTEM), інакше MSI вважатиме програму вже встановленою.';
  chkReinstall.ShowHint := True;

  chkShortcut := TCheckBox.Create(Self);
  chkShortcut.Parent := gbInstaller;
  chkShortcut.SetBounds(200, 164, 250, 20);
  chkShortcut.Caption := 'Ярлики для ВСІХ користувачів: файл';
  chkShortcut.OnClick := OptionChange;
  chkShortcut.Hint := 'Створює ярлик на загальному робочому столі та в загальному меню "Пуск" (видно всім профілям).';
  chkShortcut.ShowHint := True;

  edtShortcutExe := TEdit.Create(Self);
  edtShortcutExe.Parent := gbInstaller;
  edtShortcutExe.SetBounds(452, 160, 240, 24);
  edtShortcutExe.TextHint := 'exe у папці установки або повний шлях';
  edtShortcutExe.OnChange := OptionChange;

  MakeLabel(gbInstaller, 'назва ярлика:', 706, 164);
  edtShortcutName := TEdit.Create(Self);
  edtShortcutName.Parent := gbInstaller;
  edtShortcutName.SetBounds(790, 160, 140, 24);
  edtShortcutName.TextHint := 'за назвою файлу';
  edtShortcutName.OnChange := OptionChange;

  MakeLabel(gbInstaller, 'Пропускати ПК, де існує:', 12, 200);
  edtDetect := TEdit.Create(Self);
  edtDetect.Parent := gbInstaller;
  edtDetect.SetBounds(200, 196, 600, 24);
  edtDetect.Anchors := [akLeft, akTop, akRight];
  edtDetect.TextHint := 'необов''язково, напр. D:\ArtCraft Launcher\artcraft-launcher.exe';

  lblPreview := TLabel.Create(Self);
  lblPreview.Parent := gbInstaller;
  lblPreview.SetBounds(12, 228, 1000, 34);
  lblPreview.AutoSize := False;
  lblPreview.WordWrap := True;
  lblPreview.Anchors := [akLeft, akTop, akRight];
  lblPreview.Font.Name := 'Consolas';
  lblPreview.Font.Size := 9;
  lblPreview.ShowHint := True;

  // --- блок 2: комп'ютери ---
  gbHosts := TGroupBox.Create(Self);
  gbHosts.Parent := Self;
  gbHosts.Align := alClient;
  gbHosts.Caption := ' 2. Комп''ютери (позначені галочкою отримають програму) ';
  gbHosts.AlignWithMargins := True;
  gbHosts.Margins.SetBounds(8, 4, 8, 2);

  pnlTools := TFlowPanel.Create(Self);
  pnlTools.Parent := gbHosts;
  pnlTools.Align := alTop;
  pnlTools.AutoSize := True;
  pnlTools.BevelOuter := bvNone;
  pnlTools.AutoWrap := True;
  pnlTools.Padding.SetBounds(4, 2, 4, 2);

  btnVeyon := MakeButton(pnlTools, 'Імпорт із Veyon', VeyonClick, 120);
  btnAdd := MakeButton(pnlTools, 'Додати…', AddClick, 80);
  btnLoad := MakeButton(pnlTools, 'З файлу…', LoadClick, 80);
  btnScan := MakeButton(pnlTools, 'Сканувати', ScanClick, 90);
  btnCheckOnline := MakeButton(pnlTools, 'Позначити доступні', CheckOnlineClick, 128);
  btnCheckAll := MakeButton(pnlTools, 'Позначити всі', CheckAllClick, 100);
  btnUncheck := MakeButton(pnlTools, 'Зняти позначки', UncheckClick, 106);
  btnAccess := MakeButton(pnlTools, 'Перевірити доступ', AccessClick, 120);
  btnPrune := MakeButton(pnlTools, 'Прибрати недоступні', PruneClick, 138);
  btnRemove := MakeButton(pnlTools, 'Видалити виділені', RemoveClick, 120);
  btnClear := MakeButton(pnlTools, 'Очистити', ClearClick, 80);
  btnVeyon.Hint := 'Читає список ПК із Veyon (veyon-cli / налаштування Veyon Master) і скануює їх';
  btnVeyon.ShowHint := True;

  lvHosts := TListView.Create(Self);
  lvHosts.Parent := gbHosts;
  lvHosts.Align := alClient;
  lvHosts.ViewStyle := vsReport;
  lvHosts.CheckBoxes := True;
  lvHosts.RowSelect := True;
  lvHosts.GridLines := True;
  lvHosts.MultiSelect := True;
  lvHosts.ReadOnly := True;
  lvHosts.HideSelection := False;
  lvHosts.OnCustomDrawSubItem := HostsCustomDrawSubItem;
  lvHosts.OnChange := HostsChange;
  Col := lvHosts.Columns.Add; Col.Caption := 'Комп''ютер'; Col.Width := 200;
  Col := lvHosts.Columns.Add; Col.Caption := 'IP'; Col.Width := 105;
  Col := lvHosts.Columns.Add; Col.Caption := 'Локація (Veyon)'; Col.Width := 120;
  Col := lvHosts.Columns.Add; Col.Caption := 'Сканування'; Col.Width := 150;
  Col := lvHosts.Columns.Add; Col.Caption := 'Veyon'; Col.Width := 50;
  Col := lvHosts.Columns.Add; Col.Caption := 'SMB'; Col.Width := 45;
  Col := lvHosts.Columns.Add; Col.Caption := 'Результат установки'; Col.Width := 380;

  // позиції кнопок справа (Anchors akRight рахуються від ширини групи)
  W := gbAccess.ClientWidth;
  btnStart.Left := W - 210 - 12;
  btnStop.Left := btnStart.Left - 90 - 8;
  btnLogs.Left := btnStop.Left - 90 - 8;
  btnBrowse.Left := gbInstaller.ClientWidth - 90 - 12;
  edtFile.Width := btnBrowse.Left - 8 - edtFile.Left;
  edtDetect.Width := edtFile.Width;
end;

procedure TMainForm.SetBusy(Value: Boolean);
var
  B: TButton;
begin
  FBusy := Value;
  for B in [btnVeyon, btnAdd, btnLoad, btnScan, btnCheckAll, btnCheckOnline, btnUncheck, btnPrune,
    btnRemove, btnClear, btnAccess, btnStart, btnBrowse] do
    B.Enabled := not Value;
  edtFile.Enabled := not Value;
  edtArgs.Enabled := not Value;
  edtCodes.Enabled := not Value;
  edtDetect.Enabled := not Value;
  cmbDrive.Enabled := not Value;
  edtFolder.Enabled := not Value;
  edtMsiProp.Enabled := not Value;
  chkAllUsers.Enabled := not Value;
  chkReinstall.Enabled := not Value;
  chkShortcut.Enabled := not Value;
  edtShortcutExe.Enabled := not Value;
  edtShortcutName.Enabled := not Value;
  spnTimeout.Enabled := not Value;
  spnParallel.Enabled := not Value;
  cmbMethod.Enabled := not Value;
  chkCurrent.Enabled := not Value;
  edtUser.Enabled := (not Value) and (not chkCurrent.Checked);
  edtPass.Enabled := (not Value) and (not chkCurrent.Checked);
  if Value then Screen.Cursor := crAppStart else Screen.Cursor := crDefault;
end;

procedure TMainForm.Log(const S: string);
begin
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
end;

procedure TMainForm.LogAsync(const S: string);
begin
  TThread.Queue(nil, procedure begin Log(S); end);
end;

{ ---------- інсталятор ---------- }

procedure TMainForm.SetInstaller(const Path: string; KeepArgs: Boolean);
var
  Flavor: TInstallerFlavor;
  K: TInstallerKind;
  Info, Prod: string;
  Size: Int64;
begin
  edtFile.Text := Path;
  if not FileExists(Path) then
  begin
    lblInfo.Font.Color := clRed;
    lblInfo.Caption := 'Файл не знайдено';
    Exit;
  end;
  K := KindFromFile(Path);
  Screen.Cursor := crHourGlass;
  try
    Flavor := DetectFlavor(Path);
  finally
    Screen.Cursor := crDefault;
  end;
  FLastFlavor := Flavor;
  Size := FileSizeOf(Path);
  Prod := FileProductInfo(Path);
  Info := 'Тип: ' + FlavorNames[Flavor] + '   •   ' + FormatBytes(Size);
  if Prod <> '' then Info := Info + '   •   ' + Prod;
  if (Flavor = ifUnknown) and (K = ikExe) then
  begin
    lblInfo.Font.Color := $0000A5FF;
    lblInfo.Caption := Info + '   -   тип не визначено: вкажіть параметри тихої установки вручну';
  end
  else
  begin
    lblInfo.Font.Color := clWindowText;
    lblInfo.Caption := Info;
  end;
  FLastPath := Path;
  if not KeepArgs then edtArgs.Text := DefaultArgs(Flavor, K);
  UpdatePreview;
end;

function IsAbsolutePath(const S: string): Boolean;
begin
  Result := ((Length(S) >= 3) and (S[2] = ':') and (S[3] = '\')) or ((Length(S) >= 2) and (Copy(S, 1, 2) = '\\'));
end;

function TMainForm.ComputeInstallDir: string;
var
  F, Item: string;
begin
  Result := '';
  F := Trim(edtFolder.Text);
  if IsAbsolutePath(F) then Exit(F);
  if cmbDrive.ItemIndex <= 0 then Exit;
  Item := cmbDrive.Items[cmbDrive.ItemIndex];            // 'диск D:'
  Result := Copy(Item, Length(Item) - 1, 2) + '\' + F;   // 'D:\папка'
end;

procedure TMainForm.UpdatePreview;
var
  Cfg: TJobConfig;
  Warn, Cmd, Args: string;
begin
  if lblPreview = nil then Exit;
  Cfg := Default(TJobConfig);
  Cfg.InstallerPath := Trim(edtFile.Text);
  Cfg.Kind := KindFromFile(Cfg.InstallerPath);
  Cfg.Args := Trim(edtArgs.Text);
  Cfg.Flavor := FLastFlavor;
  Cfg.InstallDir := ComputeInstallDir;
  Cfg.InstallDirProp := Trim(edtMsiProp.Text);
  Cfg.AllUsers := chkAllUsers.Checked;
  Args := ComposeArgs(Cfg, Warn);
  case Cfg.Kind of
    ikMsi: Cmd := 'msiexec /i payload.msi ' + Args;
    ikMsp: Cmd := 'msiexec /p payload.msp ' + Args;
    ikCmd: Cmd := 'cmd /c payload ' + Args;
    ikPs1: Cmd := 'powershell -File payload.ps1 ' + Args;
  else
    Cmd := 'payload.exe ' + Args;
  end;
  if Cfg.InstallerPath = '' then Cmd := '';
  lblPreview.Caption := IfThen(Cmd = '', '', 'На ПК буде виконано (від SYSTEM): ' + Cmd);
  if Warn <> '' then
  begin
    lblPreview.Font.Color := $0000A5FF;
    lblPreview.Hint := Warn;
    lblPreview.Caption := lblPreview.Caption + '   [!] ' + Warn;
  end
  else
  begin
    lblPreview.Font.Color := clGrayText;
    lblPreview.Hint := lblPreview.Caption;
  end;
end;

procedure TMainForm.OptionChange(Sender: TObject);
begin
  UpdatePreview;
end;

procedure TMainForm.BrowseClick(Sender: TObject);
var
  D: TOpenDialog;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Title := 'Оберіть програму для встановлення';
    D.Filter := 'Інсталятори (*.exe;*.msi;*.msp;*.bat;*.cmd;*.ps1)|*.exe;*.msi;*.msp;*.bat;*.cmd;*.ps1|Усі файли (*.*)|*.*';
    if edtFile.Text <> '' then D.InitialDir := ExtractFilePath(edtFile.Text);
    if D.Execute then SetInstaller(D.FileName);
  finally
    D.Free;
  end;
end;

procedure TMainForm.FileExit(Sender: TObject);
begin
  if (Trim(edtFile.Text) <> '') and FileExists(Trim(edtFile.Text)) then
    SetInstaller(Trim(edtFile.Text), True);
end;

{ ---------- список ПК ---------- }

function TMainForm.AddHost(const Host, Location, Mac: string): THostRec;
var
  R: THostRec;
begin
  Result := nil;
  if Trim(Host) = '' then Exit;
  for R in FHosts do
    if SameText(R.Host, Trim(Host)) then Exit(R);
  Result := THostRec.Create;
  Result.Host := Trim(Host);
  Result.Location := Location;
  Result.Mac := Mac;
  Result.Item := lvHosts.Items.Add;
  Result.Item.Caption := Result.Host;
  Result.Item.Data := Result;
  while Result.Item.SubItems.Count < 6 do Result.Item.SubItems.Add('');
  FHosts.Add(Result);
  UpdateRow(Result);
end;

procedure TMainForm.UpdateRow(Rec: THostRec);
var
  Sub: TStrings;
begin
  if Rec.Item = nil then Exit;
  Sub := Rec.Item.SubItems;
  while Sub.Count < 6 do Sub.Add('');
  Rec.Item.Caption := Rec.Host;
  Sub[COL_IP] := Rec.IP;
  Sub[COL_LOC] := Rec.Location;
  Sub[COL_SCAN] := Rec.ScanText;
  if Rec.Scanned then
  begin
    Sub[COL_VEYON] := IfThen(Rec.Veyon, 'так', '-');
    Sub[COL_SMB] := IfThen(Rec.Smb, 'так', '-');
  end
  else
  begin
    Sub[COL_VEYON] := '';
    Sub[COL_SMB] := '';
  end;
  if Rec.ResultText <> '' then Sub[COL_RESULT] := Rec.ResultText
  else Sub[COL_RESULT] := Rec.Stage;
end;

procedure TMainForm.HostsCustomDrawSubItem(Sender: TCustomListView; Item: TListItem; SubItem: Integer;
  State: TCustomDrawState; var DefaultDraw: Boolean);
var
  Rec: THostRec;
begin
  Rec := THostRec(Item.Data);
  if Rec = nil then Exit;
  case SubItem - 1 of
    COL_SCAN:
      if Rec.Scanned then
      begin
        if Rec.Smb then Sender.Canvas.Font.Color := $00007000
        else if Rec.Online then Sender.Canvas.Font.Color := $0000A0FF
        else Sender.Canvas.Font.Color := clGray;
      end;
    COL_RESULT:
      if Rec.Done then
      begin
        if Rec.Skipped then Sender.Canvas.Font.Color := clGray
        else if Rec.Ok then Sender.Canvas.Font.Color := $00007000
        else Sender.Canvas.Font.Color := clRed;
      end;
  end;
end;

procedure TMainForm.HostsChange(Sender: TObject; Item: TListItem; Change: TItemChange);
var
  N: Integer;
  R: THostRec;
begin
  if Change <> ctState then Exit;
  N := 0;
  for R in FHosts do
    if (R.Item <> nil) and R.Item.Checked then Inc(N);
  if not FBusy then
    gbHosts.Caption := Format(' 2. Комп''ютери: %d у списку, %d позначено ', [FHosts.Count, N]);
end;

function TMainForm.CheckedRecs: TArray<THostRec>;
var
  L: TList<THostRec>;
  R: THostRec;
begin
  L := TList<THostRec>.Create;
  try
    for R in FHosts do
      if (R.Item <> nil) and R.Item.Checked then L.Add(R);
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

procedure TMainForm.ImportComputers(const List: TArray<TVeyonComputer>);
var
  C: TVeyonComputer;
  Added, Dup: Integer;
  R: THostRec;
  New: TList<THostRec>;
  Before: Integer;
begin
  Added := 0;
  Dup := 0;
  New := TList<THostRec>.Create;
  try
    lvHosts.Items.BeginUpdate;
    try
      for C in List do
      begin
        Before := FHosts.Count;
        R := AddHost(C.Host, C.Location, C.Mac);
        if R = nil then Continue;
        if FHosts.Count > Before then
        begin
          Inc(Added);
          New.Add(R);
        end
        else
          Inc(Dup);
      end;
    finally
      lvHosts.Items.EndUpdate;
    end;
    Log(Format('Додано ПК: %d (дублікатів пропущено: %d). Починаю сканування…', [Added, Dup]));
    if New.Count > 0 then StartScan(New.ToArray);
  finally
    New.Free;
  end;
end;

{ ---------- пул потоків ---------- }

procedure TMainForm.RunPool(Count, Workers: Integer; const Proc: TIndexProc; const Done: TProc);
var
  State: TPoolState;
  I, N: Integer;
begin
  if Count <= 0 then
  begin
    if Assigned(Done) then Done();
    Exit;
  end;
  State := TPoolState.Create;
  N := Max(1, Min(Workers, Count));
  State.Active := N;
  for I := 1 to N do
    TThread.CreateAnonymousThread(
      procedure
      var
        Idx: Integer;
      begin
        while True do
        begin
          Idx := TInterlocked.Increment(State.Next) - 1;
          if Idx >= Count then Break;
          try
            Proc(Idx);
          except
          end;
        end;
        if TInterlocked.Decrement(State.Active) = 0 then
          TThread.Queue(nil,
            procedure
            begin
              State.Free;
              if Assigned(Done) then Done();
            end);
      end).Start;
end;

{ ---------- сканування ---------- }

procedure TMainForm.StartScan(const Recs: TArray<THostRec>);
var
  Total, Found, Avail: Integer;
  Hosts: TArray<string>;
  I: Integer;
begin
  if Length(Recs) = 0 then Exit;
  SetBusy(True);
  Total := Length(Recs);
  Found := 0;
  Avail := 0;
  SetLength(Hosts, Total);
  for I := 0 to Total - 1 do
  begin
    Hosts[I] := Recs[I].Host;
    Recs[I].ScanText := 'сканування…';
    Recs[I].Scanned := False;
    UpdateRow(Recs[I]);
  end;
  pbOverall.Max := Total;
  pbOverall.Position := 0;
  lblSummary.Caption := 'Сканування…';
  RunPool(Total, 48,
    procedure(Idx: Integer)
    var
      R: TScanResult;
    begin
      R := ScanHost(Hosts[Idx]);
      TThread.Queue(nil,
        procedure
        var
          Rec: THostRec;
          First: Boolean;
        begin
          Rec := Recs[Idx];
          First := not Rec.Scanned;
          Rec.Scanned := True;
          Rec.IP := R.IP;
          Rec.Online := R.Online;
          Rec.Smb := R.Smb;
          Rec.Veyon := R.Veyon;
          Rec.ScanText := R.Summary;
          if (R.HostName <> '') and IsIPv4(Rec.Host) and (Rec.Location = '') then Rec.Location := '';
          if R.Online then Inc(Found);
          if R.Smb then Inc(Avail);
          if First and (Rec.Item <> nil) then Rec.Item.Checked := R.Smb;
          UpdateRow(Rec);
          pbOverall.Position := pbOverall.Position + 1;
        end);
    end,
    procedure
    begin
      SetBusy(False);
      lblSummary.Caption := Format('Сканування завершено: відповідають %d з %d, готові до встановлення (SMB 445): %d',
        [Found, Total, Avail]);
      Log(lblSummary.Caption);
      HostsChange(lvHosts, nil, ctState);
    end);
end;

procedure TMainForm.ScanClick(Sender: TObject);
begin
  if FHosts.Count = 0 then
  begin
    ShowMessage('Список порожній. Імпортуйте ПК із Veyon або натисніть "Додати…".');
    Exit;
  end;
  StartScan(FHosts.ToArray);
end;

procedure TMainForm.VeyonClick(Sender: TObject);
var
  Cli: string;
  D: TOpenDialog;
begin
  Cli := FVeyonCli;
  if (Cli = '') or not FileExists(Cli) then
  begin
    D := TOpenDialog.Create(Self);
    try
      D.Title := 'Вкажіть veyon-cli.exe (Скасувати - спробувати лише реєстр)';
      D.Filter := 'veyon-cli.exe|veyon-cli.exe|Усі файли|*.*';
      if D.Execute then
      begin
        Cli := D.FileName;
        FVeyonCli := Cli;
      end
      else
        Cli := '';
    finally
      D.Free;
    end;
  end;
  SetBusy(True);
  lblSummary.Caption := 'Читаю список ПК із Veyon…';
  TThread.CreateAnonymousThread(
    procedure
    var
      List: TArray<TVeyonComputer>;
      Msgs: TStringList;
      Ok: Boolean;
      Text: string;
    begin
      Msgs := TStringList.Create;
      try
        Ok := ImportFromVeyon(Cli, List, Msgs);
        Text := Msgs.Text;
      finally
        Msgs.Free;
      end;
      TThread.Queue(nil,
        procedure
        var
          Line: string;
        begin
          for Line in Text.Split([sLineBreak]) do
            if Trim(Line) <> '' then Log(Line);
          SetBusy(False);
          lblSummary.Caption := '';
          if Ok then
            ImportComputers(List)
          else
            ShowMessage('Із Veyon не вдалося отримати список ПК. Подробиці - в журналі внизу.' + sLineBreak +
              'Можна додати ПК вручну (кнопка "Додати…") або завантажити файл.');
        end);
    end).Start;
end;

procedure TMainForm.AddClick(Sender: TObject);
var
  Txt: string;
  Targets: TArray<string>;
  T: string;
  List: TArray<TVeyonComputer>;
  I: Integer;
begin
  if not InputTargets(Self, Txt) then Exit;
  try
    Targets := ExpandTargets(Txt);
  except
    on E: Exception do
    begin
      ShowMessage(E.Message);
      Exit;
    end;
  end;
  if Length(Targets) > 1000 then
    if MessageDlg(Format('Буде додано %d адрес. Продовжити?', [Length(Targets)]), mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
      Exit;
  SetLength(List, Length(Targets));
  I := 0;
  for T in Targets do
  begin
    List[I].Location := '';
    List[I].Name := T;
    List[I].Host := T;
    List[I].Mac := '';
    Inc(I);
  end;
  ImportComputers(List);
end;

procedure TMainForm.LoadClick(Sender: TObject);
var
  D: TOpenDialog;
  List: TArray<TVeyonComputer>;
begin
  D := TOpenDialog.Create(Self);
  try
    D.Title := 'Список комп''ютерів';
    D.Filter := 'Списки (*.txt;*.csv;*.json)|*.txt;*.csv;*.json|Усі файли|*.*';
    if not D.Execute then Exit;
    try
      List := LoadComputersFromFile(D.FileName);
    except
      on E: Exception do
      begin
        ShowMessage('Не вдалося прочитати файл: ' + E.Message);
        Exit;
      end;
    end;
    Log('Файл ' + D.FileName + ': записів ' + IntToStr(Length(List)));
    ImportComputers(List);
  finally
    D.Free;
  end;
end;

procedure TMainForm.CheckAllClick(Sender: TObject);
var
  R: THostRec;
begin
  for R in FHosts do R.Item.Checked := True;
end;

procedure TMainForm.CheckOnlineClick(Sender: TObject);
var
  R: THostRec;
begin
  for R in FHosts do R.Item.Checked := R.Smb;
end;

procedure TMainForm.UncheckClick(Sender: TObject);
var
  R: THostRec;
begin
  for R in FHosts do R.Item.Checked := False;
end;

procedure TMainForm.PruneClick(Sender: TObject);
var
  I, N: Integer;
  R: THostRec;
begin
  N := 0;
  lvHosts.Items.BeginUpdate;
  try
    for I := FHosts.Count - 1 downto 0 do
    begin
      R := FHosts[I];
      if R.Scanned and (not R.Smb) then
      begin
        R.Item.Delete;
        FHosts.Delete(I);
        R.Free;
        Inc(N);
      end;
    end;
  finally
    lvHosts.Items.EndUpdate;
  end;
  Log('Прибрано недоступних: ' + IntToStr(N));
  HostsChange(lvHosts, nil, ctState);
end;

procedure TMainForm.RemoveClick(Sender: TObject);
var
  I, N: Integer;
  R: THostRec;
begin
  N := 0;
  lvHosts.Items.BeginUpdate;
  try
    for I := FHosts.Count - 1 downto 0 do
    begin
      R := FHosts[I];
      if R.Item.Selected then
      begin
        R.Item.Delete;
        FHosts.Delete(I);
        R.Free;
        Inc(N);
      end;
    end;
  finally
    lvHosts.Items.EndUpdate;
  end;
  Log('Видалено зі списку: ' + IntToStr(N));
  HostsChange(lvHosts, nil, ctState);
end;

procedure TMainForm.ClearClick(Sender: TObject);
var
  R: THostRec;
begin
  if FHosts.Count = 0 then Exit;
  if MessageDlg('Очистити весь список комп''ютерів?', mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  lvHosts.Items.Clear;
  for R in FHosts do R.Free;
  FHosts.Clear;
  HostsChange(lvHosts, nil, ctState);
end;

procedure TMainForm.CurrentUserClick(Sender: TObject);
begin
  edtUser.Enabled := not chkCurrent.Checked;
  edtPass.Enabled := not chkCurrent.Checked;
end;

{ ---------- конфігурація й запуск ---------- }

function TMainForm.BuildConfig(out Cfg: TJobConfig): Boolean;
var
  Path, F, Target: string;
begin
  Result := False;
  FillChar(Cfg, SizeOf(Cfg), 0);
  Path := Trim(edtFile.Text);
  if (Path = '') or not FileExists(Path) then
  begin
    ShowMessage('Оберіть файл інсталятора (кнопка "Огляд…" або перетягніть файл у вікно).');
    Exit;
  end;
  if Path <> FLastPath then SetInstaller(Path, True);   // файл змінили вручну - перевизначити тип
  Cfg.InstallerPath := Path;
  Cfg.Kind := KindFromFile(Path);
  Cfg.Flavor := FLastFlavor;
  Cfg.Args := Trim(edtArgs.Text);

  // --- куди встановити ---
  F := Trim(edtFolder.Text);
  if (cmbDrive.ItemIndex > 0) and (F = '') then
  begin
    ShowMessage('Вкажіть назву папки на обраному диску (наприклад, ArtCraft Launcher): установка в корінь диска не підходить.');
    Exit;
  end;
  if (cmbDrive.ItemIndex <= 0) and (F <> '') and (not IsAbsolutePath(F)) then
  begin
    ShowMessage('Вказано назву папки, але не обрано диск. Оберіть диск у списку "Куди встановити" або введіть повний шлях.');
    Exit;
  end;
  Cfg.InstallDir := ComputeInstallDir;
  Cfg.InstallDirProp := Trim(edtMsiProp.Text);
  Cfg.AllUsers := chkAllUsers.Checked;
  Cfg.PreUninstall := chkReinstall.Checked and (Cfg.Kind = ikMsi);
  if chkShortcut.Checked then
  begin
    Target := Trim(edtShortcutExe.Text);
    if Target = '' then
    begin
      ShowMessage('Вкажіть файл для ярлика (exe у папці установки або повний шлях) або зніміть позначку "Ярлики для ВСІХ користувачів".');
      Exit;
    end;
    if not IsAbsolutePath(Target) then
    begin
      if Cfg.InstallDir = '' then
      begin
        ShowMessage('Для ярлика вкажіть повний шлях до exe або оберіть папку установки (тоді шлях складеться з неї).');
        Exit;
      end;
      Target := IncludeTrailingPathDelimiter(Cfg.InstallDir) + Target;
    end;
    Cfg.ShortcutTarget := Target;
    Cfg.ShortcutName := Trim(edtShortcutName.Text);
  end;
  Cfg.TimeoutMin := spnTimeout.Value;
  Cfg.SuccessCodes := ParseIntList(edtCodes.Text);
  if Length(Cfg.SuccessCodes) = 0 then Cfg.SuccessCodes := [0, 3010];
  Cfg.DetectPath := Trim(edtDetect.Text);
  case cmbMethod.ItemIndex of
    1: Cfg.Method := dmService;
    2: Cfg.Method := dmWmi;
  else
    Cfg.Method := dmAuto;
  end;
  Cfg.UseCurrentUser := chkCurrent.Checked;
  if not Cfg.UseCurrentUser then
  begin
    Cfg.User := Trim(edtUser.Text);
    Cfg.Password := edtPass.Text;
    if (Cfg.User = '') then
    begin
      ShowMessage('Вкажіть користувача (ДОМЕН\логін) та пароль адміністратора, або позначте "Поточний користувач Windows".');
      Exit;
    end;
  end;
  Result := True;
end;

function MakeLogRoot: string;
var
  Base: string;
begin
  Base := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'Logs\' + FormatDateTime('yyyy-mm-dd_hhnnss', Now);
  try
    ForceDirectories(Base);
    Result := Base;
  except
    Result := '';
  end;
  if (Result = '') or not DirectoryExists(Result) then
  begin
    Base := IncludeTrailingPathDelimiter(GetEnvironmentVariable('LOCALAPPDATA')) + 'ITDeploy\Logs\' +
      FormatDateTime('yyyy-mm-dd_hhnnss', Now);
    ForceDirectories(Base);
    Result := Base;
  end;
end;

procedure TMainForm.StartClick(Sender: TObject);
var
  Cfg: TJobConfig;
  Recs: TArray<THostRec>;
  Rec: THostRec;
  Workers: Integer;
  Warn, Summ: string;
begin
  if not BuildConfig(Cfg) then Exit;
  Recs := CheckedRecs;
  if Length(Recs) = 0 then
  begin
    ShowMessage('Позначте галочкою комп''ютери, на які треба встановити програму (кнопка "Позначити доступні").');
    Exit;
  end;
  if (Cfg.Args = '') and (Cfg.Kind in [ikExe]) then
    if MessageDlg('Параметри тихої установки порожні. Якщо інсталятор покаже вікно, він зависне невидимим на ПК ' +
      'до таймауту. Продовжити?', mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;
  Summ := Format('Встановити "%s" на %d комп''ютер(ів)?', [ExtractFileName(Cfg.InstallerPath), Length(Recs)]) +
    sLineBreak + sLineBreak;
  if Cfg.InstallDir <> '' then Summ := Summ + 'Куди: ' + Cfg.InstallDir + sLineBreak
  else Summ := Summ + 'Куди: за замовчуванням інсталятора' + sLineBreak;
  Summ := Summ + 'Параметри: ' + ComposeArgs(Cfg, Warn) + sLineBreak;
  if Cfg.PreUninstall then Summ := Summ + 'Спершу буде видалено попередню установку цього MSI' + sLineBreak;
  if Cfg.ShortcutTarget <> '' then Summ := Summ + 'Ярлики для всіх користувачів: ' + Cfg.ShortcutTarget + sLineBreak;
  if Warn <> '' then Summ := Summ + sLineBreak + 'Увага: ' + Warn + sLineBreak;
  Summ := Summ + sLineBreak + Format('Метод: %s, паралельно: %d', [cmbMethod.Text, spnParallel.Value]);
  if MessageDlg(Summ, mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;

  Cfg.LogRoot := MakeLogRoot;
  FLogRoot := Cfg.LogRoot;
  FreeAndNil(FCancel);
  FCancel := TCancelToken.Create;
  FDoneCount := 0;
  FOkCount := 0;
  FFailCount := 0;
  FSkipCount := 0;
  FTotal := Length(Recs);
  for Rec in Recs do
  begin
    Rec.Done := False;
    Rec.Ok := False;
    Rec.Skipped := False;
    Rec.ResultText := '';
    Rec.Stage := 'у черзі';
    UpdateRow(Rec);
  end;
  SetBusy(True);
  btnStop.Enabled := True;
  pbOverall.Max := FTotal;
  pbOverall.Position := 0;
  lblSummary.Caption := Format('Встановлення: 0 з %d', [FTotal]);
  Log(Format('=== Старт: %s на %d ПК. Журнали: %s', [ExtractFileName(Cfg.InstallerPath), FTotal, FLogRoot]));
  SaveSettings;
  Workers := spnParallel.Value;

  RunPool(FTotal, Workers,
    procedure(Idx: Integer)
    var
      Rec2: THostRec;
      Res: TDeployResult;
      LastPct: Integer;
      LastTick: UInt64;
    begin
      Rec2 := Recs[Idx];
      if FCancel.Cancelled then
      begin
        Res.Ok := False;
        Res.Skipped := False;
        Res.HasExitCode := False;
        Res.ExitCode := 0;
        Res.Method := '';
        Res.Msg := 'Скасовано (не запускалось)';
      end
      else
      begin
        LastPct := -2;
        LastTick := 0;
        Res := DeployToHost(Rec2.Host, Cfg, FCancel,
          procedure(const Stage: string; Pct: Integer)
          var
            Txt: string;
            Now2: UInt64;
          begin
            Now2 := GetTickCount64;
            if (Pct = LastPct) and (Now2 - LastTick < 1000) then Exit;
            LastPct := Pct;
            LastTick := Now2;
            if Pct >= 0 then Txt := Stage + ' ' + IntToStr(Pct) + '%' else Txt := Stage;
            TThread.Queue(nil,
              procedure
              begin
                if not Rec2.Done then
                begin
                  Rec2.Stage := Txt;
                  UpdateRow(Rec2);
                end;
              end);
          end);
      end;
      TThread.Queue(nil,
        procedure
        begin
          Rec2.Done := True;
          Rec2.Ok := Res.Ok;
          Rec2.Skipped := Res.Skipped;
          Rec2.Stage := '';
          Rec2.ResultText := Res.Msg;
          UpdateRow(Rec2);
          Inc(FDoneCount);
          if Res.Skipped then Inc(FSkipCount)
          else if Res.Ok then Inc(FOkCount)
          else Inc(FFailCount);
          pbOverall.Position := FDoneCount;
          lblSummary.Caption := Format('Виконано %d з %d   (успішно: %d, пропущено: %d, помилок: %d)',
            [FDoneCount, FTotal, FOkCount, FSkipCount, FFailCount]);
          Log(Rec2.Host + ': ' + Res.Msg);
        end);
    end,
    procedure
    begin
      Cfg.Password := '';
      SetBusy(False);
      btnStop.Enabled := False;
      WriteReport;
      Log(Format('=== Завершено. Успішно: %d, пропущено: %d, помилок: %d. Звіт: %s',
        [FOkCount, FSkipCount, FFailCount, FLogRoot + '\report.csv']));
      if FFailCount > 0 then
        ShowMessage(Format('Готово. Помилок: %d з %d. Докладніше - у списку та в журналах (кнопка "Журнали…").',
          [FFailCount, FTotal]))
      else
        ShowMessage(Format('Готово. Успішно: %d, пропущено: %d.', [FOkCount, FSkipCount]));
      HostsChange(lvHosts, nil, ctState);
    end);
end;

procedure TMainForm.StopClick(Sender: TObject);
begin
  if FCancel <> nil then
  begin
    FCancel.Cancel;
    Log('Зупинка: нові ПК не запускаються, активні установки скасовуються…');
    btnStop.Enabled := False;
  end;
end;

procedure TMainForm.LogsClick(Sender: TObject);
var
  Dir: string;
begin
  Dir := FLogRoot;
  if (Dir = '') or not DirectoryExists(Dir) then
    Dir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'Logs';
  if not DirectoryExists(Dir) then
  begin
    ShowMessage('Журналів ще немає.');
    Exit;
  end;
  ShellExecute(Handle, 'open', PChar(Dir), nil, nil, SW_SHOWNORMAL);
end;

procedure TMainForm.WriteReport;
var
  L: TStringList;
  R: THostRec;
  Status: string;
begin
  if FLogRoot = '' then Exit;
  L := TStringList.Create;
  try
    L.Add('Комп''ютер;IP;Статус;Повідомлення');
    for R in FHosts do
      if R.Done then
      begin
        if R.Skipped then Status := 'пропущено'
        else if R.Ok then Status := 'успішно'
        else Status := 'помилка';
        L.Add(Format('%s;%s;%s;%s', [R.Host, R.IP, Status, StringReplace(R.ResultText, ';', ',', [rfReplaceAll])]));
      end;
    try
      L.SaveToFile(FLogRoot + '\report.csv', TEncoding.UTF8);
    except
    end;
  finally
    L.Free;
  end;
end;

procedure TMainForm.AccessClick(Sender: TObject);
var
  Cfg: TJobConfig;
  Recs: TArray<THostRec>;
  Sel: TList<THostRec>;
  R: THostRec;
begin
  if not BuildConfig(Cfg) then Exit;
  Sel := TList<THostRec>.Create;
  try
    for R in FHosts do
      if R.Item.Selected then Sel.Add(R);
    if Sel.Count = 0 then
      for R in CheckedRecs do Sel.Add(R);
    Recs := Sel.ToArray;
  finally
    Sel.Free;
  end;
  if Length(Recs) = 0 then
  begin
    ShowMessage('Виділіть або позначте ПК, для яких перевірити доступ.');
    Exit;
  end;
  if Length(Recs) > 100 then
  begin
    ShowMessage('Для перевірки доступу оберіть не більше 100 ПК.');
    Exit;
  end;
  SetBusy(True);
  lblSummary.Caption := 'Перевірка доступу…';
  Log('Перевірка доступу для ' + IntToStr(Length(Recs)) + ' ПК…');
  RunPool(Length(Recs), Min(8, spnParallel.Value * 2),
    procedure(Idx: Integer)
    var
      Msg: string;
      Ok: Boolean;
      Rec: THostRec;
    begin
      Rec := Recs[Idx];
      Ok := CheckAccess(Rec.Host, Cfg, Msg);
      LogAsync(Rec.Host + ': ' + IfThen(Ok, 'OK - ', 'ПОМИЛКА - ') + Msg);
      TThread.Queue(nil,
        procedure
        begin
          Rec.Done := True;
          Rec.Ok := Ok;
          Rec.Skipped := False;
          Rec.ResultText := IfThen(Ok, 'Доступ OK', 'Немає доступу: ' + Msg);
          UpdateRow(Rec);
        end);
    end,
    procedure
    begin
      Cfg.Password := '';
      SetBusy(False);
      lblSummary.Caption := 'Перевірку доступу завершено';
    end);
end;

{ ---------- налаштування ---------- }

function TMainForm.SettingsPath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('APPDATA')) + 'ITDeploy\settings.ini';
end;

procedure TMainForm.LoadSettings;
var
  Ini: TMemIniFile;
  P, SavedArgs: string;
  N, I: Integer;
  Parts: TArray<string>;
begin
  try
    Ini := TMemIniFile.Create(SettingsPath, TEncoding.UTF8);
    try
      P := Ini.ReadString('Installer', 'Path', '');
      SavedArgs := Ini.ReadString('Installer', 'Args', '');
      if (P <> '') and FileExists(P) then
      begin
        SetInstaller(P);
        if SavedArgs <> '' then edtArgs.Text := SavedArgs;
      end;
      edtCodes.Text := Ini.ReadString('Installer', 'SuccessCodes', '0,3010');
      spnTimeout.Value := Ini.ReadInteger('Installer', 'TimeoutMin', 60);
      edtDetect.Text := Ini.ReadString('Installer', 'Detect', '');
      cmbDrive.ItemIndex := Min(Max(Ini.ReadInteger('Install', 'Drive', 0), 0), cmbDrive.Items.Count - 1);
      edtFolder.Text := Ini.ReadString('Install', 'Folder', '');
      edtMsiProp.Text := Ini.ReadString('Install', 'MsiProp', 'INSTALLFOLDER');
      chkAllUsers.Checked := Ini.ReadBool('Install', 'AllUsers', True);
      chkReinstall.Checked := Ini.ReadBool('Install', 'Reinstall', False);
      chkShortcut.Checked := Ini.ReadBool('Install', 'Shortcut', False);
      edtShortcutExe.Text := Ini.ReadString('Install', 'ShortcutExe', '');
      edtShortcutName.Text := Ini.ReadString('Install', 'ShortcutName', '');
      edtUser.Text := Ini.ReadString('Access', 'User', '');
      chkCurrent.Checked := Ini.ReadBool('Access', 'CurrentUser', False);
      CurrentUserClick(nil);
      spnParallel.Value := Ini.ReadInteger('Access', 'Parallel', 4);
      cmbMethod.ItemIndex := Ini.ReadInteger('Access', 'Method', 0);
      P := Ini.ReadString('Veyon', 'Cli', '');
      if (P <> '') and FileExists(P) then FVeyonCli := P;
      N := Ini.ReadInteger('Hosts', 'Count', 0);
      lvHosts.Items.BeginUpdate;
      try
        for I := 0 to N - 1 do
        begin
          Parts := Ini.ReadString('Hosts', 'H' + IntToStr(I), '').Split(['|']);
          if Length(Parts) >= 1 then
            if Length(Parts) >= 2 then AddHost(Parts[0], Parts[1], '') else AddHost(Parts[0], '', '');
        end;
      finally
        lvHosts.Items.EndUpdate;
      end;
      if N > 0 then Log('З минулого сеансу відновлено ПК: ' + IntToStr(FHosts.Count) + ' (натисніть "Сканувати")');
    finally
      Ini.Free;
    end;
  except
  end;
end;

procedure TMainForm.SaveSettings;
var
  Ini: TMemIniFile;
  I: Integer;
begin
  try
    ForceDirectories(ExtractFilePath(SettingsPath));
    Ini := TMemIniFile.Create(SettingsPath, TEncoding.UTF8);
    try
      Ini.WriteString('Installer', 'Path', Trim(edtFile.Text));
      Ini.WriteString('Installer', 'Args', edtArgs.Text);
      Ini.WriteString('Installer', 'SuccessCodes', edtCodes.Text);
      Ini.WriteInteger('Installer', 'TimeoutMin', spnTimeout.Value);
      Ini.WriteString('Installer', 'Detect', edtDetect.Text);
      Ini.WriteInteger('Install', 'Drive', cmbDrive.ItemIndex);
      Ini.WriteString('Install', 'Folder', edtFolder.Text);
      Ini.WriteString('Install', 'MsiProp', edtMsiProp.Text);
      Ini.WriteBool('Install', 'AllUsers', chkAllUsers.Checked);
      Ini.WriteBool('Install', 'Reinstall', chkReinstall.Checked);
      Ini.WriteBool('Install', 'Shortcut', chkShortcut.Checked);
      Ini.WriteString('Install', 'ShortcutExe', edtShortcutExe.Text);
      Ini.WriteString('Install', 'ShortcutName', edtShortcutName.Text);
      Ini.WriteString('Access', 'User', edtUser.Text);       // пароль НЕ зберігається
      Ini.WriteBool('Access', 'CurrentUser', chkCurrent.Checked);
      Ini.WriteInteger('Access', 'Parallel', spnParallel.Value);
      Ini.WriteInteger('Access', 'Method', cmbMethod.ItemIndex);
      Ini.WriteString('Veyon', 'Cli', FVeyonCli);
      Ini.EraseSection('Hosts');
      Ini.WriteInteger('Hosts', 'Count', FHosts.Count);
      for I := 0 to FHosts.Count - 1 do
        Ini.WriteString('Hosts', 'H' + IntToStr(I), FHosts[I].Host + '|' + FHosts[I].Location);
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
  end;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FBusy then
  begin
    ShowMessage('Зараз виконується операція. Натисніть "Зупинити" і дочекайтесь завершення, потім закрийте програму.');
    CanClose := False;
  end;
end;

procedure TMainForm.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  SaveSettings;
end;

end.
