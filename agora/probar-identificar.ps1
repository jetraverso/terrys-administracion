# Terry's - PRUEBA: con que campo del pedido importado Agora pone la "identificacion" del ticket
# (lo que en el TPV se hace con "Identificar ticket" y sale en la pantalla de cocina).
#
# 1) Sin -Enviar: solo muestra como estan identificadas las mesas abiertas de TAKE AWAY
#    (para ver el formato que pusiste a mano con "Identificar ticket").
# 2) Con -Enviar: manda a una mesa libre de TAKE AWAY 1 producto de prueba (por defecto 2033 = PAPAS FRITAS)
#    con varios campos candidatos, cada uno con un texto distinto (ID-A, ID-B, ...), y despues lee de la
#    base de Agora que identificacion quedo. Al terminar: anular esa mesa en el TPV.
#
#   powershell -ExecutionPolicy Bypass -File "G:\Mi unidad\Terry Admin AI\Sistema Pedidos\probar-identificar.ps1"
#   powershell -ExecutionPolicy Bypass -File "G:\Mi unidad\Terry Admin AI\Sistema Pedidos\probar-identificar.ps1" -Enviar
#
# Resultado en exploracion-mesas\probar-identificar.txt

param([switch]$Enviar, [int]$Producto = 2033)
$ErrorActionPreference = 'Stop'
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
$rutaConfig = Join-Path $carpeta 'config.json'
if (-not (Test-Path $rutaConfig)) { $rutaConfig = Join-Path $env:USERPROFILE 'Documents\Terrys Admin\config.json' }
$cfg = Get-Content $rutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$opc = Get-Content (Join-Path $carpeta 'pedidos-agora.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$base = ([uri]$cfg.agoraExport).GetLeftPart([UriPartial]::Authority)
$H = @{ 'Api-Token' = $cfg.agoraToken }
$salida = Join-Path $carpeta 'exploracion-mesas'
New-Item -ItemType Directory -Force -Path $salida | Out-Null
$archivo = Join-Path $salida 'probar-identificar.txt'
"Prueba de identificacion del ticket - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Set-Content $archivo -Encoding UTF8
function Anotar($t, $color = 'Gray') { Write-Host $t -ForegroundColor $color; Add-Content $archivo $t -Encoding UTF8 }
function Consulta($sql) {
  $cn = New-Object System.Data.SqlClient.SqlConnection 'Server=localhost\AGORA;Database=igtpos;Integrated Security=True;Connect Timeout=8;ApplicationIntent=ReadOnly'
  $cn.Open()
  try { $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $t = New-Object System.Data.DataTable; $t.Load($cmd.ExecuteReader()); return ,$t } finally { $cn.Close() }
}
$centro = [int]$opc.centroId
function Mostrar($titulo) {
  Anotar "`r`n== $titulo ==" 'Cyan'
  $tk = Consulta "select Id, SaleLocationName, FriendlyName, CustomerFiscalName, PreparationNumber, CreationDate from dbo.Ticket where FrozenDate is null and CreationDate > dateadd(day, -2, getdate()) and SaleCenterId = $centro order by Id"
  if ($tk.Rows.Count -eq 0) { Anotar '(no hay mesas abiertas de TAKE AWAY)' }
  foreach ($t in $tk.Rows) {
    Anotar ("  ticket {0} | mesa '{1}' | identificacion '{2}' | cliente '{3}' | #{4} | {5:HH:mm}" -f $t.Id, $t.SaleLocationName, $t.FriendlyName, $t.CustomerFiscalName, $t.PreparationNumber, $t.CreationDate) 'White'
  }
}

Mostrar 'Mesas abiertas de TAKE AWAY (antes)'
if (-not $Enviar) { Anotar "`r`nNo se mando nada. Para la prueba agrega -Enviar." 'Yellow'; exit 0 }

# mesa libre
$ubs = Consulta "select Name from dbo.SaleLocation where SaleCenterId = $centro order by SaleLocationIndex"
$ocup = @(foreach ($r in (Consulta "select SaleLocationName from dbo.Ticket where FrozenDate is null and CreationDate > dateadd(day, -2, getdate()) and SaleCenterId = $centro").Rows) { ([string]$r.SaleLocationName).ToLower() })
$mesa = $null
foreach ($r in $ubs.Rows) { if ($ocup -notcontains ([string]$r.Name).ToLower()) { $mesa = [string]$r.Name; break } }
if (-not $mesa) { Anotar 'No hay ninguna mesa libre de TAKE AWAY.' 'Red'; exit 1 }

$prods = ((Invoke-WebRequest -Uri "$base/api/export-master/?filter=Products" -Headers $H -UseBasicParsing).Content | ConvertFrom-Json).Products
$pr = $prods | Where-Object { [int]$_.Id -eq $Producto } | Select-Object -First 1
if (-not $pr) { Anotar "No existe el producto $Producto." 'Red'; exit 1 }
$vats = ((Invoke-WebRequest -Uri "$base/api/export-master/?filter=Vats" -Headers $H -UseBasicParsing).Content | ConvertFrom-Json).Vats
$vat = $vats | Where-Object { [int]$_.Id -eq [int]$pr.VatId } | Select-Object -First 1
$precio = 0.0; foreach ($x in @($pr.Prices)) { if ($x -and [int]$x.PriceListId -eq [int]$opc.tarifaId) { $precio = [double]$x.MainPrice } }
$ahora = Get-Date; $fecha = $ahora.ToString('yyyy-MM-ddTHH:mm:ss')
$neto = [math]::Round($precio / (1 + [double]$vat.VatRate), 2)
$linea = [ordered]@{
  Index = 0; CreationDate = $fecha; Type = 'Standard'; ParentIndex = $null
  ProductId = [int]$pr.Id; ProductName = $pr.Name; SaleFormatId = [int]$pr.BaseSaleFormatId; SaleFormatName = $pr.Name; SaleFormatRatio = 1.0
  MainBarcode = ''; ProductPrice = $precio; VatId = [int]$pr.VatId; VatRate = [double]$vat.VatRate; SurchargeRate = [double]$vat.SurchargeRate
  ProductCostPrice = 0.0; MenuGroup = ''; PreparationTypeId = $pr.PreparationTypeId; PreparationTypeName = ''; PLU = ''
  FamilyId = $pr.FamilyId; FamilyName = ''; PreparationOrderId = $pr.PreparationOrderId; PreparationOrderName = ''
  Quantity = 1.0; UnitCostPrice = 0.0; TotalCostPrice = 0.0; UserId = [int]$opc.usuarioId; UnitPrice = $precio
  DiscountRate = 0.0; CashDiscount = 0.0; OfferId = $null; OfferCode = ''; TotalAmount = $precio; PriceListId = [int]$opc.tarifaId
}
$num = 99000 + (Get-Random -Minimum 0 -Maximum 400)
# campos candidatos: cada uno con su letra, para saber cual tomo Agora
$pedido = [ordered]@{
  Serie = [string]$opc.serie; Number = $num; Type = 'Table'; DeliveryDate = $ahora.ToString('yyyy-MM-ddTHH:mm:00'); Status = 'Pending'
  Customer = [ordered]@{ Id = [long]$opc.clienteId; FiscalName = 'PRUEBA IDENTIFICAR (anular)'; Cif = ''; Street = ''; City = ''; Region = ''; ZipCode = ''; ApplySurcharge = $false; CountryCode = 'ES'; AccountCode = '' }
  DeliveryAddress = [ordered]@{ Street = ''; City = ''; Region = ''; ZipCode = '' }
  Pos = [ordered]@{ Id = [int]$opc.posId; Name = [string]$opc.posNombre }
  Workplace = [ordered]@{ Id = [int]$opc.localId; Name = [string]$opc.localNombre }
  User = [ordered]@{ Id = [int]$opc.usuarioId; Name = [string]$opc.usuarioNombre }
  SaleCenter = [ordered]@{ Id = $centro; Name = [string]$opc.centroNombre; Location = $mesa; FriendlyName = 'ID-B'; LocationFriendlyName = 'ID-C'; Alias = 'ID-D' }
  GlobalId = [guid]::NewGuid().ToString(); BusinessDay = $ahora.ToString('yyyy-MM-dd'); Guests = $null; Date = $fecha
  ServiceCharge = [ordered]@{ Rate = 0.0; VatId = 1; VatRate = 0.0; SurchargeRate = 0.0; ApplyToVatIncluded = $true; IgnoreTicketDiscounts = $false; GrossAmount = 0.0; NetAmount = 0.0; VatAmount = 0.0; SurchargeAmount = 0.0 }
  Lines = @($linea)
  Discounts = [ordered]@{ DiscountRate = 0.0; CashDiscount = 0.0 }; Payments = @(); Offers = @(); VatIncluded = $true
  Totals = [ordered]@{ GrossAmount = $precio; NetAmount = $neto; VatAmount = [math]::Round($precio - $neto, 2); SurchargeAmount = 0.0
    Taxes = @([ordered]@{ VatRate = [double]$vat.VatRate; SurchargeRate = [double]$vat.SurchargeRate; GrossAmount = $precio; NetAmount = $neto; VatAmount = [math]::Round($precio - $neto, 2); SurchargeAmount = 0.0 }) }
  ScheduledPreparation = $false
  FriendlyName = 'ID-A'; TicketFriendlyName = 'ID-E'; Alias = 'ID-F'; Name = 'ID-G'; Description = 'ID-H'; Reference = 'ID-I'
  Identifier = 'ID-J'; Comments = 'ID-K'; Notes = 'ID-L'; Label = 'ID-M'
}
$json = @{ SalesOrders = @($pedido) } | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText((Join-Path $salida 'probar-identificar.json'), $json, [Text.Encoding]::UTF8)
try {
  Invoke-WebRequest -Uri "$base/api/import/" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -Headers $H -UseBasicParsing -TimeoutSec 60 | Out-Null
  Anotar "`r`nMANDADO: 1 x $($pr.Name) a TAKE AWAY - $mesa ($($opc.serie)-$num)." 'Green'
} catch {
  $t = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
  Anotar "`r`nAGORA LO RECHAZO: $($t -replace '\s+', ' ')" 'Red'
  exit 1
}
Start-Sleep -Seconds 5
Mostrar 'Mesas abiertas de TAKE AWAY (despues)'
Anotar "`r`nFijate tambien que dice la pantalla de cocina. Despues anula esa mesa en el TPV y avisale a Claude." 'Yellow'
