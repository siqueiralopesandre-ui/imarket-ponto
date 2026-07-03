-- ============================================================================
-- iMarket — Ponto Eletrônico (Supabase / Postgres)
-- Fase 1: captura de batida na fonte, com login (e-mail+senha+2FA), LGPD e
-- painel "minhas horas". 4 colaboradores CLT que prestam assistência nas lojas.
--
-- Como aplicar: cole no SQL Editor do Supabase de um projeto NOVO (separado do
-- projeto do hospital). O app/frontend lê e grava com a chave ANON, sujeito às
-- policies de RLS abaixo. NÃO há ingestão por service role nesta fase: o próprio
-- colaborador grava a batida (mas a HORA é carimbada pelo servidor, ver trigger).
-- ============================================================================

-- ------------------------------------------------------------------- tipos
create type papel_ponto as enum ('colaborador', 'gestor');

create type tipo_batida as enum (
  'entrada',
  'entrada_intervalo',   -- saída para o intervalo/almoço
  'retorno_intervalo',   -- volta do intervalo
  'saida'
);

-- ------------------------------------------------------------------ tabelas

-- Unidades (lojas) onde o colaborador presta assistência.
create table unidades (
  id        uuid primary key default gen_random_uuid(),
  nome      text not null,
  cidade    text,
  -- coordenadas da loja (opcional) p/ futura checagem de proximidade
  lat       double precision,
  lng       double precision,
  ativo     boolean not null default true,
  criado_em timestamptz not null default now()
);

