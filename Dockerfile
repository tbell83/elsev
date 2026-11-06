FROM nginx:mainline-alpine-slim

COPY ./webapp/ /usr/share/nginx/html/
