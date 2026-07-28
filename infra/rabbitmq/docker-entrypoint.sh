#!/bin/bash
set -e

TEMPLATE=/etc/rabbitmq/definitions.template.json
TARGET=/etc/rabbitmq/definitions.json

# Compute a RabbitMQ password hash (rabbit_password_hashing_sha256) for the cleartext
# password held in the named environment variable. The value is read inside Erlang via
# os:getenv so it is never interpolated into the evaluated string (injection-safe).
# Algorithm: base64( salt(4 bytes) || sha256(salt || password) ).
rmq_hash() {
  erl -noshell -eval "
    Pw = list_to_binary(os:getenv(\"$1\")),
    Salt = crypto:strong_rand_bytes(4),
    Hash = crypto:hash(sha256, <<Salt/binary, Pw/binary>>),
    io:format(\"~s\", [base64:encode(<<Salt/binary, Hash/binary>>)]),
    halt(0)."
}

: "${RABBITMQ_ADMIN_PASSWORD:?RABBITMQ_ADMIN_PASSWORD is required}"
: "${RABBITMQ_SERVER_PASSWORD:?RABBITMQ_SERVER_PASSWORD is required}"
: "${RABBITMQ_HUB_PASSWORD:?RABBITMQ_HUB_PASSWORD is required}"

ADMIN_HASH=$(rmq_hash RABBITMQ_ADMIN_PASSWORD)
SERVER_HASH=$(rmq_hash RABBITMQ_SERVER_PASSWORD)
HUB_HASH=$(rmq_hash RABBITMQ_HUB_PASSWORD)

# base64 output never contains '|', so it is a safe sed delimiter.
sed -e "s|__ADMIN_PWD_HASH__|${ADMIN_HASH}|" \
    -e "s|__SERVER_PWD_HASH__|${SERVER_HASH}|" \
    -e "s|__HUB_PWD_HASH__|${HUB_HASH}|" \
    "$TEMPLATE" > "$TARGET"

# Hand over to the official RabbitMQ entrypoint.
exec docker-entrypoint.sh rabbitmq-server
