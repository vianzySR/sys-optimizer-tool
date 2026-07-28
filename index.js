const { execSync } = require('child_process');
const os = require('os');

class SystemOptimizer {
    constructor() {
        this.metrics = {
            cpu: { usage: 0, cores: os.cpus().length },
            memory: { total: os.totalmem(), free: os.freemem(), used: 0 },
            disk: { total: 0, used: 0, available: 0 },
            network: { latency: 0, status: 'unknown' },
            containers: { running: 0, stopped: 0, healthy: 0 }
        };
    }

    async collectMetrics() {
        this.metrics.cpu.usage = this._getCpuUsage();
        this.metrics.memory.used = this.metrics.memory.total - this.metrics.memory.free;
        this._getDiskUsage();
        await this._checkNetwork();
        this._getContainerStats();
        return this.metrics;
    }

    _getCpuUsage() {
        try {
            const load = os.loadavg();
            const cores = this.metrics.cpu.cores;
            return Math.min(100, (load[0] / cores) * 100).toFixed(1);
        } catch {
            return 0;
        }
    }

    _getDiskUsage() {
        try {
            const output = execSync("df -B1 / | tail -1", { encoding: 'utf8' });
            const parts = output.trim().split(/\s+/);
            this.metrics.disk = {
                total: parseInt(parts[1]) || 0,
                used: parseInt(parts[2]) || 0,
                available: parseInt(parts[3]) || 0
            };
        } catch {
            this.metrics.disk = { total: 0, used: 0, available: 0 };
        }
    }

    async _checkNetwork() {
        try {
            const start = Date.now();
            execSync('ping -c 1 -W 2 8.8.8.8', { stdio: 'ignore' });
            this.metrics.network = {
                latency: Date.now() - start,
                status: 'healthy'
            };
        } catch {
            this.metrics.network = { latency: -1, status: 'unreachable' };
        }
    }

    _getContainerStats() {
        try {
            const output = execSync('docker ps -a --format "{{.Status}}" 2>/dev/null || echo ""', { encoding: 'utf8' });
            const lines = output.trim().split('\n').filter(l => l);
            this.metrics.containers = {
                running: lines.filter(l => l.startsWith('Up')).length,
                stopped: lines.filter(l => l.startsWith('Exited')).length,
                healthy: lines.filter(l => l.includes('healthy')).length
            };
        } catch {
            this.metrics.containers = { running: 0, stopped: 0, healthy: 0 };
        }
    }

    generateReport() {
        const m = this.metrics;
        const memPercent = ((m.memory.used / m.memory.total) * 100).toFixed(1);
        const diskPercent = m.disk.total > 0
            ? ((m.disk.used / m.disk.total) * 100).toFixed(1)
            : 'N/A';

        return {
            timestamp: new Date().toISOString(),
            hostname: os.hostname(),
            platform: `${os.type()} ${os.release()}`,
            cpu: {
                cores: m.cpu.cores,
                load: `${m.cpu.usage}%`
            },
            memory: {
                total: this._formatBytes(m.memory.total),
                used: this._formatBytes(m.memory.used),
                percent: `${memPercent}%`
            },
            disk: {
                total: this._formatBytes(m.disk.total),
                used: this._formatBytes(m.disk.used),
                percent: `${diskPercent}%`
            },
            network: {
                status: m.network.status,
                latency: `${m.network.latency}ms`
            },
            containers: m.containers
        };
    }

    _formatBytes(bytes) {
        if (bytes === 0) return '0 B';
        const k = 1024;
        const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    }

    optimize() {
        const recommendations = [];
        const memPercent = (this.metrics.memory.used / this.metrics.memory.total) * 100;

        if (memPercent > 80) {
            recommendations.push({
                type: 'memory',
                severity: 'warning',
                message: `Memory usage at ${memPercent.toFixed(1)}%. Consider increasing limits or adding swap.`
            });
        }

        const cpuLoad = parseFloat(this.metrics.cpu.usage);
        if (cpuLoad > 80) {
            recommendations.push({
                type: 'cpu',
                severity: 'warning',
                message: `CPU load at ${cpuLoad}%. Consider scaling horizontally.`
            });
        }

        if (this.metrics.network.status !== 'healthy') {
            recommendations.push({
                type: 'network',
                severity: 'critical',
                message: 'Network connectivity issues detected.'
            });
        }

        if (this.metrics.containers.stopped > 0) {
            recommendations.push({
                type: 'containers',
                severity: 'info',
                message: `${this.metrics.containers.stopped} container(s) stopped. Review if restart is needed.`
            });
        }

        return {
            status: recommendations.length === 0 ? 'optimal' : 'needs-attention',
            recommendations
        };
    }
}

async function main() {
    const optimizer = new SystemOptimizer();

    try {
        const metrics = await optimizer.collectMetrics();
        const report = optimizer.generateReport();
        const optimization = optimizer.optimize();

        console.log('\n=== System Health Report ===');
        console.log(JSON.stringify(report, null, 2));
        console.log('\n=== Optimization Status ===');
        console.log(JSON.stringify(optimization, null, 2));
    } catch (err) {
        console.error('Health check failed:', err.message);
        process.exit(1);
    }
}

main();
