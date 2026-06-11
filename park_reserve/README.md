# park_reserve

LG CNS 임직원 단기주차 신청 자동화 스크립트입니다.

The container runs this job from Linux and uses SSH to execute headless Edge
automation on the Tailscale-reachable Mac host.

## Build

```bash
docker build -t park-reserve:latest .
```

## Local Container Run

The container needs:

- `CNS_PW`
- `DISCORD_TOKEN`
- an SSH key/config that can run `ssh cozy@mac`

Example:

```bash
docker run --rm \
  -e CNS_PW \
  -e DISCORD_TOKEN \
  -e PARK_DISCORD_CHANNEL=1470310665217507348 \
  -e PARK_RESERVE_SSH_TARGET=cozy@mac \
  -v "$HOME/.ssh:/home/appuser/.ssh:ro" \
  park-reserve:latest
```

Dry-run:

```bash
docker run --rm \
  -e CNS_PW \
  -e DISCORD_TOKEN \
  -v "$HOME/.ssh:/home/appuser/.ssh:ro" \
  park-reserve:latest --dry-run
```

## Kubernetes

Create real Secrets from `k8s/secret.example.yaml`, then apply:

```bash
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/cronjob.yaml
```

Manual one-shot run from the CronJob:

```bash
kubectl create job --from=cronjob/park-reserve park-reserve-manual-$(date +%Y%m%d%H%M%S)
```

The schedule in `k8s/cronjob.yaml` is a placeholder and should be changed to
the actual application window.
