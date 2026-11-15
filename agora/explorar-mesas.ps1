# Terry's - explora DONDE guarda Agora las mesas abiertas (SOLO LECTURA).
#
# La API de integracion de Agora no tiene un "export" de mesas/tickets abiertos, asi que
# este script busca otra forma de leerlos:
#   1. Prueba mas filtros de la API (solo GET).
#   2. Busca en la instalacion de Agora con que base de datos trabaja (oculta contrasenas).
#   3. Se conecta a esa base SQL Server con el usuario de Windows y lista las tablas que
#      tienen que ver con tickets / pedidos / mesas, con sus columnas y cantidad de filas,
#      y las ultimas 5 filas de las que parecen tickets abiertos.
# Solo hace SELECT y GET: no crea, no modifica ni borra nada en Agora.
#
# ANTES de correrlo, deja ABIERTA una mesa en Agora (p. ej. TERRAZA - MESA 1 con 1 producto)
# para que se vea en los datos. Despues se puede anular.
#
#   powershell -ExecutionPolicy Bypass -File "G:\Mi unidad\Terry Admin AI\Sistema Pedidos\explorar-mesas.ps1"
#
# Deja todo en la carpeta "exploracion-mesas" al lado del script (Claude lo lee desde el Drive).

$ErrorActionPreference = 'Continue'
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
$rutaConfig = Join-Path $carpeta 'config.json'
if (-not (Test-Path $rutaConfig)) { $rutaConfig = Join-Path $env:USERPROFILE 'Documents\Terrys Admin\config.json' }
$cfg = Get-Content $rutaConfig -Raw -Encoding UTF8 | ConvertFrom-Json
$base = ([uri]$cfg.agoraExport).GetLeftPart([UriPartial]::Authority)
$H = @{ 'Api-Token' = $cfg.agoraToken }
$salida = Join-Path $carpeta 'exploracion-mesas'
New-Item -ItemType Directory -Force -Path $salida | Out-Null
$resumen = Join-Path $salida 'resumen.txt'
"Exploracion de mesas abiertas - $(Get-Date -Format 'yyyy-MM-dd HH:mm')`r`nBase API: $base`r`n" | Set-Content $resumen -Encoding UTF8
function Anotar($t, $color = 'Gray') { Write-Host $t -ForegroundColor $color; Add-Content $resumen $t -Encoding UTF8 }
function Ocultar($t) { return ($t -replace '(?i)(password|pwd)\s*=\s*[^;"<]*', '$1=***') }

# ---------- 1. Mas filtros de la API ----------
Anotar "`r`n== 1. API =="
$hoy = (Get-Date).ToString('yyyy-MM-dd')
$urls = @()
foreach ($f in 'SaleLocations','Locations','Tables','OpenTables','Accounts') { $urls += "$base/api/export-master/?filter=$f" }
foreach ($f in 'OpenSalesDocuments','PendingSalesDocuments','SalesDocuments','Tickets','OpenTickets','PendingTickets',
               'TableOrders','Orders','Bills','Accounts','PosCloseOuts','SystemCloseOuts','WorkplacesSummary','SaleLocations') {
  $urls += "$base/api/export/?filter=$f&business-day=$hoy"
}
foreach ($p in '/api/sale-locations/','/api/tables/','/api/tickets/','/api/open-tickets/','/api/orders/','/api/status/') { $urls += "$base$p" }
foreach ($u in $urls) {
  try {
    $r = Invoke-WebRequest -Uri $u -Headers $H -UseBasicParsing -TimeoutSec 30
    $n = 'api-' + (($u -replace [regex]::Escape($base), '') -replace '[^a-zA-Z0-9]+', '_') + '.txt'
    $r.Content | Set-Content (Join-Path $salida $n) -Encoding UTF8
    Anotar ("OK     {0}  {1}  ({2} bytes)" -f $r.StatusCode, $u, $r.Content.Length)
  } catch {
    $c = $null; try { $c = [int]$_.Exception.Response.StatusCode } catch {}
    Anotar ("ERROR  {0}  {1}" -f $c, $u)
  }
}

# ---------- 2. Con que base trabaja Agora ----------
Anotar "`r`n== 2. Configuracion de Agora =="
$dirs = @("${env:ProgramFiles(x86)}\IGT Microelectronics", "$env:ProgramFiles\IGT Microelectronics", "$env:ProgramData\IGT Microelectronics", "$env:LOCALAPPDATA\IGT Microelectronics", "$env:APPDATA\IGT Microelectronics")
$pistas = @()
foreach ($d in $dirs) {
  if (-not (Test-Path $d)) { continue }
  Anotar "Carpeta: $d"
  Get-ChildItem $d -Recurse -File -Include *.config,*.ini,*.json,*.xml,*.conf -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -lt 2MB -and $_.FullName -notmatch 'custom-queries|\\locales?\\|\\res\\' } |
    ForEach-Object {
      $f = $_.FullName
      try {
        Select-String -Path $f -Pattern 'Data Source|Server\s*=|Initial Catalog|Database\s*=|SqlServer|connectionString|\\SQLEXPRESS' -ErrorAction SilentlyContinue |
          Select-Object -First 6 | ForEach-Object { $l = Ocultar ($_.Line.Trim()); if ($l.Length -gt 300) { $l = $l.Substring(0,300) }; Anotar "  $f : $l"; $script:pistas += $l }
      } catch {}
    }
}
Anotar "Servicios de SQL Server:"
Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'MSSQL*' -or $_.Name -like 'SQL*' -or $_.DisplayName -like '*Agora*' } |
  ForEach-Object { Anotar ("  {0}  [{1}]  {2}" -f $_.Name, $_.Status, $_.DisplayName) }
