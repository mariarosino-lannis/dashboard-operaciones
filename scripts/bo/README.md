# Datos del BO de Lannis (campañas y DDJJ)

El dashboard lee `data/bo.json`. Ese archivo lo genera una tarea programada de Claude que consulta el BO
por el MCP de Lannis (solo lectura) y lo sube a este repo. El navegador no habla con el BO ni con el MCP.

## Qué hay en `data/bo.json`

Solo agregados: conteos por campaña, por impuesto, por segmento y por persona del equipo.
**Nunca** CUITs, emails ni nombres de clientes (el repo es público).

- `campanias`: embudo por template (enviados → entregados → abiertos → clics → registros / suscripciones)
  y serie diaria. La conversión se mide cruzando destinatario con cuentas de Lannis dentro de la ventana
  de `campanias.json` (14 días por defecto).
- `facturacion`: facturas emitidas desde Lannis por canal (WhatsApp con IA, app web, MCP, integraciones…) y
  cuántos clientes facturaron por cada uno, por semana y por mes, más los clientes activos al cierre de cada
  período (para "consultas por cliente activo"). Sin facturas importadas.
- `ddjj`: estado actual, avance por período fiscal, evolución semanal reconstruida desde el historial de
  cambios, movimientos por quién los hizo y actividad del equipo. `historial` guarda una foto semanal de
  vencidas y abiertas (eso no se puede reconstruir hacia atrás).

## Universo de DDJJ

Obligaciones de clientes propios de Lannis: sin clientes de estudios (`estudio_client`) ni cuentas free,
y sin Monotributo, Autónomos ni anticipos (son pagos, no DDJJ que trabaje el equipo).

## Cómo actualizar a mano

```bash
python3 scripts/bo/build.py render      # escribe scripts/bo/out/*.sql
# correr cada scripts/bo/out/<nombre>.sql con run_readonly_query (MCP de Lannis)
# y guardar el resultado (columna j) en scripts/bo/out/<nombre>.json
python3 scripts/bo/build.py build       # escribe data/bo.json
git add data/bo.json && git commit -m "Actualizar datos del BO" && git push
```

## Clics por enlace

`clics.sql` lee la tabla `EmailClick` del BO (existe desde el 13/11/2026) y agrupa los clics de cada campaña por
destino. El enlace exacto incluye el email y un token del destinatario (por ejemplo el de darse de baja), así que
**nunca** se usa completo: se guarda solo dominio + ruta, con ids largos tapados, y el enlace de baja como `BAJA`.
`build.py` rechaza cualquier destino que tenga `@`, `%40`, `?` o `=`.

## Análisis escrito de campañas

La actualización de los lunes escribe 3 a 6 puntos sobre las campañas de la semana anterior
(`analisis.semanal`) y, el primer lunes de cada mes, un análisis más completo del mes anterior
(`analisis.mensual`). Aparecen en la slide "Campañas de email" del Weekly / Mensual y arriba de la
pestaña Campañas. Se guarda el historial de los últimos 12 de cada tipo. `build.py` rechaza cualquier
punto que tenga algo parecido a un email, un CUIT o un teléfono.

## Sumar o sacar campañas

Editar `scripts/bo/campanias.json`. Cada grupo es una campaña y cada template, un segmento.
Grupo `tipo: puntual` = envío manual o tanda (slide propia mientras dura la ventana de conversión);
`tipo: continua` = flujo automático diario (va en la slide "Campañas de email" con los envíos del período).
`conversion: false` = no se mide conversión (encuestas).
Template `tipo: externa` = lista de no usuarios (convierte si se registra o se suscribe);
`tipo: cuentas` = usuarios existentes (convierte si se suscribe).