-- Liga o usuário do Supabase Auth (auth.users) ao cadastro de colaborador.
create table colaboradores (
  id         uuid primary key references auth.users(id) on delete cascade,
  matricula  text unique not null,
  nome       text not null,
  cargo      text,
  papel      papel_ponto not null default 'colaborador',
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

-- Cada batida de ponto. A HORA real é definida pelo servidor (trigger), nunca
-- pelo celular do colaborador — impede fraude por mudar o relógio do aparelho.
create table registros_ponto (
  id             uuid primary key default gen_random_uuid(),
  colaborador_id uuid not null references colaboradores(id) on delete cascade,
  tipo           tipo_batida not null,
  -- carimbo do servidor (UTC). Forçado pelo trigger fn_carimba_hora.
  registrado_em  timestamptz not null default now(),
  -- dia de referência (fuso America/Sao_Paulo, UTC-3). Também forçado no trigger.
  data_ref       date not null default ((now() at time zone 'America/Sao_Paulo')::date),
  unidade_id     uuid references unidades(id),
  -- geolocalização capturada no momento da batida
  lat            double precision,
  lng            double precision,
  precisao_m     double precision,   -- precisão do GPS em metros
  dispositivo    text,               -- user agent / descrição do aparelho
  observacao     text
);

-- Aceite de LGPD. Guarda a versão do texto aceito e quando.
create table consentimentos_lgpd (
  id             uuid primary key default gen_random_uuid(),
  colaborador_id uuid not null references colaboradores(id) on delete cascade,
  versao_texto   text not null,            -- ex.: 'v1-2026-06'
  aceito_em      timestamptz not null default now(),
  dispositivo    text
);

-- Escala prevista (entrada/saída por dia, folga). Estrutura já criada para a
-- Fase 2 (área de gestão); o app da Fase 1 ainda não escreve aqui.
create table escalas (
  id               uuid primary key default gen_random_uuid(),
  colaborador_id   uuid not null references colaboradores(id) on delete cascade,
  data             date not null,
  eh_folga         boolean not null default false,
  entrada_prevista time,
  saida_prevista   time,
  intervalo_min    int,                    -- minutos de intervalo previstos
  unidade_id       uuid references unidades(id),
  criado_em        timestamptz not null default now(),
  unique (colaborador_id, data)
);

create index on registros_ponto (colaborador_id, data_ref);
create index on registros_ponto (data_ref);
create index on escalas (colaborador_id, data);

-- ---------------------------------------------- trigger: hora do servidor
-- Garante que registrado_em e data_ref são definidos pelo servidor, ignorando
-- o que o cliente tentar enviar. Essência do controle anti-fraude de horário.
create or replace function fn_carimba_hora() returns trigger
  language plpgsql as $$
begin
  new.registrado_em := now();
  new.data_ref := (now() at time zone 'America/Sao_Paulo')::date;
  return new;
end;
$$;

create trigger trg_carimba_hora
  before insert on registros_ponto
  for each row execute function fn_carimba_hora();

-- ---------------------------------------------------- funções de contexto
create or replace function eh_gestor() returns boolean
  language sql stable security definer set search_path = public as $$
  select coalesce(
    (select papel = 'gestor' from colaboradores where id = auth.uid()),
    false)
$$;

-- ------------------------------------------------------------------- RLS
alter table unidades            enable row level security;
alter table colaboradores       enable row level security;
alter table registros_ponto     enable row level security;
alter table consentimentos_lgpd enable row level security;
alter table escalas             enable row level security;

-- Unidades: qualquer usuário logado pode listar (precisa escolher na batida).
create policy unidades_select on unidades for select
  to authenticated using (ativo or eh_gestor());

-- Colaborador vê o próprio cadastro; gestor vê todos.
create policy colab_select on colaboradores for select
  to authenticated using (id = auth.uid() or eh_gestor());

-- Registros: colaborador vê só os SEUS; gestor vê todos.
create policy reg_select on registros_ponto for select
  to authenticated using (colaborador_id = auth.uid() or eh_gestor());

-- Registros: colaborador só insere batida em nome PRÓPRIO. A hora é forçada
-- pelo trigger, então mesmo que o cliente mande outro horário, ele é ignorado.
create policy reg_insert on registros_ponto for insert
  to authenticated with check (colaborador_id = auth.uid());

-- Sem UPDATE/DELETE p/ colaborador: batida não se apaga nem se edita pelo app.

-- LGPD: colaborador lê e grava só o próprio aceite.
create policy lgpd_select on consentimentos_lgpd for select
  to authenticated using (colaborador_id = auth.uid() or eh_gestor());
create policy lgpd_insert on consentimentos_lgpd for insert
  to authenticated with check (colaborador_id = auth.uid());

-- Escalas: colaborador vê a própria; gestor vê/edita todas (Fase 2).
create policy escala_select on escalas for select
  to authenticated using (colaborador_id = auth.uid() or eh_gestor());
create policy escala_gestor_all on escalas for all
  to authenticated using (eh_gestor()) with check (eh_gestor());

-- ---------------------------------------------- view: minhas batidas do dia
-- Conveniência p/ o painel: batidas já no fuso local, com nome da unidade.
create or replace view vw_minhas_batidas with (security_invoker = on) as
  select
    r.id,
    r.colaborador_id,
    r.tipo,
    r.registrado_em,
    (r.registrado_em at time zone 'America/Sao_Paulo') as hora_local,
    r.data_ref,
    r.unidade_id,
    u.nome as unidade,
    r.lat, r.lng, r.precisao_m
  from registros_ponto r
  left join unidades u on u.id = r.unidade_id;

grant select on vw_minhas_batidas to authenticated;

-- ============================================================================
-- NOTAS DE OPERAÇÃO
-- 1) 2FA/MFA: habilitar TOTP no painel Supabase (Authentication > Providers/MFA).
--    O app faz enroll na 1ª vez e challenge nos logins seguintes.
-- 2) Confirmação de e-mail: para os 4 colaboradores de teste, pode-se criar os
--    usuários já confirmados (Admin) e cadastrar a linha em colaboradores com
--    o mesmo id (auth.users.id).
-- 3) A integração futura com o RHfoco (auditoria CLT) lê registros_ponto e roda
--    as regras de intra/interjornada sobre as batidas reais.
-- ============================================================================
