# Terry's - PRUEBA REAL: manda a Agora UN pedido take away de 1 Coca-Cola (2,50 EUR)
# a nombre de "PRUEBA WEB (anular)", para ver si aparece en el TPV y en la pantalla de cocina.
#
# Hace falta poner -Enviar a proposito (sin eso no manda nada):
#   powershell -ExecutionPolicy Bypass -File .\probar-pedido.ps1 -Enviar
#
# Prueba hasta 3 formas del pedido, de la mas simple a la mas completa, y se FRENA en
# la primera que Agora acepta (asi se crea un solo pedido). Despues exporta los pedidos
# de hoy para ver como quedo guardado. Al terminar: anular el pedido en el TPV.

param([switch]$Enviar, [string]$Serie = '', [string]$Estado = 'Pending', [switch]$Programada, [int]$Minutos = 30, [int]$Numero = 0, [switch]$Pagado)
$ErrorActionPreference = 'Stop'
if (-not $Enviar) { Write-Host "No se mando nada. Para mandar el pedido de prueba agrega -Enviar." -ForegroundColor Yellow; exit 0 }
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
# config.json: al lado del script o, si se corre desde el Drive, en Documents\Terrys Admin (no viaja por el Drive)
$rutaConfig = Join-Path $carpeta 'config.json'
if (-not (Test-Path $rutaConfig)) { $rutaConfig = Join-Path $env:USERPROFILE 'Documents\Terrys Admin\config.json' }
$cfg = Get-Content $rutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$base = ([uri]$cfg.agoraExport).GetLeftPart([UriPartial]::Authority)
$salida = Join-Path $carpeta 'exploracion'
New-Item -ItemType Directory -Force -Path $salida | Out-Null
$H = @{ 'Api-Token' = $cfg.agoraToken }

$ahora   = Get-Date
# Serie: WEB si existe (conviene crearla en Agora para estos pedidos), si no P. Numero: el siguiente libre.
$series = (Invoke-WebRequest -Uri "$base/api/export-master/?filter=Series" -Headers $H -UseBasicParsing).Content | ConvertFrom-Json
if (-not $Serie) { $Serie = if ($series.Series | Where-Object { $_.Name -eq 'WEB' }) { 'WEB' } else { 'P' } }
$ser = $series.Series | Where-Object { $_.Name -eq $Serie } | Select-Object -First 1
$numero = if ($ser) { [int]$ser.LastNumber + 1 } else { 1 }
# Si la serie todavia no figura "en uso", mira los pedidos de los ultimos 3 dias para no repetir numero
foreach ($d in 0..3) {
  $dd = (Get-Date).Date.AddDays(-$d).ToString('yyyy-MM-dd')
  try {
    $txt = ([string](Invoke-WebRequest -Uri "$base/api/export/?filter=SalesOrders&business-day=$dd" -Headers $H -UseBasicParsing).Content).Trim([char[]]@([char]0xFEFF, [char]32, [char]13, [char]10))
    if ($txt.Length -gt 10) { foreach ($o in ($txt | ConvertFrom-Json).SalesOrders) { if ($o.Serie -eq $Serie -and [int]$o.Number -ge $numero) { $numero = [int]$o.Number + 1 } } }
  } catch {}
}
if ($Numero -gt 0) { $numero = $Numero }
Write-Host "Serie $Serie, numero $numero"
$hoy     = $ahora.ToString('yyyy-MM-dd')
$fecha   = $ahora.ToString('yyyy-MM-ddTHH:mm:ss')
$entrega = $ahora.AddMinutes($Minutos).ToString('yyyy-MM-ddTHH:mm:00')

