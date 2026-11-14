# Terry's - PRUEBA: pedido de terraza a una mesa de Agora (centro TERRAZA, Id 13).
#
# Paso 1 (siempre, no carga nada visible): prueba que "Type" acepta Agora para un pedido de mesa,
#   mandando pedidos ANULADOS (Cancelled) con numeros de prueba nuevos (99100 en adelante).
# Paso 2 (solo con -Enviar): manda UN pedido real de 1 Coca-Cola a la mesa (MESA 10 por defecto),
#   a nombre de "PRUEBA MESA (anular)", con el primer Type aceptado.
#   Despues hay que mirar en el TPV si imprimio, si va a la pantalla de cocina/barra y si aparece en la mesa.
#
#   powershell -ExecutionPolicy Bypass -File .\probar-mesa.ps1
#   powershell -ExecutionPolicy Bypass -File .\probar-mesa.ps1 -Enviar
#   powershell -ExecutionPolicy Bypass -File .\probar-mesa.ps1 -Enviar -Mesa "MESA 9" -Tipo Table -Numero 99021

param([switch]$Enviar, [string]$Mesa = 'MESA 10', [string]$Tipo = '', [int]$Numero = 0, [string]$Estado = 'Pending')
$ErrorActionPreference = 'Stop'
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
$rutaConfig = Join-Path $carpeta 'config.json'
if (-not (Test-Path $rutaConfig)) { $rutaConfig = Join-Path $env:USERPROFILE 'Documents\Terrys Admin\config.json' }
$cfg = Get-Content $rutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$base = ([uri]$cfg.agoraExport).GetLeftPart([UriPartial]::Authority)
$salida = Join-Path $carpeta 'exploracion'
New-Item -ItemType Directory -Force -Path $salida | Out-Null
$H = @{ 'Api-Token' = $cfg.agoraToken }
$opc = Get-Content (Join-Path $carpeta 'pedidos-agora.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$informe = @("Prueba de pedido a mesa - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
function Anotar($t, $color = 'Gray') { Write-Host $t -ForegroundColor $color; $script:informe += $t }

# Centro TERRAZA y sus mesas, tal como estan en Agora
$centros = (Invoke-WebRequest -Uri "$base/api/export-master/?filter=SaleCenters" -Headers $H -UseBasicParsing).Content | ConvertFrom-Json
$terraza = $centros.SaleCenters | ForEach-Object { $_ } | Where-Object { -not $_.DeletionDate -and $_.Name -eq 'TERRAZA' } | Select-Object -First 1
if (-not $terraza) { Anotar 'No encontre el centro de venta TERRAZA activo.' 'Red'; exit 1 }
$mesas = @($terraza.SaleLocations | ForEach-Object { $_.Name })
Anotar "Centro TERRAZA Id $($terraza.Id), tarifa $($terraza.PriceListId), mesas: $($mesas -join ', ')"
if ($mesas -notcontains $Mesa) { Anotar "La mesa '$Mesa' no existe en TERRAZA." 'Red'; exit 1 }

$ahora = Get-Date
$hoy = $ahora.ToString('yyyy-MM-dd'); $fecha = $ahora.ToString('yyyy-MM-ddTHH:mm:ss')
$linea = [ordered]@{
  Index = 0; CreationDate = $fecha; Type = 'Standard'; ParentIndex = $null
  ProductId = 2093; ProductName = 'COCA COLA 350ML'; SaleFormatId = 2338; SaleFormatName = 'COCA COLA 350ML'; SaleFormatRatio = 1.0
  MainBarcode = ''; ProductPrice = 2.5; VatId = 3; VatRate = 0.1; SurchargeRate = 0.014; ProductCostPrice = 0.773
  MenuGroup = ''; PreparationTypeId = 26; PreparationTypeName = 'Barra / Bebidas'; PLU = ''
  FamilyId = 59; FamilyName = 'BEBIDA'; PreparationOrderId = 1; PreparationOrderName = 'Bebidas'
  Quantity = 1.0; UnitCostPrice = 0.773; TotalCostPrice = 0.773; UserId = [int]$opc.usuarioId; UnitPrice = 2.5
  DiscountRate = 0.0; CashDiscount = 0.0; OfferId = $null; OfferCode = ''; TotalAmount = 2.5; PriceListId = [int]$terraza.PriceListId
}
function Pedido($tipo, $estado, $numero) {
  $p = [ordered]@{
    Serie = [string]$opc.serie; Number = $numero; Type = $tipo; DeliveryDate = $ahora.ToString('yyyy-MM-ddTHH:mm:00'); Status = $estado
    Customer = [ordered]@{ Id = [long]$opc.clienteId; FiscalName = "PRUEBA MESA (anular) - $Mesa"; Cif = ''; Street = ''; City = ''; Region = ''; ZipCode = ''; ApplySurcharge = $false; CountryCode = 'ES'; AccountCode = '' }
    DeliveryAddress = [ordered]@{ Street = ''; City = ''; Region = ''; ZipCode = '' }
    Pos = [ordered]@{ Id = [int]$opc.posId; Name = [string]$opc.posNombre }
    Workplace = [ordered]@{ Id = [int]$opc.localId; Name = [string]$opc.localNombre }
    User = [ordered]@{ Id = [int]$opc.usuarioId; Name = [string]$opc.usuarioNombre }
    SaleCenter = [ordered]@{ Id = [int]$terraza.Id; Name = [string]$terraza.Name; Location = $Mesa }
    GlobalId = [guid]::NewGuid().ToString(); BusinessDay = $hoy; Guests = $null; Date = $fecha
    ServiceCharge = [ordered]@{ Rate = 0.0; VatId = 1; VatRate = 0.0; SurchargeRate = 0.0; ApplyToVatIncluded = $true; IgnoreTicketDiscounts = $false; GrossAmount = 0.0; NetAmount = 0.0; VatAmount = 0.0; SurchargeAmount = 0.0 }
    Lines = @($linea)
    Discounts = [ordered]@{ DiscountRate = 0.0; CashDiscount = 0.0 }; Payments = @(); Offers = @(); VatIncluded = $true
    Totals = [ordered]@{ GrossAmount = 2.5; NetAmount = 2.27; VatAmount = 0.23; SurchargeAmount = 0.0
      Taxes = @([ordered]@{ VatRate = 0.1; SurchargeRate = 0.014; GrossAmount = 2.5; NetAmount = 2.27; VatAmount = 0.23; SurchargeAmount = 0.0 }) }
    ScheduledPreparation = $false
  }
  return @{ SalesOrders = @($p) }
}
function Mandar($cuerpo, $nombre) {
  $json = $cuerpo | ConvertTo-Json -Depth 10
  [IO.File]::WriteAllText((Join-Path $salida "mesa-$nombre.json"), $json, [Text.Encoding]::UTF8)
  try {
    $r = Invoke-WebRequest -Uri "$base/api/import/" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -Headers $H -UseBasicParsing -TimeoutSec 60
    return @{ ok = $true; texto = [string]$r.Content }
  } catch {
    $t = ''; if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $t = $_.ErrorDetails.Message }
    if (-not $t) { $t = $_.Exception.Message }
    return @{ ok = $false; texto = ($t -replace '\s+', ' ') }
  }
}

