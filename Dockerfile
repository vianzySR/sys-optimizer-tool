FROM node:20-slim

LABEL maintainer="vianzySR"
LABEL description="System performance monitoring and container optimization toolkit"
LABEL version="1.2.0"

WORKDIR /app

RUN apt-get update && apt-get install -y \
    curl \
    iputils-ping \
    net-tools \
    docker.io \
    && rm -rf /var/lib/apt/lists/*

COPY package*.json ./
RUN npm ci --only=production

COPY . .

RUN chmod +x setup.sh deploy.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD node index.js || exit 1

ENTRYPOINT ["node"]
CMD ["index.js"]
