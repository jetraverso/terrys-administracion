# Terry's - PRUEBA: quitar un producto que ya esta en una mesa abierta de Agora
# mandando ese mismo producto con cantidad -1 (pedido de mesa, Type = Table).
#
# Muestra la mesa antes, manda el -1 y la muestra despues. Hay que mirar en el TPV:
#   1) si el producto desaparece o queda en 0 (o aparece una linea en negativo),
#   2) si imprime algo en cocina/barra (una comanda de anulacion o un "-1"),
#   3) que el total de la mesa baje.
#
#   powershell -ExecutionPolicy Bypass -File "G:\Mi unidad\Terry Admin AI\Sistema Pedidos\probar-anular.ps1" -Centro 7 -Mesa "2" -Producto 2033
#
# -Centro: 7 LOCAL, 13 TERRAZA, 12 TAKE AWAY. -Producto: codigo de Agora (2033 = PAPAS FRITAS).
# La mesa tiene que estar abierta y tener ese producto. Resultado en exploracion-mesas\probar-anular.txt

param([int]$Centro = 7, [string]$Mesa = '2', [int]$Producto = 2033)
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
$archivo = Join-Path $salida 'probar-anular.txt'
"Prueba de quitar un producto con -1 - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Set-Content $archivo -Encoding UTF8
function Anotar($t, $color = 'Gray') { Write-Host $t -ForegroundColor $color; Add-Content $archivo $t -Encoding UTF8 }

function Consulta($sql) {
  $cn = New-Object System.Data.SqlClient.SqlConnection 'Server=localhost\AGORA;Database=igtpos;Integrated Security=True;Connect Timeout=8;ApplicationIntent=ReadOnly'
  $cn.Open()
  try { $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $t = New-Object System.Data.DataTable; $t.Load($cmd.ExecuteReader()); return ,$t } finally { $cn.Close() }
}
function Mostrar($titulo) {
  Anotar "`r`n== $titulo ==" 'Cyan'
  $m = $Mesa.Replace("'", "''")
  $tk = Consulta "select Id, SaleCenterName, SaleLocationName, CreationDate from dbo.Ticket where FrozenDate is null and SaleCenterId = $Centro and SaleLocationName = N'$m'"
  if ($tk.Rows.Count -eq 0) { Anotar '(la mesa no esta abierta)'; return }
  foreach ($t in $tk) {
    Anotar "$($t.SaleCenterName) - $($t.SaleLocationName) (ticket $($t.Id))" 'White'
    foreach ($l in (Consulta "select ProductName, Quantity, TotalAmount, IsCancelled, Status, HasBeenPrinted, CreationDate from dbo.TicketLine where TicketId = $($t.Id) order by TicketLineIndex")) {
      Anotar ("    {0:0.##} x {1}  {2:0.00}  anulada={3} estado={4} {5:HH:mm:ss}" -f $l.Quantity, $l.ProductName, $l.TotalAmount, $l.IsCancelled, $l.Status, $l.CreationDate)
    }
  }
}

$centros = (Invoke-WebRequest -Uri "$base/api/export-master/?filter=SaleCenters" -Headers $H -UseBasicParsing).Content | ConvertFrom-Json
$c = $centros.SaleCenters | Where-Object { [int]$_.Id -eq $Centro } | Select-Object -First 1
if (-not $c) { Anotar "No existe el centro $Centro." 'Red'; exit 1 }
$prods = ((Invoke-WebRequest -Uri "$base/api/export-master/?filter=Products" -Headers $H -UseBasicParsing).Content | ConvertFrom-Json).Products
$pr = $prods | Where-Object { [int]$_.Id -eq $Producto } | Select-Object -First 1
if (-not $pr) { Anotar "No existe el producto $Producto." 'Red'; exit 1 }
$vats = ((Invoke-WebRequest -Uri "$base/api/export-master/?filter=Vats" -Headers $H -UseBasicParsing).Content | ConvertFrom-Json).Vats
$vat = $vats | Where-Object { [int]$_.Id -eq [int]$pr.VatId } | Select-Object -First 1
$precio = 0.0; foreach ($x in @($pr.Prices)) { if ($x -and [int]$x.PriceListId -eq [int]$opc.tarifaId) { $precio = [double]$x.MainPrice } }

Mostrar 'Antes'

