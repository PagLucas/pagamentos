-- =====================================================================
-- Alertas v2 (2026-11-06)
--   Urgentes (vencidas / vencem hoje): uma notificação por conta, a cada
--   30 min das 7h às 21h, com botões "✅ Paguei" e "Abrir painel".
--   Próximas (vencem em 1..N dias): um aviso único às 7h, 11h, 15h e 20h.
-- O botão "Paguei" chama a Edge Function "ntfy", que marca a conta como paga.
-- =====================================================================

-- ntfy() ganha o parâmetro opcional de botões (actions)
drop function if exists public.ntfy(text, text, int, text);
create or replace function public.ntfy(p_title text, p_message text, p_priority int, p_tag text,
                                       p_actions jsonb default null)
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
                 'click',    cfg.app_url,
                 'actions',  p_actions)),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-chave', cfg.relay_chave),
    timeout_milliseconds := 30000);
end $$;

-- Próximas: contas que vencem de amanhã até N dias (as de hoje e vencidas são urgentes)
create or replace function public.enviar_alertas() returns void
language plpgsql security definer set search_path = '' as $$
declare
  hoje   date := (now() at time zone 'America/Sao_Paulo')::date;
  dias   int;
  r      record;
  linhas text := '';
  n      int := 0;
begin
  select dias_antecedencia into dias from public.config_alertas where id = 1;

  for r in
    select descricao, empresa, valor, vencimento
      from public.contas
     where pago_em is null and vencimento > hoje and vencimento <= hoje + dias
     order by vencimento, empresa, descricao
  loop
    n := n + 1;
    linhas := linhas || '🟡 ' || to_char(r.vencimento, 'DD/MM')
      || ' · ' || r.descricao || ' (' || r.empresa || ')'
      || coalesce(' · ' || public.brl(r.valor), '') || E'\n';
  end loop;

  if n = 0 then
    return;
  end if;

  perform public.ntfy(
    n || case when n = 1 then ' conta vence em breve' else ' contas vencem em breve' end,
    rtrim(linhas, E'\n'), 4, 'money_with_wings');
end $$;

-- Urgentes: uma notificação por conta vencida ou que vence hoje, com botões
create or replace function public.enviar_urgentes() returns void
language plpgsql security definer set search_path = '' as $$
declare
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  cfg  public.config_alertas;
  r    record;
begin
  select * into cfg from public.config_alertas where id = 1;

  for r in
    select id, descricao, empresa, valor, vencimento, observacao
      from public.contas
     where pago_em is null and vencimento <= hoje
     order by vencimento, empresa, descricao
  loop
    perform public.ntfy(
      case when r.vencimento < hoje
           then '🔴 VENCIDA há ' || (hoje - r.vencimento)
                || case when hoje - r.vencimento = 1 then ' dia: ' else ' dias: ' end
           else '🟠 VENCE HOJE: ' end || r.descricao,
      r.empresa || coalesce(' · ' || public.brl(r.valor), '')
        || ' · venc. ' || to_char(r.vencimento, 'DD/MM')
        || coalesce(E'\n' || r.observacao, ''),
      5,
      case when r.vencimento < hoje then 'rotating_light' else 'warning' end,
      jsonb_build_array(
        jsonb_build_object(
          'action',  'http',
          'label',   '✅ Paguei',
          'url',     cfg.supabase_url || '/functions/v1/ntfy',
          'method',  'POST',
          'headers', jsonb_build_object('Content-Type', 'application/json', 'x-chave', cfg.relay_chave),
          'body',    jsonb_build_object('pagar', r.id)::text,
          'clear',   true),
        jsonb_build_object(
          'action', 'view',
          'label',  'Abrir painel',
          'url',    cfg.app_url)));
  end loop;
end $$;

revoke execute on function public.ntfy(text, text, int, text, jsonb) from public, anon, authenticated;
revoke execute on function public.enviar_alertas()  from public, anon, authenticated;
revoke execute on function public.enviar_urgentes() from public, anon, authenticated;

-- Agendamentos (cron em UTC; Brasília = UTC-3)
--   próximas: 7h, 11h, 15h e 20h · urgentes: a cada 30 min das 7h às 21h
select cron.schedule('alertas-pagamentos',   '0 10,14,18,23 * * *', 'select public.enviar_alertas()');
select cron.schedule('alertas-urgentes',     '*/30 10-23 * * *',    'select public.enviar_urgentes()');
select cron.schedule('alertas-urgentes-21h', '0 0 * * *',           'select public.enviar_urgentes()');

-- Dispara agora, para testar (só envia se houver conta vencida ou vencendo hoje)
select public.enviar_urgentes();