# Linea: 1 Coca-Cola 350 ml (producto 2093, formato 2338, IVA reducido 10%)
$lineaMin = [ordered]@{ Index = 0; ProductId = 2093; SaleFormatId = 2338; Quantity = 1.0; UnitPrice = 2.5; TotalAmount = 2.5 }
$lineaFull = [ordered]@{
  Index = 0; CreationDate = $fecha; Type = 'Standard'; ParentIndex = $null
  ProductId = 2093; ProductName = 'COCA COLA 350ML'; SaleFormatId = 2338; SaleFormatName = 'COCA COLA 350ML'; SaleFormatRatio = 1.0
  MainBarcode = ''; ProductPrice = 2.5; VatId = 3; VatRate = 0.1; SurchargeRate = 0.014; ProductCostPrice = 0.773
  MenuGroup = ''; PreparationTypeId = 26; PreparationTypeName = 'Barra / Bebidas'; PLU = ''
  FamilyId = 59; FamilyName = 'BEBIDA'; PreparationOrderId = 1; PreparationOrderName = 'Bebidas'
  Quantity = 1.0; UnitCostPrice = 0.773; TotalCostPrice = 0.773; UserId = 1018; UnitPrice = 2.5
  DiscountRate = 0.0; CashDiscount = 0.0; OfferId = $null; OfferCode = ''; TotalAmount = 2.5; PriceListId = 2
}
$cliente = [ordered]@{ FiscalName = 'PRUEBA WEB (anular)'; Cif = ''; Street = ''; City = ''; Region = ''; ZipCode = ''; ApplySurcharge = $false; CountryCode = 'ES'; AccountCode = '' }
$clienteWeb = [ordered]@{ Id = 1000000312; FiscalName = 'PRUEBA WEB'; Cif = ''; Street = ''; City = ''; Region = ''; ZipCode = ''; ApplySurcharge = $false; CountryCode = 'ES'; AccountCode = '' }

function Pedido($linea, $completo, $estado, $conNumero, $clienteExistente) {
  $p = [ordered]@{
    Serie = $Serie; Type = 'TakeAway'; DeliveryDate = $entrega
    Customer = $(if ($clienteExistente) { $clienteWeb } else { $cliente })
    Pos = [ordered]@{ Id = 1; Name = 'TPV' }; Workplace = [ordered]@{ Id = 1; Name = 'TERRYS BURGERS' }
    User = [ordered]@{ Id = 1018; Name = '1' }; SaleCenter = [ordered]@{ Id = 12; Name = 'TAKE AWAY'; Location = 'Take away' }
    BusinessDay = $hoy; Date = $fecha
    Lines = @($linea)
  }
  if ($completo) {
    $p.GlobalId = [guid]::NewGuid().ToString()
    $p.DeliveryAddress = [ordered]@{ Street = ''; City = ''; Region = ''; ZipCode = '' }
    $p.Discounts = [ordered]@{ DiscountRate = 0.0; CashDiscount = 0.0 }
    $p.Payments = @(); $p.Offers = @(); $p.VatIncluded = $true
    if ($Pagado) {   # pago con tarjeta ya cobrado (como lo exporta Agora; IsPrepayment = pagado por adelantado)
      $p.Payments = @([ordered]@{ MethodId = 2; MethodName = ('Tarjeta de cr' + [char]0xE9 + 'dito'); Amount = 2.5; PaidAmount = 2.5; ChangeAmount = 0.0; TipAmount = 0.0; Date = $fecha; PosId = 1; IsPrepayment = $true; ExtraInformation = 'PRUEBA WEB' })
    }
    $p.Guests = $null
    $p.ServiceCharge = [ordered]@{ Rate = 0.0; VatId = 1; VatRate = 0.0; SurchargeRate = 0.0; ApplyToVatIncluded = $true; IgnoreTicketDiscounts = $false; GrossAmount = 0.0; NetAmount = 0.0; VatAmount = 0.0; SurchargeAmount = 0.0 }
    $p.Totals = [ordered]@{ GrossAmount = 2.5; NetAmount = 2.27; VatAmount = 0.23; SurchargeAmount = 0.0
      Taxes = @([ordered]@{ VatRate = 0.1; SurchargeRate = 0.014; GrossAmount = 2.5; NetAmount = 2.27; VatAmount = 0.23; SurchargeAmount = 0.0 }) }
    $p.ScheduledPreparation = [bool]$Programada
  }
  if ($estado) { $p.Status = $estado }
  if ($conNumero) { $p.Insert(1, 'Number', $numero) }
  return @{ SalesOrders = @($p) }
}

$variantes = @(
  @{ n = "J-$Estado$(if ($Programada) { '-programada' })$(if ($Pagado) { '-pagado' })"; cuerpo = (Pedido $lineaFull $true $Estado $true $true) }
)
$inicio = Get-Date

