unit Parser;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, lconvencoding, StrUtils;

const
  STX = #2;   // символ STX в CP866 (в строке UTF-8 это будет один символ, но лучше сравнивать по коду)
  ETX = #3;
  FS = #28;

  DateCmds: array[0..6] of string = ('01','02','03','10','30','31','34');

type
  TArrow = (arToKKT, arFromKKT, arError, arOther);

  TLogEntry = record
    LineIndex: Integer;   // Индекс записи
    FormDate: string;     // Дата в формате дд.мм.гг
    Time: string;         // Время в формате чч:мм:сс
    Arrow: TArrow;        // Тип записи, так повелось, что это направвление, но это тип
    Cmd: string[2];       // Код команды в формате HEX - один байт
    RawData: TStringList; // Сырые данные
  end;

  TLogEntryArray = array of TLogEntry;

  // Объявляем процедурный тип для колбэка обновления прогресса
  TProgressCallback = procedure(CurrentLine: Integer) of object;

// Добавлен необязательный параметр ProgressCallback для обновления прогресса
function ParseLogFile(const AFileName: string; var Entries: TLogEntryArray; ProgressCallback: TProgressCallback = nil): Boolean;

implementation

uses
  LazUTF8;


function ArrowFromStr(const S: string): TArrow;
begin
  if Pos('T ->', S) > 0 then Result := arToKKT
  else if Pos('R <-', S) > 0 then Result := arFromKKT
  else Result := arOther;
end;

function ParseLogFile(const AFileName: string; var Entries: TLogEntryArray; ProgressCallback: TProgressCallback): Boolean;
var
  F: TextFile;
  Line: string;
  CurrentDate: string;
  RawBytes: TBytes;
  UTF8Line: string;
  i: Integer;
  Entry: TLogEntry;
  Arrow: TArrow;
  Cmd: string;
  SpamBuffer: TStringList;
  SpamCounter: Integer;
  LineNumber: Integer; // Номер текущей строки
  procedure AddSpam;
  begin
    if SpamCounter > 0 then
    begin
      Entry.LineIndex := Length(Entries);
      Entry.FormDate := CurrentDate;
      Entry.Time := Copy(SpamBuffer[0], 1, 8);
      Entry.Arrow := arOther;
      Entry.Cmd := '00';
      Entry.RawData := TStringList.Create;
      Entry.RawData.Assign(SpamBuffer);
      SetLength(Entries, Length(Entries)+1);
      Entries[High(Entries)] := Entry;
      SpamBuffer.Clear;
      SpamCounter := 0;
    end;
  end;
begin
  CurrentDate:= '000000';
  Result := False;
  SetLength(Entries, 0);
  SpamBuffer := TStringList.Create;
  SpamCounter := 0;
  LineNumber := 0; // Начальный номер строки

  AssignFile(F, AFileName);
  {$I-}
  Reset(F);
  {$I+}
  if IOResult <> 0 then Exit;

  while not EOF(F) do
  begin
    Readln(F, Line);  // Line в кодировке файла (скорее всего CP866)
    Inc(LineNumber); // Увеличиваем счётчик строк

    // Преобразуем в UTF-8
    UTF8Line := ConvertEncoding(Line, 'cp866', 'utf8');

    // Ищем признаки начала команды: длина >18 и 18-й символ = STX
    if (Length(UTF8Line) > 18) and (UTF8Line[18] = STX) then
    begin
      // Сначала добавим накопленный спам
      AddSpam;

      // Парсим команду
      Arrow := ArrowFromStr(UTF8Line);
      // Извлекаем код команды (зависит от формата, упрощённо)
      // Например, ищем STX и берём следующие 2 символа
      i := Pos(STX, UTF8Line);
      if i > 0 then
      begin
        if Arrow = arToKKT then
        begin
          Cmd := Copy(UTF8Line, i+6, 2);
          if IndexStr(cmd, DateCmds) >= 0 then
            CurrentDate:= Copy(UTF8Line, i+9, 2) + '.' + Copy(UTF8Line, i+11, 2) + '.' + Copy(UTF8Line, i+13, 2)
        end
        else
        begin
          Cmd := Copy(UTF8Line, i+2, 2);
          Writeln(Copy(UTF8Line, i+13, 4));
          if Copy(UTF8Line, i+13, 4) <> '0000' then
            Arrow := arError;
        end;
      end
      else
        Cmd := 'FF';

      // Создаём запись
      Entry.LineIndex := Length(Entries);
      // Попытка выделить дату и время (в реальности нужно парсить строку)
      // В упрощении можно взять начало строки до пробела
      Entry.Time := Copy(UTF8Line, 1, 8); // пример: "12:34:56"
      Entry.FormDate := CurrentDate;
      Entry.Arrow := Arrow;
      Entry.Cmd := Cmd;
      Entry.RawData := TStringList.Create;
      Entry.RawData.Add(UTF8Line); // сохраняем всю строку

      SetLength(Entries, Length(Entries)+1);
      Entries[High(Entries)] := Entry;
    end
    else
    begin
      // Это спам — копим
      SpamBuffer.Add(UTF8Line);
      Inc(SpamCounter);
    end;

    // Вызываем колбек для обновления прогресса каждые 100 строк
    if Assigned(ProgressCallback) and ((LineNumber mod 100) = 0) then
      ProgressCallback(LineNumber); // Вызываем колбек
  end;

  // Добавляем оставшийся спам
  AddSpam;

  CloseFile(F);
  SpamBuffer.Free;
  Result := True;
end;

end.
