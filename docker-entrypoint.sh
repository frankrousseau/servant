#!/bin/sh
set -e

mkdir -p /data/uploads

# Migrate uploads created before UPLOADS_DIR was configured
if [ -d /app/lib/servant-0.1.0/priv/uploads ] && [ -z "$(ls -A /data/uploads 2>/dev/null)" ]; then
  cp -a /app/lib/servant-0.1.0/priv/uploads/. /data/uploads/ 2>/dev/null || true
fi

# Apply any pending database migrations
/app/bin/servant eval "Servant.Release.migrate"

# Hand off to the release (CMD), e.g. `bin/servant start`
exec /app/"$@"
