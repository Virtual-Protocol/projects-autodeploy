# The page an app shows from hosting until its first deploy. host-app.yml
# builds it; scripts/provision.sh deploys it with the app's details.
FROM node:24-slim
WORKDIR /app
COPY server.mjs ./
USER node
CMD ["node", "server.mjs"]
