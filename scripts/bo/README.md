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

## Sumar o sacar campañas

Editar `scripts/bo/campanias.json`. Cada grupo es una campaña y cada template, un segmento.
`tipo: externa` = lista de no usuarios (convierte si se registra o se suscribe);
`tipo: cuentas` = usuarios existentes (convierte si se suscribe).
