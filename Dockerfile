# syntax=docker/dockerfile:1
FROM oven/bun:1 AS base
WORKDIR /app

# ---- install deps (works on Debian/Ubuntu or Alpine variants) ----
USER root
RUN set -eux; \
  if command -v apt-get >/dev/null 2>&1; then \
    apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip \
      libfontconfig1 libfreetype6 \
      libx11-6 libxext6 libxrender1 libxi6 libxrandr2 libxinerama1 libxcursor1 \
      libgl1 \
    && rm -rf /var/lib/apt/lists/*; \
  elif command -v apk >/dev/null 2>&1; then \
    apk add --no-cache \
      ca-certificates curl unzip \
      fontconfig freetype \
      libx11 libxext libxrender libxi libxrandr libxinerama libxcursor \
      mesa-gl; \
  else \
    echo "No supported package manager found (apt-get/apk)"; exit 1; \
  fi
  
# ---- install godot 4.6 (headless-capable binary) ----
RUN set -eux; \
  mkdir -p /opt/godot && cd /opt/godot; \
  curl -L -o godot.zip "https://godot-releases.nbg1.your-objectstorage.com/4.6-stable/Godot_v4.6-stable_linux.x86_64.zip"; \
  unzip -o godot.zip; \
  rm godot.zip; \
  chmod +x /opt/godot/Godot_v4.6-stable_linux.x86_64; \
  ln -sf /opt/godot/Godot_v4.6-stable_linux.x86_64 /usr/local/bin/godot

# Install dependencies
FROM base AS install
COPY package.json bun.lock* ./
RUN bun install --frozen-lockfile --production

# Final image
FROM base AS release
COPY --from=install /app/node_modules ./node_modules
COPY . .
RUN test -f /app/godot/project.godot

ENV NODE_ENV=production
ENV PORT=3000

ENV PATH="/usr/local/bin:/usr/bin:/bin"

EXPOSE 3000

USER bun
CMD ["bun", "run", "start"]