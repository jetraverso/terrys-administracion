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
