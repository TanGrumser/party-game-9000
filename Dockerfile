# syntax=docker/dockerfile:1

# ---- Base Image ----
FROM oven/bun:1 AS base
WORKDIR /app
USER root

# ---- Install System Dependencies & Godot ----
# This layer will be cached as long as the dependencies don't change.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    unzip \
    libfontconfig1 \
    libfreetype6 \
    libx11-6 libxext6 libxrender1 libxi6 libxrandr2 libxinerama1 libxcursor1 \
    libgl1 \
 && rm -rf /var/lib/apt/lists/*

# Install Godot
RUN curl -L -o godot.zip "https://github.com/godotengine/godot/releases/download/4.2.2-stable/Godot_v4.2.2-stable_linux.x86_64.zip" && \
    unzip godot.zip && \
    mv Godot_v4.2.2-stable_linux.x86_64 /usr/local/bin/godot && \
    chmod +x /usr/local/bin/godot && \
    rm godot.zip

# ---- Install Application Dependencies ----
FROM base AS deps
COPY package.json bun.lock* ./
RUN bun install --frozen-lockfile --production

# ---- Final Production Image ----
FROM base AS release
USER bun
WORKDIR /app

# Copy installed dependencies and application code
COPY --from=deps /app/node_modules ./node_modules
COPY . .

ENV NODE_ENV=production
ENV PORT=3000

EXPOSE 3000
CMD ["bun", "run", "start"]