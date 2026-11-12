# Terry's - manda a Agora los pedidos take away de la web (terrysburgers.com/pedido/).
#
# Corre en la computadora del TPV. Cada 15 segundos le pregunta a Supabase si hay pedidos
# nuevos (agora_pendientes), los carga en Agora por la API local (/api/import/) en la serie
# WEB y le avisa a Supabase como le fue (agora_marcar). El admin muestra "En Agora" o el error.
#
#   powershell -ExecutionPolicy Bypass -File .\enviar-pedidos.ps1            queda corriendo
#   powershell -ExecutionPolicy Bypass -File .\enviar-pedidos.ps1 -UnaVez    una vuelta y termina
#   powershell -ExecutionPolicy Bypass -File .\enviar-pedidos.ps1 -Simular   arma los pedidos y los
#                                       guarda en exploracion\ sin mandarlos ni marcarlos
#
# Usa config.json (tokens: al lado del script o en Documents\Terrys Admin) y pedidos-agora.json
# (serie, cliente, TPV, centro de venta: sin secretos). Registro en enviar-pedidos.log.
# En Agora: sin pago el pedido entra Pendiente (tocar Preparar); pagado entra solo a cocina.

param([switch]$UnaVez, [switch]$Simular)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $carpeta 'enviar-pedidos.log'

function Escribir($texto) {
  $linea = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $texto
  Write-Host $linea
  try {
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log ($log + '.anterior') -Force }
    Add-Content -Path $log -Value $linea -Encoding UTF8
  } catch {}
}

# ---------- configuracion ----------
$rutaConfig = Join-Path $carpeta 'config.json'
if (-not (Test-Path $rutaConfig)) { $rutaConfig = Join-Path $env:USERPROFILE 'Documents\Terrys Admin\config.json' }
$cfg = Get-Content $rutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$opc = Get-Content (Join-Path $carpeta 'pedidos-agora.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($k in 'agoraExport', 'agoraToken', 'supabaseUrl', 'supabaseKey', 'integracionToken') {
  if (-not $cfg.$k) { Escribir "En config.json falta '$k'."; exit 1 }
}
if (-not $opc.clienteId -or [int]$opc.clienteId -le 0) {
  Escribir "Falta el numero del cliente WEB de Agora en pedidos-agora.json (clienteId)."; exit 1
}
$base = ([uri]$cfg.agoraExport).GetLeftPart([UriPartial]::Authority)
$supa = $cfg.supabaseUrl.TrimEnd('/') + '/rest/v1/rpc/'
$cada = if ($opc.cadaSegundos) { [int]$opc.cadaSegundos } else { 15 }
$cadaFuera = if ($opc.cadaSegundosFuera) { [int]$opc.cadaSegundosFuera } else { 60 }
# En horario del local revisa seguido; fuera de horario mas espaciado (igual entran los pedidos para despues).
function Espera {
  if (-not $opc.horarios) { return $cada }
  $ahora = (Get-Date).ToString('HH:mm')
  foreach ($h in $opc.horarios) { if ($ahora -ge $h[0] -and $ahora -lt $h[1]) { return $cada } }
  return $cadaFuera
}

# una sola copia corriendo
$mutex = New-Object Threading.Mutex($false, 'TerrysEnviarPedidosAgora')
if (-not $mutex.WaitOne(0)) { Write-Host 'Ya hay otro enviar-pedidos corriendo.'; exit 0 }

# ---------- llamadas ----------
function Supabase($funcion, $cuerpo) {
  $wc = New-Object System.Net.WebClient
  $wc.Encoding = [Text.Encoding]::UTF8
  $wc.Headers['apikey'] = $cfg.supabaseKey
  $wc.Headers['Authorization'] = 'Bearer ' + $cfg.supabaseKey
  $wc.Headers['Content-Type'] = 'application/json'
  $resp = $wc.UploadString($supa + $funcion, 'POST', ($cuerpo | ConvertTo-Json -Depth 10 -Compress))
  if ($resp) { return ($resp | ConvertFrom-Json) }
}
function AgoraMaestro($filtro) {
  $wc = New-Object System.Net.WebClient
  $wc.Encoding = [Text.Encoding]::UTF8
  $wc.Headers['Api-Token'] = $cfg.agoraToken
  return ($wc.DownloadString("$base/api/export-master/?filter=$filtro") | ConvertFrom-Json).$filtro
}
function AgoraImportar($json) {
  try {
    Invoke-WebRequest -Uri "$base/api/import/" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
      -ContentType 'application/json; charset=utf-8' -Headers @{ 'Api-Token' = $cfg.agoraToken } -UseBasicParsing -TimeoutSec 60 | Out-Null
    return $null
  } catch {
    $m = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    return ($m -replace '\s+', ' ').Trim()
  }
}

