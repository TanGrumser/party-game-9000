# syntax=docker/dockerfile:1

# Use the official Bun image as our one and only base
FROM oven/bun:1

# Switch to the root user to install packages
USER root

# All installation steps happen in a single RUN command to optimize layer caching.
# This ensures all dependencies and the Godot binary exist together in the same layer.
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Essential utilities
    ca-certificates \
    curl \
    unzip \
    # Godot headless dependencies
    libfontconfig1 \
    libfreetype6 \
    libx11-6 libxext6 libxrender1 libxi6 libxrandr2 libxinerama1 libxcursor1 \
    libgl1 \
 && rm -rf /var/lib/apt/lists/* \
 && curl -L -o godot.zip "https://github.com/godotengine/godot/releases/download/4.2.2-stable/Godot_v4.2.2-stable_linux.x86_64.zip" \
 && unzip godot.zip \
 && mv Godot_v4.2.2-stable_linux.x86_64 /usr/local/bin/godot \
 && chmod +x /usr/local/bin/godot \
 && rm godot.zip

# Set the working directory for the application
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

# Install production dependencies. Bun will cache this layer.
RUN bun install --frozen-lockfile --production

# Copy the rest of your application source code
COPY . .


RUN chown -R bun:bun /app
RUN su -s /bin/sh bun -c '/usr/local/bin/godot --headless --path /app/godot --editor --quit'

RUN test -f /app/godot/project.godot
RUN test -d /app/godot/.godot/imported
ENV NODE_ENV=production
ENV PORT=3000

# Expose the port your app runs on
EXPOSE 3000

# Define the command to run your application
CMD ["bun", "run", "start"]