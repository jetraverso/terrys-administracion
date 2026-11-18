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
# Pagina de camareros (admin.terrysburgers.com/pos/): sube la carta de cada centro y las mesas
# abiertas (leidas de la base de Agora) y carga los pedidos en la mesa elegida (Type = Table).

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
  $script:M.Fmt = @{}   # formato de venta -> producto (las lineas de la base de Agora guardan el formato)
  foreach ($p in (AgoraMaestro 'Products')) {
    $script:M.Prod[[int]$p.Id] = $p
    if (-not $p.DeletionDate -and $p.BaseSaleFormatId) { $script:M.Fmt[[int]$p.BaseSaleFormatId] = [int]$p.Id }
  }
  foreach ($x in (AgoraMaestro 'Families')) { $script:M.Fam[[int]$x.Id] = $x.Name }
  foreach ($x in (AgoraMaestro 'PreparationTypes')) { $script:M.PT[[int]$x.Id] = $x.Name }
  foreach ($x in (AgoraMaestro 'PreparationOrders')) { $script:M.PO[[int]$x.Id] = $x.Name }
  foreach ($x in (AgoraMaestro 'Vats')) { $script:M.Vat[[int]$x.Id] = $x }
  $script:maestrosHora = Get-Date
  Escribir ("Datos de Agora cargados: {0} productos." -f $script:M.Prod.Count)
  try { SubirCatalogo } catch { Escribir "Catalogo: $($_.Exception.Message)" }
  try { SubirCartaPos } catch { Escribir "Carta del local: $($_.Exception.Message)" }
}

# Catalogo para la web (parte 18): productos vendibles con precio en la tarifa del centro TAKE AWAY
# y sus grupos de opciones (EXTRA, QUITAR, SALSA, menus...). Solo se sube si cambio.
$huellaCatalogo = ''
function PrecioTarifa($p, $campo) {
  foreach ($x in @($p.Prices)) { if ($x -and [int]$x.PriceListId -eq [int]$opc.tarifaId) { return $x.$campo } }
  return $null
}
function SubirCatalogo {
  $porFormato = @{}
  foreach ($p in $M.Prod.Values) { if (-not $p.DeletionDate) { $porFormato[[int]$p.BaseSaleFormatId] = $p } }
  $lista = @()
  foreach ($p in $M.Prod.Values) {
    if ($p.DeletionDate -or -not $p.SaleableAsMain) { continue }
    $precio = PrecioTarifa $p 'MainPrice'
    if ($null -eq $precio) { continue }
    $roles = @()
    foreach ($r in @($p.AddinRoles)) {
      if (-not $r) { continue }
      $ops = @()
      foreach ($a in @($r.Addins)) {
        if (-not $a) { continue }
        $q = $porFormato[[int]$a.AddinSaleFormatId]
        if ($q) { $pa = PrecioTarifa $q 'AddinPrice'; $ops += [ordered]@{ id = [int]$q.Id; nombre = [string]$q.Name; precio = $(if ($null -ne $pa) { [double]$pa } else { 0.0 }) } }
      }
      $roles += [ordered]@{ nombre = [string]$r.Name; min = [int]$r.MinAddins; max = [int]$r.MaxAddins; opciones = $ops }
    }
    $lista += [ordered]@{ id = [int]$p.Id; nombre = [string]$p.Name; cocina = (N $p.PreparationOrderId $M.PO); precio = [double]$precio; roles = $roles }
  }
  if (-not $lista.Count) { return }
  $json = $lista | Sort-Object { $_.id } | ConvertTo-Json -Depth 8 -Compress
  if ($json -eq $script:huellaCatalogo -or $Simular) { return }
  $n = Supabase 'agora_subir_catalogo' @{ p_token = $cfg.integracionToken; p_productos = @($lista) }
  $script:huellaCatalogo = $json
  Escribir "Catalogo de Agora subido a la web: $n productos."
}
function N($id, $tabla) { if ($null -ne $id -and $tabla.ContainsKey([int]$id)) { $tabla[[int]$id] } else { '' } }

