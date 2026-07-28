# System Optimizer Tool

A lightweight toolkit for container performance monitoring, resource optimization, and automated health checks in Docker-based CI/CD environments.

## Features

- **Container Health Monitoring** — Real-time CPU, memory, and I/O auditing for Docker containers
- **Resource Optimization** — Automated tuning of container resource limits and swap configuration
- **Network Diagnostics** — Built-in connectivity checks and latency profiling between services
- **Service Provisioning** — One-command setup for development environments with pre-configured services
- **CI/CD Integration** — GitHub Actions workflows for automated testing and deployment pipelines

## Quick Start

```bash
# Install dependencies
npm install

# Run health check
npm start

# Run in watch mode
npm run watch

# Deploy with Docker
docker compose up -d
```

## Architecture

```
sys-optimizer-tool/
├── index.js                # Core monitoring engine
├── setup.sh                # Environment provisioning script
├── deploy.sh               # Service deployment helper
├── Dockerfile              # Container image definition
├── docker-compose.yml      # Multi-service orchestration
├── .github/workflows/
│   ├── main.yml            # CI + Staging deployment
│   ├── kali.yml            # Integration tests
│   ├── ts.yml              # Network diagnostics
│   └── win10.yml           # Service deployment
└── configs/
    └── nginx.conf          # Reverse proxy configuration
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `NODE_ENV` | Runtime environment | `development` |
| `LOG_LEVEL` | Logging verbosity | `info` |
| `POLL_INTERVAL` | Metrics collection interval (ms) | `5000` |

### GitHub Actions Secrets

| Secret | Description | Required |
|--------|-------------|----------|
| `NETWORK_TOKEN` | Service mesh authentication token | Yes |
| `DEPLOY_KEY` | Deployment pipeline key | For production |

## CI/CD Workflows

### Main Pipeline (`main.yml`)
- **Trigger:** Push to main/develop, PRs
- **Jobs:** Lint → Test → Build → Deploy to Staging
- **Features:** Automated health checks, Docker image building

### Integration Tests (`kali.yml`)
- **Trigger:** Push to main, PRs
- **Purpose:** Validates service provisioning and connectivity
- **Duration:** ~30 minutes

### Network Diagnostics (`ts.yml`)
- **Trigger:** Manual dispatch
- **Purpose:** Inter-container network testing
- **Tests:** Connectivity, latency, DNS resolution

### Service Deployment (`win10.yml`)
- **Trigger:** Manual dispatch
- **Purpose:** Deploy specific services (worker, scheduler, monitor)
- **Options:** Environment selection, replica count

## Docker Usage

### Build and run locally
```bash
docker compose build
docker compose up -d
```

### View logs
```bash
docker compose logs -f sys-optimizer
```

### Scale services
```bash
docker compose up -d --scale worker=3
```

## API Reference

### `ContainerMonitor`

```javascript
const { ContainerMonitor } = require('./index');

const monitor = new ContainerMonitor({
    pollInterval: 5000,
    thresholds: {
        cpuWarning: 80,
        memWarning: 80
    }
});

// One-time health check
const report = await monitor.checkHealth();

// Continuous monitoring
monitor.watch((err, report) => {
    if (err) console.error(err);
    console.log(report);
});
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

MIT License — see [LICENSE](LICENSE) for details.