$ok = $null
foreach ($v in $variantes) {
  $json = $v.cuerpo | ConvertTo-Json -Depth 10
  [IO.File]::WriteAllText((Join-Path $salida "pedido-$($v.n).json"), $json, [Text.Encoding]::UTF8)
  try {
    $r = Invoke-WebRequest -Uri "$base/api/import/" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
         -ContentType 'application/json; charset=utf-8' -Headers $H -UseBasicParsing -TimeoutSec 60
    Write-Host "ACEPTADO  $($v.n)  ($($r.StatusCode))  $($r.Content)" -ForegroundColor Green
    $ok = $v.n; break
  } catch {
    $codigo = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { '---' }
    $cuerpo = ''
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $cuerpo = $_.ErrorDetails.Message }   # PowerShell 5.1 deja aca el texto del error
    if (-not $cuerpo) { try { $st = $_.Exception.Response.GetResponseStream(); if ($st.CanSeek) { $st.Position = 0 }; $cuerpo = (New-Object IO.StreamReader($st)).ReadToEnd() } catch {} }
    Write-Host "RECHAZADO $($v.n)  ($codigo)  $cuerpo"
    [IO.File]::WriteAllText((Join-Path $salida "pedido-$($v.n)-respuesta.txt"), [string]$cuerpo, [Text.Encoding]::UTF8)
  }
}

Start-Sleep -Seconds 2
$r = Invoke-WebRequest -Uri "$base/api/export/?filter=SalesOrders&business-day=$hoy" -Headers $H -UseBasicParsing -TimeoutSec 60
[IO.File]::WriteAllText((Join-Path $salida "pedidos-hoy-despues.txt"), $r.Content, [Text.Encoding]::UTF8)

if ($ok) {
  Write-Host "`r`nAgora acepto la forma '$ok'. Fijate en el TPV (consola de pedidos) y en la pantalla de cocina si aparece" -ForegroundColor Green
  Write-Host "el pedido de PRUEBA WEB con 1 Coca-Cola. Despues anulalo." -ForegroundColor Green
} else {
  Write-Host "`r`nAgora no acepto ninguna de las formas." -ForegroundColor Yellow
}
# El error real queda en el log de Agora: busca archivos de log tocados durante la prueba.
Write-Host "`r`n--- Log de Agora (lineas de estos minutos con error/import) ---"
$logs = foreach ($dir in "$env:ProgramData\IGT Microelectronics", "${env:ProgramFiles(x86)}\IGT Microelectronics", "$env:ProgramFiles\IGT Microelectronics", "$env:LOCALAPPDATA\IGT Microelectronics", "$env:APPDATA\IGT Microelectronics") {
  if (Test-Path $dir) { Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $inicio.AddMinutes(-1) -and $_.Extension -in '.log', '.txt', '' } }
}
$todo = @()
foreach ($l in $logs) {
  $todo += "== $($l.FullName)"
  $todo += Get-Content $l.FullName -Tail 300 -ErrorAction SilentlyContinue | Select-String -Pattern 'import|exception|error|SalesOrder|requerid|required|invalid|null' | Select-Object -Last 40 | ForEach-Object { $_.Line }
}
if (-not $logs) { $todo += "No encontre logs modificados recien en las carpetas de IGT Microelectronics." }
# Visor de eventos de Windows (Aplicacion): errores de estos minutos
$todo += "== Visor de eventos (Aplicacion)"
try {
  Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $inicio.AddMinutes(-1) } -ErrorAction Stop |
    Where-Object { $_.LevelDisplayName -match 'Error|Advertencia|Warning' -or $_.ProviderName -match 'Agora|IGT|ASP|\.NET' } |
    Select-Object -First 15 | ForEach-Object { $todo += "[$($_.TimeCreated.ToString('HH:mm:ss'))] $($_.ProviderName): $(($_.Message -replace '\s+', ' ').Substring(0, [math]::Min(600, ($_.Message -replace '\s+', ' ').Length)))" }
} catch { $todo += "Sin eventos nuevos." }
$todo | ForEach-Object { Write-Host $_ }
[IO.File]::WriteAllLines((Join-Path $salida 'log-agora-prueba.txt'), [string[]]$todo, [Text.Encoding]::UTF8)
Write-Host "`r`nPasale a Claude lo que salio en pantalla y exploracion\log-agora-prueba.txt."
