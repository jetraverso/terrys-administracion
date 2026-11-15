# Terry's - muestra las mesas ABIERTAS de Agora con lo que tienen cargado (lee la base de Agora, SOLO LECTURA).
#
#   powershell -ExecutionPolicy Bypass -File "G:\Mi unidad\Terry Admin AI\Sistema Pedidos\ver-mesas.ps1"
#
# Con -Probar "MESA 1": muestra las mesas, manda a esa mesa de TERRAZA un pedido de prueba
# (1 Coca-Cola, con probar-mesa.ps1) y vuelve a mostrar las mesas, para ver si Agora lo suma
# a la cuenta que ya estaba abierta o abre otra cuenta en la misma mesa. Despues hay que anularlo.
#
#   powershell -ExecutionPolicy Bypass -File "G:\Mi unidad\Terry Admin AI\Sistema Pedidos\ver-mesas.ps1" -Probar "MESA 1"
#
# Deja el resultado en exploracion-mesas\ver-mesas.txt (Claude lo lee del Drive).

param([string]$Probar = '')
$ErrorActionPreference = 'Stop'
$carpeta = Split-Path -Parent $MyInvocation.MyCommand.Path
$salida = Join-Path $carpeta 'exploracion-mesas'
New-Item -ItemType Directory -Force -Path $salida | Out-Null
$archivo = Join-Path $salida 'ver-mesas.txt'
"Mesas abiertas en Agora - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Set-Content $archivo -Encoding UTF8
function Anotar($t, $color = 'Gray') { Write-Host $t -ForegroundColor $color; Add-Content $archivo $t -Encoding UTF8 }

function Consulta($sql) {
  $cn = New-Object System.Data.SqlClient.SqlConnection 'Server=localhost\AGORA;Database=igtpos;Integrated Security=True;Connect Timeout=8;ApplicationIntent=ReadOnly'
  $cn.Open()
  try {
    $cmd = $cn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 20
    $t = New-Object System.Data.DataTable; $t.Load($cmd.ExecuteReader()); return ,$t
  } finally { $cn.Close() }
}

function Mostrar($titulo) {
  Anotar "`r`n== $titulo ($(Get-Date -Format 'HH:mm:ss')) ==" 'Cyan'
  $tk = Consulta @"
select t.Id, t.SaleCenterId, t.SaleCenterName, t.SaleLocationName, t.CreationDate, t.FriendlyName, t.Type, t.PrintCount,
       t.OpenerPosId, t.BlockerPosId, t.CurrentUserId
  from dbo.Ticket t
 where t.FrozenDate is null and t.CreationDate > dateadd(day, -2, getdate())
 order by t.SaleCenterName, t.SaleLocationName, t.Id
"@
  if ($tk.Rows.Count -eq 0) { Anotar '(ninguna mesa abierta)'; return }
  $ln = Consulta @"
select l.TicketId, l.Id, l.TicketLineIndex, l.ProductName, l.Quantity, l.TotalAmount, l.IsCancelled, l.Status, l.CreationDate, l.Notes,
       stuff((select ', ' + a.ProductName from dbo.TicketLineAddin a where a.TicketLineId = l.Id order by a.AddinIndex for xml path('')), 1, 2, '') as Addins
  from dbo.TicketLine l
 where l.TicketId in (select Id from dbo.Ticket where FrozenDate is null and CreationDate > dateadd(day, -2, getdate()))
 order by l.TicketId, l.TicketLineIndex
"@
  foreach ($t in $tk) {
    $nombre = if ($t.FriendlyName -is [DBNull]) { '' } else { " '$($t.FriendlyName)'" }
    Anotar ("{0} - {1}{2}  (ticket {3}, centro {4}, abierta {5:HH:mm}, tipo {6}, impresiones {7}, bloqueada por TPV {8})" -f `
      $t.SaleCenterName, $t.SaleLocationName, $nombre, $t.Id, $t.SaleCenterId, $t.CreationDate, $t.Type, $t.PrintCount, $t.BlockerPosId) 'White'
    foreach ($l in ($ln | Where-Object { $_.TicketId -eq $t.Id })) {
      $x = if ($l.IsCancelled) { ' [ANULADA]' } else { '' }
      $a = if ($l.Addins -is [DBNull] -or -not $l.Addins) { '' } else { "  + $($l.Addins)" }
      $n = if ($l.Notes -is [DBNull] -or -not $l.Notes) { '' } else { "  ($($l.Notes))" }
      Anotar ("    {0:0} x {1}  {2:0.00}  estado {3}  {4:HH:mm}{5}{6}{7}" -f $l.Quantity, $l.ProductName, $l.TotalAmount, $l.Status, $l.CreationDate, $a, $n, $x)
    }
  }
}

try { Mostrar 'Antes' } catch { Anotar "No pude leer la base de Agora: $($_.Exception.Message)" 'Red'; exit 1 }

if ($Probar) {
  Anotar "`r`nMando el pedido de prueba (1 Coca-Cola) a TERRAZA - $Probar ..." 'Yellow'
  & (Join-Path $carpeta 'probar-mesa.ps1') -Enviar -Mesa $Probar -Tipo Table
  Start-Sleep -Seconds 6
  Mostrar 'Despues del pedido de prueba'
  Anotar "`r`nMira tambien en el TPV como quedo $Probar (una cuenta o dos) y despues anula la Coca-Cola de prueba." 'Yellow'
}
Anotar "`r`nListo. Avisale a Claude." 'Green'
