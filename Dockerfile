FROM chatwoot/chatwoot:v4.12.1

USER root

# pg_isready is needed by start.sh — install postgresql-client (alpine)
RUN apk add --no-cache postgresql-client

COPY start.sh /start.sh
RUN chmod +x /start.sh

CMD ["/start.sh"]
