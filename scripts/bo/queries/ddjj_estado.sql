-- Estado actual de las DDJJ que gestiona el equipo de Ops. Devuelve una fila con la columna j (JSON).
-- Universo: obligaciones de clientes propios de Lannis (sin clientes de estudios ni cuentas free),
-- sin Monotributo, Autónomos ni anticipos (son pagos, no DDJJ).
-- snapshot: [familia, segmento, estado, cantidad, vencidas sin presentar, vencen en 7 días, >7 días sin moverse, >14 días sin moverse]
-- periodos: [periodo, familia, total, presentadas o más]
-- excluidas: obligaciones fuera del universo (estudios, free)
WITH ob AS (
  SELECT t.id, t.status s, t."createdAt" cr, t."presentationExpirationDate" pv, t.periodo,
    CASE WHEN t."taxId"=30 THEN 'IVA' WHEN t."taxId" IN (10,11) THEN 'Ganancias' WHEN t."taxId"=180 THEN 'Bienes Personales' WHEN t."taxId"=217 THEN 'SICORE' WHEN t."taxId"=301 THEN 'F.931' WHEN tx.name ~* '(IIBB|II BB|INGRESOS BRUTOS)' THEN 'IIBB' ELSE initcap(tx.name) END fam,
    CASE u."tipoUsuario" WHEN 'responsable_inscripto' THEN 'RI' WHEN 'sociedad_anonima' THEN 'SAS' WHEN 'monotributista' THEN 'Mono' ELSE 'Otro' END seg
  FROM "TaxObligation" t JOIN "Tax" tx ON tx.id=t."taxId"
  JOIN LATERAL (SELECT * FROM "User" uu WHERE uu.cuit=t."userCuit" AND uu."deletedAt" IS NULL ORDER BY uu.id LIMIT 1) u ON true
  WHERE t."taxId" NOT IN (20,308,9100,9101) AND u."estudioId" IS NULL AND COALESCE(u."planKey",'free') NOT IN ('free','estudio_client')
), lst AS (
  SELECT ob.*, COALESCE((SELECT max(a."createdAt") FROM "ObligationAuditLog" a WHERE a."obligationId"=ob.id AND a."toStatus" IS NOT NULL), ob.cr) since,
    ob.s IN ('PRESENTADA','PENDIENTE_PAGO','PAGO_INFORMADO','PAGADA','COMPLETADA') pres
  FROM ob
)
SELECT json_build_object(
 'snapshot', (SELECT json_agg(json_build_array(fam,seg,s,n,venc,v7,d7,d14) ORDER BY fam,seg,s) FROM (
    SELECT fam,seg,s,count(*) n,
     count(*) FILTER (WHERE NOT pres AND pv < now()) venc,
     count(*) FILTER (WHERE NOT pres AND pv >= now() AND pv < now()+interval '7 days') v7,
     count(*) FILTER (WHERE NOT pres AND s NOT IN ('PENDIENTE') AND since < now()-interval '7 days') d7,
     count(*) FILTER (WHERE NOT pres AND s NOT IN ('PENDIENTE') AND since < now()-interval '14 days') d14
    FROM lst GROUP BY 1,2,3) x),
 'periodos', (SELECT json_agg(json_build_array(periodo,fam,n,p) ORDER BY periodo DESC,fam) FROM (
    SELECT periodo,fam,count(*) n,count(*) FILTER (WHERE pres) p FROM lst
    WHERE periodo >= to_char(now()-interval '4 months','YYYYMM')::int OR periodo % 100 = 0 GROUP BY 1,2) y),
 'excluidas', (SELECT json_build_object('estudios', count(*) FILTER (WHERE u."estudioId" IS NOT NULL OR u."planKey"='estudio_client'), 'free', count(*) FILTER (WHERE u."estudioId" IS NULL AND COALESCE(u."planKey",'free')='free'))
    FROM "TaxObligation" t JOIN LATERAL (SELECT * FROM "User" uu WHERE uu.cuit=t."userCuit" AND uu."deletedAt" IS NULL ORDER BY uu.id LIMIT 1) u ON true WHERE t."taxId" NOT IN (20,308,9100,9101))
) j
