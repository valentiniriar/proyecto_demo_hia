FROM node:22-alpine AS build

WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build -- --configuration production

FROM nginxinc/nginx-unprivileged:alpine

# nginx.conf se copia como plantilla: al arrancar, la imagen reemplaza ${BACKEND_UPSTREAM}
# y genera /etc/nginx/conf.d/default.conf (SCRUM-60). Solo se sustituyen variables definidas,
# así que $host, $remote_addr, etc. quedan intactas.
ENV BACKEND_UPSTREAM=http://host.docker.internal:3000
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist/proy-frontend/browser/ /usr/share/nginx/html/

EXPOSE 8080
