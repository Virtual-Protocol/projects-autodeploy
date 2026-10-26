# projects-autodeploy: standard Dockerfile.
# Works for Next.js, Express and Vite + Express apps as long as
# `npm ci`, `npm run build` and `npm start` work from a clean checkout.
FROM node:24-slim

# openssl: needed by Prisma. tini: passes stop signals to Node so deploys shut down cleanly.
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN chown node:node /app
USER node

# Dev dependencies stay installed: build tools need them.
COPY --chown=node:node package*.json ./
RUN npm ci

COPY --chown=node:node . .
ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build --if-present

ENV NODE_ENV=production
ENV PORT=3000
EXPOSE 3000

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["npm", "start"]
