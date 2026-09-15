unit DataModule;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser;

type
  TFieldInfo = record
    FieldName: string;
    FieldType: string;
    Length: string;
    Conversion: string; // может быть именем справочника или JSON-строкой словаря
  end;

  TFieldArray = array of TFieldInfo;

  PCommandInfo = ^TCommandInfo;
  TCommandInfo = record
    Name: string;
    SendFields: TFieldArray;
    RecvFields: TFieldArray;
  end;

var
  AllCommands: TStringList; // ключ – код команды (2 символа), объект – PCommandInfo

procedure LoadCommands(const AFileName: string);
function GetCommandName(const ACmd: string): string;
function GetSendFieldsByCode(const CmdCode: string; var Fields: TFieldArray): Boolean;
function GetRecvFieldsByCode(const CmdCode: string; var Fields: TFieldArray): Boolean;

procedure FreeCommands;

implementation

uses
  LazUTF8, LConvEncoding;

function ReadFileAsUTF8(const AFileName: string): string;
var
  Stream: TFileStream;
  Buffer: TBytes;
  Size: Int64;
begin
  Result := '';
  if not FileExists(AFileName) then Exit;
  Stream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    Size := Stream.Size;
    if Size = 0 then Exit;
    SetLength(Buffer, Size);
    Stream.Read(Buffer[0], Size);
    // Удаляем BOM, если есть
    if (Size >= 3) and (Buffer[0] = $EF) and (Buffer[1] = $BB) and (Buffer[2] = $BF) then
      SetString(Result, PAnsiChar(@Buffer[3]), Size - 3)
    else
      SetString(Result, PAnsiChar(@Buffer[0]), Size);
  finally
    Stream.Free;
  end;
end;

procedure ParseFields(FieldsNode: TJSONArray; var Target: TFieldArray);
var
  k: Integer;
  FieldArray: TJSONArray;
  Item: TJSONData;
begin
  SetLength(Target, FieldsNode.Count);
  for k := 0 to FieldsNode.Count - 1 do
  begin
    Item := FieldsNode.Items[k];
    if not (Item is TJSONArray) then
    begin
      // Если элемент не массив, пропускаем (можно записать в лог)
      Continue;
    end;
    FieldArray := TJSONArray(Item);
    if FieldArray.Count < 4 then Continue;

    // Поле FieldName (индекс 0) – может быть строкой или объектом
    if FieldArray.Items[0].JSONType = jtString then
      Target[k].FieldName := FieldArray.Items[0].AsString
    else
      Target[k].FieldName := FieldArray.Items[0].AsJSON; // сохраняем как JSON-строку

    // FieldType (индекс 1) – ожидаем строку
    if FieldArray.Items[1].JSONType = jtString then
      Target[k].FieldType := FieldArray.Items[1].AsString
    else
      Target[k].FieldType := FieldArray.Items[1].AsJSON; // на всякий случай

    // Length (индекс 2) – может быть строкой или объектом
    if FieldArray.Items[2].JSONType = jtString then
      Target[k].Length := FieldArray.Items[2].AsString
    else
      Target[k].Length := FieldArray.Items[2].AsJSON;

    // Conversion (индекс 3) – может быть строкой, объектом или чем-то ещё
    case FieldArray.Items[3].JSONType of
      jtString: Target[k].Conversion := FieldArray.Items[3].AsString;
      jtObject: Target[k].Conversion := FieldArray.Items[3].AsJSON;
    else
      Target[k].Conversion := '';
    end;
  end;
end;

procedure LoadCommands(const AFileName: string);
var
  JSONData: TJSONData = nil;
  JSONObject: TJSONObject;
  JSONArray: TJSONArray;
  CmdCode: string;
  P: PCommandInfo;
  i: Integer;
  FileContent: string;
