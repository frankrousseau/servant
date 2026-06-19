#!/bin/sh
set -e

# Apply any pending database migrations
/app/bin/servant eval "Servant.Release.migrate"

# Hand off to the release (CMD), e.g. `bin/servant start`
exec /app/"$@"
