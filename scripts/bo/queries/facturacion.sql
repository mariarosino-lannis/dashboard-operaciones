-- Facturación por canal y clientes activos, por semana (últimas 12, lunes a domingo) y por mes (últimos 6). Hora de Argentina.
-- Devuelve una fila con la columna j (JSON).
-- Facturas: emitidas desde Lannis y autorizadas por ARCA (sin las importadas de ARCA ni de Mercado Libre).
-- Canal = Invoice.source (varys = WhatsApp con IA, dashboard = app web, mcp_external = IA externa por MCP, etc.).
-- Clientes activos al cierre de cada período: se reconstruye con inicio y cancelación de suscripción
-- (clientes propios, sin estudios). Da apenas menos que el conteo exacto de hoy (activosHoy).
-- semanas / meses: [período, clientes activos al cierre, {canal: [facturas, clientes que facturaron]}, clientes únicos que facturaron]
WITH inv AS (
  SELECT COALESCE(source,'otro') src, cuit, ("createdAt" AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires') t
  FROM "Invoice" WHERE "importSource" IS NULL AND estado='AUTORIZADA' AND "createdAt" >= now() - interval '200 days'
), u AS (
  SELECT ("subscriptionStartedAt" AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires') s, ("subscriptionCanceledAt" AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires') c
  FROM "User" WHERE "deletedAt" IS NULL AND "subscriptionStartedAt" IS NOT NULL AND "estudioId" IS NULL AND COALESCE("planKey",'')<>'estudio_client'
), loc AS (SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires') n),
wk AS (SELECT generate_series(date_trunc('week',(SELECT n FROM loc)) - interval '11 weeks', date_trunc('week',(SELECT n FROM loc)), interval '1 week') p),
mo AS (SELECT generate_series(date_trunc('month',(SELECT n FROM loc)) - interval '5 months', date_trunc('month',(SELECT n FROM loc)), interval '1 month') p)
SELECT json_build_object(
 'semanas', (SELECT json_agg(json_build_array(to_char(p,'YYYY-MM-DD'),
     (SELECT count(*) FROM u WHERE u.s < LEAST(p+interval '1 week',(SELECT n FROM loc)) AND (u.c IS NULL OR u.c >= LEAST(p+interval '1 week',(SELECT n FROM loc)))),
     (SELECT json_object_agg(src, json_build_array(n,cl)) FROM (SELECT src,count(*) n,count(DISTINCT cuit) cl FROM inv WHERE t>=p AND t<p+interval '1 week' GROUP BY src) x),
     (SELECT count(DISTINCT cuit) FROM inv WHERE t>=p AND t<p+interval '1 week')) ORDER BY p) FROM wk),
 'meses', (SELECT json_agg(json_build_array(to_char(p,'YYYY-MM'),
     (SELECT count(*) FROM u WHERE u.s < LEAST(p+interval '1 month',(SELECT n FROM loc)) AND (u.c IS NULL OR u.c >= LEAST(p+interval '1 month',(SELECT n FROM loc)))),
     (SELECT json_object_agg(src, json_build_array(n,cl)) FROM (SELECT src,count(*) n,count(DISTINCT cuit) cl FROM inv WHERE t>=p AND t<p+interval '1 month' GROUP BY src) x),
     (SELECT count(DISTINCT cuit) FROM inv WHERE t>=p AND t<p+interval '1 month')) ORDER BY p) FROM mo),
 'activosHoy', (SELECT count(*) FROM "User" WHERE "deletedAt" IS NULL AND "subscriptionStatus"='active' AND COALESCE("planKey",'') NOT IN ('estudio_client','free'))
) j
