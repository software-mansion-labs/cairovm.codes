# Container image for Cloud Run (walnut-infra/cairovm.tf).
#
# The contract that file expects: the server listens on 8080, on every
# interface, and the image starts it with no arguments.
#
# Node version: keep this in sync with .nvmrc
ARG NODE_VERSION=24.19.0

FROM node:${NODE_VERSION}-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
# `npm ci` and not `npm install`: the lockfile is the point of a reproducible
# image. This installs devDependencies too, which the build needs - typescript,
# tailwind, the webpack loaders in next.config.js.
RUN npm ci

FROM node:${NODE_VERSION}-slim AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# NEXT_PUBLIC_* values are compiled into the browser bundle, so they are build
# arguments and not runtime environment variables. Setting this on the Cloud Run
# service does nothing at all; changing it means rebuilding the image.
#
# The default matches util/constants.ts, which falls back to the same URL with
# `||`. That fallback treats an empty string as unset, so passing an empty build
# arg through is harmless here - unlike a `??` call site, where it would compile
# an empty API URL into the bundle.
#
# This is a websocket endpoint on a host this deployment does not own. Serving
# the site over https at code.starkloupe.co means the browser will refuse a
# plain `ws://` here as mixed content - it has to stay `wss://`.
ARG NEXT_PUBLIC_CAIRO_VM_API_URL=wss://codeapi.starkloupe.co/ws
ENV NEXT_PUBLIC_CAIRO_VM_API_URL=${NEXT_PUBLIC_CAIRO_VM_API_URL}

ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

FROM node:${NODE_VERSION}-slim AS runner
WORKDIR /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=8080 \
    # Next's standalone server binds to localhost unless told otherwise, which
    # would make it unreachable from outside the container.
    HOSTNAME=0.0.0.0

RUN groupadd --system --gid 1001 nodejs \
  && useradd --system --uid 1001 --gid nodejs nextjs

# Three copies, and all three are load-bearing. output: 'standalone' emits only
# the traced server - it copies neither of the other two directories, and
# missing either fails at runtime rather than at build time:
#
#   .next/static   the client chunks and CSS. Without it the page renders
#                  unstyled and the editor never loads.
#   public/        favicon.ico, og.png and the logos, served from the site root.
#                  The sibling starknet-debugger-app has no public/ and so no
#                  such line; this repository does.
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nodejs /app/public ./public

USER nextjs
EXPOSE 8080

# server.js is what standalone emits, and it reads PORT and HOSTNAME from the
# environment above.
CMD ["node", "server.js"]
