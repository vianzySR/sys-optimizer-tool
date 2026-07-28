# System Optimizer Tool

A lightweight toolkit for container performance monitoring, resource optimization, and automated health checks in Docker-based CI/CD environments.

## Features

- **Container Health Monitoring** — Real-time CPU, memory, and I/O auditing for Docker containers
- **Resource Optimization** — Automated tuning of container resource limits and swap configuration
- **Network Diagnostics** — Built-in connectivity checks and latency profiling between services
- **Service Provisioning** — One-command setup for development environments with pre-configured services
- **CI/CD Integration** — GitHub Actions workflows for automated testing and deployment pipelines

## Architecture

```
sys-optimizer-tool/
├── index.js              # Core monitoring engine
├── setup.sh              # Container environment provisioning
├── deploy.sh             # Service deployment helper
├── .github/workflows/
│   ├── ci.yml            # Main CI pipeline
│   ├── test.yml          # Integration tests
│   ├── deploy-staging.yml# Staging deployment
│   └── deploy-prod.yml   # Production deployment
└── configs/
    └── docker-compose.yml
```

## Installation

```bash
npm install
```

## Usage

### Run health check
```bash
npm start
```

### Run integration tests
```bash
npm test
```

### Deploy development environment
```bash
chmod +x setup.sh
./setup.sh
```

### Deploy services
```bash
chmod +x deploy.sh
./deploy.sh
```

## Configuration

Set the following environment variables for CI/CD workflows:

| Variable | Description | Required |
|----------|-------------|----------|
| `DOCKER_REGISTRY` | Container registry URL | No |
| `DEPLOY_KEY` | Deployment authentication key | Yes (for deploy) |
| `NETWORK_TOKEN` | Inter-service network token | Yes (for network setup) |

## CI/CD Workflows

This project includes GitHub Actions workflows for:

- **Continuous Integration** — Runs on every push and PR
- **Integration Testing** — Validates container orchestration and service connectivity
- **Staging Deployment** — Auto-deploys to staging on main branch updates
- **Production Deployment** — Manual trigger with approval gates

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

MIT License — see [LICENSE](LICENSE) for details.
