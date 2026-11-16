#!/bin/sh
# Hostless injects PORT at runtime (commonly 8080) and expects the app to
# listen on it. n8n reads N8N_PORT, defaults to 5678. Map one to the other.
set -e
export N8N_PORT="${PORT:-${N8N_PORT:-5678}}"
export N8N_HOST="${N8N_HOST:-localhost}"
exec n8n start
