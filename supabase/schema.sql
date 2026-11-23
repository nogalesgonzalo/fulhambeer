-- Fulhambeer F7 · esquema
create table if not exists public.jugadores (
  id text primary key,
  nombre text not null,
  nombre_ficha text,
  dorsal int,
  fijo boolean not null default false,
  activo boolean not null default true,
  en_ficha boolean not null default false,
  orden int,
  alias text[] not null default '{}',
  estado_defecto text not null default 'pendiente' check (estado_defecto in ('si','no','duda','pendiente')),
  motivo_defecto text
);

create table if not exists public.partidos (
  id text primary key,                 -- YYYY-MM-DD (o YYYY-MM-DD-n)
  fecha date not null,
  temporada text not null,
  rival text,
  lugar text,
  hora text,
  jornada int,
  competicion text not null default 'Liga',
  condicion text check (condicion in ('Local','Visitante')),
  gf int,
  gc int,
  fuente text,
  updated_at timestamptz not null default now()
);
create index if not exists partidos_fecha_idx on public.partidos (fecha);

create table if not exists public.respuestas (
  partido_id text not null references public.partidos(id) on update cascade on delete cascade,
  jugador_id text not null references public.jugadores(id) on update cascade on delete cascade,
  estado text not null default 'pendiente' check (estado in ('si','no','duda','pendiente')),
  motivo text,
  cerveza boolean,
  motivo_cerveza text,
  updated_at timestamptz not null default now(),
  primary key (partido_id, jugador_id)
);

-- histórico de cambios (para "bajas de última hora" y fiabilidad)
create table if not exists public.respuestas_log (
  id bigint generated always as identity primary key,
  partido_id text not null,
  jugador_id text not null,
  estado text,
  cerveza boolean,
  at timestamptz not null default now()
);

