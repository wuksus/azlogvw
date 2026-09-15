unit fm_main;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, LResources, Forms, Controls, Graphics, Dialogs, ExtCtrls,
  ComCtrls, StdCtrls, Buttons, CheckLst, LCLType, Grids, LCLIntf,
  //свои модули
  Parser, DataModule, Types;

type

  { TfmMain }

  TfmMain = class(TForm)
    bbFiltersDefault: TBitBtn;
    bbToFilter: TBitBtn;
    bbOpen: TBitBtn;
    Button1: TButton;
    cbxCommands: TCheckBox;
    cbgDirectionFilter: TCheckGroup;
    clbCommands: TCheckListBox;
    cbbDate: TComboBox;
    gbFilters: TGroupBox;
    ilMain: TImageList;
    lbDate: TLabel;
    lbLog: TListBox;
    odMain: TOpenDialog;
    pLeft: TPanel;
    pRight: TPanel;
    pbMain: TProgressBar;
    pStatus: TPanel;
    splVertical: TSplitter;
    splHorizontal: TSplitter;
    sgDetails: TStringGrid;
    tmrMain: TTimer;
    procedure bbFiltersDefaultClick(Sender: TObject);
    procedure bbOpenClick(Sender: TObject);
    procedure bbToFilterClick(Sender: TObject);
    procedure Button1Click(Sender: TObject);
    procedure cbxCommandsClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure lbLogDrawItem(Control: TWinControl; Index: Integer; ARect: TRect;
      State: TOwnerDrawState);
    procedure lbLogSelectionChange(Sender: TObject; User: boolean);
    procedure sgDetailsDrawCell(Sender: TObject; aCol, aRow: Integer;
      aRect: TRect; aState: TGridDrawState);
    procedure sgDetailsColumnResize(Sender: TObject; aCol, aWidth: Integer);
    procedure tmrMainTimer(Sender: TObject);
  private
    FLogEntries: TLogEntryArray;  // все записи
    FFilteredIndices: array of Integer; // индексы записей, прошедших фильтр
    FFileTotalLines: Integer; // Всего строк в файле
    FPrevColWidths: array of Integer; // массив для хранения предыдущих ширин колонок
    FCurrentLine: Integer; // Текущая строка
    procedure UpdateProgress; // Процедура обновления прогресса
    procedure ApplyFilter;
    procedure AddFieldsToGrid(const Entry: TLogEntry; sg: TStringGrid);
    procedure AdjustRowHeights(sg: TStringGrid);
    procedure ParseProgress(CurrentLine: Integer);
  public

  end;

var
  fmMain: TfmMain;

implementation

function GetMonospaceFontName: string;
const
  // Список шрифтов в порядке предпочтения
  PreferredFonts: array[0..5] of string = (
    'monospace',          // Системный алиас (самый лучший вариант)
    'Consolas',           // Отличный шрифт от Microsoft
    'DejaVu Sans Mono',   // Очень популярен в Linux
    'Liberation Mono',    // Метрически совместим с Courier New, есть везде
    'Courier New',        // Классика Windows
    'FreeMono'            // Шрифт из проекта GNU FreeFont
  );
var
  i: Integer;
begin
  Result := 'default'; // Значение по умолчанию, если ничего не найдено
  for i := 0 to High(PreferredFonts) do
  begin
    if Screen.Fonts.IndexOf(PreferredFonts[i]) >= 0 then
    begin
      Result := PreferredFonts[i];
      Exit;
    end;
  end;
end;

function FileLineCount(const Filename: string): Integer;
var
  Stream: TFileStream;
  Buf: array[0..4095] of Byte;
  BytesRead: Longint;
  LineCount, i: Integer;
