#!/bin/sh
set -e

mkdir -p /data/files /data/tmp

# Migrate legacy flat uploads tree into files/ if present
legacy="/data/uploads"
if [ -d "$legacy" ] && [ -n "$(ls -A "$legacy" 2>/dev/null)" ]; then
  cp -a "$legacy/." /data/files/ 2>/dev/null || true
fi

# Apply any pending database migrations
/app/bin/servant eval "Servant.Release.migrate"

# Hand off to the release (CMD), e.g. `bin/servant start`
exec /app/"$@"