# ---------- datos maestros de Agora (se refrescan cada hora) ----------
$M = $null; $maestrosHora = [datetime]::MinValue
function CargarMaestros {
  $script:M = @{
    Prod = @{}; Fam = @{}; PT = @{}; PO = @{}; Vat = @{}
  }
  foreach ($p in (AgoraMaestro 'Products')) { $script:M.Prod[[int]$p.Id] = $p }
  foreach ($x in (AgoraMaestro 'Families')) { $script:M.Fam[[int]$x.Id] = $x.Name }
  foreach ($x in (AgoraMaestro 'PreparationTypes')) { $script:M.PT[[int]$x.Id] = $x.Name }
  foreach ($x in (AgoraMaestro 'PreparationOrders')) { $script:M.PO[[int]$x.Id] = $x.Name }
  foreach ($x in (AgoraMaestro 'Vats')) { $script:M.Vat[[int]$x.Id] = $x }
  $script:maestrosHora = Get-Date
  Escribir ("Datos de Agora cargados: {0} productos." -f $script:M.Prod.Count)
}
function N($id, $tabla) { if ($null -ne $id -and $tabla.ContainsKey([int]$id)) { $tabla[[int]$id] } else { '' } }

# ---------- armar el pedido como lo exporta Agora ----------
function ArmarPedido($p) {
  $ahora = Get-Date
  $fecha = $ahora.ToString('yyyy-MM-ddTHH:mm:ss')
  $lineas = @(); $impuestos = @{}; $i = 0
  foreach ($l in $p.lineas) {
    if (-not $l.agora_id) { throw "Falta el codigo de Agora de '$($l.nombre)$(if ($l.extra) { ' ' + $l.extra })' (solapa Pedidos > Productos)." }
    $pr = $M.Prod[[int]$l.agora_id]
    if (-not $pr) { throw "El codigo de Agora $($l.agora_id) ('$($l.nombre)') no existe en Agora." }
    $vat = $M.Vat[[int]$pr.VatId]
    $cant = [double]$l.cant; $precio = [double]$l.precio; $tot = [math]::Round($cant * $precio, 2)
    $costo = if ($pr.CostPrice) { [double]$pr.CostPrice } else { 0.0 }
    $linea = [ordered]@{
      Index = $i; CreationDate = $fecha; Type = 'Standard'; ParentIndex = $null
      ProductId = [int]$pr.Id; ProductName = $pr.Name; SaleFormatId = [int]$pr.BaseSaleFormatId; SaleFormatName = $pr.Name; SaleFormatRatio = 1.0
      MainBarcode = ''; ProductPrice = $precio; VatId = [int]$pr.VatId; VatRate = [double]$vat.VatRate; SurchargeRate = [double]$vat.SurchargeRate
      ProductCostPrice = $costo; MenuGroup = ''
      PreparationTypeId = $pr.PreparationTypeId; PreparationTypeName = (N $pr.PreparationTypeId $M.PT); PLU = [string]$pr.PLU
      FamilyId = $pr.FamilyId; FamilyName = (N $pr.FamilyId $M.Fam)
      PreparationOrderId = $pr.PreparationOrderId; PreparationOrderName = (N $pr.PreparationOrderId $M.PO)
      Quantity = $cant; UnitCostPrice = $costo; TotalCostPrice = [math]::Round($costo * $cant, 4); UserId = [int]$opc.usuarioId
      UnitPrice = $precio; DiscountRate = 0.0; CashDiscount = 0.0; OfferId = $null; OfferCode = ''; TotalAmount = $tot
      PriceListId = [int]$opc.tarifaId
    }
    if ($l.agora_salsa) {
      $sa = $M.Prod[[int]$l.agora_salsa]
      if (-not $sa) { throw "El codigo de Agora $($l.agora_salsa) (salsa '$($l.salsa)') no existe en Agora." }
      $sv = $M.Vat[[int]$sa.VatId]
      $linea.Addins = @([ordered]@{
        ProductId = [int]$sa.Id; ProductName = $sa.Name; SaleFormatId = [int]$sa.BaseSaleFormatId; SaleFormatName = $sa.Name; SaleFormatRatio = 1.0
        MainBarcode = ''; ProductPrice = 0.0; VatId = [int]$sa.VatId; VatRate = [double]$sv.VatRate; SurchargeRate = [double]$sv.SurchargeRate
        ProductCostPrice = $(if ($sa.CostPrice) { [double]$sa.CostPrice } else { 0.0 })
        PreparationTypeId = $pr.PreparationTypeId; PreparationTypeName = (N $pr.PreparationTypeId $M.PT); PLU = ''; FamilyId = $null; FamilyName = ''
      })
    }
    $lineas += $linea; $i++
    $k = '{0}|{1}' -f $vat.VatRate, $vat.SurchargeRate
    if (-not $impuestos.ContainsKey($k)) { $impuestos[$k] = @{ VatRate = [double]$vat.VatRate; SurchargeRate = [double]$vat.SurchargeRate; Gross = 0.0 } }
    $impuestos[$k].Gross += $tot
  }
  $taxes = @(); $g = 0.0; $n = 0.0
  foreach ($t in $impuestos.Values) {
    $neto = [math]::Round($t.Gross / (1 + $t.VatRate), 2)
    $taxes += [ordered]@{ VatRate = $t.VatRate; SurchargeRate = $t.SurchargeRate; GrossAmount = [math]::Round($t.Gross, 2); NetAmount = $neto; VatAmount = [math]::Round($t.Gross - $neto, 2); SurchargeAmount = 0.0 }
    $g += $t.Gross; $n += $neto
  }
  $g = [math]::Round($g, 2); $n = [math]::Round($n, 2)

  $nombreCliente = if ($opc.nombreEnCliente) { ('{0} - {1} (web)' -f $p.nombre, $p.hora) } else { [string]$opc.clienteNombre }
  $pedido = [ordered]@{
    Serie = [string]$opc.serie; Number = [int]$opc.offsetNumero + [int]$p.id; Type = 'TakeAway'
    DeliveryDate = ('{0}T{1}:00' -f $p.dia, $p.hora); Status = 'Pending'
    Customer = [ordered]@{ Id = [long]$opc.clienteId; FiscalName = $nombreCliente; Cif = ''; Street = ''; City = ''; Region = ''; ZipCode = ''; ApplySurcharge = $false; CountryCode = 'ES'; AccountCode = '' }
    DeliveryAddress = [ordered]@{ Street = ''; City = ''; Region = ''; ZipCode = '' }
    Pos = [ordered]@{ Id = [int]$opc.posId; Name = [string]$opc.posNombre }
    Workplace = [ordered]@{ Id = [int]$opc.localId; Name = [string]$opc.localNombre }
    User = [ordered]@{ Id = [int]$opc.usuarioId; Name = [string]$opc.usuarioNombre }
    SaleCenter = [ordered]@{ Id = [int]$opc.centroId; Name = [string]$opc.centroNombre; Location = [string]$opc.centroUbicacion }
    GlobalId = [guid]::NewGuid().ToString(); BusinessDay = $ahora.ToString('yyyy-MM-dd'); Guests = $null; Date = $fecha
    ServiceCharge = [ordered]@{ Rate = 0.0; VatId = 1; VatRate = 0.0; SurchargeRate = 0.0; ApplyToVatIncluded = $true; IgnoreTicketDiscounts = $false; GrossAmount = 0.0; NetAmount = 0.0; VatAmount = 0.0; SurchargeAmount = 0.0 }
    Lines = $lineas
    Discounts = [ordered]@{ DiscountRate = 0.0; CashDiscount = 0.0 }
    Payments = @(); Offers = @(); VatIncluded = $true
    Totals = [ordered]@{ GrossAmount = $g; NetAmount = $n; VatAmount = [math]::Round($g - $n, 2); SurchargeAmount = 0.0; Taxes = $taxes }
    ScheduledPreparation = $false
  }
  if ($p.pagado) {   # pagado online: Agora lo pasa solo a En Preparacion (imprime y va a cocina)
    $pedido.Payments = @([ordered]@{ MethodId = [int]$opc.formaPagoTarjetaId; MethodName = [string]$opc.formaPagoTarjetaNombre; Amount = $g; PaidAmount = $g; ChangeAmount = 0.0; TipAmount = 0.0; Date = $fecha; PosId = [int]$opc.posId; IsPrepayment = $true; ExtraInformation = ('Web ' + $p.id) })
  }
  return $pedido
}

