-- Campañas de email del BO (tabla EmailSend). Devuelve una fila con la columna j (JSON).
-- {{TEMPLATES}} se reemplaza por la lista de templates de campanias.json, entre comillas simples y separados por coma.
-- {{DIAS}} se reemplaza por ventanaConversionDias. Las fechas (día) se expresan en hora de Argentina.
-- funnel: [template, primer envío, destinatarios, entregados, abiertos, clics, rebotes, spam, fallidos, ya eran usuarios, se registraron, se suscribieron,
--          personas que convirtieron (crearon cuenta o se suscribieron, contadas una vez)]
-- Atribución: si una persona recibió varias campañas, su cuenta nueva o suscripción se asigna a UNA sola:
--   la del último mail que abrió o en el que hizo clic antes de convertir; si no abrió ninguno, la del último envío.
--   Las campañas con "conversion": false (por ejemplo, las encuestas) no compiten por la atribución.
-- daily:  [template, día, enviados, abiertos, clics, registros, suscripciones, entregados, rebotes, personas que convirtieron]
--          (enviados, entregados y rebotes por día de envío; abiertos, clics, registros y suscripciones por día en que ocurrieron)
WITH tpl AS (SELECT unnest(ARRAY[{{TEMPLATES}}]) t),
s AS (
  SELECT e.template, lower(e.email) email, min(e.cuit) cuit, min(e."sentAt") sent, max(e."deliveredAt") dl, min(e."openedAt") op, min(e."clickedAt") cl, max(e."bouncedAt") bo, max(e."complainedAt") co, max(e."failedAt") fa
  FROM "EmailSend" e JOIN tpl ON tpl.t=e.template GROUP BY 1,2
), c AS (
  SELECT s.*, u.cr, u.ss FROM s LEFT JOIN LATERAL (
    SELECT min(us."createdAt") cr, min(us."subscriptionStartedAt") FILTER (WHERE us."subscriptionStartedAt" >= s.sent) ss
    FROM "User" us WHERE us."deletedAt" IS NULL AND (lower(us.email)=s.email OR (s.cuit IS NOT NULL AND us.cuit=s.cuit))) u ON true
), cv0 AS (
  SELECT *, (cr >= sent AND cr < sent + interval '{{DIAS}} days') reg0, (ss < sent + interval '{{DIAS}} days') sub0, (cr IS NOT NULL AND cr < sent) prev FROM c
), cand AS (
  SELECT email, template, sent, CASE WHEN cl <= ev THEN cl WHEN op <= ev THEN op END tch FROM (
    SELECT *, CASE WHEN reg0 THEN cr ELSE ss END ev FROM cv0 WHERE (reg0 OR sub0) AND template <> ALL (ARRAY[{{SIN_CONVERSION}}]::text[])) x
), win AS (
  SELECT DISTINCT ON (email) email, template FROM cand ORDER BY email, (tch IS NOT NULL) DESC, tch DESC NULLS LAST, sent DESC
), cv AS (
  SELECT cv0.*, (w.email IS NOT NULL AND COALESCE(reg0,false)) reg, (w.email IS NOT NULL AND COALESCE(sub0,false)) sub
  FROM cv0 LEFT JOIN win w ON w.email=cv0.email AND w.template=cv0.template
), f AS (
  SELECT template, to_char(min(sent) AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires','YYYY-MM-DD') d0, count(*) n, count(dl) dl, count(op) op, count(cl) cl, count(bo) bo, count(co) co, count(fa) fa, count(*) FILTER (WHERE prev) pv, count(*) FILTER (WHERE reg) rg, count(*) FILTER (WHERE sub) sb, count(*) FILTER (WHERE reg OR sub) cvp FROM cv GROUP BY 1
), dd AS (
  SELECT template, d, sum(se) se, sum(op) op, sum(cl) cl, sum(rg) rg, sum(sb) sb, sum(dl) dl, sum(bo) bo, sum(cvp) cvp FROM (
     SELECT template, to_char(sent AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires','YYYY-MM-DD') d, 1 se, 0 op, 0 cl, 0 rg, 0 sb, (dl IS NOT NULL)::int dl, (bo IS NOT NULL OR fa IS NOT NULL)::int bo, 0 cvp FROM cv
     UNION ALL SELECT template, to_char(op AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires','YYYY-MM-DD'), 0,1,0,0,0,0,0,0 FROM cv WHERE op IS NOT NULL
     UNION ALL SELECT template, to_char(cl AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires','YYYY-MM-DD'), 0,0,1,0,0,0,0,0 FROM cv WHERE cl IS NOT NULL
     UNION ALL SELECT template, to_char(cr AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires','YYYY-MM-DD'), 0,0,0,1,0,0,0,0 FROM cv WHERE reg
     UNION ALL SELECT template, to_char(ss AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires','YYYY-MM-DD'), 0,0,0,0,1,0,0,0 FROM cv WHERE sub
     UNION ALL SELECT template, to_char((CASE WHEN reg THEN cr ELSE ss END) AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires','YYYY-MM-DD'), 0,0,0,0,0,0,0,1 FROM cv WHERE reg OR sub) z GROUP BY 1,2
)
SELECT json_build_object(
 'funnel', (SELECT json_agg(json_build_array(template,d0,n,dl,op,cl,bo,co,fa,pv,rg,sb,cvp) ORDER BY template) FROM f),
 'daily', (SELECT json_agg(json_build_array(template,d,se,op,cl,rg,sb,dl,bo,cvp) ORDER BY template,d) FROM dd)
) j
