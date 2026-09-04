# Small on purpose: this service exists to be running when everything else is
# not, so it must cost almost nothing. Alpine + python3 stdlib + the docker CLI.
FROM alpine:3.21

RUN apk add --no-cache python3 docker-cli docker-cli-compose

COPY app.py /app/app.py
COPY static /app/static

# Must match the host path of the project, because bind mounts declared in
# docker-compose.yml are resolved by the daemon on the host filesystem.
WORKDIR /srv/monitoring

EXPOSE 8080
CMD ["python3", "-u", "/app/app.py"]