# ---------- aviso al celular (ntfy) desde la conexion del local ----------
# ntfy.sh gratis limita por IP; la de Supabase es compartida y se queda sin cupo, la del local no.
# Simbolos con [char] para que el archivo siga en ASCII (PowerShell 5.1 lee mal los acentos).
$C = @{ punto = [char]0x00B7; por = [char]0x00D7; eur = [char]0x20AC; no = [char]0x00BA; enie = [char]0x00D1; flecha = [char]0x21B3 }
# JSON solo con ASCII: todo lo demas viaja como \uXXXX (asi no se rompe en el camino).
function JsonAscii($obj) {
  $j = $obj | ConvertTo-Json -Compress -Depth 5
  return [regex]::Replace($j, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}
function TextoAviso($a) {
  $cuando = switch ($a.cuando) { 'hoy' { 'HOY' } 'manana' { 'MA' + $C.enie + 'ANA' } default { $a.dia } }
  $titulo = 'Pedido n{0} {1} {2} {3} {4}' -f $C.no, $a.id, $C.punto, $cuando, $a.hora
  $lineas = @()
  foreach ($it in @($a.items | ForEach-Object { $_ })) {
    if (-not $it) { continue }
    $lineas += ('{0}{1} {2}{3}' -f $it.cant, $C.por, $it.nombre, $(if ($it.extra) { ' (' + ([string]$it.extra).ToLower() + ')' } else { '' }))
  }
  $total = ([double]$a.total).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture).Replace('.', ',')
  $lineas += ('Total {0} {1} {2} se paga al retirar' -f $total, $C.eur, $C.punto)
  if ($a.comentario) { $lineas += 'Tiene comentario (ver en el admin)' }
  return @{ titulo = $titulo; mensaje = ($lineas -join "`n") }
}
function AvisarPedidos {
  $r = Supabase 'tpv_avisos_pendientes' @{ p_token = $cfg.integracionToken }
  if (-not $r -or -not $r.tema) { return }
  $ok = @()
  foreach ($a in @($r.avisos | ForEach-Object { $_ })) {
    if (-not $a) { continue }
    $t = TextoAviso $a
    if ($Simular) { Escribir "SIMULADO aviso pedido $($a.id): $($t.titulo) | $($t.mensaje -replace "`n", ' | ')"; continue }
    try {
      $cuerpo = JsonAscii @{ topic = $r.tema; title = $t.titulo; message = $t.mensaje; tags = @('takeout_box'); priority = $(if ($a.cuando -eq 'hoy') { 5 } else { 4 }); click = 'https://admin.terrysburgers.com/' }
      Invoke-WebRequest -Uri 'https://ntfy.sh/' -Method Post -Body ([Text.Encoding]::ASCII.GetBytes($cuerpo)) -ContentType 'application/json' -UseBasicParsing -TimeoutSec 20 | Out-Null
      $ok += [long]$a.id
      Escribir "AVISO pedido $($a.id) enviado: $($t.titulo) | $($t.mensaje -replace "`n", ' | ')"
    } catch {
      $m = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
      Escribir "No se pudo avisar el pedido $($a.id): $($m -replace '\s+', ' ')"
    }
  }
  if ($ok.Count) { Supabase 'tpv_aviso_marcar' @{ p_token = $cfg.integracionToken; p_ids = $ok } | Out-Null }
}