$instancias = @()
try {
  $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
  $k.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $instancias += $_.Name }
} catch {}
Anotar "Instancias en el registro: $($instancias -join ', ')"

# ---------- 3. Tablas de la base ----------
Anotar "`r`n== 3. Base de datos =="
$servidores = @()
foreach ($i in $instancias) { if ($i -eq 'MSSQLSERVER') { $servidores += '.' } else { $servidores += ".\$i" } }
foreach ($p in $pistas) { if ($p -match '(?i)(Data Source|Server)\s*=\s*([^;"<]+)') { $servidores += $Matches[2].Trim() } }
$servidores = @($servidores | Select-Object -Unique)
if (-not $servidores) { $servidores = @('.\SQLEXPRESS', '.') }

function Consulta($cn, $sql) {
  $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 30
  $t = New-Object System.Data.DataTable
  $t.Load($cmd.ExecuteReader())
  return ,$t
}
$hecho = $false
foreach ($s in $servidores) {
  try {
    $cn = New-Object System.Data.SqlClient.SqlConnection "Server=$s;Database=master;Integrated Security=True;Connect Timeout=8;ApplicationIntent=ReadOnly"
    $cn.Open()
  } catch { Anotar "No me pude conectar a $s : $($_.Exception.Message)"; continue }
  Anotar "Conectado a $s"
  $dbs = Consulta $cn "select name from sys.databases where database_id > 4 order by name"
  Anotar ("Bases: " + (($dbs | ForEach-Object { $_.name }) -join ', '))
  foreach ($db in ($dbs | ForEach-Object { $_.name })) {
    try { $cn.ChangeDatabase($db) } catch { Anotar "  (sin permiso para $db)"; continue }
    $tabs = Consulta $cn "select s.name + '.' + t.name as tabla, sum(p.rows) as filas from sys.tables t join sys.schemas s on s.schema_id = t.schema_id join sys.partitions p on p.object_id = t.object_id and p.index_id in (0,1) group by s.name, t.name order by 1"
    $lista = $tabs | ForEach-Object { "{0} ({1})" -f $_.tabla, $_.filas }
    ($lista -join "`r`n") | Set-Content (Join-Path $salida "tablas-$db.txt") -Encoding UTF8
    Anotar "  Base $db : $($tabs.Rows.Count) tablas (lista en tablas-$db.txt)"
    $interes = $tabs | Where-Object { $_.tabla -match '(?i)ticket|order|pedido|location|table|mesa|salecenter|salesdoc|document|line|open|pending|account' }
    $det = @()
    foreach ($t in $interes) {
      $cols = Consulta $cn ("select c.name + ' ' + ty.name as col from sys.columns c join sys.types ty on ty.user_type_id = c.user_type_id where c.object_id = object_id('{0}') order by c.column_id" -f $t.tabla)
      $det += "### $($t.tabla)  ($($t.filas) filas)"
      $det += "    " + (($cols | ForEach-Object { $_.col }) -join ', ')
      # Ultimas filas de las tablas chicas o que parecen tickets/mesas abiertos (para ver la mesa de prueba)
      if ($t.tabla -match '(?i)open|pending|ticket|location|order' -and $t.filas -gt 0) {
        try {
          $filas = Consulta $cn ("select top 5 * from {0} order by 1 desc" -f $t.tabla)
          foreach ($f in $filas) {
            $vals = foreach ($c in $filas.Columns) { $v = [string]$f[$c.ColumnName]; if ($v.Length -gt 60) { $v = $v.Substring(0,60) + '...' }; "$($c.ColumnName)=$v" }
            $det += "    - " + ($vals -join ' | ')
          }
        } catch { $det += "    (no pude leer filas: $($_.Exception.Message))" }
      }
    }
    ($det -join "`r`n") | Set-Content (Join-Path $salida "detalle-$db.txt") -Encoding UTF8
    Anotar "  Tablas de interes en $db : $(@($interes).Count) (detalle en detalle-$db.txt)"
    $hecho = $true
  }
  $cn.Close()
}
if (-not $hecho) { Anotar "No pude leer ninguna base con el usuario de Windows." 'Yellow' }
Anotar "`r`nListo. Avisale a Claude (lee la carpeta exploracion-mesas desde el Drive)." 'Green'
