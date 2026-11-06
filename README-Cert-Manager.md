## Configure SSL with Let’s Encrypt in Kubernetes Using Cert-Manager DNS-01
Step 1: Install cert-manager
Use Helm to install cert-manager, which handles Let’s Encrypt certificate issuance:
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait
```
**Verify all three pods are Ready**
kubectl -n cert-manager wait --for=condition=Ready pod --all --timeout=180s
kubectl -n cert-manager get pods

**Prepare YAML files for LetsEncrypt SSL certificates with Cloudflare API TOKEN:**
```text
├── templates/                                 
│   ├── certificate.yaml
│   ├── cert-manager-secret.yaml
│   ├── clusterissuer.yaml

```
### `templates/certificate.yaml` — Automated TLS Certificate

The `Certificate` resource is the declarative request that tells
`cert-manager` **what certificate to obtain and where to store it**.
Once applied, the `cert-manager` controller owns the entire lifecycle:

| Stage | What happens |
|---|---|
| **Create** | `cert-manager` creates a `CertificateRequest`, `Order`, and `Challenge` |
| **Validate** | A temporary `_acme-challenge` TXT record is written via the Cloudflare DNS-01 solver |
| **Store** | Let's Encrypt signs the cert; `tls.crt` + `tls.key` are written to `gateway-tls-secret` |
| **Renew** | `cert-manager` renews automatically ~30 days before expiry — no CronJob, no manual step |

The gateway Deployment mounts `gateway-tls-secret` as a volume, so the
Nginx instance always serves the current certificate. Renewal rotation
is picked up either by a manual `kubectl rollout restart` or automatically
via [Stakater Reloader](https://github.com/stakater/Reloader).

**Guarded by domain check:** the template renders only when
`certManager.certificate.domain` is non-empty — so the chart deploys
cleanly even before a domain is configured (the gateway falls back to a
self-signed cert in that case).

### `templates/clusterissuer.yaml` — Let's Encrypt ACME Issuer

A `ClusterIssuer` is the **cluster-wide signing authority** that
`cert-manager` uses to obtain certificates. This one is configured for
**Let's Encrypt production** with a **Cloudflare DNS-01** solver.

Once applied, `cert-manager` registers an ACME account with Let's Encrypt
and stores the account private key in the secret named by
`privateKeySecretName`. Every `Certificate` in any namespace can then
reference it with:

```yaml
issuerRef:
  name: letsencrypt-cloudflare
  kind: ClusterIssuer
```
```text
Why DNS-01 (not HTTP-01)? The gateway is a custom Nginx Deployment
behind a LoadBalancer — no Ingress controller exists in front of it, so
HTTP-01 challenges have nowhere to land. DNS-01 sidesteps the routing
problem entirely: cert-manager writes a _acme-challenge TXT record via
the Cloudflare API, Let's Encrypt verifies it, and no traffic ever needs
to reach the gateway during validation.

Cluster-scoped: despite being part of the nidan Helm release, the
ClusterIssuer has no namespace. It's usable by Certificate resources
in nidan, cert-manager, or any other namespace.

Guarded rendering: the template renders only when
certManager.enabled and certManager.clusterIssuer.enabled are both
true — so the chart stays installable with cert-manager turned off
(e.g., during bootstrapping without a domain).
```
### `templates/cert-manager-secret.yaml` — Cloudflare API Token Secret

Holds the **Cloudflare API token** that the `ClusterIssuer`'s DNS-01
solver uses to create and delete `_acme-challenge` TXT records. Without
this Secret, the `Challenge` resource gets stuck and the `Certificate`
never reaches `READY=True`.

**Namespace:** `cert-manager` (not `nidan`) — the solver's
`apiTokenSecretRef` is resolved **in the `cert-manager` namespace**, where
the `cert-manager` controller pods live.

**Secret type:** `Opaque` — a plain key/value Secret with a single
`api-token` key containing the token value.

**Guarded rendering:** created only when
`certManager.enabled: true` **and**
`certManager.clusterIssuer.cloudflare.createSecret: true`. Set
`createSecret: false` to manage the Secret out-of-band (e.g., via
[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets),
[External Secrets Operator](https://external-secrets.io/), or a manual
`kubectl create secret generic ...`).

**Fail-fast validation:** the template uses Helm's `required` function:

```yaml
{{ required "certManager.clusterIssuer.cloudflare.apiToken is required when createSecret=true" .Values.certManager.clusterIssuer.cloudflare.apiToken | quote }}
```

**Update domian and details in nidan-chart/values.yaml of certManager section:
```yaml
certManager:
  enabled: true       ## Set false if no domain during initial running of application

  clusterIssuer:
    enabled: true
    name: letsencrypt-cloudflare
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "EMAIL_ADDRESS"    
    privateKeySecretName: letsencrypt-cloudflare-account-key
    cloudflare:
      # Secret must exist in the cert-manager namespace (created manually in Step 2)
      secretName: cloudflare-api-token
      secretKey: api-token
      createSecret: true
      apiToken: "API_TOKEN_OF_CLOUDFLARE"    ##API Token Generated from Cloudflare, AWS.
  certificate:
    enabled: true
    name: gateway-cert
    secretName: gateway-tls-secret
    domain: ""           ##Domain name to install letsencrypt cert
    additionalDnsNames: []      
```
** Update/Install app through Helm command:**
```bash
helm upgrade --install nidan . -n nidan -f values.yaml
```
**Verify all  pods are Ready**
```bash
kubectl -n cert-manager wait --for=condition=Ready pod --all --timeout=180s
kubectl -n cert-manager get pods
kubectl get secret -n cert-manager cloudflare-api-token

#Verify after deploy
# Secret created in cert-manager ns
kubectl get secret -n cert-manager cloudflare-api-token -o name

# ClusterIssuer Ready
kubectl get clusterissuer letsencrypt-cloudflare

# Certificate issued
kubectl get certificate -n nidan -w
# Wait for READY=True (1–3 min)

# Gateway pod
kubectl get pods -n nidan

# Real cert served
kubectl exec -n nidan deploy/gateway -- \
  openssl x509 -in /etc/letsencrypt/live/localhost/fullchain.pem -noout -subject
        ##subject=CN = utsavdeshar.com.np

```
## Configure SSL with Let’s Encrypt in Kubernetes Using http-01
1. Git clone the branch cert/httpd-01
   git clone https://github.com/NidanHIS/nidan-kubernet.git

2. Update email and domin to values.yaml.
   acme:
     email: "EMAIL-ADDRESS"
   certManager:
     certManager:
       domain: "YOUR-DOMAIN"
3. Install NidanEHR with SSL
   helm upgrade --install nidan . -n nidan -f values.yaml
4. Verify the served cert:
   kubectl -n nidan logs -l app=gateway -c acme -f
   kubectl -n nidan exec deploy/gateway -c gateway -- \
   openssl x509 -in /etc/letsencrypt/live/localhost/fullchain.pem -noout -issuer -subject -dates
      # Expect: issuer=Let's Encrypt, subject=CN=k3s.nidanehr.com
   curl -sv https://k3s.nidanehr.com 2>&1 | grep -E 'issuer|subject|expire'

   

   





