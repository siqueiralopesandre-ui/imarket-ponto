# Ponto Eletrônico iMarket — Fase 1

Sistema de bater ponto pela web (celular), com login + 2FA, aceite LGPD,
captura de **unidade + GPS** e painel **"minhas horas"** do próprio colaborador.
Hospedagem: **Cloudflare Pages** (frontend estático) + **Supabase** (Auth + banco + RLS).

## O que já está pronto e no ar (backend)
- **Projeto Supabase:** `imarket-ponto` (região São Paulo / sa-east-1).
- **URL:** `https://qcvigrulgqhzfzyhohbz.supabase.co`
- **Schema aplicado:** `unidades`, `colaboradores`, `registros_ponto`,
  `consentimentos_lgpd`, `escalas` (esta última já criada para a Fase 2).
- **Segurança (RLS):** cada colaborador só vê e insere as PRÓPRIAS batidas;
  o papel `gestor` enxerga todos. A **hora da batida é carimbada pelo servidor**
  (trigger `fn_carimba_hora`), então não dá pra fraudar mudando o relógio do celular.
- **10 unidades** genéricas cadastradas (renomeie — ver abaixo).
- **Usuário demo** pra testar: `demo@imarket.com` / senha `Ponto@2026`.

## Estrutura
```
ponto-imarket/
├── public/              <- isto é o que vai pro Cloudflare Pages
│   ├── index.html       (app inteiro: login, 2FA, LGPD, ponto, minhas horas)
│   └── config.js        (URL + chave pública do Supabase — já preenchidos)
├── supabase/
│   └── schema.sql       (schema completo, fonte da verdade)
└── README.md
```

## Como hospedar no Cloudflare Pages (5 min)
A chave que está no `config.js` é a **publishable/anon** — pode ser pública
(a proteção real é o RLS no banco). Nunca coloque a *service role* aqui.

**Opção A — arrastar e soltar (mais fácil):**
1. Acesse o painel Cloudflare → **Workers & Pages** → **Create** → **Pages** →
   **Upload assets**.
2. Dê um nome (ex.: `ponto-imarket`) e **arraste a pasta `public/`** inteira.
3. **Deploy.** O Cloudflare te dá uma URL `https://ponto-imarket.pages.dev`.

**Opção B — linha de comando (wrangler):**
```bash
cd ponto-imarket
npx wrangler pages deploy public --project-name ponto-imarket
```

> ⚠️ O GPS do navegador **exige HTTPS** — funciona no `*.pages.dev` (tem HTTPS),
> não funciona abrindo o arquivo direto no celular.

## Cadastrar os 4 colaboradores reais
Para cada colaborador, no painel Supabase → **Authentication → Users → Add user**
(marque *Auto Confirm User*), depois rode no **SQL Editor** vinculando o cadastro:

```sql
insert into colaboradores (id, matricula, nome, cargo, papel)
select id, 'MAT001', 'Nome do Colaborador', 'Assistente de loja', 'colaborador'
from auth.users where email = 'email-do-colaborador@exemplo.com';
```
Para um **gestor** (acompanha todos), troque `'colaborador'` por `'gestor'`.

## Renomear as unidades
No SQL Editor:
```sql
update unidades set nome = 'iMarket — Residencial X', cidade = 'Petrolina'
where nome = 'iMarket — Unidade 01';
```

## Como funciona pro colaborador
1. Abre a URL no celular → entra com e-mail e senha.
2. **1ª vez:** ativa o 2FA escaneando o QR num app autenticador (Google
   Authenticator / Authy). Nos próximos logins, só digita o código de 6 dígitos.
3. Aceita o termo de **LGPD** (uma vez por versão do termo).
4. **Bater ponto:** escolhe a unidade, toca em *Entrada / Saída intervalo /
   Volta intervalo / Saída*. O app pega a localização e grava. Data = dia atual,
   hora = momento exato (servidor).
5. **Minhas horas:** vê as próprias batidas dos últimos 7 dias e o total de horas.

## Recomendações de segurança (opcionais, no painel Supabase)
- **Authentication → Providers → Email:** manter "Confirm email" ligado para
  cadastros futuros.
- **Authentication → Policies:** ative *Leaked password protection* (checa senhas
  vazadas no HaveIBeenPwned).
- O 2FA (TOTP) já vem habilitado; o app força o cadastro no 1º acesso.

## Próximas fases
- **Fase 2 — Gestão:** tela pra carregar **escala** (dias de trabalho, folgas,
  entrada/saída previstas) e **dashboard de KPIs** por colaborador (dias
  trabalhados, horas, faltas, atrasos, banco de horas, atestados).
- **Integração RHfoco:** rodar o motor de regras CLT (intra/interjornada, hora
  extra) sobre as batidas reais capturadas aqui — auditoria dentro de casa.
