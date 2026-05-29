# Auth0 — Setup para o conector MCP (Claude Code + Claude.ai)

O `docs-mcp-server` usa o Auth0 como **Authorization Server** com **Dynamic Client
Registration (DCR)** — assim cada cliente (Claude Code, Claude.ai) se auto-registra
e nenhum segredo precisa ser distribuído. A equipe loga com **contas Google/Workspace**
via uma social connection do Auth0.

> ⚠️ O dashboard do Auth0 muda com frequência. **Fonte de verdade (mantida pela Auth0):**
> - Guia oficial MCP: https://auth0.com/ai/docs/mcp
> - Guia 3rd-party (passo a passo, atual): https://zuplo.com/docs/articles/configuring-auth0-for-mcp-auth
>
> Abaixo o **mapa dos passos + os valores exatos do nosso servidor**. Se um rótulo
> estiver diferente, siga o guia oficial usando estes mesmos valores.

## Valores deste servidor

| Campo | Valor |
|---|---|
| API Identifier (audience) | `https://docs-mcp-server` |
| Default Audience | `https://docs-mcp-server` |
| Scopes | `openid`, `profile`, `email` |

## Passos (dashboard Auth0)

### 1. Criar a API
**Applications → APIs → + Create API**
- Name: `docs-mcp-server`
- Identifier: `https://docs-mcp-server`
- Signing Algorithm: `RS256`

### 2. Default Audience (emite JWT em vez de token opaco) — **essencial**
**Settings → General → Default Audience** = `https://docs-mcp-server`, salvar.

> Os clientes MCP enviam `resource` mas não `audience`. Sem Default Audience, o Auth0
> emite token opaco (difícil de validar). Com ele, emite JWT que o servidor valida via JWKS.

### 3. Habilitar DCR
**Settings → Advanced** →
- toggle **Dynamic Client Registration (DCR)** = ON
- toggle **Enable Application Connections** = ON
- salvar

### 4. Permissões padrão para third-party apps — **passo novo, não pule**
Clientes registrados via DCR são "third-party"; eles só acessam a API se houver
**default permissions** definidas. Configure as permissões/escopos padrão da API
para third-party apps conforme o guia oficial (seção *default permissions* /
*third-party applications*). Sem isso, o login completa mas o cliente não recebe acesso.

### 5. Permitir que o Management API gerencie connections (p/ DCR + Application Connections)
**Applications → Auth0 Management API → (aba) APIs/Permissions** → autorizar e marcar
**`update:connections`** → Update.

### 6. Login com Google (equipe entra com contas Google/Workspace)
**Authentication → Social → Create Connection → Google**
- Início rápido: usar as *Auth0 dev keys*.
- Produção: criar um OAuth client no GCP (☰ → Google Auth Platform → Clients → Web application)
  com redirect `https://<seu-tenant>.<região>.auth0.com/login/callback`, e colar Client ID/Secret.
- (Recomendado) Restringir ao domínio: definir **Hosted Domain (HD)** = `nexuz.com.br`.
- Habilitar a connection nas Applications.

---

## Resultado — me envie estes dois valores

```
AUTH_ISSUER_URL=https://<seu-tenant>.<região>.auth0.com/   (com barra final)
AUTH_AUDIENCE=https://docs-mcp-server
```

Com eles eu redeployo o serviço unificado (`04-deploy-unified.sh` — troca de 2 env vars,
dados preservados, ~1 min), valido o fluxo OAuth/DCR (metadata → registro → JWT via JWKS)
e te entrego os comandos de equipe (Claude Code `--scope project`) e do conector Claude.ai.

## Validação do meu lado (após você enviar os valores)
- `authorization_servers` na metadata aponta para o Auth0
- registro dinâmico via `/oidc/register` aceito
- token chega como JWT com `aud=https://docs-mcp-server` e valida por JWKS
