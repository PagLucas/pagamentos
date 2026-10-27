-- =====================================================================
-- Painel de Pagamentos — setup do banco (rodar UMA vez no SQL Editor)
-- Supabase > SQL Editor > New query > colar tudo > Run
-- Horários sempre em Brasília (America/Sao_Paulo).
-- =====================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---------------------------------------------------------------------
-- Contas: cada linha é UMA ocorrência (a conta de um mês).
-- Recorrentes compartilham serie_id; ao pagar, a do mês seguinte é criada.
-- ---------------------------------------------------------------------
create table if not exists public.contas (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  descricao   text not null,
  empresa     text not null check (empresa in ('Spark', 'K&C', 'Pessoal')),
  categoria   text,
  valor       numeric(12,2),
  vencimento  date not null,
  recorrente  boolean not null default false,
  dia_venc    smallint,   -- dia original do vencimento (31 vira 30/28 e volta a 31)
  serie_id    uuid,
  pago_em     date,
  valor_pago  numeric(12,2),
  observacao  text,
  criado_em   timestamptz not null default now()
);
create index if not exists contas_user_venc on public.contas (user_id, vencimento);
create unique index if not exists contas_serie_venc on public.contas (serie_id, vencimento)
  where serie_id is not null;

alter table public.contas enable row level security;
drop policy if exists contas_dono on public.contas;
create policy contas_dono on public.contas for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
revoke all on public.contas from anon;

create or replace function public.contas_preencher() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' or new.vencimento is distinct from old.vencimento then
    new.dia_venc := extract(day from new.vencimento);
  end if;
  if new.recorrente and new.serie_id is null then
    new.serie_id := new.id;
  end if;
  return new;
end $$;

drop trigger if exists contas_preencher on public.contas;
create trigger contas_preencher before insert or update on public.contas
  for each row execute function public.contas_preencher();

-- ---------------------------------------------------------------------
-- Marcar como pago (roda com as permissões do usuário logado).
-- ---------------------------------------------------------------------
create or replace function public.marcar_pago(p_id uuid, p_data date default null, p_valor numeric default null)
returns void language plpgsql security invoker set search_path = '' as $$
declare
  c    public.contas;
  base date;
  prox date;
begin
  update public.contas
     set pago_em    = coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date),
         valor_pago = coalesce(p_valor, valor)
   where id = p_id
  returning * into c;
  if not found then
    raise exception 'Conta não encontrada';
  end if;

  if c.recorrente then
    base := (date_trunc('month', c.vencimento) + interval '1 month')::date;
    prox := make_date(extract(year from base)::int, extract(month from base)::int,
                      least(c.dia_venc, extract(day from base + interval '1 month' - interval '1 day')::int));
    insert into public.contas (user_id, descricao, empresa, categoria, valor, vencimento,
                               recorrente, serie_id, observacao)
    values (c.user_id, c.descricao, c.empresa, c.categoria, c.valor, prox,
            true, c.serie_id, c.observacao)
    on conflict (serie_id, vencimento) where serie_id is not null do nothing;
    -- mantém o dia original da série (o trigger usa o dia de "prox")
    update public.contas set dia_venc = c.dia_venc
     where serie_id = c.serie_id and vencimento = prox;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Configuração dos alertas (só o próprio banco lê; o painel não vê).
-- ---------------------------------------------------------------------
create table if not exists public.config_alertas (
  id                int primary key default 1 check (id = 1),
  ntfy_topic        text not null,
  app_url           text,
  supabase_url      text,
  supabase_key      text,
  relay_chave       text,   -- mesma CHAVE do edge-ntfy.ts
  dias_antecedencia int not null default 3
);
alter table public.config_alertas enable row level security;  -- sem policies de propósito
revoke all on public.config_alertas from anon, authenticated;

insert into public.config_alertas (ntfy_topic)
values ('pagamentos-' || replace(gen_random_uuid()::text, '-', ''))
on conflict (id) do nothing;

-- R$ 1.234,56
create or replace function public.brl(v numeric) returns text
language sql immutable set search_path = '' as $$
  select 'R$ ' || translate(to_char(v, 'FM999,999,990.00'), ',.', '.,')
$$;

create or replace function public.ntfy(p_title text, p_message text, p_priority int, p_tag text)
returns void language plpgsql security definer set search_path = '' as $$
declare cfg public.config_alertas;
begin
  select * into cfg from public.config_alertas where id = 1;
  -- O banco não consegue conectar direto no ntfy.sh (handshake TLS dá timeout),
  -- então o envio passa pela Edge Function "ntfy" (edge-ntfy.ts), que repassa.
  perform net.http_post(
    url     := cfg.supabase_url || '/functions/v1/ntfy',
    body    := jsonb_strip_nulls(jsonb_build_object(
                 'title',    p_title,
                 'message',  p_message,
                 'priority', p_priority,
                 'tags',     jsonb_build_array(p_tag),
                 'click',    cfg.app_url)),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-chave', cfg.relay_chave),
    timeout_milliseconds := 30000);
end $$;