create table if not exists public.liga (
  id text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.multas (
  id bigint generated always as identity primary key,
  jugador_id text not null references public.jugadores(id) on update cascade on delete cascade,
  partido_id text references public.partidos(id) on update cascade on delete set null,
  concepto text not null,
  importe numeric(6,2) not null default 0,
  pagada boolean not null default false,
  created_at timestamptz not null default now()
);

-- configuración privada (sin políticas para anon: solo la función admin la lee)
create table if not exists public.admin_config (
  key text primary key,
  value text not null
);

-- timestamps + log
create or replace function public.touch_respuesta() returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' or new.estado is distinct from old.estado or new.cerveza is distinct from old.cerveza then
    insert into public.respuestas_log (partido_id, jugador_id, estado, cerveza) values (new.partido_id, new.jugador_id, new.estado, new.cerveza);
  end if;
  return new;
end $$;
drop trigger if exists respuestas_touch on public.respuestas;
create trigger respuestas_touch before insert or update on public.respuestas
  for each row execute function public.touch_respuesta();

-- Al crear un partido, la convocatoria parte de los fijos con su estado por defecto
create or replace function public.convocatoria_inicial() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.respuestas (partido_id, jugador_id, estado, motivo)
  select new.id, j.id, j.estado_defecto, j.motivo_defecto from public.jugadores j where j.fijo and j.activo
  on conflict do nothing;
  return new;
end $$;
drop trigger if exists partidos_convocatoria on public.partidos;
create trigger partidos_convocatoria after insert on public.partidos
  for each row when (new.fecha >= current_date) execute function public.convocatoria_inicial();

-- Multas propuestas por la gente y votadas
create table if not exists public.multa_propuestas (
  id bigint generated always as identity primary key,
  jugador_id text not null references public.jugadores(id) on update cascade on delete cascade,
  propuesto_por text not null references public.jugadores(id) on update cascade on delete cascade,
  partido_id text references public.partidos(id) on update cascade on delete set null,
  concepto text not null check (length(trim(concepto)) between 3 and 160),
  importe numeric(6,2) not null default 1 check (importe >= 0 and importe <= 50),
  estado text not null default 'votacion' check (estado in ('votacion','aprobada','rechazada')),
  created_at timestamptz not null default now()
);
create table if not exists public.multa_votos (
  propuesta_id bigint not null references public.multa_propuestas(id) on delete cascade,
  votante_id text not null references public.jugadores(id) on update cascade on delete cascade,
  voto boolean not null,
  at timestamptz not null default now(),
  primary key (propuesta_id, votante_id)
);
-- con 6 votos a favor (mayoría de los 11 fijos) se aprueba; con 6 en contra se rechaza
create or replace function public.resolver_multa() returns trigger language plpgsql security definer set search_path = public as $$
declare a int; c int; pr public.multa_propuestas;
begin
  select * into pr from public.multa_propuestas where id = new.propuesta_id;
  if pr.estado <> 'votacion' then return new; end if;
  select count(*) filter (where voto), count(*) filter (where not voto) into a, c from public.multa_votos where propuesta_id = new.propuesta_id;
  if a >= 6 and a > c then
    update public.multa_propuestas set estado = 'aprobada' where id = pr.id;
    insert into public.multas (jugador_id, partido_id, concepto, importe) values (pr.jugador_id, pr.partido_id, pr.concepto || ' (votada ' || a || '-' || c || ')', pr.importe);
  elsif c >= 6 and c >= a then
    update public.multa_propuestas set estado = 'rechazada' where id = pr.id;
  end if;
  return new;
end $$;
drop trigger if exists multa_votos_resolver on public.multa_votos;
create trigger multa_votos_resolver after insert or update on public.multa_votos for each row execute function public.resolver_multa();

-- MVP y MVPn't
create table if not exists public.votos_mvp (
  partido_id text not null references public.partidos(id) on update cascade on delete cascade,
  votante_id text not null references public.jugadores(id) on update cascade on delete cascade,
  tipo text not null check (tipo in ('mvp','mvpnt')),
  elegido_id text not null references public.jugadores(id) on update cascade on delete cascade,
  comentario text check (comentario is null or length(comentario) <= 140),
  at timestamptz not null default now(),
  primary key (partido_id, votante_id, tipo),
  check (votante_id <> elegido_id)
);
create or replace function public.voto_mvp_valido(p_partido text, p_votante text, p_elegido text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.partidos p where p.id = p_partido and p.fecha between current_date - 4 and current_date)
     and exists (select 1 from public.respuestas r where r.partido_id = p_partido and r.jugador_id = p_votante and r.estado = 'si')
     and exists (select 1 from public.respuestas r where r.partido_id = p_partido and r.jugador_id = p_elegido and r.estado = 'si')
$$;

-- RLS
alter table public.multa_propuestas enable row level security;
alter table public.multa_votos enable row level security;
alter table public.votos_mvp enable row level security;
create policy "lectura publica" on public.multa_propuestas for select to anon, authenticated using (true);
create policy "lectura publica" on public.multa_votos for select to anon, authenticated using (true);
create policy "lectura publica" on public.votos_mvp for select to anon, authenticated using (true);
create policy "proponer multa" on public.multa_propuestas for insert to anon, authenticated
  with check (estado = 'votacion' and jugador_id <> propuesto_por and exists (select 1 from public.jugadores j where j.id = propuesto_por and j.activo));
create policy "votar multa" on public.multa_votos for insert to anon, authenticated
  with check (exists (select 1 from public.multa_propuestas m where m.id = propuesta_id and m.estado = 'votacion' and m.jugador_id <> votante_id));
create policy "cambiar voto multa" on public.multa_votos for update to anon, authenticated
  using (exists (select 1 from public.multa_propuestas m where m.id = propuesta_id and m.estado = 'votacion'))
  with check (exists (select 1 from public.multa_propuestas m where m.id = propuesta_id and m.estado = 'votacion' and m.jugador_id <> votante_id));
create policy "votar mvp" on public.votos_mvp for insert to anon, authenticated with check (public.voto_mvp_valido(partido_id, votante_id, elegido_id));
create policy "cambiar voto mvp" on public.votos_mvp for update to anon, authenticated
  using (public.voto_mvp_valido(partido_id, votante_id, elegido_id)) with check (public.voto_mvp_valido(partido_id, votante_id, elegido_id));
grant insert on public.multa_propuestas to anon, authenticated;
grant insert, update on public.multa_votos, public.votos_mvp to anon, authenticated;

alter table public.jugadores enable row level security;
alter table public.partidos enable row level security;
alter table public.respuestas enable row level security;
alter table public.respuestas_log enable row level security;
alter table public.liga enable row level security;
alter table public.multas enable row level security;
alter table public.admin_config enable row level security;

create policy "lectura publica" on public.jugadores for select to anon, authenticated using (true);
create policy "lectura publica" on public.partidos for select to anon, authenticated using (true);
create policy "lectura publica" on public.respuestas for select to anon, authenticated using (true);
create policy "lectura publica" on public.respuestas_log for select to anon, authenticated using (true);
create policy "lectura publica" on public.liga for select to anon, authenticated using (true);
create policy "lectura publica" on public.multas for select to anon, authenticated using (true);

-- Los jugadores solo pueden escribir respuestas del partido abierto:
-- convocatoria hasta el día del partido; cerveza hasta 3 días después.
-- Un "no" exige motivo; una cerveza "no" exige motivo.
create or replace function public.respuesta_valida(p_partido text, p_estado text, p_motivo text, p_cerveza boolean, p_motivo_cerveza text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.partidos p
    where p.id = p_partido
      and p.fecha between current_date - 3 and current_date + 21
  )
  and (p_estado <> 'no' or length(trim(coalesce(p_motivo, ''))) >= 3)
  and (p_cerveza is distinct from false or length(trim(coalesce(p_motivo_cerveza, ''))) >= 3)
  and (p_cerveza is null or p_estado = 'si')
$$;

create policy "responder partido abierto" on public.respuestas for insert to anon, authenticated
  with check (public.respuesta_valida(partido_id, estado, motivo, cerveza, motivo_cerveza));
create policy "editar respuesta partido abierto" on public.respuestas for update to anon, authenticated
  using (exists (select 1 from public.partidos p where p.id = partido_id and p.fecha between current_date - 3 and current_date + 21))
  with check (public.respuesta_valida(partido_id, estado, motivo, cerveza, motivo_cerveza));

grant select on all tables in schema public to anon, authenticated;
grant insert, update on public.respuestas to anon, authenticated;
revoke all on public.admin_config from anon, authenticated;

-- realtime
alter publication supabase_realtime add table public.respuestas;
alter publication supabase_realtime add table public.partidos;
alter publication supabase_realtime add table public.multa_votos;
alter publication supabase_realtime add table public.votos_mvp;

-- Migración 2: fusiones Goni→Nogales y Ebri→Elías, invitados, cerveza previa al partido y porra
alter table public.jugadores add column if not exists invitado boolean not null default false;
create or replace function public.respuesta_valida(p_partido text, p_estado text, p_motivo text, p_cerveza boolean, p_motivo_cerveza text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.partidos p where p.id = p_partido and p.fecha between current_date - 3 and current_date + 21)
  and (p_estado <> 'no' or length(trim(coalesce(p_motivo, ''))) >= 3)
  and (p_cerveza is distinct from false or length(trim(coalesce(p_motivo_cerveza, ''))) >= 3)
$$;
create table if not exists public.porras (
  partido_id text not null references public.partidos(id) on update cascade on delete cascade,
  jugador_id text not null references public.jugadores(id) on update cascade on delete cascade,
  gf int not null check (gf between 0 and 30), gc int not null check (gc between 0 and 30),
  at timestamptz not null default now(), primary key (partido_id, jugador_id)
);
create or replace function public.porra_abierta(p_partido text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.partidos p where p.id = p_partido
    and ((p.fecha + coalesce(nullif(p.hora, '')::time, time '23:59')) at time zone 'Europe/Madrid') > now() and p.fecha <= current_date + 21)
$$;
alter table public.porras enable row level security;
create policy "lectura publica" on public.porras for select to anon, authenticated using (true);
create policy "apostar" on public.porras for insert to anon, authenticated with check (public.porra_abierta(partido_id) and exists (select 1 from public.jugadores j where j.id = jugador_id and j.activo));
create policy "cambiar apuesta" on public.porras for update to anon, authenticated using (public.porra_abierta(partido_id)) with check (public.porra_abierta(partido_id));
grant select, insert, update on public.porras to anon, authenticated;