begin
  Result := 0;
  LineCount := 0;
  Stream := TFileStream.Create(Filename, fmOpenRead or fmShareDenyWrite);
  try
    repeat
      BytesRead := Stream.Read(Buf, SizeOf(Buf));
      if BytesRead > 0 then
      begin
        // Подсчет переносов строк (\n)
        for i := 0 to BytesRead - 1 do
          if Buf[i] = Ord(#10) then
            Inc(LineCount);
      end;
    until BytesRead < SizeOf(Buf);
  finally
    Stream.Free;
  end;
  Result := LineCount;
end;

function StripControlChars(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    // Оставляем символы с кодом >= 32 (печатные), табуляцию (#9) и перевод строки (#10, #13)
    if (S[i] >= #32) or (S[i] in [#9, #10, #13]) then
      Result := Result + S[i]
    else if S[i] = STX then
      Result := Result + '>'
    else if S[i] = ETX then
      Result := Result + '<'
    else if S[i] = FS then
      Result := Result + '#'
    else
      Result := Result + '·'; // или можно просто пропустить: Result := Result;
  end;
end;

{ TfmMain }

procedure TfmMain.UpdateProgress;
begin
  // Обновляем прогресс-бар
  pbMain.Position := Trunc((FCurrentLine / FFileTotalLines) * 100);
  Application.ProcessMessages; // Обновляем интерфейс
end;

procedure TfmMain.ApplyFilter;
var
  i, j: Integer;
  VisibleIndices: array of Integer;
  DateFilter: string;
  ArrowOk: Boolean;
  CmdOk: Boolean;
  Entry: TLogEntry;
  Item: TListItem;
  DirSymbol: string; // Промежуточная переменная для направления
  CmdCode: string;
begin
  SetLength(VisibleIndices, 0);
  DateFilter := cbbDate.Text;
  if DateFilter = 'Все' then DateFilter := '';

  lbLog.Items.BeginUpdate;
  lbLog.Items.Clear;
  try
    for i := 0 to High(FLogEntries) do
    begin
      Entry := FLogEntries[i];

      // Фильтр по дате
      if (DateFilter <> '') and (Entry.FormDate <> DateFilter) then
        Continue;

      // Фильтр по направлению
      ArrowOk := False;
      case Entry.Arrow of
        arToKKT: ArrowOk := cbgDirectionFilter.Checked[0];
        arFromKKT: ArrowOk := cbgDirectionFilter.Checked[1];
        arOther: ArrowOk := cbgDirectionFilter.Checked[2];
        arError: ArrowOk := cbgDirectionFilter.Checked[3];
      end;
      if not ArrowOk then Continue;

      // Фильтр по команде (если не спам)
      if Entry.Cmd <> '00' then
      begin
        CmdOk := False;
        for j := 0 to clbCommands.Count-1 do
        begin
          // Извлекаем код команды из строки clbCommands.Items[j]
          // Предполагается, что код всегда идёт до двоеточия
          CmdCode := Copy(clbCommands.Items[j], 1, Pos(':', clbCommands.Items[j]) - 1);
          if (CmdCode = Entry.Cmd) and clbCommands.Checked[j] then
          begin
            CmdOk := True;
            Break;
          end;
        end;
        if not CmdOk then Continue;
      end;

      // Запись проходит фильтр
      SetLength(VisibleIndices, Length(VisibleIndices)+1);
      VisibleIndices[High(VisibleIndices)] := i;
    end;

    // Заново заполняем lbLog только видимыми записями
    for i := 0 to High(VisibleIndices) do
    begin
      Entry := FLogEntries[VisibleIndices[i]];

      // Определяем символ направления
      case Entry.Arrow of
        arToKKT: DirSymbol := '-->';
        arFromKKT: DirSymbol := '<--';
        arError: DirSymbol := 'ERR';
        arOther: DirSymbol := 'OTR';
      end;

      lbLog.Items.AddObject(
        Format('%s %s %s %s %s', [
          Entry.FormDate,
          Entry.Time,
          DirSymbol,
          Entry.Cmd,
          GetCommandName(Entry.Cmd)
        ]), TObject(PtrInt(VisibleIndices[i]))
      );
    end;
  finally
    lbLog.Items.EndUpdate;
  end;
end;

procedure TfmMain.bbFiltersDefaultClick(Sender: TObject);
var
  i: Integer;
begin
  cbbDate.ItemIndex := 0; // предполагаем, что 0 - это "Все"
  for i := 0 to cbgDirectionFilter.Items.Count-1 do
    cbgDirectionFilter.Checked[i] := True;
  cbxCommands.Checked := True;
  cbxCommandsClick(nil);
  ApplyFilter;
end;

procedure TfmMain.bbOpenClick(Sender: TObject);
var
  i: Integer;
  Entry: TLogEntry;
  CmdCount: TStringList;
  DateList: TStringList;
  DirSymbol: string;
begin
  if not odMain.Execute then Exit;

  // Освобождаем предыдущие данные
  for i := 0 to High(FLogEntries) do
    if Assigned(FLogEntries[i].RawData) then
      FLogEntries[i].RawData.Free;
  SetLength(FLogEntries, 0);
  lbLog.Clear;

  // Прогресс
  pbMain.Visible := True;
  pbMain.Position := 0;
  Application.ProcessMessages;

  FFileTotalLines := FileLineCount(odMain.FileName);
  FCurrentLine := 0;

  // Парсинг
  if not ParseLogFile(odMain.FileName, FLogEntries, @ParseProgress) then
  begin
    ShowMessage('Ошибка при чтении файла');
    pbMain.Visible := False;
    Exit;
  end;

  pbMain.Position := 0;
  pbMain.Visible := False;

  // Подготовка коллекций для уникальных значений
  CmdCount := TStringList.Create;
  CmdCount.Sorted := True;
  CmdCount.Duplicates := dupIgnore;

  DateList := TStringList.Create;
  DateList.Sorted := True;
  DateList.Duplicates := dupIgnore;

  try
    // Один проход: заполняем lbLog (если нужно) и собираем команды/даты
    lbLog.Items.BeginUpdate;
    try
      for i := 0 to High(FLogEntries) do
      begin
        Entry := FLogEntries[i];

        // Определяем символ направления
        case Entry.Arrow of
          arToKKT:   DirSymbol := '-->';
          arFromKKT: DirSymbol := '<--';
          arError:   DirSymbol := 'ERR';
          arOther:   DirSymbol := 'OTR';
        end;

        // Добавляем строку в список логов
        lbLog.Items.AddObject(
          Format('%s %s %s %s %s', [
            Entry.FormDate,
            Entry.Time,
            DirSymbol,
            Entry.Cmd,
            GetCommandName(Entry.Cmd)
          ]), TObject(PtrInt(i))
        );

        // Уникальные команды (не спам)
        if Entry.Cmd <> '00' then
          CmdCount.Add(Entry.Cmd);

        // Уникальные даты (не пустые)
        if Entry.FormDate <> '' then
          DateList.Add(Entry.FormDate);
      end;
    finally
      lbLog.Items.EndUpdate;
    end;

    // Заполняем список команд
    clbCommands.Clear;
    for i := 0 to CmdCount.Count - 1 do
    begin
      clbCommands.Items.Add(CmdCount[i] + ': ' + GetCommandName(CmdCount[i]));
      clbCommands.Checked[i] := True;
    end;

    // Заполняем список дат
    cbbDate.Items.Clear;
    cbbDate.Items.Add('Все');
    for i := 0 to DateList.Count - 1 do
      cbbDate.Items.Add(DateList[i]);
    cbbDate.ItemIndex := 0;

  finally
    CmdCount.Free;
    DateList.Free;
  end;

  // Сброс фильтров
  cbxCommands.Checked := True;
  for i := 0 to cbgDirectionFilter.Items.Count - 1 do
    cbgDirectionFilter.Checked[i] := True;

end;

procedure TfmMain.bbToFilterClick(Sender: TObject);
begin
  ApplyFilter;
end;

procedure TfmMain.Button1Click(Sender: TObject);
begin
  // Реализуй нужное действие кнопки
end;

procedure TfmMain.cbxCommandsClick(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to clbCommands.Count-1 do
    clbCommands.Checked[i] := cbxCommands.Checked;
end;

procedure TfmMain.FormCreate(Sender: TObject);
var
  i: Integer;
begin
  lbLog.Font.Name := GetMonospaceFontName;
  //sgDetails.Options := sgDetails.Options + [goColSizing];
  LoadCommands('commands_cmp.json');
  SetLength(FPrevColWidths, sgDetails.ColCount);
  for i := 0 to sgDetails.ColCount - 1 do
    FPrevColWidths[i] := sgDetails.ColWidths[i];
end;

procedure TfmMain.lbLogDrawItem(Control: TWinControl; Index: Integer;
  ARect: TRect; State: TOwnerDrawState);
var
  Idx: Integer;
  Entry: TLogEntry;
  s: string;
begin
  // Получаем индекс записи из Objects[Index]
  Idx := PtrInt(lbLog.Items.Objects[Index]);
  if (Idx < 0) or (Idx >= Length(FLogEntries)) then Exit;
  Entry := FLogEntries[Idx];

  // Настраиваем кисть (фон)
  if odSelected in State then
    lbLog.Canvas.Brush.Color := clHighlight
  else
    lbLog.Canvas.Brush.Color := lbLog.Color; // обычно clWindow

  // Заливаем фон всей строки
  lbLog.Canvas.FillRect(ARect);

  // Выбираем цвет текста в зависимости от направления и состояния
  if odSelected in State then
    lbLog.Canvas.Font.Color := clHighlightText
  else
    case Entry.Arrow of
      arToKKT:   lbLog.Canvas.Font.Color := clWindowText;      // чёрный/белый (системный)
      arFromKKT: lbLog.Canvas.Font.Color := RGBToColor(100, 150, 255); // светло-синий
      arError:   lbLog.Canvas.Font.Color := RGBToColor(255, 100, 100); // светло-красный
      arOther:   lbLog.Canvas.Font.Color := RGBToColor(100, 255, 100); // светло-зелёный
    end;

  // Получаем текст элемента
  s := lbLog.Items[Index];

  // Рисуем текст с вертикальным центрированием (необязательно)
  lbLog.Canvas.TextRect(ARect, ARect.Left + 2, ARect.Top + (ARect.Height - lbLog.Canvas.TextHeight(s)) div 2, s);
end;

procedure TfmMain.lbLogSelectionChange(Sender: TObject; User: boolean);
var
  i, Idx, Row: Integer;
  Entry: TLogEntry;
begin
  sgDetails.BeginUpdate;
  try
    sgDetails.RowCount := sgDetails.FixedRows;

    // Перебираем все элементы списка, проверяем выделенные
    for i := 0 to lbLog.Items.Count - 1 do
    begin
      if lbLog.Selected[i] then
      begin
        Idx := NativeInt(lbLog.Items.Objects[i]); // или PtrInt
        if (Idx >= 0) and (Idx < Length(FLogEntries)) then
        begin
          Entry := FLogEntries[Idx];

          // --- Заголовок записи ---
          Row := sgDetails.RowCount;
          sgDetails.RowCount := Row + 1;
          sgDetails.Cells[0, Row] := '--- Запись #' + IntToStr(Idx) + ' ---';
          sgDetails.Cells[1, Row] := '';

          // --- Дата ---
          if Entry.FormDate <> '' then
          begin
            Row := sgDetails.RowCount;
            sgDetails.RowCount := Row + 1;
            sgDetails.Cells[0, Row] := 'Дата';
            sgDetails.Cells[1, Row] := Entry.FormDate;
          end;

          // --- Время ---
          if Entry.Time <> '' then
          begin
            Row := sgDetails.RowCount;
            sgDetails.RowCount := Row + 1;
            sgDetails.Cells[0, Row] := 'Время';
            sgDetails.Cells[1, Row] := Entry.Time;
          end;

          // --- Направление ---
          Row := sgDetails.RowCount;
          sgDetails.RowCount := Row + 1;
          sgDetails.Cells[0, Row] := 'Направление';
          case Entry.Arrow of
            arToKKT:   sgDetails.Cells[1, Row] := 'В ККТ';
            arFromKKT: sgDetails.Cells[1, Row] := 'ИЗ ККТ';
            arError:   sgDetails.Cells[1, Row] := 'ОШИБКА';
            arOther:   sgDetails.Cells[1, Row] := 'ПРОЧЕЕ';
          end;

          // --- Код команды ---
          Row := sgDetails.RowCount;
          sgDetails.RowCount := Row + 1;
          sgDetails.Cells[0, Row] := 'Код команды';
          sgDetails.Cells[1, Row] := Entry.Cmd;

          // --- Сырые данные (если есть) ---
          if Assigned(Entry.RawData) and (Entry.RawData.Count > 0) then
          begin
            Row := sgDetails.RowCount;
            sgDetails.RowCount := Row + 1;
            sgDetails.Cells[0, Row] := 'Содержимое';
            sgDetails.Cells[1, Row] := StripControlChars(Entry.RawData.Text);
          end;

          // --- Разбор полей для команд ККТ ---
          if Entry.Arrow in [arToKKT, arFromKKT, arError] then
            AddFieldsToGrid(Entry, sgDetails);

          // --- Пустая строка-разделитель между записями ---
          Row := sgDetails.RowCount;
          sgDetails.RowCount := Row + 1;
          sgDetails.Cells[0, Row] := '';
          sgDetails.Cells[1, Row] := '';
        end;
      end;
    end;

    // --- Подгонка высоты строк ---
    AdjustRowHeights(sgDetails);
  finally
    sgDetails.EndUpdate;
  end;
end;

procedure TfmMain.AddFieldsToGrid(const Entry: TLogEntry; sg: TStringGrid);
var
  Fields: TFieldArray;
  Data: TStringList;
  k, Row: Integer;
begin
  if Entry.Arrow = arToKKT then
  begin
    if not GetSendFieldsByCode(Entry.Cmd, Fields) then Exit;
  end
  else // arFromKKT, arError
  begin
    if not GetRecvFieldsByCode(Entry.Cmd, Fields) then Exit;
  end;

  if not Assigned(Entry.RawData) or (Entry.RawData.Count = 0) then Exit;

  Data := TStringList.Create;
  try
    Data.Delimiter := #$1C;
    Data.StrictDelimiter := True;
    Data.DelimitedText := Entry.RawData.Text;

    for k := 0 to Data.Count - 2 do
    begin
      Row := sg.RowCount;
      sg.RowCount := Row + 1;
      if k < Length(Fields) then
        sg.Cells[0, Row] := Fields[k].FieldName
      else
        sg.Cells[0, Row] := 'Поле ' + IntToStr(k);
      sg.Cells[1, Row] := Data[k];
    end;
  finally
    Data.Free;
  end;
end;

procedure TfmMain.AdjustRowHeights(sg: TStringGrid);
var
  j, FirstRow, LastRow: Integer;
  r: TRect;
  Flags: Integer;
  H0, H1, MaxH: Integer;
begin
  Flags := DT_LEFT or DT_TOP or DT_WORDBREAK or DT_CALCRECT;

  // Определяем диапазон видимых строк (для производительности)
  FirstRow := sg.TopRow;
  LastRow := FirstRow + sg.VisibleRowCount - 1;
  if LastRow >= sg.RowCount then LastRow := sg.RowCount - 1;

  for j := FirstRow to LastRow do
  begin
    // Вычисляем высоту для первой колонки
    r := sg.CellRect(0, j);
    InflateRect(r, -2, -2);
    LCLIntf.DrawText(sg.Canvas.Handle, PChar(sg.Cells[0, j]), -1, r, Flags);
    H0 := r.Bottom - r.Top + 4; // небольшой запас

    // Вычисляем высоту для второй колонки
    r := sg.CellRect(1, j);
    InflateRect(r, -2, -2);
    LCLIntf.DrawText(sg.Canvas.Handle, PChar(sg.Cells[1, j]), -1, r, Flags);
    H1 := r.Bottom - r.Top + 4;

    // Берём максимальную высоту
    if H0 > H1 then MaxH := H0 else MaxH := H1;
    sg.RowHeights[j] := MaxH;
  end;
end;

procedure TfmMain.sgDetailsDrawCell(Sender: TObject; aCol, aRow: Integer;
  aRect: TRect; aState: TGridDrawState);
var
  Grid: TStringGrid;
  CellText: string;
  DrawFlags: Integer;
  NewRect, TextRect: TRect;
  OffsetX: Integer;
  IconRect: TRect;
begin
  Grid := Sender as TStringGrid;

  // --- Заливка фона ---
  if gdSelected in aState then
  begin
    Grid.Canvas.Brush.Color := clHighlight;
    Grid.Canvas.Font.Color := clHighlightText;
  end
  else
  begin
    Grid.Canvas.Brush.Color := Grid.Color;
    Grid.Canvas.Font.Color := Grid.Font.Color;
  end;
  Grid.Canvas.FillRect(aRect);

  CellText := Grid.Cells[aCol, aRow];

  // --- Если это вторая колонка и строка является заголовком записи ---
  if (aCol = 1) and (Pos('--- Запись #', Grid.Cells[0, aRow]) = 1) and Assigned(ilMain) then
  begin
    OffsetX := aRect.Left + 2;

    // Иконка с индексом 1
    IconRect := Rect(OffsetX, aRect.Top + 2,
                     OffsetX + ilMain.Width, aRect.Top + 2 + ilMain.Height);
    ilMain.Draw(Grid.Canvas, IconRect.Left, IconRect.Top, 1);
    OffsetX := OffsetX + ilMain.Width + 4;

    // Иконка с индексом 0
    IconRect := Rect(OffsetX, aRect.Top + 2,
                     OffsetX + ilMain.Width, aRect.Top + 2 + ilMain.Height);
    ilMain.Draw(Grid.Canvas, IconRect.Left, IconRect.Top, 0);

    // Если в ячейке есть ещё и текст (обычно там пусто), выводим его справа
    if CellText <> '' then
    begin
      TextRect := Rect(OffsetX + 4, aRect.Top + 2, aRect.Right - 2, aRect.Bottom - 2);
      DrawText(Grid.Canvas.Handle, PChar(CellText), -1, TextRect, DT_LEFT or DT_TOP);
    end;

    Exit;
  end;

  // --- Стандартная отрисовка для остальных ячеек ---
  if CellText = '' then Exit;

  Grid.Canvas.Font := Grid.Font;
  Grid.Canvas.Brush.Style := bsClear;

  NewRect := aRect;
  InflateRect(NewRect, -2, -2);

  DrawFlags := DT_LEFT or DT_TOP or DT_WORDBREAK;
  DrawText(Grid.Canvas.Handle, PChar(CellText), -1, NewRect, DrawFlags);
end;

procedure TfmMain.sgDetailsColumnResize(Sender: TObject; aCol, aWidth: Integer);
begin
  // Пересчитываем высоту строк, только если изменилась вторая колонка (содержащая текст)
  // или если вы хотите пересчитывать при изменении любой колонки, уберите условие.
  if aCol = 1 then
    AdjustRowHeights(sgDetails);
end;

procedure TfmMain.tmrMainTimer(Sender: TObject);
var
  i: Integer;
  WidthChanged: Boolean;
begin
  WidthChanged := False;
  // Проверяем, изменилась ли ширина любой колонки
  for i := 0 to sgDetails.ColCount - 1 do
  begin
    if sgDetails.ColWidths[i] <> FPrevColWidths[i] then
    begin
      FPrevColWidths[i] := sgDetails.ColWidths[i];
      WidthChanged := True;
    end;
  end;
  if WidthChanged then
    AdjustRowHeights(sgDetails);
end;

procedure TfmMain.ParseProgress(CurrentLine: Integer);
begin
  FCurrentLine := CurrentLine;
  if FFileTotalLines > 0 then
    pbMain.Position := Trunc((FCurrentLine / FFileTotalLines) * 100);
  Application.ProcessMessages; // для обновления интерфейса
end;

initialization
  {$I fm_main.lrs}

end.
