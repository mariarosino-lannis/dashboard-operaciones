-- Otros servicios de Ops (solo agregados). Devuelve una fila con la columna j (JSON).
-- Fechas en hora de Argentina. Semanas de lunes a domingo.
-- semanas / meses: [período (lunes YYYY-MM-DD o YYYY-MM), VEPs generados, contribuyentes con VEP,
--                   facturas que se emitieron en un reintento, facturas que ARCA no dejó emitir (sin resolver)]
-- recat: ciclos de recategorización por mes de creación: [mes, casos, pidieron cambio, se quedan, sin respuesta, solicitudes completadas]
-- etapas: DDJJ de clientes propios presentadas en cada mes (mismo universo que ddjj_estado.sql):
--         [mes, presentadas, días promedio por empezar, esperando al cliente, en preparación, en borrador, total desde que se creó]
WITH ev AS (
  SELECT "createdAt" AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires' t, * FROM "Vep" WHERE "createdAt" >= now() - interval '7 months'
), rt AS (
  SELECT "createdAt" AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires' t, status FROM "InvoiceRetryJob" WHERE "createdAt" >= now() - interval '7 months'
), ob AS (
  SELECT t.id, t."createdAt" cr
  FROM "TaxObligation" t JOIN "Tax" tx ON tx.id=t."taxId"
  JOIN LATERAL (SELECT * FROM "User" uu WHERE uu.cuit=t."userCuit" AND uu."deletedAt" IS NULL ORDER BY uu.id LIMIT 1) u ON true
  WHERE t."taxId" NOT IN (20,308,9100,9101) AND u."estudioId" IS NULL AND COALESCE(u."planKey",'free') NOT IN ('free','estudio_client')
    AND u."subscriptionStatus" IS NOT NULL AND tx."isEnabled"
), fp AS (
  SELECT ob.id, ob.cr, min(a."createdAt") fp FROM ob JOIN "ObligationAuditLog" a ON a."obligationId"=ob.id
  WHERE a."toStatus" IN ('PRESENTADA','PENDIENTE_PAGO','PAGO_INFORMADO','PAGADA','COMPLETADA') AND a.action<>'obligation_created'
    AND a."createdAt" >= date_trunc('month', now()) - interval '6 months'
  GROUP BY 1,2
), seg AS (
  SELECT fp.id, fp.fp, fp.cr, a."toStatus" s, a."createdAt" t0,
    LEAST(COALESCE(lead(a."createdAt") OVER (PARTITION BY fp.id ORDER BY a."createdAt"), fp.fp), fp.fp) t1
  FROM fp JOIN "ObligationAuditLog" a ON a."obligationId"=fp.id AND a."toStatus" IS NOT NULL AND a."createdAt" < fp.fp
), dur AS (
  SELECT id, fp, cr,
    sum(EXTRACT(EPOCH FROM (t1-t0))/86400) FILTER (WHERE s='PENDIENTE') d_emp,
    sum(EXTRACT(EPOCH FROM (t1-t0))/86400) FILTER (WHERE s='INFORMACION_PENDIENTE') d_cli,
    sum(EXTRACT(EPOCH FROM (t1-t0))/86400) FILTER (WHERE s IN ('PENDIENTE_REVISION','EN_CURSO','REVISION_SOLICITADA')) d_prep,
    sum(EXTRACT(EPOCH FROM (t1-t0))/86400) FILTER (WHERE s IN ('BORRADOR_A_REVISAR','BORRADOR_APROBADO')) d_borr
  FROM seg GROUP BY 1,2,3
)
SELECT json_build_object(
 'semanas', (SELECT json_agg(json_build_array(p,v,c,ok,ko) ORDER BY p) FROM (
    SELECT to_char(date_trunc('week', x.t),'YYYY-MM-DD') p, count(*) FILTER (WHERE x.k='v') v, count(DISTINCT x.tp) FILTER (WHERE x.k='v') c,
      count(*) FILTER (WHERE x.k='r' AND x.st='resolved') ok, count(*) FILTER (WHERE x.k='r' AND x.st='dead_letter') ko
    FROM (SELECT t, 'v' k, "taxpayerID"::text tp, NULL st FROM ev UNION ALL SELECT t, 'r', NULL, status::text FROM rt) x
    WHERE x.t >= date_trunc('week', now() AT TIME ZONE 'America/Argentina/Buenos_Aires') - interval '11 weeks' GROUP BY 1) w),
 'meses', (SELECT json_agg(json_build_array(p,v,c,ok,ko) ORDER BY p) FROM (
    SELECT to_char(x.t,'YYYY-MM') p, count(*) FILTER (WHERE x.k='v') v, count(DISTINCT x.tp) FILTER (WHERE x.k='v') c,
      count(*) FILTER (WHERE x.k='r' AND x.st='resolved') ok, count(*) FILTER (WHERE x.k='r' AND x.st='dead_letter') ko
    FROM (SELECT t, 'v' k, "taxpayerID"::text tp, NULL st FROM ev UNION ALL SELECT t, 'r', NULL, status::text FROM rt) x
    WHERE x.t >= date_trunc('month', now() AT TIME ZONE 'America/Argentina/Buenos_Aires') - interval '6 months' GROUP BY 1) m),
 'recat', (SELECT json_agg(json_build_array(mes,n,cambio,quedan,sin,sol) ORDER BY mes) FROM (
    SELECT mes, sum(n) n, sum(cambio) cambio, sum(quedan) quedan, sum(sin) sin, sum(sol) sol FROM (
      SELECT to_char("createdAt" AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires','YYYY-MM') mes, count(*) n,
        count(*) FILTER (WHERE "userResponse"::text='change_requested') cambio, count(*) FILTER (WHERE "userResponse"::text='stays') quedan,
        count(*) FILTER (WHERE "userResponse"::text='unanswered') sin, 0 sol
      FROM "RecategorizacionCase" GROUP BY 1
      UNION ALL SELECT to_char("createdAt" AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires','YYYY-MM'), 0,0,0,0, count(*) FILTER (WHERE status::text='completed')
      FROM "RecategorizacionRequest" GROUP BY 1) z GROUP BY 1) r),
 'etapas', (SELECT json_agg(json_build_array(mes,n,emp,cli,prep,borr,tot) ORDER BY mes) FROM (
    SELECT to_char(fp AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires','YYYY-MM') mes, count(*) n,
      round(avg(COALESCE(d_emp,0))::numeric,1) emp, round(avg(COALESCE(d_cli,0))::numeric,1) cli,
      round(avg(COALESCE(d_prep,0))::numeric,1) prep, round(avg(COALESCE(d_borr,0))::numeric,1) borr,
      round(avg(EXTRACT(EPOCH FROM (fp-cr))/86400)::numeric,1) tot
    FROM dur GROUP BY 1) e)
) j
