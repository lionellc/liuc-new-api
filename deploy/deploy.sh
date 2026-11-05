#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
umask 077

image="${1:?Usage: deploy.sh ghcr.io/OWNER/IMAGE@sha256:DIGEST}"
if [[ ! "$image" =~ ^ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$ ]]; then
  echo "An immutable GHCR image digest is required" >&2
  exit 1
fi

for dependency in docker flock; do
  command -v "$dependency" > /dev/null || {
    printf 'Missing dependency: %s\n' "$dependency" >&2
    exit 1
  }
done

compose_version="$(docker compose version --short)"
if [[ ! "$compose_version" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
  echo "Cannot determine Docker Compose version" >&2
  exit 1
fi
if (( BASH_REMATCH[1] < 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] < 30) )); then
  echo "Docker Compose 2.30.0 or later is required" >&2
  exit 1
fi

for configuration in node.env app.env; do
  if [[ ! -f "$configuration" ]]; then
    echo "Missing $configuration; run init-site.sh first" >&2
    exit 1
  fi
  if grep -q 'REPLACE_' "$configuration"; then
    echo "Unconfigured placeholders in $configuration" >&2
    exit 1
  fi
done

exec 9>.deploy.lock
flock -n 9 || {
  echo "Another deployment is running" >&2
  exit 1
}

candidate="$(mktemp .release.XXXXXX)"
trap 'rm -f "$candidate"' EXIT
printf 'NEW_API_IMAGE=%s\n' "$image" > "$candidate"

dc() {
  docker compose \
    --env-file node.env \
    --env-file "$candidate" \
    -f compose.yaml \
    "$@"
}

dc config --quiet
docker pull "$image"

# A failed attempt may still change containers or migrate the database.
# Keep its image reference even if the successful release pointer is unchanged.
cp "$candidate" release.env.attempt

if [[ ! -f release.env ]]; then
  dc up -d --wait --wait-timeout 180 postgres redis
else
  backup_dir="backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$backup_dir"
  echo "Backing up the site's database before deployment"

  dc exec -T postgres pg_dump -U newapi -d newapi -Fc \
    > "$backup_dir/database.dump.tmp"

  dc exec -T postgres pg_restore --list \
    < "$backup_dir/database.dump.tmp" > /dev/null

  mv "$backup_dir/database.dump.tmp" "$backup_dir/database.dump"
  cp node.env app.env release.env compose.yaml "$backup_dir/"
fi

if ! dc up -d --no-deps --wait --wait-timeout 300 new-api; then
  dc logs --tail 100 new-api || true
  cp "$candidate" release.env.failed
  echo "Deployment failed; inspect logs and database compatibility before rollback" >&2
  exit 1
fi

if [[ -f release.env ]] && ! cmp -s release.env "$candidate"; then
  cp release.env release.env.previous
fi
mv "$candidate" release.env

printf '%s %s\n' "$(date -u +%FT%TZ)" "$image" >> deployment-history.log
printf 'Deployment succeeded: %s\n' "$image"
