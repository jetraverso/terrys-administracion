# Terry's - averigua que estados (Status) acepta Agora en un pedido, SIN CREAR NINGUNO.
#
# Manda el pedido COMPLETO a la serie P, que esta en uso: ahi Agora solo acepta pedidos
# cancelados, asi que ninguno se puede guardar. Si el estado existe, contesta "serie en uso";
# si no existe, contesta otro error. "NoExiste123" es el control (tiene que salir distinto).
# No se prueba Cancelled (ese si se guardaria).
#   powershell -ExecutionPolicy Bypass -File .\estados-pedido.ps1

$ErrorActionPreference = 'Stop'
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
$rutaConfig = Join-Path $carpeta 'config.json'
if (-not (Test-Path $rutaConfig)) { $rutaConfig = Join-Path $env:USERPROFILE 'Documents\Terrys Admin\config.json' }
$cfg = Get-Content $rutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$base = ([uri]$cfg.agoraExport).GetLeftPart([UriPartial]::Authority)
$salida = Join-Path $carpeta 'exploracion'
New-Item -ItemType Directory -Force -Path $salida | Out-Null
$H = @{ 'Api-Token' = $cfg.agoraToken }
$res = Join-Path $salida 'estados-validos.txt'
"Estados de pedido v2 - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Set-Content $res -Encoding UTF8
Write-Host "estados-pedido v2"

$series = (Invoke-WebRequest -Uri "$base/api/export-master/?filter=Series" -Headers $H -UseBasicParsing).Content | ConvertFrom-Json
$numP = [int](($series.Series | Where-Object { $_.Name -eq 'P' } | Select-Object -First 1).LastNumber) + 1
$ahora = Get-Date; $hoy = $ahora.ToString('yyyy-MM-dd'); $fecha = $ahora.ToString('yyyy-MM-ddTHH:mm:ss')
$entrega = $ahora.AddMinutes(30).ToString('yyyy-MM-ddTHH:mm:00')

$candidatos = 'NoExiste123','Pending','Accepted','Confirmed','Requested','Received','New','Open','Started',
  'InPreparation','Preparing','PendingPreparation','Preparation','Cooking','InProgress','Processing','InKitchen',
  'Prepared','Ready','ReadyToDeliver','ReadyForPickup','Delivering','OnTheWay','Sent','Shipped','InDelivery',
  'Delivered','PickedUp','Finished','Completed','Closed','Invoiced','Rejected'

foreach ($st in $candidatos) {
  $pedido = [ordered]@{
    Serie = 'P'; Number = $numP; Type = 'TakeAway'; DeliveryDate = $entrega; Status = $st
    Customer = [ordered]@{ Id = 1000000312; FiscalName = 'PRUEBA WEB'; Cif = ''; Street = ''; City = ''; Region = ''; ZipCode = ''; ApplySurcharge = $false; CountryCode = 'ES'; AccountCode = '' }
    DeliveryAddress = [ordered]@{ Street = ''; City = ''; Region = ''; ZipCode = '' }
    Pos = [ordered]@{ Id = 1; Name = 'TPV' }; Workplace = [ordered]@{ Id = 1; Name = 'TERRYS BURGERS' }
    User = [ordered]@{ Id = 1018; Name = '1' }; SaleCenter = [ordered]@{ Id = 12; Name = 'TAKE AWAY'; Location = 'Take away' }
    GlobalId = [guid]::NewGuid().ToString(); BusinessDay = $hoy; Guests = $null; Date = $fecha
    ServiceCharge = [ordered]@{ Rate = 0.0; VatId = 1; VatRate = 0.0; SurchargeRate = 0.0; ApplyToVatIncluded = $true; IgnoreTicketDiscounts = $false; GrossAmount = 0.0; NetAmount = 0.0; VatAmount = 0.0; SurchargeAmount = 0.0 }
    Lines = @([ordered]@{
      Index = 0; CreationDate = $fecha; Type = 'Standard'; ParentIndex = $null
      ProductId = 2093; ProductName = 'COCA COLA 350ML'; SaleFormatId = 2338; SaleFormatName = 'COCA COLA 350ML'; SaleFormatRatio = 1.0
      MainBarcode = ''; ProductPrice = 2.5; VatId = 3; VatRate = 0.1; SurchargeRate = 0.014; ProductCostPrice = 0.773
      MenuGroup = ''; PreparationTypeId = 26; PreparationTypeName = 'Barra / Bebidas'; PLU = ''
      FamilyId = 59; FamilyName = 'BEBIDA'; PreparationOrderId = 1; PreparationOrderName = 'Bebidas'
      Quantity = 1.0; UnitCostPrice = 0.773; TotalCostPrice = 0.773; UserId = 1018; UnitPrice = 2.5
      DiscountRate = 0.0; CashDiscount = 0.0; OfferId = $null; OfferCode = ''; TotalAmount = 2.5; PriceListId = 2 })
    Discounts = [ordered]@{ DiscountRate = 0.0; CashDiscount = 0.0 }
    Payments = @(); Offers = @(); VatIncluded = $true
    Totals = [ordered]@{ GrossAmount = 2.5; NetAmount = 2.27; VatAmount = 0.23; SurchargeAmount = 0.0
      Taxes = @([ordered]@{ VatRate = 0.1; SurchargeRate = 0.014; GrossAmount = 2.5; NetAmount = 2.27; VatAmount = 0.23; SurchargeAmount = 0.0 }) }
    ScheduledPreparation = $false
  }
  $json = @{ SalesOrders = @($pedido) } | ConvertTo-Json -Depth 10
  $msg = ''
  try {
    $r = Invoke-WebRequest -Uri "$base/api/import/" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -Headers $H -UseBasicParsing -TimeoutSec 30
    $msg = "200 (!) $($r.Content)"
  } catch {
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $_.ErrorDetails.Message } else { $msg = $_.Exception.Message }
  }
  $msg = $msg -replace '\s+', ' '
  $veredicto = if ($msg -match 'serie est. en uso') { 'EXISTE' } elseif ($msg -match '200 \(!\)') { 'SE GUARDO (!)' } else { 'no' }
  $linea = "{0,-20} {1,-14} {2}" -f $st, $veredicto, $msg
  if ($linea.Length -gt 240) { $linea = $linea.Substring(0, 240) }
  Write-Host $linea
  Add-Content $res $linea -Encoding UTF8
  if ($veredicto -eq 'SE GUARDO (!)') { Write-Host "Se guardo un pedido en la serie P (no deberia). Me freno; anulalo en el TPV." -ForegroundColor Red; break }
}
Write-Host "`r`nListo. Claude lo lee de exploracion\estados-validos.txt" -ForegroundColor Green