# Paso 1: que Type acepta (pedidos anulados, no se preparan ni se cobran)
$tipos = if ($Tipo) { @($Tipo) } else { @('Table', 'Local', 'EatIn', 'DineIn', 'Restaurant', 'Hall', 'OnSite', 'TakeAway') }
# numeros de prueba nuevos en cada corrida (un numero ya usado Agora lo trata distinto)
$n = 99100 + (Get-Random -Minimum 0 -Maximum 800) * 10
$aceptados = @()
foreach ($t in $tipos) {
  $r = Mandar (Pedido $t 'Cancelled' $n) "tipo-$t"
  if ($r.ok) { Anotar ("ACEPTA   Type={0,-11} (anulado WEB-{1})" -f $t, $n) 'Green'; $aceptados += $t }
  else { Anotar ("RECHAZA  Type={0,-11} {1}" -f $t, $r.texto) }
  $n++
}
if (-not $Enviar) {
  Anotar "`r`nNo mande ningun pedido real. Si hay algun ACEPTA, corre de nuevo con -Enviar." 'Yellow'
} else {
  $t = ($aceptados | Where-Object { $_ -ne 'TakeAway' } | Select-Object -First 1)
  if (-not $t) { Anotar "`r`nNingun tipo de mesa fue aceptado: no mando el pedido real. Si dice 'jornada abierta', proba con la caja abierta." 'Yellow'; $t = $null }
  $num = if ($Numero -gt 0) { $Numero } else { $n + 5 }
}
if ($Enviar -and $t) {
  $r = Mandar (Pedido $t $Estado $num) "real-$t"
  if ($r.ok) {
    Anotar "`r`nMANDADO WEB-$num a $Mesa (Type=$t, Status=$Estado): 1 Coca-Cola." 'Green'
    Anotar 'Fijate en el TPV: 1) si imprimio la comanda en la barra, 2) si aparece en la mesa de TERRAZA, 3) si aparece en la solapa de pedidos. Despues anulalo.' 'Green'
  } else { Anotar "`r`nRECHAZADO el pedido real: $($r.texto)" 'Red' }
}
Start-Sleep -Seconds 2
try {
  $e = (Invoke-WebRequest -Uri "$base/api/export/?filter=SalesOrders&business-day=$hoy" -Headers $H -UseBasicParsing -TimeoutSec 60).Content
  [IO.File]::WriteAllText((Join-Path $salida 'mesa-pedidos-hoy.txt'), $e, [Text.Encoding]::UTF8)
} catch {}
[IO.File]::WriteAllLines((Join-Path $salida 'mesa-resultado.txt'), [string[]]$informe, [Text.Encoding]::UTF8)
Write-Host "`r`nListo. Quedo en exploracion\mesa-resultado.txt (Claude lo lee del Drive)."
