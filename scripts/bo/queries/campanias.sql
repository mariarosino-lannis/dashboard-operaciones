-- Campañas de email del BO (tabla EmailSend). Devuelve una fila con la columna j (JSON).
-- {{TEMPLATES}} se reemplaza por la lista de templates de campanias.json, entre comillas simples y separados por coma.
-- {{DIAS}} se reemplaza por ventanaConversionDias.
-- funnel: [template, primer envío, destinatarios, entregados, abiertos, clics, rebotes, spam, fallidos, ya eran usuarios, se registraron, se suscribieron]
-- daily:  [template, día, enviados, abiertos, clics, registros, suscripciones]
WITH tpl AS (SELECT unnest(ARRAY[{{TEMPLATES}}]) t),
s AS (
  SELECT e.template, lower(e.email) email, min(e.cuit) cuit, min(e."sentAt") sent, max(e."deliveredAt") dl, min(e."openedAt") op, min(e."clickedAt") cl, max(e."bouncedAt") bo, max(e."complainedAt") co, max(e."failedAt") fa
  FROM "EmailSend" e JOIN tpl ON tpl.t=e.template GROUP BY 1,2
), c AS (
  SELECT s.*, u.cr, u.ss FROM s LEFT JOIN LATERAL (
    SELECT min(us."createdAt") cr, min(us."subscriptionStartedAt") FILTER (WHERE us."subscriptionStartedAt" >= s.sent) ss
    FROM "User" us WHERE us."deletedAt" IS NULL AND (lower(us.email)=s.email OR (s.cuit IS NOT NULL AND us.cuit=s.cuit))) u ON true
), cv AS (
  SELECT *, (cr >= sent AND cr < sent + interval '{{DIAS}} days') reg, (ss < sent + interval '{{DIAS}} days') sub, (cr IS NOT NULL AND cr < sent) prev FROM c
), f AS (
  SELECT template, to_char(min(sent),'YYYY-MM-DD') d0, count(*) n, count(dl) dl, count(op) op, count(cl) cl, count(bo) bo, count(co) co, count(fa) fa, count(*) FILTER (WHERE prev) pv, count(*) FILTER (WHERE reg) rg, count(*) FILTER (WHERE sub) sb FROM cv GROUP BY 1
), dd AS (
  SELECT template, d, sum(se) se, sum(op) op, sum(cl) cl, sum(rg) rg, sum(sb) sb FROM (
     SELECT template, to_char(sent,'YYYY-MM-DD') d, 1 se, 0 op, 0 cl, 0 rg, 0 sb FROM cv
     UNION ALL SELECT template, to_char(op,'YYYY-MM-DD'), 0,1,0,0,0 FROM cv WHERE op IS NOT NULL
     UNION ALL SELECT template, to_char(cl,'YYYY-MM-DD'), 0,0,1,0,0 FROM cv WHERE cl IS NOT NULL
     UNION ALL SELECT template, to_char(cr,'YYYY-MM-DD'), 0,0,0,1,0 FROM cv WHERE reg
     UNION ALL SELECT template, to_char(ss,'YYYY-MM-DD'), 0,0,0,0,1 FROM cv WHERE sub) z GROUP BY 1,2
)
SELECT json_build_object(
 'funnel', (SELECT json_agg(json_build_array(template,d0,n,dl,op,cl,bo,co,fa,pv,rg,sb) ORDER BY template) FROM f),
 'daily', (SELECT json_agg(json_build_array(template,d,se,op,cl,rg,sb) ORDER BY template,d) FROM dd)
) j
