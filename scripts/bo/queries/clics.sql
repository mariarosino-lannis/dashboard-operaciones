-- Clics por enlace de las campañas (tabla EmailClick, existe desde el 13/11/2026). Devuelve una fila con la columna j (JSON).
-- Los enlaces traen el email y un token del destinatario (por ejemplo el de darse de baja), así que NUNCA se usa
-- el enlace completo: se agrupa por destino = dominio + ruta, sin parámetros, con los ids largos tapados.
-- El enlace de baja (/avisos/baja) se agrupa como "BAJA".
-- {{TEMPLATES}} se reemplaza por la lista de templates de campanias.json.
-- total: [template, destino, personas, clics]
-- daily: [template, destino, día (hora de Argentina), personas, clics]
WITH tpl AS (SELECT unnest(ARRAY[{{TEMPLATES}}]) t),
k AS (
  SELECT s.template, c."sendId", c."clickedAt",
    regexp_replace(regexp_replace(lower(c.link), '^https?://(www\.)?([^/?#]+)([^?#]*).*$', '\2\3'), '/+$', '') hp
  FROM "EmailClick" c JOIN "EmailSend" s ON s.id=c."sendId" JOIN tpl ON tpl.t=s.template
), d AS (
  SELECT template, "sendId", "clickedAt",
    CASE WHEN hp LIKE '%/avisos/baja%' THEN 'BAJA'
         WHEN hp ~ '(@|%40)' THEN 'OTRO'
         ELSE regexp_replace(hp, '/[0-9a-z_-]{20,}|/[0-9a-f-]{16,}|/[0-9]{5,}', '/…', 'g') END dest
  FROM k
)
SELECT json_build_object(
 'total', (SELECT json_agg(json_build_array(template,dest,p,n) ORDER BY template,n DESC) FROM (SELECT template,dest,count(DISTINCT "sendId") p,count(*) n FROM d GROUP BY 1,2) x),
 'daily', (SELECT json_agg(json_build_array(template,dest,dia,p,n) ORDER BY template,dia) FROM (SELECT template,dest,to_char("clickedAt" AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires','YYYY-MM-DD') dia,count(DISTINCT "sendId") p,count(*) n FROM d GROUP BY 1,2,3) y),
 'desde', (SELECT to_char(min("clickedAt") AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires','YYYY-MM-DD') FROM "EmailClick")
) j
