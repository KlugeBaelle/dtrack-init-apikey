# dtrack-init-apikey

An idempotent bash script that creates a team in [Dependency-Track](https://dependencytrack.org) (v5 REST API), gives it an API key, and stores that key in a Kubernetes secret. It is meant to run as a Kubernetes init job or a Helm/Argo hook, and is safe to run on every deploy.

## What it does

1. Waits until `GET /api/version` answers, so it can start alongside Dependency-Track.
2. Logs in as `admin`. On a fresh instance nobody has logged in yet, so the account still has the default password `admin` and Dependency-Track demands a change. The script sets the new admin password itself (see [Admin account](#admin-account)).
3. Looks the team up by name (paginated). Creates it if missing.
4. Grants the configured permissions. Permissions the team already has are skipped.
5. Reads the target secret. If it holds a key that Dependency-Track accepts for this team, it exits without changes.
6. Otherwise it creates a new API key and applies the secret. If writing the secret fails, the new key is deleted again so no unused key is left behind.

The secret contains `DTRACK_URL` and `DTRACK_API_KEY`, the variable names read by [dtrack-to-csv](https://github.com/KlugeBaelle/dtrack-to-csv), so it can be mounted with `envFrom`.

## Requirements

- `bash`, `curl`, `jq`, `kubectl` and `base64` in the container. The `alpine/k8s` image has all of them.
- A freshly deployed Dependency-Track whose `admin` account still has the default password. No API key is needed up front.
- A service account that may `get`, `create` and `patch` secrets in the target namespace.

## Configuration

All settings are environment variables.

| Variable | Default | Description |
|---|---|---|
| `DTRACK_URL` | required | Base URL of Dependency-Track, for example `http://dependency-track-api:8080`. |
| `DTRACK_ADMIN_PASSWORD` | generated | Password the admin account should get. When unset, a random one is generated and kept in `ADMIN_SECRET_NAME`. Must not be `admin`. |
| `ADMIN_SECRET_NAME` | `dtrack-admin-credentials` | Secret holding the generated admin `username` and `password`. |
| `DTRACK_ADMIN_USERNAME` | `admin` | Admin account name. |
| `DTRACK_ADMIN_API_KEY` | unset | Skips the admin login and uses this key instead. For instances that are already set up. |
| `TEAM_NAME` | `cve-reporting` | Team to create. |
| `TEAM_PERMISSIONS` | `VIEW_PORTFOLIO,VIEW_VULNERABILITY` | Comma-separated permissions for the team. |
| `SECRET_NAME` | `dtrack-<team>-api-key` | Secret that receives the key. Lowercased, invalid characters become `-`. |
| `NAMESPACE` | the pod's namespace | Namespace of that secret. |
| `WAIT_TIMEOUT_SECONDS` | `300` | How long to wait for the API to become ready. |

## Admin account

On first contact the default `admin`/`admin` login answers `401 FORCE_PASSWORD_CHANGE`. The script then changes the password through `/api/v1/user/forceChangePassword` and logs in with the JWT it gets back.

- With `DTRACK_ADMIN_PASSWORD` set, that password is used.
- Without it, the script generates a 32 character password and stores it in the secret `ADMIN_SECRET_NAME` before touching Dependency-Track. A crash in between can therefore never leave an admin account nobody knows the password of. Later runs read the password from that secret.
- If neither the configured nor the default password works, someone changed it. The script stops with an error instead of guessing.
- If `admin`/`admin` is accepted without a forced change, the script refuses to continue, because that state is unexpected.

The admin password secret is the way back into the Dependency-Track UI: `kubectl get secret dtrack-admin-credentials -o jsonpath='{.data.password}' | base64 -d`.

## Running it in Kubernetes

The script is not baked into an image. Put it in a ConfigMap and run it with a stock image:

```sh
kubectl create configmap dtrack-init-apikey --from-file=provision-team.sh
```

Example manifests:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dtrack-init-apikey
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dtrack-init-apikey
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dtrack-init-apikey
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: dtrack-init-apikey
subjects:
  - kind: ServiceAccount
    name: dtrack-init-apikey
---
apiVersion: batch/v1
kind: Job
metadata:
  name: dtrack-init-apikey
spec:
  backoffLimit: 3
  template:
    spec:
      serviceAccountName: dtrack-init-apikey
      restartPolicy: OnFailure
      containers:
        - name: provision
          image: alpine/k8s:1.31.2
          command: ["bash", "/scripts/provision-team.sh"]
          env:
            - name: DTRACK_URL
              value: http://dependency-track-api:8080
            - name: TEAM_NAME
              value: cve-reporting
          volumeMounts:
            - name: script
              mountPath: /scripts
      volumes:
        - name: script
          configMap:
            name: dtrack-init-apikey
```

Pin the image to a version you have checked. Consuming the key:

```yaml
envFrom:
  - secretRef:
      name: dtrack-cve-reporting-api-key
```

## Idempotency

| Situation | Result |
|---|---|
| First run on a fresh instance | Sets the admin password, creates team, grants permissions, creates key, writes both secrets. |
| Rerun, secret holds a working key | No changes. |
| Admin password was changed outside the script | Fails with an error. Fix the stored password or `DTRACK_ADMIN_PASSWORD`. |
| Rerun, key in the secret was revoked or belongs to another team | Creates a new key and overwrites the secret. |
| Team exists, secret missing | Reuses the team, creates a key, writes the secret. |
| Permissions list changed | Missing permissions are granted. Existing ones are never removed. |

The existing key is checked with `GET /api/v1/team/self`. If that endpoint answers 404 on your version, the script logs a warning and trusts the stored key, so a revoked key is not detected. If a run dies after creating a key but before the secret is written, and the cleanup call also fails, that key stays in Dependency-Track unused. The next run creates a fresh one.

## Security notes

- Passwords, tokens and API keys are never logged and never appear in a process listing. curl reads credentials from stdin and secrets reach `kubectl` through a piped manifest.
- Anyone who can read the admin secret has full control of Dependency-Track, and anyone who can read the key secret has the team's key. Restrict access with RBAC.
- The Role in the example can read every secret in the namespace. Narrow it with `resourceNames` once the secret names are fixed (`create` cannot be limited by name).

## Local use

```sh
export DTRACK_URL=https://dependency-track.example.com
export NAMESPACE=my-namespace
./provision-team.sh
```

`kubectl` uses your current context, so check it first.
