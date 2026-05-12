FROM ubuntu:22.04
RUN apt-get update && apt-get install -y bash curl python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY bot.sh .
RUN mkdir -p /tmp/smartpal/users
RUN chmod +x bot.sh
CMD ["bash", "bot.sh"]
