-- Evolución semanal de las DDJJ (últimas 12 semanas, lunes a domingo). Devuelve una fila con la columna j (JSON).
-- Mismo universo que ddjj_estado.sql. El estado de cada obligación al cierre de cada semana se reconstruye
-- con el historial de cambios (ObligationAuditLog).
-- Etapas: 0 por empezar (PENDIENTE, INFORMACION_PENDIENTE) · 1 en preparación (PENDIENTE_REVISION, EN_CURSO, REVISION_SOLICITADA)
--         2 borrador (BORRADOR_A_REVISAR, BORRADOR_APROBADO) · 3 presentada / a pagar (PRESENTADA, PENDIENTE_PAGO, PAGO_INFORMADO)
--         4 cerrada (PAGADA, COMPLETADA)
-- stagesBySeg / stagesByFam: [semana, segmento o familia, e0, e1, e2, e3, e4]
-- presentadas: [semana, familia, segmento, obligaciones que llegaron a presentada o más por primera vez]
-- moves: [semana, quién (accountant = equipo, user = cliente, system), estado destino, cambios]
-- team: [semana, persona del equipo, cambios de estado, otras acciones (documentos, revisiones, filas)]
WITH ob AS (
  SELECT t.id, t.status s, t."createdAt" cr,
    CASE WHEN t."taxId"=30 THEN 'IVA' WHEN t."taxId" IN (10,11) THEN 'Ganancias' WHEN t."taxId"=180 THEN 'Bienes Personales' WHEN t."taxId"=217 THEN 'SICORE' WHEN t."taxId"=301 THEN 'F.931' WHEN tx.name ~* '(IIBB|II BB|INGRESOS BRUTOS)' THEN 'IIBB' ELSE initcap(tx.name) END fam,
    CASE u."tipoUsuario" WHEN 'responsable_inscripto' THEN 'RI' WHEN 'sociedad_anonima' THEN 'SAS' WHEN 'monotributista' THEN 'Mono' ELSE 'Otro' END seg
  FROM "TaxObligation" t JOIN "Tax" tx ON tx.id=t."taxId"
  JOIN LATERAL (SELECT * FROM "User" uu WHERE uu.cuit=t."userCuit" AND uu."deletedAt" IS NULL ORDER BY uu.id LIMIT 1) u ON true
  WHERE t."taxId" NOT IN (20,308,9100,9101) AND u."estudioId" IS NULL AND COALESCE(u."planKey",'free') NOT IN ('free','estudio_client')
), wk AS (SELECT generate_series(date_trunc('week', now()) - interval '11 weeks', date_trunc('week', now()), interval '1 week') ws),
st AS (
  SELECT wk.ws, ob.fam, ob.seg, COALESCE(
    (SELECT a."toStatus" FROM "ObligationAuditLog" a WHERE a."obligationId"=ob.id AND a."toStatus" IS NOT NULL AND a."createdAt" < wk.ws + interval '7 days' ORDER BY a."createdAt" DESC LIMIT 1),
    (SELECT a."fromStatus" FROM "ObligationAuditLog" a WHERE a."obligationId"=ob.id AND a."toStatus" IS NOT NULL AND a."createdAt" >= wk.ws + interval '7 days' ORDER BY a."createdAt" ASC LIMIT 1),
    ob.s) s
  FROM wk JOIN ob ON ob.cr < wk.ws + interval '7 days'
), stg AS (
  SELECT ws, fam, seg, CASE WHEN s IN ('PENDIENTE','INFORMACION_PENDIENTE') THEN 0 WHEN s IN ('PENDIENTE_REVISION','EN_CURSO','REVISION_SOLICITADA') THEN 1 WHEN s IN ('BORRADOR_A_REVISAR','BORRADOR_APROBADO') THEN 2 WHEN s IN ('PRESENTADA','PENDIENTE_PAGO','PAGO_INFORMADO') THEN 3 ELSE 4 END e FROM st
), ev AS (
  SELECT a.*, ob.fam, ob.seg, date_trunc('week',a."createdAt") w FROM "ObligationAuditLog" a JOIN ob ON ob.id=a."obligationId" WHERE a."createdAt" >= date_trunc('week', now()) - interval '11 weeks'
), firstpres AS (
  SELECT a."obligationId", min(a."createdAt") t FROM "ObligationAuditLog" a JOIN ob ON ob.id=a."obligationId" WHERE a."toStatus" IN ('PRESENTADA','PENDIENTE_PAGO','PAGO_INFORMADO','PAGADA','COMPLETADA') AND a.action<>'obligation_created' GROUP BY 1
)
SELECT json_build_object(
 'stagesBySeg', (SELECT json_agg(json_build_array(to_char(ws,'YYYY-MM-DD'),seg,c0,c1,c2,c3,c4) ORDER BY ws,seg) FROM (SELECT ws,seg,count(*) FILTER (WHERE e=0) c0,count(*) FILTER (WHERE e=1) c1,count(*) FILTER (WHERE e=2) c2,count(*) FILTER (WHERE e=3) c3,count(*) FILTER (WHERE e=4) c4 FROM stg GROUP BY 1,2) a),
 'stagesByFam', (SELECT json_agg(json_build_array(to_char(ws,'YYYY-MM-DD'),fam,c0,c1,c2,c3,c4) ORDER BY ws,fam) FROM (SELECT ws,fam,count(*) FILTER (WHERE e=0) c0,count(*) FILTER (WHERE e=1) c1,count(*) FILTER (WHERE e=2) c2,count(*) FILTER (WHERE e=3) c3,count(*) FILTER (WHERE e=4) c4 FROM stg GROUP BY 1,2) b),
 'presentadas', (SELECT json_agg(json_build_array(w,fam,seg,n) ORDER BY w,fam,seg) FROM (SELECT to_char(date_trunc('week',f.t),'YYYY-MM-DD') w, ob.fam, ob.seg, count(*) n FROM firstpres f JOIN ob ON ob.id=f."obligationId" WHERE f.t >= date_trunc('week', now()) - interval '11 weeks' GROUP BY 1,2,3) c),
 'moves', (SELECT json_agg(json_build_array(w,actor,"toStatus",n) ORDER BY w,actor,"toStatus") FROM (SELECT to_char(w,'YYYY-MM-DD') w, "performedBy" actor, "toStatus", count(*) n FROM ev WHERE action='status_change' GROUP BY 1,2,3) d),
 'team', (SELECT json_agg(json_build_array(w,who,sc,oth) ORDER BY w,who) FROM (SELECT to_char(w,'YYYY-MM-DD') w,
     CASE WHEN "performerName" IS NULL THEN 'Equipo (sin nombre)' WHEN "performerName" ILIKE '%@%' THEN initcap(replace(split_part(lower("performerName"),'@',1),'.',' ')) ELSE translate("performerName",'áéíóúÁÉÍÓÚ','aeiouAEIOU') END who,
     count(*) FILTER (WHERE action='status_change') sc, count(*) FILTER (WHERE action<>'status_change') oth
   FROM ev WHERE "performedBy"='accountant' GROUP BY 1,2) e)
) j
