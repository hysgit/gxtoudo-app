FROM node:24-alpine
WORKDIR /app
COPY --chown=node:node server.mjs ./
COPY --chown=node:node public ./public
ENV GXTODO_WEB_HOST=0.0.0.0
ENV GXTODO_WEB_PORT=18120
EXPOSE 18120
USER node
CMD ["node", "server.mjs"]
