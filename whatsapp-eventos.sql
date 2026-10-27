-- Registro dos avisos recebidos da Meta (WhatsApp). Só a Edge Function grava e lê.
create table if not exists public.whatsapp_eventos (
  id          bigserial primary key,
  recebido_em timestamptz not null default now(),
  resumo      text,
  corpo       jsonb
);
alter table public.whatsapp_eventos enable row level security;  -- sem policies de propósito
revoke all on public.whatsapp_eventos from anon, authenticated;
