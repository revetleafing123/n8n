# n8n for Hostless (free tier)
# Hostless builds apps from a Git repo via a Dockerfile — there is no
# "pull an image from a registry" option, so we reference the official
# prebuilt image here. The runtime result is identical.
#
# Build-arg lets us switch the default registry. Docker Hub is the default
# because docker.n8n.io rate-limits anonymous pulls (429 Too Many Requests),
# which fails CI/builder environments. Override with
#   --build-arg N8N_IMAGE=docker.n8n.io/n8nio/n8n:latest
# if you need the vendor registry specifically.
ARG N8N_IMAGE=n8nio/n8n:latest
FROM ${N8N_IMAGE}

# Hostless runs apps with a read-only root filesystem. /tmp, /root and
# /app/.cache are writable but wiped on restart. n8n appends '.n8n' to
# N8N_USER_FOLDER, so the folder must be /tmp (not /tmp/.n8n) to land on
# /tmp/.n8n at runtime.
# State that must survive redeploys lives in the external Postgres (Neon);
# the encryption key is injected as an env var, so a wiped /tmp is safe.
# NOTE: do not create the folder at build time — run as the unprivileged
# 'node' user and let n8n mkdir it at startup, or permissions break.
USER node
ENV N8N_USER_FOLDER=/tmp

# The base image sets ENTRYPOINT [tini -- /docker-entrypoint.sh], which only
# runs 'exec n8n "$@"' — it treats the CMD as n8n subcommands, not as a
# program to execute (hence: Command "/app/start.sh" not found). Clear the
# entrypoint so our script runs directly and can map PORT -> N8N_PORT.
ENTRYPOINT []
COPY --chmod=755 start.sh /app/start.sh
CMD ["/app/start.sh"]