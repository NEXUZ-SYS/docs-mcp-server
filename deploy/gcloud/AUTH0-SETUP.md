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

## 5. (Opcional) Conexão de login

Em **Authentication → Database**, confirme que existe `Username-Password-Authentication` habilitada. Se quiser login com Google/GitHub, habilite em **Authentication → Social**. Qualquer conexão habilitada e marcada como padrão funciona.

---

## Resultado — me envie estes dois valores

```
AUTH0_ISSUER_URL=https://<seu-tenant>.<região>.auth0.com/
AUTH0_AUDIENCE=https://docs-mcp-server
```

Com eles eu rodo o deploy do `mcp` (`05-deploy-mcp.sh`) e validamos o fluxo OAuth completo conectando no Claude.ai.

---

## Notas de validação / fallback

- O servidor valida o token assim: tenta **JWT via JWKS** (checando `iss` e `aud`); se falhar, faz **fallback para o endpoint `userinfo`** do Auth0. Ou seja, mesmo que haja um descasamento de audience, um token Auth0 válido ainda autentica — o setup é tolerante.
- Se o Claude.ai falhar no registro (`/oauth/register`), revise o passo 3 (DCR ON + Default Directory).
- O endpoint que você cola no Claude.ai é `https://<mcp-url>.run.app/mcp` (a URL sai do `05-deploy-mcp.sh`).
- Endpoints de discovery que o Auth0 expõe (para conferência):
  `https://<tenant>/.well-known/openid-configuration`