# ---------- pagina de camareros (parte 24): carta por centro y mesas abiertas ----------
# Se leen de la base de Agora en este TPV (SOLO LECTURA): la API no da las mesas abiertas.
$posCentros = @(if ($opc.posCentros) { $opc.posCentros | ForEach-Object { [int]$_ } } else { 7, 13, 12 })
function AgoraSql($sql) {
  $cn = New-Object System.Data.SqlClient.SqlConnection ([string]$(if ($opc.agoraSql) { $opc.agoraSql } else { 'Server=localhost\AGORA;Database=igtpos;Integrated Security=True;Connect Timeout=8;ApplicationIntent=ReadOnly' }))
  $cn.Open()
  try {
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 20
    $tab = New-Object System.Data.DataTable; $tab.Load($cmd.ExecuteReader()); return ,$tab
  } finally { $cn.Close() }
}
function Txt($v) { if ($v -is [DBNull] -or $null -eq $v) { return '' } return [string]$v }
function ColorAgora($v) { $s = Txt $v; if ($s -match '([0-9A-Fa-f]{6})$') { return '#' + $Matches[1].ToLower() } return $null }
$huellaCartaPos = ''
function SubirCartaPos {
  $lista = ($posCentros -join ',')
  $centros = AgoraSql "select Id, Name, StyleBackColor from dbo.SaleCenter where DeletionDate is null and Id in ($lista)"
  $ubic = AgoraSql "select SaleCenterId, Name from dbo.SaleLocation where SaleCenterId in ($lista) order by SaleCenterId, SaleLocationIndex"
  $cs = AgoraSql "select CategoryId, SaleCenterId from dbo.CategorySaleCenters where SaleCenterId in ($lista)"
  $cats = @{}; foreach ($c in (AgoraSql 'select Id, Name, StyleBackColor from dbo.Category where DeletionDate is null and ShowInPos = 1')) { $cats[[int]$c.Id] = $c }
  $prodCat = @{}
  foreach ($x in (AgoraSql 'select CategoryId, ProductId from dbo.ProductCategory')) {
    $k = [int]$x.CategoryId; $prodId = [int]$x.ProductId
    $pr = $M.Prod[$prodId]
    if (-not $pr -or $pr.DeletionDate -or -not $pr.SaleableAsMain) { continue }
    if (-not $prodCat.ContainsKey($k)) { $prodCat[$k] = New-Object System.Collections.ArrayList }
    if (-not $prodCat[$k].Contains($prodId)) { [void]$prodCat[$k].Add($prodId) }
  }
  $salida = @()
  foreach ($id in $posCentros) {
    $c = $centros | Where-Object { [int]$_.Id -eq $id } | Select-Object -First 1
    if (-not $c) { continue }
    $categorias = @()
    foreach ($r in ($cs | Where-Object { [int]$_.SaleCenterId -eq $id })) {
      $k = [int]$r.CategoryId
      if (-not $cats.ContainsKey($k) -or -not $prodCat.ContainsKey($k)) { continue }
      $categorias += [ordered]@{ id = $k; nombre = (Txt $cats[$k].Name); color = (ColorAgora $cats[$k].StyleBackColor); productos = @($prodCat[$k] | Sort-Object) }
    }
    $mesas = @($ubic | Where-Object { [int]$_.SaleCenterId -eq $id } | ForEach-Object { Txt $_.Name })
    $salida += [ordered]@{ id = $id; nombre = (Txt $c.Name); color = (ColorAgora $c.StyleBackColor); mesas = $mesas; categorias = $categorias }
  }
  $carta = [ordered]@{ centros = $salida }
  $json = $carta | ConvertTo-Json -Depth 8 -Compress
  if ($json -eq $script:huellaCartaPos -or $Simular) { return }
  Supabase 'tpv_subir_carta' @{ p_token = $cfg.integracionToken; p_carta = $carta } | Out-Null
  $script:huellaCartaPos = $json
  Escribir ("Carta del local subida: {0} centros." -f $salida.Count)
}
$huellaMesas = ''; $ultimasMesas = [datetime]::MinValue
function SubirMesas {
  $lista = ($posCentros -join ',')
  $tk = AgoraSql "select Id, SaleCenterId, SaleLocationName, CreationDate, FriendlyName from dbo.Ticket where FrozenDate is null and CreationDate > dateadd(day, -2, getdate()) and SaleCenterId in ($lista) order by Id"
  $abiertos = "select Id from dbo.Ticket where FrozenDate is null and CreationDate > dateadd(day, -2, getdate()) and SaleCenterId in ($lista)"
  $ln = AgoraSql @"
select l.Id, l.TicketId, l.SaleFormatId, l.ProductName, l.Quantity, l.TotalAmount, l.Notes
  from dbo.TicketLine l
 where l.IsCancelled = 0 and l.TicketId in ($abiertos)
 order by l.TicketId, l.TicketLineIndex
"@
  $adds = @{}
  foreach ($a in (AgoraSql "select a.TicketLineId, a.SaleFormatId, a.ProductName, a.Price from dbo.TicketLineAddin a join dbo.TicketLine l on l.Id = a.TicketLineId where l.IsCancelled = 0 and l.TicketId in ($abiertos) order by a.TicketLineId, a.AddinIndex")) {
    $k = [int]$a.TicketLineId
    if (-not $adds.ContainsKey($k)) { $adds[$k] = New-Object System.Collections.ArrayList }
    $fid = [int]$a.SaleFormatId
    [void]$adds[$k].Add([ordered]@{ id = $(if ($M.Fmt.ContainsKey($fid)) { $M.Fmt[$fid] } else { $null }); n = (Txt $a.ProductName); p = [math]::Round([double]$a.Price, 2) })
  }
  $mesas = @()
  foreach ($t in $tk) {
    $lineas = @(); $total = 0.0
    foreach ($l in ($ln | Where-Object { [int]$_.TicketId -eq [int]$t.Id })) {
      $total += [double]$l.TotalAmount
      $fid = [int]$l.SaleFormatId; $ad = @(); if ($adds.ContainsKey([int]$l.Id)) { $ad = @($adds[[int]$l.Id]) }
      $cant = [double]$l.Quantity
      # id = producto de Agora y ad = extras con su precio: con eso la pagina puede quitarlo (mismo producto con cantidad negativa)
      $lineas += [ordered]@{ n = (Txt $l.ProductName); c = $cant; t = [math]::Round([double]$l.TotalAmount, 2)
                             u = $(if ($cant -ne 0) { [math]::Round([double]$l.TotalAmount / $cant, 2) } else { 0 })
                             id = $(if ($M.Fmt.ContainsKey($fid)) { $M.Fmt[$fid] } else { $null })
                             a = (($ad | ForEach-Object { $_.n }) -join ', '); ad = $ad; nota = (Txt $l.Notes) }
    }
    $mesas += [ordered]@{ centro = [int]$t.SaleCenterId; mesa = (Txt $t.SaleLocationName); ticket = [int]$t.Id
                          abierta = ([datetime]$t.CreationDate).ToString('HH:mm'); nombre = (Txt $t.FriendlyName)
                          total = [math]::Round($total, 2); lineas = $lineas }
  }
  $json = ConvertTo-Json -InputObject @($mesas) -Depth 6 -Compress
  # se sube si cambio algo, y cada 30 s igual (asi la pagina sabe que el TPV esta conectado)
  if ($json -eq $script:huellaMesas -and ((Get-Date) - $script:ultimasMesas).TotalSeconds -lt 30) { return }
  if ($Simular) { Escribir "SIMULADO mesas abiertas: $json"; return }
  Supabase 'tpv_subir_mesas' @{ p_token = $cfg.integracionToken; p_mesas = @($mesas) } | Out-Null
  $script:huellaMesas = $json; $script:ultimasMesas = Get-Date
}

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
    # extras / quitar / salsa / partes del menu: van colgados del producto, a la misma cocina (como en Agora)
    $adds = @(); $sumaAdd = 0.0
    foreach ($ad in @($l.addins | ForEach-Object { $_ })) {
      if (-not $ad -or -not $ad.id) { continue }
      $sa = $M.Prod[[int]$ad.id]
      if (-not $sa) { throw "El codigo de Agora $($ad.id) ('$($ad.nombre)') no existe en Agora." }
      $sv = $M.Vat[[int]$sa.VatId]
      $pa = if ($ad.precio) { [double]$ad.precio } else { 0.0 }
      $sumaAdd += $pa
      $adds += [ordered]@{
        ProductId = [int]$sa.Id; ProductName = $sa.Name; SaleFormatId = [int]$sa.BaseSaleFormatId; SaleFormatName = $sa.Name; SaleFormatRatio = 1.0
        MainBarcode = ''; ProductPrice = $pa; VatId = [int]$sa.VatId; VatRate = [double]$sv.VatRate; SurchargeRate = [double]$sv.SurchargeRate
        ProductCostPrice = $(if ($sa.CostPrice) { [double]$sa.CostPrice } else { 0.0 })
        PreparationTypeId = $pr.PreparationTypeId; PreparationTypeName = (N $pr.PreparationTypeId $M.PT); PLU = ''; FamilyId = $null; FamilyName = ''
      }
    }
    if ($adds.Count) { $linea.Addins = $adds; $linea.ProductPrice = [math]::Round($precio - $sumaAdd, 2) }
    if ($l.nota) { $linea.Notes = [string]$l.nota }
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
  # Terraza (parte 21): pedido de mesa (Type = Table) en la mesa del centro TERRAZA; necesita la jornada abierta
  $tipo = 'TakeAway'
  $centro = [ordered]@{ Id = [int]$opc.centroId; Name = [string]$opc.centroNombre; Location = [string]$opc.centroUbicacion }
  if ($p.mesa) {
    $tipo = 'Table'
    $centro = [ordered]@{ Id = [int]$opc.terrazaCentroId; Name = [string]$opc.terrazaCentroNombre; Location = [string]$p.agora_mesa }
    $nombreCliente = ('Mesa {0} - {1} (web)' -f $p.mesa, $p.nombre)
  }
  if ($p.agora_centro) {   # pagina de camareros (parte 24): a la mesa elegida; Agora lo suma a la cuenta abierta
    $tipo = 'Table'
    $centro = [ordered]@{ Id = [int]$p.agora_centro; Name = [string]$p.centro_nombre; Location = [string]$p.agora_ubicacion }
    $nombreCliente = ('{0} - {1}' -f $p.agora_ubicacion, $p.camarero)
  }
  $pedido = [ordered]@{
    Serie = [string]$opc.serie; Number = [int]$opc.offsetNumero + [int]$p.id; Type = $tipo
    DeliveryDate = ('{0}T{1}:00' -f $p.dia, $p.hora); Status = 'Pending'
    Customer = [ordered]@{ Id = [long]$opc.clienteId; FiscalName = $nombreCliente; Cif = ''; Street = ''; City = ''; Region = ''; ZipCode = ''; ApplySurcharge = $false; CountryCode = 'ES'; AccountCode = '' }
    DeliveryAddress = [ordered]@{ Street = ''; City = ''; Region = ''; ZipCode = '' }
    Pos = [ordered]@{ Id = [int]$opc.posId; Name = [string]$opc.posNombre }
    Workplace = [ordered]@{ Id = [int]$opc.localId; Name = [string]$opc.localNombre }
    User = [ordered]@{ Id = [int]$opc.usuarioId; Name = [string]$opc.usuarioNombre }
    SaleCenter = $centro
    GlobalId = [guid]::NewGuid().ToString(); BusinessDay = $ahora.ToString('yyyy-MM-dd'); Guests = $null; Date = $fecha
    ServiceCharge = [ordered]@{ Rate = 0.0; VatId = 1; VatRate = 0.0; SurchargeRate = 0.0; ApplyToVatIncluded = $true; IgnoreTicketDiscounts = $false; GrossAmount = 0.0; NetAmount = 0.0; VatAmount = 0.0; SurchargeAmount = 0.0 }
    Lines = $lineas
    Discounts = [ordered]@{ DiscountRate = 0.0; CashDiscount = 0.0 }
    Payments = @(); Offers = @(); VatIncluded = $true
    Totals = [ordered]@{ GrossAmount = $g; NetAmount = $n; VatAmount = [math]::Round($g - $n, 2); SurchargeAmount = 0.0; Taxes = $taxes }
    ScheduledPreparation = $false
  }
  if ($p.pagado) {   # pagado online (parte 28, Redsys): Agora lo pasa solo a En Preparacion (imprime y va a cocina)
    # forma de pago propia de la web si esta en pedidos-agora.json (formaPagoWebId), si no la de tarjeta
    $fpId = if ($opc.formaPagoWebId) { [int]$opc.formaPagoWebId } else { [int]$opc.formaPagoTarjetaId }
    $fpNom = if ($opc.formaPagoWebId) { [string]$opc.formaPagoWebNombre } else { [string]$opc.formaPagoTarjetaNombre }
    $pedido.Payments = @([ordered]@{ MethodId = $fpId; MethodName = $fpNom; Amount = $g; PaidAmount = $g; ChangeAmount = 0.0; TipAmount = 0.0; Date = $fecha; PosId = [int]$opc.posId; IsPrepayment = $true; ExtraInformation = ('Web {0} Redsys {1}' -f $p.id, $p.pago_ref) })
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
  if ($a.mesa) { $titulo = 'Pedido n{0} {1} {2} TERRAZA MESA {3}' -f $C.no, $a.id, $C.punto, $a.mesa }
  $lineas = @()
  foreach ($it in @($a.items | ForEach-Object { $_ })) {
    if (-not $it) { continue }
    $lineas += ('{0}{1} {2}{3}' -f $it.cant, $C.por, $it.nombre, $(if ($it.extra) { ' (' + ([string]$it.extra).ToLower() + ')' } else { '' }))
  }
  $total = ([double]$a.total).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture).Replace('.', ',')
  $lineas += ('Total {0} {1} {2} {3}' -f $total, $C.eur, $C.punto, $(if ($a.pagado) { 'PAGADO online con tarjeta' } elseif ($a.mesa) { 'se paga en la mesa' } else { 'se paga al retirar' }))
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
  try { SubirMesas; $script:errMesas = $null } catch {
    $m = $_.Exception.Message
    if ($m -ne $script:errMesas) { Escribir "Mesas: $m"; $script:errMesas = $m }
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
      if ($p.agora_centro) {
        Escribir "OK  pedido $($p.id) -> Agora $($opc.serie)-$num, $($p.centro_nombre) $($p.agora_ubicacion) ($($p.camarero)), $($pedido.Totals.GrossAmount) EUR"
        $script:ultimasMesas = [datetime]::MinValue   # que la pagina vea enseguida la mesa actualizada
      } else {
        Escribir "OK  pedido $($p.id) -> Agora $($opc.serie)-$num, retira $($p.dia) $($p.hora), $($pedido.Totals.GrossAmount) EUR"
      }
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
