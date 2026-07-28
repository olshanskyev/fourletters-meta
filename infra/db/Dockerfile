FROM postgres:15-alpine

# bash is required by the substitution wrapper script
RUN apk add --no-cache bash

# Init SQL scripts are executed by the official image on first boot (empty data dir).
# They are copied verbatim; placeholders of the form __VAR__ are substituted at start.
COPY ./init /docker-entrypoint-initdb.d

# Wrapper that substitutes __VAR__ placeholders then execs the official entrypoint.
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 5432

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["postgres"]