# ---------- estado de los pedidos en Agora -> admin (cada 30 s) ----------
# La API de Agora solo dice Pending / Cancelled / Invoiced. Se guarda lo exportado en
# exploracion\estados-agora.json (solo si cambia) para ver si aparece algo mas.
$ultimosEstados = [datetime]::MinValue; $huellaEstados = ''
function SincronizarEstados {
  $script:ultimosEstados = Get-Date
  $lista = @(); $crudo = @()
  foreach ($d in 0..2) {
    $dia = (Get-Date).Date.AddDays(-$d).ToString('yyyy-MM-dd')
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [Text.Encoding]::UTF8
    $wc.Headers['Api-Token'] = $cfg.agoraToken
    $txt = ([string]$wc.DownloadString("$base/api/export/?filter=SalesOrders&business-day=$dia")).Trim([char[]]@([char]0xFEFF, [char]32, [char]13, [char]10))
    if ($txt.Length -lt 10) { continue }
    foreach ($o in @(($txt | ConvertFrom-Json).SalesOrders | ForEach-Object { $_ })) {
      if (-not $o -or $o.Serie -ne $opc.serie) { continue }
      $lista += @{ numero = [int]$o.Number; status = [string]$o.Status }
      $crudo += [ordered]@{ Number = $o.Number; Status = $o.Status; ScheduledPreparation = $o.ScheduledPreparation; DeliveryDate = $o.DeliveryDate; BusinessDay = $o.BusinessDay; Payments = @($o.Payments).Count; Campos = (($o.PSObject.Properties | ForEach-Object { $_.Name }) -join ',') }
    }
  }
  if (-not $lista.Count) { return }
  $huella = ($crudo | ConvertTo-Json -Depth 4 -Compress)
  if ($huella -ne $script:huellaEstados) {
    $script:huellaEstados = $huella
    $dir = Join-Path $carpeta 'exploracion'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir 'estados-agora.json'), ($crudo | ConvertTo-Json -Depth 4), [Text.Encoding]::UTF8)
  }
  if ($Simular) { return }
  $n = Supabase 'agora_estados' @{ p_token = $cfg.integracionToken; p_estados = $lista }
  if ($n -and [int]$n -gt 0) { Escribir "ESTADOS: $n pedido(s) actualizados desde Agora." }
}

