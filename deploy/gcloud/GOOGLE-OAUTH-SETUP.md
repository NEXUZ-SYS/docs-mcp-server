# Google OAuth (manual) — Setup para o conector Claude.ai (spike)

Caminho "só Google": criamos **1 client OAuth Web** no projeto e informamos `client_id`/`client_secret` ao conector do Claude.ai. Sem DCR (o Google não suporta), então depende de o Claude.ai aceitar credenciais manuais — é isto que o spike valida.

> Projeto: `gen-lang-client-0927668204`. Console: https://console.cloud.google.com/auth (Google Auth Platform).

## 1. Tela de consentimento OAuth

1. Console → **APIs & Services → OAuth consent screen** (Google Auth Platform).
2. **User type: External** → Create.
3. App name: `docs-mcp-server`; e-mail de suporte: o seu; e-mail de contato do dev: o seu.
4. **Scopes:** adicione `openid`, `.../auth/userinfo.email`, `.../auth/userinfo.profile` (não-sensíveis → sem verificação).
5. **Test users:** adicione seu próprio e-mail (`nexuz@nexuz.com.br`). Em modo *Testing* só test users logam — suficiente para o spike. (Publicar depois é opcional, sem verificação para esses scopes.)

## 2. Criar o OAuth Client (Web application)

1. Console → **APIs & Services → Credentials → + Create Credentials → OAuth client ID**.
2. **Application type: Web application**. Name: `docs-mcp claude connector`.
3. **Authorized redirect URIs** → adicione:
   ```
   https://claude.ai/api/mcp/auth_callback
   ```
   (callback do conector do Claude.ai, conforme a doc do Google Cloud para MCP).
4. **Create.** Copie o **Client ID** e o **Client secret**.

## 3. Me envie / guarde

- `CLIENT_ID` (ex: `123456-abc.apps.googleusercontent.com`)
- `CLIENT_SECRET` (você vai colar no Claude.ai)

> O servidor já está configurado com `issuer=https://accounts.google.com`. O `audience` no servidor é cosmético neste caminho (a validação real do token usa o endpoint `userinfo` do Google).

## 4. Adicionar o conector no Claude.ai

1. Claude.ai → **Settings → Connectors → Add custom connector**.
2. **URL:** `https://docs-mcp-qysz5zbtda-rj.a.run.app/mcp`
3. Em **Advanced settings**, procure os campos **OAuth Client ID** e **OAuth Client Secret** e cole os valores do passo 3.
4. Conectar → o Claude.ai redireciona para o login Google → consentimento → volta conectado.

## Critério do spike (o que valida se o caminho Google funciona)

- ✅ **Funciona** se: o Claude.ai mostrar os campos de Client ID/Secret manuais, completar o login Google e listar as tools.
- ❌ **Não funciona** se: o Claude.ai exigir registro automático (DCR) e não oferecer campos manuais, ou travar no scope/redirect.

**Se não funcionar → fallback Auth0** (sem retrabalho): eu só troco 2 env vars do serviço já implantado:
```
DOCS_MCP_AUTH_ISSUER_URL=https://<tenant>.auth0.com/
DOCS_MCP_AUTH_AUDIENCE=https://docs-mcp-server
```
e o Claude.ai se auto-registra via DCR (ver `AUTH0-SETUP.md`).