$ahora = Get-Date; $fecha = $ahora.ToString('yyyy-MM-ddTHH:mm:ss')
$neto = [math]::Round(-$precio / (1 + [double]$vat.VatRate), 2)
$linea = [ordered]@{
  Index = 0; CreationDate = $fecha; Type = 'Standard'; ParentIndex = $null
  ProductId = [int]$pr.Id; ProductName = $pr.Name; SaleFormatId = [int]$pr.BaseSaleFormatId; SaleFormatName = $pr.Name; SaleFormatRatio = 1.0
  MainBarcode = ''; ProductPrice = $precio; VatId = [int]$pr.VatId; VatRate = [double]$vat.VatRate; SurchargeRate = [double]$vat.SurchargeRate
  ProductCostPrice = 0.0; MenuGroup = ''; PreparationTypeId = $pr.PreparationTypeId; PreparationTypeName = ''; PLU = ''
  FamilyId = $pr.FamilyId; FamilyName = ''; PreparationOrderId = $pr.PreparationOrderId; PreparationOrderName = ''
  Quantity = -1.0; UnitCostPrice = 0.0; TotalCostPrice = 0.0; UserId = [int]$opc.usuarioId; UnitPrice = $precio
  DiscountRate = 0.0; CashDiscount = 0.0; OfferId = $null; OfferCode = ''; TotalAmount = -$precio; PriceListId = [int]$opc.tarifaId
}
$num = 99500 + (Get-Random -Minimum 0 -Maximum 400)
$pedido = [ordered]@{
  Serie = [string]$opc.serie; Number = $num; Type = 'Table'; DeliveryDate = $ahora.ToString('yyyy-MM-ddTHH:mm:00'); Status = 'Pending'
  Customer = [ordered]@{ Id = [long]$opc.clienteId; FiscalName = "PRUEBA QUITAR - $Mesa"; Cif = ''; Street = ''; City = ''; Region = ''; ZipCode = ''; ApplySurcharge = $false; CountryCode = 'ES'; AccountCode = '' }
  DeliveryAddress = [ordered]@{ Street = ''; City = ''; Region = ''; ZipCode = '' }
  Pos = [ordered]@{ Id = [int]$opc.posId; Name = [string]$opc.posNombre }
  Workplace = [ordered]@{ Id = [int]$opc.localId; Name = [string]$opc.localNombre }
  User = [ordered]@{ Id = [int]$opc.usuarioId; Name = [string]$opc.usuarioNombre }
  SaleCenter = [ordered]@{ Id = [int]$c.Id; Name = [string]$c.Name; Location = $Mesa }
  GlobalId = [guid]::NewGuid().ToString(); BusinessDay = $ahora.ToString('yyyy-MM-dd'); Guests = $null; Date = $fecha
  ServiceCharge = [ordered]@{ Rate = 0.0; VatId = 1; VatRate = 0.0; SurchargeRate = 0.0; ApplyToVatIncluded = $true; IgnoreTicketDiscounts = $false; GrossAmount = 0.0; NetAmount = 0.0; VatAmount = 0.0; SurchargeAmount = 0.0 }
  Lines = @($linea)
  Discounts = [ordered]@{ DiscountRate = 0.0; CashDiscount = 0.0 }; Payments = @(); Offers = @(); VatIncluded = $true
  Totals = [ordered]@{ GrossAmount = -$precio; NetAmount = $neto; VatAmount = [math]::Round(-$precio - $neto, 2); SurchargeAmount = 0.0
    Taxes = @([ordered]@{ VatRate = [double]$vat.VatRate; SurchargeRate = [double]$vat.SurchargeRate; GrossAmount = -$precio; NetAmount = $neto; VatAmount = [math]::Round(-$precio - $neto, 2); SurchargeAmount = 0.0 }) }
  ScheduledPreparation = $false
}
$json = @{ SalesOrders = @($pedido) } | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText((Join-Path $salida 'probar-anular.json'), $json, [Text.Encoding]::UTF8)
try {
  Invoke-WebRequest -Uri "$base/api/import/" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -Headers $H -UseBasicParsing -TimeoutSec 60 | Out-Null
  Anotar "`r`nMANDADO: -1 x $($pr.Name) a $($c.Name) - $Mesa (WEB-$num)." 'Green'
} catch {
  $t = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
  Anotar "`r`nAGORA LO RECHAZO: $($t -replace '\s+', ' ')" 'Red'
}
Start-Sleep -Seconds 5
Mostrar 'Despues'
Anotar "`r`nMira en el TPV como quedo la mesa y si imprimio algo, y avisale a Claude." 'Yellow'
