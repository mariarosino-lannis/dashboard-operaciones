-- Estado actual de las DDJJ que gestiona el equipo de Ops. Devuelve una fila con la columna j (JSON).
-- Universo: obligaciones de clientes propios de Lannis (sin clientes de estudios, cuentas free ni cuentas que nunca se suscribieron),
-- sin Monotributo, Autónomos ni anticipos (son pagos, no DDJJ).
-- Corte: los vencimientos cuentan hasta el último día del mes en curso (hora argentina). Lo que vence el mes que
-- viene (por ejemplo, el período en curso) ya está generado pero todavía no es trabajo del mes: va aparte (prox).
-- snapshot: [familia, segmento, estado, cantidad, vencidas sin presentar, vencen de hoy a fin de mes,
--            >7 días sin moverse, >14 días sin moverse, sin presentar que vencen el mes que viene o después]
-- finMes: último día del mes en curso (YYYY-MM-DD)
-- meses: cumplimiento por mes de vencimiento (últimos 4 meses y el actual):
--        [mes YYYY-MM, vencen en el mes, presentadas, presentadas en término, vencidas sin presentar, por vencer, días de anticipación promedio]
--        "En término" = llegó a presentada (o más) el día del vencimiento o antes, según el historial de cambios.
-- periodos: [periodo, familia, total, presentadas o más]
-- excluidas: obligaciones fuera del universo (estudios, free)
WITH hoy AS (
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date d,
    (date_trunc('month', now() AT TIME ZONE 'America/Argentina/Buenos_Aires') + interval '1 month')::date fm
), ob AS (
  SELECT t.id, t.status s, t."createdAt" cr, t."presentationExpirationDate" pv, t.periodo,
    CASE WHEN t."taxId"=30 THEN 'IVA' WHEN t."taxId" IN (10,11) THEN 'Ganancias' WHEN t."taxId"=180 THEN 'Bienes Personales' WHEN t."taxId"=217 THEN 'SICORE' WHEN t."taxId"=301 THEN 'F.931' WHEN tx.name ~* '(IIBB|II BB|INGRESOS BRUTOS)' THEN 'IIBB' ELSE initcap(tx.name) END fam,
    CASE u."tipoUsuario" WHEN 'responsable_inscripto' THEN 'RI' WHEN 'sociedad_anonima' THEN 'SAS' WHEN 'monotributista' THEN 'Mono' ELSE 'Otro' END seg
  FROM "TaxObligation" t JOIN "Tax" tx ON tx.id=t."taxId"
  JOIN LATERAL (SELECT * FROM "User" uu WHERE uu.cuit=t."userCuit" AND uu."deletedAt" IS NULL ORDER BY uu.id LIMIT 1) u ON true
  WHERE t."taxId" NOT IN (20,308,9100,9101) AND u."estudioId" IS NULL AND COALESCE(u."planKey",'free') NOT IN ('free','estudio_client')
    AND u."subscriptionStatus" IS NOT NULL -- nunca se suscribió: no es cliente de Ops
    AND tx."isEnabled" -- impuestos deshabilitados en el BO (ej. IIBB Convenio Multilateral viejo, id 9001): el tablero del BO no los muestra
), lst AS (
  SELECT ob.*, COALESCE((SELECT max(a."createdAt") FROM "ObligationAuditLog" a WHERE a."obligationId"=ob.id AND a."toStatus" IS NOT NULL), ob.cr) since,
    ob.s IN ('PRESENTADA','PENDIENTE_PAGO','PAGO_INFORMADO','PAGADA','COMPLETADA') pres,
    (SELECT min(a."createdAt") FROM "ObligationAuditLog" a WHERE a."obligationId"=ob.id AND a."toStatus" IN ('PRESENTADA','PENDIENTE_PAGO','PAGO_INFORMADO','PAGADA','COMPLETADA') AND a.action<>'obligation_created') fp,
    COALESCE(ob.pv::date >= (SELECT fm FROM hoy), false) prox
  FROM ob
)
SELECT json_build_object(
 'snapshot', (SELECT json_agg(json_build_array(fam,seg,s,n,venc,vmes,d7,d14,px) ORDER BY fam,seg,s) FROM (
    SELECT fam,seg,s,count(*) n,
     count(*) FILTER (WHERE NOT pres AND pv::date < (SELECT d FROM hoy)) venc,
     count(*) FILTER (WHERE NOT pres AND pv::date >= (SELECT d FROM hoy) AND NOT prox) vmes,
     count(*) FILTER (WHERE NOT pres AND NOT prox AND s NOT IN ('PENDIENTE') AND since < now()-interval '7 days') d7,
     count(*) FILTER (WHERE NOT pres AND NOT prox AND s NOT IN ('PENDIENTE') AND since < now()-interval '14 days') d14,
     count(*) FILTER (WHERE NOT pres AND prox) px
    FROM lst GROUP BY 1,2,3) x),
 'finMes', (SELECT to_char(fm - 1,'YYYY-MM-DD') FROM hoy),
 'meses', (SELECT json_agg(json_build_array(mes,n,p,pt,venc,pv,dias) ORDER BY mes) FROM (
    SELECT to_char(pv,'YYYY-MM') mes, count(*) n, count(*) FILTER (WHERE pres) p,
     count(*) FILTER (WHERE pres AND fp IS NOT NULL AND (fp AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires')::date <= pv::date) pt,
     count(*) FILTER (WHERE NOT pres AND pv::date < (SELECT d FROM hoy)) venc,
     count(*) FILTER (WHERE NOT pres AND pv::date >= (SELECT d FROM hoy)) pv,
     round(avg(pv::date - (fp AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires')::date) FILTER (WHERE pres AND fp IS NOT NULL)::numeric,1) dias
    FROM lst WHERE pv >= date_trunc('month', (SELECT d FROM hoy)) - interval '4 months' AND pv < (SELECT fm FROM hoy) GROUP BY 1) m),
 'periodos', (SELECT json_agg(json_build_array(periodo,fam,n,p) ORDER BY periodo DESC,fam) FROM (
    SELECT periodo,fam,count(*) n,count(*) FILTER (WHERE pres) p FROM lst
    WHERE periodo >= to_char(now()-interval '4 months','YYYYMM')::int OR periodo % 100 = 0 GROUP BY 1,2) y),
 'excluidas', (SELECT json_build_object('estudios', count(*) FILTER (WHERE u."estudioId" IS NOT NULL OR u."planKey"='estudio_client'), 'free', count(*) FILTER (WHERE u."estudioId" IS NULL AND COALESCE(u."planKey",'free')='free'), 'sinSuscripcion', count(*) FILTER (WHERE u."estudioId" IS NULL AND COALESCE(u."planKey",'free') NOT IN ('free','estudio_client') AND u."subscriptionStatus" IS NULL))
    FROM "TaxObligation" t JOIN LATERAL (SELECT * FROM "User" uu WHERE uu.cuit=t."userCuit" AND uu."deletedAt" IS NULL ORDER BY uu.id LIMIT 1) u ON true WHERE t."taxId" NOT IN (20,308,9100,9101))
) j