begin
  FreeCommands;
  AllCommands := TStringList.Create;
  AllCommands.Sorted := True;
  AllCommands.Duplicates := dupIgnore;

  if not FileExists(AFileName) then
  begin
    // Можно показать предупреждение
    Exit;
  end;

  // Читаем файл как UTF-8 строку
  FileContent := ReadFileAsUTF8(AFileName);
  if FileContent = '' then Exit;

  // Парсим JSON с обработкой ошибок
  try
    JSONData := GetJSON(FileContent);
  except
    on E: Exception do
    begin
      WriteLn('Ошибка при разборе JSON: ' + E.Message + #13#10 +
                  'Начало файла: ' + Copy(FileContent, 1, 500));
      Exit;
    end;
  end;

  if JSONData = nil then
  begin
    WriteLn('JSONData = nil');
    Exit;
  end;

  try
    if JSONData.JSONType <> jtObject then
    begin
      WriteLn('Корневой элемент не является объектом');
      Exit;
    end;
    JSONObject := JSONData as TJSONObject;

    for i := 0 to JSONObject.Count - 1 do
    begin
      CmdCode := JSONObject.Names[i];
      // Проверяем, что значение – объект
      if JSONObject.Items[i].JSONType <> jtObject then Continue;

      New(P);
      FillChar(P^, SizeOf(TCommandInfo), 0);

      // Имя команды
      P^.Name := JSONObject.Objects[CmdCode].Get('name', '');

      // Send-поля
      if JSONObject.Objects[CmdCode].Find('send') <> nil then
      begin
        JSONArray := JSONObject.Objects[CmdCode].Arrays['send'];
        if Assigned(JSONArray) and (JSONArray.JSONType = jtArray) then
          ParseFields(JSONArray, P^.SendFields);
      end;

      // Recv-поля
      if JSONObject.Objects[CmdCode].Find('recv') <> nil then
      begin
        JSONArray := JSONObject.Objects[CmdCode].Arrays['recv'];
        if Assigned(JSONArray) and (JSONArray.JSONType = jtArray) then
          ParseFields(JSONArray, P^.RecvFields);
      end;

      AllCommands.AddObject(CmdCode, TObject(P));
    end;
  finally
    JSONData.Free;
  end;
end;

function GetCommandName(const ACmd: string): string;
var
  Idx: Integer;
begin
  Result := 'Прочее...';
  if ACmd = '00' then
    Exit;
  if not Assigned(AllCommands) then
  begin
    Result := 'Список команд не загружен';
    Exit;
  end;
  Idx := AllCommands.IndexOf(ACmd);
  if Idx >= 0 then
    Result := PCommandInfo(AllCommands.Objects[Idx])^.Name
  else
    Result := 'Неизвестная команда';
end;

function GetSendFieldsByCode(const CmdCode: string; var Fields: TFieldArray): Boolean;
var
  Idx: Integer;
  CmdInfo: PCommandInfo; // Указатель на структуру
begin
  Result := False;

  // Проверяем существование команды
  Idx := AllCommands.IndexOf(CmdCode);
  if Idx = -1 then
    Exit;

  // Получаем указатель на структуру команды
  CmdInfo := PCommandInfo(AllCommands.Objects[Idx]);

  // Копируем массив полей
  Fields := CmdInfo^.SendFields;

  Result := True;
end;

function GetRecvFieldsByCode(const CmdCode: string; var Fields: TFieldArray): Boolean;
var
  Idx: Integer;
  CmdInfo: PCommandInfo; // Указатель на структуру
begin
  Result := False;

  // Проверяем существование команды
  Idx := AllCommands.IndexOf(CmdCode);
  if Idx = -1 then
    Exit;

  // Получаем указатель на структуру команды
  CmdInfo := PCommandInfo(AllCommands.Objects[Idx]);

  // Копируем массив полей
  Fields := CmdInfo^.RecvFields;

  Result := True;
end;

procedure FreeCommands;
var
  i: Integer;
begin
  if Assigned(AllCommands) then
  begin
    for i := 0 to AllCommands.Count - 1 do
      if AllCommands.Objects[i] <> nil then
        Dispose(PCommandInfo(AllCommands.Objects[i]));
    FreeAndNil(AllCommands);
  end;
end;

initialization
  AllCommands := nil;

finalization
  FreeCommands;

end.
