# Ventas de Ágora → Terry's Administración

`subir-ventas.ps1` corre en la computadora del TPV (Windows, no hay que instalar nada) y cada noche le pide a la API de integración de Ágora las ventas del día y las sube a Supabase. La página las muestra en la solapa **Ventas**.

## Instalación (una sola vez, en la computadora del TPV)

1. Creá una carpeta, por ejemplo `C:\TerrysAdmin`, y copiá adentro `subir-ventas.ps1` y `config.ejemplo.json`.
2. Renombrá `config.ejemplo.json` a `config.json` y completalo:
   - `agoraExport`: la URL de la API de Ágora con `{dia}` donde va la fecha. Si la muestra la sacaste con otra URL (otro puerto u otro parámetro), poné esa.
   - `agoraToken`: el token de la API de Ágora (Administración → Servicios de integración).
   - `integracionToken`: el token que diste de alta en Supabase (ver abajo).
3. En Supabase → SQL Editor, dá de alta el token (elegí uno largo y al azar; el mismo va en `config.json`):
   ```sql
   insert into public.integraciones (nombre, token_hash)
   values ('agora', encode(extensions.digest('EL-TOKEN', 'sha256'), 'hex'))
   on conflict (nombre) do update set token_hash = excluded.token_hash;
   ```
4. Probalo a mano. En PowerShell, dentro de la carpeta:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\subir-ventas.ps1 -Dias 3
   ```
   Tiene que decir `OK 2026-09-21: 26 tickets`. Si dice ERROR, el mensaje explica qué falló (token, URL de Ágora, internet).
5. Carga inicial de lo que ya tenés en Ágora (por ejemplo desde julio):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\subir-ventas.ps1 -Desde 2026-07-01
   ```
6. Programalo para que corra solo todas las noches (4:00). En PowerShell **como administrador**:
   ```powershell
   schtasks /Create /TN "Terrys ventas a Supabase" /SC DAILY /ST 04:00 /RL HIGHEST /F /TR "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\TerrysAdmin\subir-ventas.ps1"
   ```
   Si la computadora suele estar apagada a esa hora, abrí el Programador de tareas, buscá la tarea y en **Configuración** tildá "Ejecutar la tarea lo antes posible si se omite un inicio programado". Como cada corrida sube los últimos 3 días, si un día falla se rellena solo al día siguiente.

Cada corrida deja una línea en `subir-ventas.log`, en la misma carpeta.

## Qué se guarda

Cada día queda en la tabla `ventas_dias` tal cual lo devuelve Ágora (tickets, líneas, pagos, centro de venta, hora, quién cobró, precio de costo). La página arma un resumen compacto por día la primera vez que lo necesita, y con eso hace los reportes de la solapa Ventas.

Si un día se vuelve a subir (por ejemplo después de corregir algo en Ágora), reemplaza al anterior.

# Pedidos de la web → Ágora (`enviar-pedidos.ps1`)

Los pedidos take away de terrysburgers.com/pedido/ entran solos en Ágora (solapa de pedidos **Delivery**, serie **WEB**, número = 100 + nº del pedido web). Sin pago entran **Pendientes**: tocar **Preparar** en el TPV para que se imprima y salga en cocina. Si algún día llegan pagados online, Ágora los pasa solo a En Preparación.

- `enviar-pedidos.ps1` corre en el TPV y cada 5 s en horario del local (12–16 y 19–23:30; 60 s fuera de horario, configurable en `pedidos-agora.json`) le pide a Supabase los pedidos nuevos (`agora_pendientes`, token `agora`, el mismo de las ventas), los arma con los datos de Ágora (productos, IVA, familias, preparación) y los manda a `/api/import/`. Después marca cada pedido en Supabase (`agora_marcar`): el admin muestra «En Ágora · WEB-n» o el error (con botón Reintentar).
- `pedidos-agora.json`: serie, cliente WEB (`clienteId`), TPV, local, usuario, centro de venta TAKE AWAY y tarifa. Sin secretos.
- Qué producto de Ágora es cada producto de la web: en el admin, solapa Pedidos → Productos → Editar (código Ágora, código doble y salsas `Barbacoa=2167, …`).
- Aviso al celular de cada pedido nuevo: lo manda este mismo programa a ntfy desde la conexión del local (parte 16 del schema: `tpv_avisos_pendientes` / `tpv_aviso_marcar`), porque ntfy.sh gratis limita por IP y la de Supabase es compartida. Solo con el TPV prendido; pedidos de las últimas 6 horas.
- Catálogo para la web (parte 18): al cargar los datos de Ágora (al arrancar y cada hora) sube a Supabase los productos con precio en la tarifa del centro TAKE AWAY y sus grupos de opciones (`agora_subir_catalogo`). La página de pedidos toma de ahí precios, extras, quitar, salsas y menús; cada opción elegida viaja a Ágora como `Addin` del producto.
- Registro: `enviar-pedidos.log` al lado del script.

Puesta en marcha (una vez):
1. Supabase → SQL Editor: correr la parte 14 de `schema.sql`.
2. En Ágora crear el cliente «WEB» y poner su número en `clienteId` de `pedidos-agora.json`.
3. Probar sin mandar nada: `powershell -ExecutionPolicy Bypass -File .\enviar-pedidos.ps1 -Simular` (deja `exploracion\simulado-pedido-N.json`).
4. Probar una vuelta de verdad: `... -File .\enviar-pedidos.ps1 -UnaVez`.
5. Que arranque solo al iniciar sesión en el TPV (PowerShell como administrador):
   ```powershell
   schtasks /Create /TN "Terrys pedidos web a Agora" /SC ONLOGON /DELAY 0001:00 /RL HIGHEST /F /TR "powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File \"G:\Mi unidad\Terry Admin AI\Sistema Pedidos\enviar-pedidos.ps1\""
   ```
   (`/DELAY` deja tiempo a que Google Drive monte la unidad G:.) Para frenarlo: `schtasks /End /TN "Terrys pedidos web a Agora"`.

Scripts de exploración que se usaron para armar esto (solo para diagnóstico): `explorar-api.ps1`, `buscar-pedidos.ps1`, `probar-import.ps1`, `estados-pedido.ps1`, `probar-pedido.ps1`.
