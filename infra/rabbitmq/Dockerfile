FROM rabbitmq:3.13-management

# Static broker config: load definitions on boot, disable remote guest login.
COPY rabbitmq.conf /etc/rabbitmq/rabbitmq.conf

# Definition template; the entrypoint fills in password hashes from env at start.
COPY definitions.template.json /etc/rabbitmq/definitions.template.json

COPY docker-entrypoint.sh /usr/local/bin/generate-and-run.sh
RUN chmod +x /usr/local/bin/generate-and-run.sh

EXPOSE 5672 15672

ENTRYPOINT ["/usr/local/bin/generate-and-run.sh"]
