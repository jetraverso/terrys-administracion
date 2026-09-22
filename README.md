# Terry's Administración

Página de administración general de Terry's Burgers. Tiene tres solapas: **Compras** (ingresos, egresos y facturas a proveedores de Terrys Burgers S.L., mes a mes; reemplaza al Google Sheet), **Ventas** (las ventas diarias que llegan de Ágora) y **Reportes** (en qué se va la plata). Es una sola página (`index.html`) que guarda todo en Supabase y pide email y contraseña para entrar.

Mismo diseño que [Terry's Horarios](https://github.com/jetraverso/terrys-horarios), siempre en modo noche.

## Qué hace

- **Planilla con las 13 columnas fijas arriba:** Fecha, Ingresos, Egresos, Detalle operación, Tipo de operación, Desde dónde, Hacia dónde, Estado, Información, Facturas, Pagado, Clara, Comentarios.
- **Se carga como un Sheet:** se escribe directo en las celdas y se guarda solo al salir de cada una. La última fila en blanco es para un movimiento nuevo. Enter baja a la fila de abajo.
- **Mes a mes:** flechas ‹ › y una tira con los 12 meses del año (cada uno muestra cuánto se gastó). El primer botón de la tira muestra el **año completo**, con las filas agrupadas por mes y un subtotal por mes.
- **Tarjetas de resumen** del período: ingresos, egresos, balance, por pagar (egresos sin tildar Pagado) y egresos sin factura.
- **Fecha en día/mes/año** (no depende del idioma del navegador). Se puede escribir corta: `23/7`, `2307` o solo `23` (el mes y el año que falten se toman de la fecha que ya tenía la fila), o elegirla con el ícono del calendario de la celda.
- **Orden por fecha:** al salir de una fila nueva, o de una a la que le cambiaste la fecha, la fila se acomoda sola en su lugar (con un destello para ver dónde quedó).
- **Teclado:** Tab recorre todas las celdas, incluidas Pagado y Clara (la barra espaciadora las tilda o destilda); Enter baja a la fila de abajo.
- **Tipo, Desde, Hacia y Estado** sugieren lo que ya cargaste antes **en esa misma columna** (de cualquier año), así quedan siempre escritos igual: al escribir aparece la lista, se elige con las flechas y se acepta con Enter (se queda en la celda) o con Tab (pasa a la siguiente).
- **Columnas que se adaptan:** cada columna toma el ancho de su texto más largo. Si no entra todo en la pantalla, Detalle, Información y Comentarios siguen en el renglón de abajo (la fila crece en alto) en vez de cortarse.
- **Ancho a mano:** arrastrando el borde derecho del título de una columna se le pone el ancho que quieras; queda guardado en ese navegador (cada persona y cada computadora tiene los suyos) y la columna queda marcada con una rayita azul. Doble clic en el borde la vuelve a automática, y abajo de la planilla hay un link para volver todas.
- **Información con link de la factura:** en Información se ve solo un texto (por ejemplo `FACTURA` o `Factura luz`) y el link queda guardado atrás: el botón ↗ lo abre. Si pegás un link pelado queda como `FACTURA` con ese link; si pegás texto + link, el texto queda como nombre. Para ponerle o cambiarle el link a un texto ya escrito: el botón de la cadenita de la celda (o Ctrl/Cmd + K). En la base se guarda como `[TEXTO](https://link)` en el campo `informacion`.
- **Facturas, Pagado y Clara son casillas.** Facturas se tilda sola cuando Información pasa a tener link (se puede tildar o destildar a mano igual). En la base `factura` guarda `Sí` o vacío. Las filas cargadas con la versión anterior (nombre + link en Facturas) se pasan solas a Información la primera vez que se abre su año.
- **Buscar y filtrar** (por pagar, sin factura, sin Clara), **duplicar** una fila (para gastos que se repiten), **borrar** con "Deshacer".
- **Pegar desde Sheet:** copiás las filas del Google Sheet (las 13 columnas en ese orden) y las importa de una. Saltea solos los títulos de mes y los subtotales.
- **Exportar CSV** del mes o del año que estés viendo (abre bien en Excel y Sheets).
- **Copia completa:** baja un solo CSV con todos los movimientos de todos los años y todas las solapas. Es la copia de seguridad: conviene bajarla cada tanto y guardarla (el plan gratis de Supabase no hace backups). Abajo de la planilla dice cuándo fue la última.

## Reportes

Solapa **Reportes**. Usa el mismo mes/año que la planilla (la tira de meses; el primer botón es el año completo) y no guarda nada: todo se calcula en el momento con los movimientos cargados.

- **Resumen del período:** egresos e ingresos (con la variación contra el mes anterior, o contra el año anterior en la vista de año), balance, dónde más se gastó, % pagado y % con factura.
- **Ingresos y egresos por mes** del año. Tocando un mes se pasa a su detalle.
- **En qué se fue la plata:** ranking de egresos agrupados por *Proveedor (Hacia dónde)*, *Detalle*, *Tipo de operación* o *Desde dónde* (selector "Agrupar por"), con el % del total y la variación contra el período anterior. Junta solo las variantes de escritura (mayúsculas y acentos: "Reposición" y "Reposicion" cuentan como lo mismo). Tocando una fila se ven sus movimientos, con link a la factura y un atajo para verlos en la planilla.
- **Mes a mes:** tabla del año con los 15 grupos de más gasto y un color más fuerte cuanto más se gastó, para ver qué viene subiendo.

## Ventas (Ágora POS)

Solapa **Ventas**: reportes de las ventas del local que llegan solas desde Ágora cada noche (ver [`agora/README.md`](agora/README.md) para instalar el script en la computadora del TPV). Mismo mes/año que la planilla; el primer botón de la tira es el año completo.

- **Resumen:** ventas, tickets y promedio por día, ticket promedio y artículos por ticket, neto sin IVA, margen sobre producto (con el precio de costo cargado en Ágora), descuentos e invitaciones, y ventas menos los egresos de la planilla. Con la variación contra el mes anterior (por día si el mes no terminó).
- **Ventas por día** del mes (o por mes en la vista de año). Fines de semana sombreados y rayas en los días que no llegaron (arriba avisa cuáles faltan y qué comando correr en el TPV).
- **Promedio por día de la semana**, **por hora**, **centro de venta** (local, terraza, delivery, take away), **formas de pago** (efectivo, tarjeta, Glovo), **familia y preparación**, **quién cobró**.
- **Productos más vendidos** con unidades, importe, % y margen (ordenables por importe, unidades o margen).
- **Tickets del día:** tocando un día del gráfico aparecen todos sus tickets con hora, centro, forma de pago, quién cobró y los productos.

Mientras `SUPABASE_URL` esté vacío la página funciona en **modo demo**: entra con cualquier email y contraseña `1234`, y guarda solo en ese navegador. Sirve para probarla, no para trabajar.

## Puesta en marcha (una sola vez)

### 1. Proyecto en Supabase

1. https://supabase.com → **New project** (por ejemplo `terrys-admin`), región **West EU**. Conviene un proyecto aparte del de horarios.
2. **SQL Editor** → pegá todo [`schema.sql`](schema.sql) → **Run**. Tiene que decir "Success. No rows returned".

### 2. Crear tu usuario

1. **Authentication → Users → Add user → Create new user**.
2. Tu email, una contraseña, y tildá **Auto Confirm User**.
3. **SQL Editor:** `insert into public.admin_usuarios (email, nombre) values ('tu@mail.com', 'Tu nombre');` (la lista de quién entra no está en `schema.sql` porque el repositorio es público).

> Supabase no acepta contraseñas de menos de 6 caracteres, así que `1234` no sirve ahí. Poné una provisoria de 6 o más (o ya la definitiva) y después la cambiás desde la página con el botón **Contraseña**.

### 3. Cerrar el registro público (importante)

**Authentication → Sign In / Providers → Allow new users to sign up → desactivar.** Así nadie puede crearse una cuenta por su lado: los usuarios los creás solo vos.

### 4. Conectar la página

**Project Settings → API**: copiá la **Project URL** y la clave **anon / public**, y pegalas al principio del script de `index.html`:

```js
const SUPABASE_URL='https://xxxx.supabase.co';
const SUPABASE_KEY='eyJ...';
```

La `anon` es pública por diseño. La que **nunca** va en la página es la `service_role`.

### 5. Publicarla

Tres caminos, los tres igual de seguros para los datos (el código no tiene ningún secreto y los datos nunca están en el archivo, están en Supabase):

- **Repo público + GitHub Pages (gratis):** igual que Terry's Horarios. Settings → Pages → Deploy from a branch → `main` / root.
- **Repo privado + GitHub Pages:** lo mismo, pero necesita GitHub Pro. La página publicada es pública igual; lo único que se oculta es el código y su historial en GitHub.
- **Repo privado + Cloudflare Pages o Netlify (gratis):** conectás el repo y publican `index.html` en cada commit (preset `None`, sin build command, output `/`).

La dirección de la página la puede abrir cualquiera que la conozca, pero sin email, contraseña y el código del celular solo se ve la pantalla de entrada.

Después de publicar: Supabase → Authentication → URL Configuration → **Site URL** = la dirección de la página.

## Cómo está protegido

- Entrar exige usuario y contraseña de Supabase Auth **y un código de 6 dígitos del celular** (verificación en dos pasos, TOTP). La primera vez que alguien entra, la página le muestra un QR para vincular su app de autenticación (Google Authenticator, Microsoft Authenticator, 1Password, Contraseñas del iPhone). Conviene que cada persona entre y lo vincule apenas le creás el usuario.
- La base también lo exige, no solo la página: `es_admin()` pide una sesión de nivel `aal2`. Con la contraseña sola, sin el código, no se lee ni se escribe nada.
- Además, el email tiene que estar en la tabla `admin_usuarios`. Todas las tablas tienen RLS: sin sesión, o con una sesión que no esté en esa lista, no se lee ni se escribe nada.
- Cada alta, edición y borrado queda en `movimientos_log` con quién, cuándo, el antes y el después. Si se borra algo por error se recupera desde ahí (Supabase → Table Editor).

### Si alguien pierde o cambia el celular

Supabase → Authentication → Users → abrí el usuario → borrá su factor MFA. Si no encontrás esa opción, en el SQL Editor: `delete from auth.mfa_factors where user_id = (select id from auth.users where email = 'persona@mail.com');`. La próxima vez que entre, la página le muestra un QR nuevo. (Si sos vos, lo hacés desde tu panel de Supabase: por eso esa cuenta también tiene que tener verificación en dos pasos.)

### Darle acceso a otra persona

1. Authentication → Users → Add user (su email y una contraseña, Auto Confirm).
2. SQL Editor: `insert into public.admin_usuarios (email, nombre) values ('persona@mail.com', 'Nombre');`

Para quitárselo: `delete from public.admin_usuarios where email = 'persona@mail.com';`

## Agregar solapas

- **Otra sociedad con la misma planilla:** una línea más en `TABS` (en `index.html`) con otro valor de `empresa`. No hay que tocar la base.
- **Solapas de otro tipo** (proveedores, caja, etc.): se agregan como una vista nueva en la página y, si hace falta, una tabla nueva en `schema.sql` con la misma política `es_admin()`.

## Archivos

- `index.html` — toda la aplicación.
- `schema.sql` — tablas, seguridad (RLS) y registro de cambios para Supabase. Se puede correr las veces que haga falta: no borra datos.
- `agora/` — script de PowerShell que sube las ventas diarias de Ágora a Supabase, con su README de instalación.
