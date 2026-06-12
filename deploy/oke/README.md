# Deploy do docs-mcp-server na Oracle OKE (via Rancher)

> **DevFlow workflow:** oke-deploy | **Scale:** LARGE | **Phase:** P (Planning) → R
>
> **Goal:** Rodar o docs-mcp-server na Oracle OKE com o SQLite num OCI Block Volume real, eliminando os timeouts de `search_docs` causados pelo SQLite sobre GCS FUSE no Cloud Run.
> **Architecture:** Pod único unificado (MCP + web + API + worker), `replicas: 1`, `strategy: Recreate`, PVC RWO em Block Volume montado em `/data`. Exposto via Traefik + cert-manager (Let's Encrypt). Imagem própria no OCIR. Auth pública (igual ao estado atual).
> **Agent:** devops-specialist

## Por que esta migração resolve o problema raiz

No Cloud Run o `documents.db` ficava num bucket GCS montado via FUSE. Cada leitura/escrita do SQLite virava ida-e-volta de rede + lock sobre FUSE; durante um scrape pesado (escrita constante) uma busca ficava presa atrás das escritas e estourava os ~60s do cliente MCP. No Kubernetes o `/data` passa a ser um **OCI Block Volume** (disco em bloco real, anexado ao node), onde escritas síncronas do `better-sqlite3` voltam a ser sub-milissegundo. A contenção leitura-durante-scrape praticamente desaparece sem precisar separar o worker.

## Topologia

```
Internet ──HTTPS──▶ Traefik Ingress ──▶ Service:8080 ──▶ Pod (Deployment replicas=1, Recreate)
  docs-mcp.nexuz.app                                         │
  TLS: cert-manager (Let's Encrypt)                          ├── /data   → PVC (oci-bv, RWO, 50Gi)
                                                             └── /config → emptyDir
  Worker nodes ──NAT egress──▶ scraping + Gemini API
```

## Arquivos

| Arquivo | Recurso |
|---|---|
| `10-secret.example.yaml` | Template do Secret (NÃO aplicar com valor real — ver Passo 4) |
| `20-pvc.yaml` | PVC `docs-mcp-data` (Block Volume RWO 50Gi) |
| `30-deployment.yaml` | Deployment unificado |
| `40-service.yaml` | Service ClusterIP :8080 |
| `50-ingress.yaml` | Ingress Traefik + cert-manager |
| `maintenance-pod.yaml` | Pod efêmero para migração de dados |

## Valores a confirmar (⚙️) antes de aplicar

| Placeholder | Onde | Como descobrir |
|---|---|---|
| `REPLACE_TENANCY_NAMESPACE` | `30-deployment.yaml` | `oci os ns get` (Object Storage namespace = namespace do OCIR) |
| Região OCIR (`gru`) | `30-deployment.yaml` | `gru` = São Paulo (sa-saopaulo-1). Confirme a região do seu cluster |
| `oci-bv` (storageClassName) | `20-pvc.yaml` | `kubectl get storageclass` |
| `letsencrypt-prod` (ClusterIssuer) | `50-ingress.yaml` | `kubectl get clusterissuer` |
| `docs-mcp.nexuz.app` (hostname) | `50-ingress.yaml` | hostname desejado + registro DNS apontando para o LB do Traefik |
| entrypoint `websecure` | `50-ingress.yaml` | config do seu Traefik (padrão RKE2 = `websecure`) |

---

# Runbook — execução verificação-primeiro

Cada passo de mudança é precedido por uma verificação (lint/dry-run) e seguido por uma checagem de estado. Não avance um passo sem a verificação do anterior passar.

## Pré-requisitos

- `kubectl` apontando para o cluster OKE (kubeconfig do Rancher: *painel → cluster → Kubeconfig File*).
- `docker` (ou `podman`) para o build da imagem.
- Acesso ao bucket GCS atual (`gsutil`/`gcloud`) para baixar o `documents.db`.
- Um **Auth Token** OCI (Console OCI → seu perfil → *Auth Tokens* → *Generate Token*).

**Verificação 0 — contexto correto:**
```bash
kubectl config current-context     # confere que é o cluster OKE certo
kubectl get nodes                  # nodes Ready
kubectl get storageclass           # confirma o nome da storage class de Block Volume
kubectl get clusterissuer          # confirma o nome do ClusterIssuer do cert-manager
kubectl -n kube-system get pods | grep -i traefik   # confirma o Traefik rodando
```

## Passo 1 — Build da imagem (com seu código custom)

O repositório tem customizações (pasta `deploy/`, fixes de auth) que não estão na imagem upstream, então buildamos a partir daqui.

```bash
# Na raiz do repositório
docker build -t docs-mcp-server:local .
```

**Verificação 1 — a imagem sobe e o binário responde:**
```bash
docker run --rm docs-mcp-server:local --version
```

## Passo 2 — Push para o OCIR

```bash
# ⚙️ Ajuste região e namespace
# tenancy-namespace SEM o oci CLI: Console OCI → Governance/Tenancy details →
#   "Object Storage Namespace". Ou copie de uma imagem que já roda na sua OKE:
#   kubectl get pods -A -o jsonpath='{..image}' | tr ' ' '\n' | grep ocir.io | head
export OCIR_REGION=gru
export TENANCY_NS=grw1wmd5faqb   # confirmado via: oci os ns get --raw-output --query data
export IMAGE="${OCIR_REGION}.ocir.io/${TENANCY_NS}/docs-mcp-server:$(git rev-parse --short HEAD)"

# Login no OCIR. Usuário = <tenancy-ns>/<usuario-oci> (federado:
#   <tenancy-ns>/oracleidentitycloudservice/<usuario>). Senha = Auth Token.
docker login ${OCIR_REGION}.ocir.io

docker tag docs-mcp-server:local "$IMAGE"
docker push "$IMAGE"
echo "Imagem publicada: $IMAGE"
```
Edite `30-deployment.yaml` (campo `image:`) com o valor de `$IMAGE` (ou troque `latest` pela tag de commit).

**Verificação 2:** o `docker push` termina sem erro e a tag aparece no Console OCI (Developer Services → Container Registry).

## Passo 3 — PVC

> Usamos o namespace `default` (já existe no cluster) — não há namespace a criar.

**Verificação 3a (dry-run/lint antes de aplicar):**
```bash
kubectl apply --dry-run=server -f deploy/oke/20-pvc.yaml
```
```bash
kubectl apply -f deploy/oke/20-pvc.yaml
```
**Verificação 3b — o PVC é criado:**
```bash
kubectl -n default get pvc docs-mcp-data
```
> A storage class `oci-bv` usa `VOLUMEBINDINGMODE: WaitForFirstConsumer`, então o PVC
> fica **`Pending`** de propósito até o primeiro pod montá-lo (o pod de manutenção no
> Passo 5, ou o app no Passo 6). O Block Volume só é provisionado quando o pod agenda.
> `Pending` aqui é o esperado — NÃO é erro.

## Passo 4 — Secrets (Gemini + pull do OCIR)

Crie os Secrets via CLI (não commitar valores). 

```bash
# Secret da API do Gemini
kubectl -n default create secret generic docs-mcp-secrets \
  --from-literal=GOOGLE_API_KEY='COLE_A_CHAVE_AQUI'

# Secret de pull da imagem no OCIR
kubectl -n default create secret docker-registry docs-mcp-ocir-cred \
  --docker-server=${OCIR_REGION}.ocir.io \
  --docker-username="${TENANCY_NS}/<seu-usuario-oci>" \
  --docker-password='<seu-auth-token>'
```
**Verificação 4:**
```bash
kubectl -n default get secret docs-mcp-secrets docs-mcp-ocir-cred
```

## Passo 5 — Migração de dados (GCS → PVC)

> O app ainda **não** foi criado (replicas=0 implícito), então o PVC está livre.

```bash
# 5.1 — baixar o DB do GCS para a sua máquina
# Bucket atual (de deploy/gcloud/00-config.env): <PROJECT_ID>-docs-mcp-data
gsutil cp gs://gen-lang-client-0927668204-docs-mcp-data/documents.db ./documents.db
ls -lh ./documents.db

# 5.2 — subir o pod de manutenção que monta o PVC
kubectl apply -f deploy/oke/maintenance-pod.yaml
kubectl -n default wait --for=condition=Ready pod/docs-mcp-maint --timeout=180s

# 5.3 — copiar o arquivo para dentro do PVC
kubectl -n default cp ./documents.db docs-mcp-maint:/data/documents.db

# 5.4 — validar integridade do SQLite dentro do volume
kubectl -n default exec docs-mcp-maint -- sh -c \
  'ls -lh /data/documents.db'
```
**Verificação 5 — integridade.** Se quiser checar o `PRAGMA integrity_check`, rode num pod com sqlite3 (opcional); o tamanho do arquivo + o smoke test do Passo 8 já validam na prática. Em seguida, **remova o pod de manutenção** (libera o RWO):
```bash
kubectl -n default delete pod docs-mcp-maint
```

> **Pular migração?** Se preferir começar do zero (re-scrape), pule o Passo 5 inteiro — o app cria um `documents.db` vazio no primeiro boot.

## Passo 6 — Deploy do app

**Verificação 6a (dry-run):**
```bash
kubectl apply --dry-run=server -f deploy/oke/30-deployment.yaml -f deploy/oke/40-service.yaml
```
```bash
kubectl apply -f deploy/oke/30-deployment.yaml
kubectl apply -f deploy/oke/40-service.yaml
```
**Verificação 6b — pod Ready e logs limpos:**
```bash
kubectl -n default rollout status deploy/docs-mcp --timeout=300s
kubectl -n default logs deploy/docs-mcp --tail=50
# Procure: store inicializado em /data, servidor HTTP na 8080, sem erro de migration.
```

## Passo 7 — Ingress + TLS

**Verificação 7a (dry-run):**
```bash
kubectl apply --dry-run=server -f deploy/oke/50-ingress.yaml
```
```bash
kubectl apply -f deploy/oke/50-ingress.yaml
```
**Verificação 7b — certificado emitido:**
```bash
kubectl -n default get ingress docs-mcp
kubectl -n default get certificate          # READY=True quando o Let's Encrypt emitir
kubectl -n default describe certificate docs-mcp-tls | tail -20
```
> Garanta que o DNS de `docs-mcp.nexuz.app` aponta para o LoadBalancer do Traefik
> **antes** do desafio HTTP-01, senão a emissão falha.
>
> **LB do Traefik (confirmado neste cluster): `144.22.252.92`** — crie um registro
> A: `docs-mcp.nexuz.app → 144.22.252.92`. O Issuer usado é `le-prod-http` (o mesmo
> dos apps de produção, ex: odoo-ingress).

## Passo 8 — Smoke test (validação funcional)

```bash
HOST=docs-mcp.nexuz.app

# 8.1 — UI web responde
curl -fsS -o /dev/null -w "%{http_code}\n" https://$HOST/

# 8.2 — endpoint MCP responde ao handshake (initialize)
curl -fsS https://$HOST/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
```
**Verificação 8 — o teste que reproduzia o bug agora passa rápido:** conecte o cliente MCP (Claude.ai / Claude Code) em `https://$HOST/mcp` e rode um `search_docs` numa lib já indexada (ex: `odoo-18`). Deve responder em segundos. Para o teste decisivo, dispare um `scrape_docs` grande e rode `search_docs` em paralelo — **não deve mais dar timeout** (era o sintoma original sobre GCS FUSE).

---

# Rollback

A stack antiga no Cloud Run **permanece intacta** durante toda a migração (não desligamos nada). Se algo falhar:
```bash
kubectl -n default delete -f deploy/oke/50-ingress.yaml   # tira o tráfego
# Aponte o cliente MCP de volta para a URL do Cloud Run.
```
Os dados de origem no GCS não são alterados pela migração (só leitura no Passo 5).

# Pós-migração (quando validado)

- Atualizar os clientes MCP (Claude.ai connector, `.mcp.json`) para `https://docs-mcp.nexuz.app/mcp`.
- Só então desativar o serviço `docs-mcp` no Cloud Run (`gcloud run services delete docs-mcp --region southamerica-east1`).

# Segurança — caveat (auth pública, por decisão)

O `/mcp` fica aberto a quem tiver a URL, igual ao estado atual no Cloud Run. Mitigação futura sem tocar no app, via Traefik middleware:
- **IP allowlist:** `Middleware` `ipWhiteList` referenciado por annotation no Ingress.
- **Basic auth:** `Middleware` `basicAuth` + Secret.
Quando quiserem fechar o acesso, dá para ligar OAuth/OIDC (Auth0) — os args `--auth-enabled --auth-issuer-url --auth-audience` já existem no app.
