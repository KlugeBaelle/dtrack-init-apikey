# dtrack-init-apikey

An idempotent bash script that creates a team in [Dependency-Track](https://dependencytrack.org) (v5 REST API), gives it an API key, and stores that key in a Kubernetes secret. It is meant to run as a Kubernetes init job or a Helm/Argo hook, and is safe to run on every deploy.

## What it does

1. Waits until `GET /api/version` answers, so it can start alongside Dependency-Track.
2. Looks the team up by name (paginated). Creates it if missing.
3. Grants the configured permissions. Permissions the team already has are skipped.
4. Reads the target secret. If it holds a key that Dependency-Track accepts for this team, it exits without changes.
5. Otherwise it creates a new API key and applies the secret. If writing the secret fails, the new key is deleted again so no unused key is left behind.

The secret contains `DTRACK_URL` and `DTRACK_API_KEY`, the variable names read by [dtrack-to-csv](https://github.com/KlugeBaelle/dtrack-to-csv), so it can be mounted with `envFrom`.

## Requirements

- `bash`, `curl`, `jq`, `kubectl` and `base64` in the container. The `alpine/k8s` image has all of them.
- A Dependency-Track API key with `ACCESS_MANAGEMENT` (team, permission and key management).
- A service account that may `get`, `create` and `patch` secrets in the target namespace.

## Configuration

All settings are environment variables.

| Variable | Default | Description |
|---|---|---|
| `DTRACK_URL` | required | Base URL of Dependency-Track, for example `http://dependency-track-api:8080`. |
| `DTRACK_ADMIN_API_KEY` | required | Admin API key used to manage the team. Mount it from a secret. |
| `TEAM_NAME` | `cve-reporting` | Team to create. |
| `TEAM_PERMISSIONS` | `VIEW_PORTFOLIO,VIEW_VULNERABILITY` | Comma-separated permissions for the team. |
| `SECRET_NAME` | `dtrack-<team>-api-key` | Secret that receives the key. Lowercased, invalid characters become `-`. |
| `NAMESPACE` | the pod's namespace | Namespace of that secret. |
| `WAIT_TIMEOUT_SECONDS` | `300` | How long to wait for the API to become ready. |

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
            - name: DTRACK_ADMIN_API_KEY
              valueFrom:
                secretKeyRef:
                  name: dtrack-admin-api-key
                  key: apiKey
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
| First run | Creates team, grants permissions, creates key, writes secret. |
| Rerun, secret holds a working key | No changes. |
| Rerun, key in the secret was revoked or belongs to another team | Creates a new key and overwrites the secret. |
| Team exists, secret missing | Reuses the team, creates a key, writes the secret. |
| Permissions list changed | Missing permissions are granted. Existing ones are never removed. |

The existing key is checked with `GET /api/v1/team/self`. If that endpoint answers 404 on your version, the script logs a warning and trusts the stored key, so a revoked key is not detected. If a run dies after creating a key but before the secret is written, and the cleanup call also fails, that key stays in Dependency-Track unused. The next run creates a fresh one.

## Security notes

- The admin key and the new key are never logged and never appear in a process listing. curl reads the admin key from stdin and the new key reaches `kubectl` through a piped manifest.
- Anyone who can read the target secret can read the team's API key. Restrict access with RBAC.
- The admin key has broad rights. Mount it only into this job.

## Local use

```sh
export DTRACK_URL=https://dependency-track.example.com
export DTRACK_ADMIN_API_KEY=...
export NAMESPACE=my-namespace
./provision-team.sh
```

`kubectl` uses your current context, so check it first.
