# Auth0 — Setup para o conector Claude.ai (quickdoc)

O `docs-mcp-server` funciona como **proxy OAuth2**: ele descobre os endpoints do Auth0, e o Claude.ai se **auto-registra via Dynamic Client Registration (DCR)** e faz login pelo Auth0. Este guia configura o Auth0 para esse fluxo.

> Tempo estimado: ~10 min. Tudo no plano gratuito do Auth0.

---

## 1. Criar conta/tenant

1. Acesse https://auth0.com → **Sign up** (free).
2. Ao criar, você escolhe um **tenant domain** e uma região. Anote o domínio, ex:
   `meu-tenant.us.auth0.com`
3. Seu **issuer** será esse domínio com `https://` e **barra final**:
   ```
   AUTH0_ISSUER_URL=https://meu-tenant.us.auth0.com/
   ```

## 2. Criar a API (define o `audience`)

1. Menu lateral → **Applications → APIs → + Create API**.
2. Preencha:
   - **Name:** `docs-mcp-server`
   - **Identifier:** `https://docs-mcp-server`  ← este é o **audience** (não precisa ser uma URL real, só um identificador único)
   - **Signing Algorithm:** `RS256` (padrão)
3. **Create.** Guarde:
   ```
   AUTH0_AUDIENCE=https://docs-mcp-server
   ```

## 3. Habilitar Dynamic Client Registration (DCR)

Sem isso o Claude.ai não consegue se registrar.

1. Menu lateral → **Settings** (engrenagem no rodapé) → aba **Advanced**.
2. Ligue **OIDC Dynamic Application Registration** = **ON**.
3. Ainda em **Settings → Advanced**, em **Default Directory**, defina:
   ```
   Username-Password-Authentication
   ```
   (é o nome da conexão de banco de dados padrão do Auth0; necessário para apps registrados via DCR conseguirem autenticar usuários).

## 4. Default Audience (passo-chave)

Apps registrados via DCR (como o Claude.ai) não especificam o audience da sua API. Para os tokens saírem **assinados para a sua API**, defina um audience padrão:

1. **Settings → API Authorization Settings → Default Audience:**
   ```
   https://docs-mcp-server
   ```
   (o mesmo Identifier do passo 2).
2. **Save.**

> Isso garante que o JWT emitido tenha `aud = https://docs-mcp-server`, que é o que o servidor valida (`DOCS_MCP_AUTH_AUDIENCE`).

## 5. Login com Google (a equipe entra com contas Google/Workspace)

Para que cada membro entre com a conta Google de sempre — sem criar senha — habilite o Google como **social connection** no Auth0:

1. **Authentication → Social → Create Connection → Google / Google Workspace**.
2. Para começar rápido, use as **Auth0 dev keys** (botão padrão; bom para validar). Para produção, crie credenciais próprias:
   - No GCP (☰ → **Google Auth Platform → Clients → Create client → Web application**), adicione como **Authorized redirect URI**:
     ```
     https://<seu-tenant>.<região>.auth0.com/login/callback
     ```
   - Cole o **Client ID/Secret** desse client Google na connection do Auth0.
3. Em **Applications**, deixe a connection **habilitada** (toggle) para que ela seja oferecida no login.
4. (Opcional, recomendado p/ equipe) Restrinja ao seu domínio Workspace: na connection Google, defina o **Hosted Domain (HD)** (ex: `nexuz.com.br`) para aceitar só e-mails desse domínio.

> Identidade = Google/Workspace; Authorization Server = Auth0 (que fornece o DCR que o MCP exige). O `Username-Password-Authentication` pode ficar habilitado como fallback ou ser desativado — sua escolha.

## 6. Controle de quem acessa

- **Modo Workspace (HD):** qualquer conta do domínio loga.
- **Mais restrito:** desabilite signups e gerencie usuários em **User Management → Users**, ou use uma **Action/Rule** para permitir só e-mails de uma lista.

---

## Resultado — me envie estes dois valores

```
AUTH_ISSUER_URL=https://<seu-tenant>.<região>.auth0.com/
AUTH_AUDIENCE=https://docs-mcp-server
```

Com eles eu redeployo o serviço unificado (`04-deploy-unified.sh`, troca de 2 env vars, dados preservados), valido o fluxo OAuth/DCR e te entrego os comandos de equipe (Claude Code `--scope project`) e o conector do Claude.ai.

---

## Notas de validação / fallback

- O servidor valida o token assim: tenta **JWT via JWKS** (checando `iss` e `aud`); se falhar, faz **fallback para o endpoint `userinfo`** do Auth0. Ou seja, mesmo que haja um descasamento de audience, um token Auth0 válido ainda autentica — o setup é tolerante.
- Se o Claude.ai falhar no registro (`/oauth/register`), revise o passo 3 (DCR ON + Default Directory).
- O endpoint que você cola no Claude.ai é `https://<mcp-url>.run.app/mcp` (a URL sai do `05-deploy-mcp.sh`).
- Endpoints de discovery que o Auth0 expõe (para conferência):
  `https://<tenant>/.well-known/openid-configuration`
