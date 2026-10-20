# Painel de Pagamentos — comandos importantes

Projeto Supabase: **pagamentos** (conta nova, separada da conta do KC).
Todos os comandos abaixo são colados no **SQL Editor** do projeto (ver como abrir logo abaixo).

> A senha do banco NÃO fica neste arquivo de propósito: esta pasta vai para um
> repositório público no GitHub. Guarde a senha num gerenciador de senhas.

---

## Como abrir o SQL Editor

1. Entre em https://supabase.com/dashboard com o e-mail da conta nova.
2. Clique no projeto **pagamentos**.
3. Na barra da esquerda, clique em **SQL Editor** (ícone `>_`; passe o mouse
   sobre os ícones para ver os nomes).
4. Clique em **+ New query** (ou no `+` no topo da lista de queries).
5. Cole o comando na área de texto e clique em **Run** (ou `Ctrl+Enter`).
   O resultado aparece embaixo, em **Results**.

Se aparecer o aviso *"Potential issue detected"* / *"destructive operation"*,
é por causa dos comandos `drop ... if exists` do setup; pode clicar em
**Run this query** (ou **Confirm**).

---

## Primeira configuração (uma vez só)

Colar o arquivo `setup.sql` inteiro e rodar. No final ele mostra o tópico do ntfy.

Depois de publicar o site e ter a URL e a chave do projeto:

```sql
update public.config_alertas set
  app_url      = 'https://SEU-SITE.github.io/pagamentos/',
  supabase_url = 'https://SEU-PROJETO.supabase.co',
  supabase_key = 'sb_publishable_...';
```

---

## Testes

```sql
-- Manda um push de teste agora
select public.testar_alerta();

-- Roda o alerta real agora (só envia se houver conta vencida/vencendo em até 3 dias)
select public.enviar_alertas();

-- Manda o resumo semanal agora
select public.resumo_semanal();

-- Resposta do ntfy às últimas mensagens (status 200 = entregue ao ntfy)
select id, status_code, content, created from net._http_response order by created desc limit 10;
```

## Ver configuração e agendamentos

```sql
-- Tópico do ntfy, URL do app, antecedência dos alertas
select * from public.config_alertas;

-- Agendamentos ativos (horários em UTC: Brasília = UTC-3)
select jobname, schedule, active from cron.job;

-- Últimas execuções (deu certo? deu erro?)
select j.jobname, d.status, d.return_message, d.start_time
  from cron.job_run_details d join cron.job j using (jobid)
 order by d.start_time desc limit 20;
```

## Ajustes

```sql
-- Avisar com 5 dias de antecedência em vez de 3
update public.config_alertas set dias_antecedencia = 5;

-- Mudar horários dos alertas (exemplo: 8h, 12h, 18h BRT = 11, 15, 21 UTC)
select cron.schedule('alertas-pagamentos', '0 11,15,21 * * *', 'select public.enviar_alertas()');

-- Pausar alertas (férias etc.) e religar depois
update cron.job set active = false where jobname = 'alertas-pagamentos';
update cron.job set active = true  where jobname = 'alertas-pagamentos';

-- Trocar o tópico do ntfy (se vazar). Depois assine o novo no app.
update public.config_alertas set ntfy_topic = 'pagamentos-' || replace(gen_random_uuid()::text, '-', '')
returning ntfy_topic;
```

## Consultas úteis

```sql
-- Contas em aberto, por vencimento
select vencimento, empresa, descricao, valor from public.contas
 where pago_em is null order by vencimento;

-- Total pago por empresa no mês (trocar o mês)
select empresa, sum(coalesce(valor_pago, valor)) as total
  from public.contas
 where pago_em >= '2026-10-01' and pago_em < '2026-11-01'
 group by empresa;
```

## Configurações no painel do Supabase (sem SQL)

- **Bloquear novos cadastros** (depois de criar seu login):
  Authentication → Sign In / Providers → desligar *Allow new users to sign up*.
- **URL e chave do projeto:** Project Settings → API (ou "Data API" / "API Keys").
- **Projeto pausado?** Se o painel parar de carregar, entrar no dashboard e clicar
  em *Restore project*. Os alertas ficam parados enquanto o projeto estiver pausado.