# ---------- una vuelta ----------
function Vuelta {
  if (-not $M -or ((Get-Date) - $maestrosHora).TotalMinutes -ge 60) { CargarMaestros }
  if (((Get-Date) - $ultimosEstados).TotalSeconds -ge 30) {
    try { SincronizarEstados; $script:errEstados = $null } catch {
      $m = $_.Exception.Message
      if ($m -ne $script:errEstados) { Escribir "Estados: $m"; $script:errEstados = $m }
    }
  }
  try { AvisarPedidos; $script:errAviso = $null } catch {
    $m = $_.Exception.Message
    if ($m -ne $script:errAviso) { Escribir "Avisos: $m"; $script:errAviso = $m }   # no repetir el mismo error cada 5 s
  }
  # (PowerShell 5.1 devuelve el arreglo JSON como un solo objeto: el pipe lo separa en pedidos)
  $pendientes = @(Supabase 'agora_pendientes' @{ p_token = $cfg.integracionToken } | ForEach-Object { $_ })
  foreach ($p in $pendientes) {
    if (-not $p) { continue }
    $num = [int]$opc.offsetNumero + [int]$p.id
    try {
      $pedido = ArmarPedido $p
      $json = @{ SalesOrders = @($pedido) } | ConvertTo-Json -Depth 10
      if ($Simular) {
        $dir = Join-Path $carpeta 'exploracion'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir "simulado-pedido-$($p.id).json"), $json, [Text.Encoding]::UTF8)
        Escribir "SIMULADO pedido $($p.id) -> $($opc.serie)-$num ($($p.lineas.Count) lineas, $($pedido.Totals.GrossAmount) EUR)"
        continue
      }
      $err = AgoraImportar $json
      if ($err) { throw "Agora: $err" }
      Supabase 'agora_marcar' @{ p_token = $cfg.integracionToken; p_id = [long]$p.id; p_ok = $true; p_numero = $num; p_error = $null } | Out-Null
      Escribir "OK  pedido $($p.id) -> Agora $($opc.serie)-$num, retira $($p.dia) $($p.hora), $($pedido.Totals.GrossAmount) EUR"
    } catch {
      $msg = $_.Exception.Message
      Escribir "ERROR pedido $($p.id): $msg"
      if (-not $Simular) {
        try { Supabase 'agora_marcar' @{ p_token = $cfg.integracionToken; p_id = [long]$p.id; p_ok = $false; p_numero = $null; p_error = $msg } | Out-Null } catch {}
      }
    }
  }
}

Escribir "enviar-pedidos arranca (cada $cada s en horario, $cadaFuera s fuera$(if ($Simular) { ', SIMULANDO' }))."
$fallas = 0
while ($true) {
  try {
    Vuelta
    if ($fallas -gt 0) { Escribir 'Conexion recuperada.' }
    $fallas = 0
  } catch {
    $fallas++
    # no llenar el registro si se corta internet: una linea cada 20 fallas seguidas
    if ($fallas -eq 1 -or $fallas % 20 -eq 0) {
      $m = $_.Exception.Message
      if ($m -match '403') { $m += ' - el integracionToken de config.json no coincide con el de Supabase' }
      Escribir "No se pudo revisar ($fallas): $m"
    }
  }
  if ($UnaVez -or $Simular) { break }
  Start-Sleep -Seconds (Espera)
}
$mutex.ReleaseMutex()
