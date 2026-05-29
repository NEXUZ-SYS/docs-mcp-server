# Google OAuth (manual) — Setup para o conector Claude.ai (spike)

Caminho "só Google": criamos **1 client OAuth Web** no projeto e informamos
`client_id`/`client_secret` ao conector do Claude.ai. Sem DCR (o Google não
suporta), então depende de o Claude.ai aceitar credenciais manuais — é isto que
o spike valida.

> Projeto: `gen-lang-client-0927668204`. A interface foi consolidada no
> **Google Auth Platform** (☰ → **Google Auth Platform**), com as abas
> **Branding · Audience · Data Access · Clients**.
> Link direto: https://console.cloud.google.com/auth/clients

## 1. Configurar o Google Auth Platform (Branding) — só na 1ª vez

1. Console → ☰ → **Google Auth Platform**. Se aparecer *"Google Auth Platform not
   configured yet"*, clique **Get Started**.
2. **App Information:** App name = `docs-mcp-server`; User support email = o seu.
3. **Audience:** selecione **External**.
4. **Contact Information:** seu e-mail.
5. **Finish:** aceite a *User Data Policy* → **Create**.

## 2. Audience (test users)

1. ☰ → **Google Auth Platform → Audience**.
2. Se o status for **Testing**, em **Test users** clique **Add users** e adicione
   `nexuz@nexuz.com.br` (e qualquer outro que vá logar). Em Testing, só test users
   conseguem autenticar — suficiente para o spike.

## 3. Data Access (scopes)

1. ☰ → **Google Auth Platform → Data Access** → **Add or remove scopes**.
2. Marque: `openid`, `.../auth/userinfo.email`, `.../auth/userinfo.profile`
   (não-sensíveis → sem verificação) → **Update** → **Save**.

## 4. Criar o Client OAuth (Web application)

1. ☰ → **Google Auth Platform → Clients** → **+ Create client**
   (ou direto: https://console.cloud.google.com/auth/clients).
2. **Application type: Web application**. Name: `docs-mcp claude connector`.
3. **Authorized redirect URIs** → **Add URI**:
   ```
   https://claude.ai/api/mcp/auth_callback
   ```
4. **Create.** Copie o **Client ID** e o **Client secret** (botão de copiar no
   painel do client; o secret também fica em *Additional information*).

> Pode ignorar "Authorized JavaScript origins" (não é fluxo de browser SPA).

## 5. Me envie / guarde

- `CLIENT_ID` (ex: `123456-abc.apps.googleusercontent.com`)
- `CLIENT_SECRET` (você cola no Claude.ai)

> O servidor já está com `issuer=https://accounts.google.com`. O `audience` no
> servidor é cosmético neste caminho (a validação real do token usa o endpoint
> `userinfo` do Google).

## 6. Adicionar o conector no Claude.ai

1. Claude.ai → **Settings → Connectors → Add custom connector**.
2. **URL:** `https://docs-mcp-qysz5zbtda-rj.a.run.app/mcp`
3. Em **Advanced settings**, cole **OAuth Client ID** e **OAuth Client Secret**.
4. Conectar → login Google → consentimento → volta conectado.

## Critério do spike

- ✅ **Funciona** se: o Claude.ai oferecer os campos de Client ID/Secret manuais,
  completar o login Google e listar as tools.
- ❌ **Não funciona** se: o Claude.ai exigir registro automático (DCR) sem campos
  manuais, ou travar em scope/redirect.

**Se não funcionar → fallback Auth0** (sem retrabalho): troco 2 env vars do serviço
já implantado e o Claude.ai se auto-registra via DCR (ver `AUTH0-SETUP.md`):
```
DOCS_MCP_AUTH_ISSUER_URL=https://<tenant>.auth0.com/
DOCS_MCP_AUTH_AUDIENCE=https://docs-mcp-server
```