-- ---------------------------------------------------------------------
-- Alerta: contas vencidas ou que vencem nos próximos N dias.
-- Não manda nada se estiver tudo em dia.
-- ---------------------------------------------------------------------
create or replace function public.enviar_alertas() returns void
language plpgsql security definer set search_path = '' as $$
declare
  hoje   date := (now() at time zone 'America/Sao_Paulo')::date;
  dias   int;
  r      record;
  linhas text := '';
  n      int := 0;
  n_venc int := 0;
  n_hoje int := 0;
  titulo text;
begin
  select dias_antecedencia into dias from public.config_alertas where id = 1;

  for r in
    select descricao, empresa, valor, vencimento
      from public.contas
     where pago_em is null and vencimento <= hoje + dias
     order by vencimento, empresa, descricao
  loop
    n := n + 1;
    if r.vencimento < hoje then n_venc := n_venc + 1;
    elsif r.vencimento = hoje then n_hoje := n_hoje + 1;
    end if;
    linhas := linhas
      || case when r.vencimento < hoje then '🔴 VENCIDA há ' || (hoje - r.vencimento) || 'd'
              when r.vencimento = hoje then '🟠 VENCE HOJE'
              else '🟡 ' || to_char(r.vencimento, 'DD/MM') end
      || ' · ' || r.descricao || ' (' || r.empresa || ')'
      || coalesce(' · ' || public.brl(r.valor), '') || E'\n';
  end loop;

  if n = 0 then
    return;
  end if;

  titulo := case
    when n_venc > 0 then n_venc || case when n_venc = 1 then ' conta VENCIDA' else ' contas VENCIDAS' end
    when n_hoje > 0 then n_hoje || case when n_hoje = 1 then ' conta vence HOJE' else ' contas vencem HOJE' end
    else n || case when n = 1 then ' conta vence em breve' else ' contas vencem em breve' end
  end;

  perform public.ntfy(titulo, rtrim(linhas, E'\n'),
                      case when n_venc > 0 or n_hoje > 0 then 5 else 4 end,
                      case when n_venc > 0 then 'rotating_light' else 'money_with_wings' end);
end $$;

-- Resumo de segunda-feira: prova de que os alertas estão funcionando,
-- mesmo numa semana sem nada vencido.
create or replace function public.resumo_semanal() returns void
language plpgsql security definer set search_path = '' as $$
declare
  hoje  date := (now() at time zone 'America/Sao_Paulo')::date;
  n     int;
  total numeric;
begin
  select count(*), coalesce(sum(valor), 0) into n, total
    from public.contas
   where pago_em is null and vencimento <= hoje + 7;
  perform public.ntfy(
    'Resumo da semana',
    case when n = 0 then 'Nada vence nos próximos 7 dias. Alertas funcionando ✅'
         else n || ' conta(s) até ' || to_char(hoje + 7, 'DD/MM') || ' · ' || public.brl(total) end,
    3, 'calendar');
end $$;

-- Mantém o projeto gratuito ativo: uma chamada diária pela API do próprio projeto.
create or replace function public.keepalive() returns void
language plpgsql security definer set search_path = '' as $$
declare cfg public.config_alertas;
begin
  select * into cfg from public.config_alertas where id = 1;
  if cfg.supabase_url is null or cfg.supabase_key is null then
    return;
  end if;
  perform net.http_get(
    url     := cfg.supabase_url || '/rest/v1/contas?select=id&limit=1',
    headers := jsonb_build_object('apikey', cfg.supabase_key));
end $$;

create or replace function public.testar_alerta() returns void
language sql security definer set search_path = '' as $$
  select public.ntfy('Teste do Painel de Pagamentos', 'Se você está lendo isto, o push funciona ✅', 5, 'white_check_mark')
$$;

revoke execute on function public.ntfy(text, text, int, text) from public, anon, authenticated;
revoke execute on function public.enviar_alertas()  from public, anon, authenticated;
revoke execute on function public.resumo_semanal()  from public, anon, authenticated;
revoke execute on function public.keepalive()       from public, anon, authenticated;
revoke execute on function public.testar_alerta()   from public, anon, authenticated;
revoke execute on function public.marcar_pago(uuid, date, numeric) from public, anon;
grant  execute on function public.marcar_pago(uuid, date, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- Agendamentos (cron em UTC; Brasília = UTC-3)
--   alertas: 7h, 11h, 15h e 20h · resumo: segunda 8h · keepalive: 11h30
-- ---------------------------------------------------------------------
select cron.schedule('alertas-pagamentos', '0 10,14,18,23 * * *', 'select public.enviar_alertas()');
select cron.schedule('resumo-semanal',     '0 11 * * 1',          'select public.resumo_semanal()');
select cron.schedule('keepalive',          '30 14 * * *',         'select public.keepalive()');

-- Mostra o tópico do ntfy para assinar no celular
select ntfy_topic as "Tópico ntfy (assinar no app)" from public.config_alertas;
-- Registro dos avisos recebidos da Meta (WhatsApp). Só a Edge Function grava e lê.
create table if not exists public.whatsapp_eventos (
  id          bigserial primary key,
  recebido_em timestamptz not null default now(),
  resumo      text,
  corpo       jsonb
);
alter table public.whatsapp_eventos enable row level security;  -- sem policies de propósito
revoke all on public.whatsapp_eventos from anon, authenticated;
