const { exec } = require('child_process');
const os = require('os');
const fs = require('fs');
const path = require('path');
const { promisify } = require('util');

const execAsync = promisify(exec);

class ContainerMonitor {
    constructor(options = {}) {
        this.config = {
            dockerSocket: options.dockerSocket || '/var/run/docker.sock',
            pollInterval: options.pollInterval || 5000,
            logDir: options.logDir || '/tmp/sys-optimizer-logs',
            thresholds: {
                cpuWarning: 80,
                cpuCritical: 95,
                memWarning: 80,
                memCritical: 95,
                diskWarning: 85,
                diskCritical: 95,
                ...options.thresholds
            }
        };

        this.state = {
            containers: new Map(),
            metrics: { cpu: 0, memory: 0, disk: 0, network: 0 },
            alerts: [],
            lastCheck: null
        };

        this._ensureLogDir();
    }

    _ensureLogDir() {
        if (!fs.existsSync(this.config.logDir)) {
            fs.mkdirSync(this.config.logDir, { recursive: true });
        }
    }

    async _exec(cmd, timeout = 10000) {
        try {
            const { stdout } = await execAsync(cmd, { encoding: 'utf8', timeout });
            return stdout.trim();
        } catch (err) {
            throw new Error(`Command failed: ${cmd} — ${err.message}`);
        }
    }

    async _execSafe(cmd, fallback = '', timeout = 10000) {
        try {
            const { stdout } = await execAsync(cmd, { encoding: 'utf8', timeout });
            return stdout.trim();
        } catch {
            return fallback;
        }
    }

    async checkHealth() {
        const report = {
            timestamp: new Date().toISOString(),
            hostname: os.hostname(),
            platform: `${os.type()} ${os.release()}`,
            uptime: this._formatUptime(os.uptime()),
            system: this._getSystemMetrics(),
            containers: await this._getContainerMetrics(),
            network: await this._getNetworkMetrics(),
            disk: await this._getDiskMetrics(),
            recommendations: []
        };

        report.recommendations = this._generateRecommendations(report);
        this._writeReport(report);
        this.state.lastCheck = Date.now();

        return report;
    }

    _getSystemMetrics() {
        const load = os.loadavg();
        const totalMem = os.totalmem();
        const freeMem = os.freemem();

        return {
            cpu: {
                cores: os.cpus().length,
                model: os.cpus()[0]?.model || 'unknown',
                loadAvg: {
                    '1m': load[0].toFixed(2),
                    '5m': load[1].toFixed(2),
                    '15m': load[2].toFixed(2)
                },
                usagePercent: ((load[0] / os.cpus().length) * 100).toFixed(1)
            },
            memory: {
                total: this._formatBytes(totalMem),
                free: this._formatBytes(freeMem),
                used: this._formatBytes(totalMem - freeMem),
                usagePercent: (((totalMem - freeMem) / totalMem) * 100).toFixed(1)
            }
        };
    }

    async _getContainerMetrics() {
        const containers = { running: 0, stopped: 0, healthy: 0, unhealthy: 0, total: 0, stats: [] };

        try {
            const output = await this._execSafe(
                'docker ps -a --format "{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}|{{.Ports}}"'
            );

            if (output) {
                const lines = output.split('\n').filter(l => l);
                containers.total = lines.length;

                for (const line of lines) {
                    const [id, name, status, image, ports] = line.split('|');

                    if (status.startsWith('Up')) {
                        containers.running++;
                        if (status.includes('healthy')) containers.healthy++;
                        else if (status.includes('unhealthy')) containers.unhealthy++;
                    } else {
                        containers.stopped++;
                    }

                    this.state.containers.set(id, { name, status, image, ports, lastSeen: Date.now() });
                }
            }
        } catch (err) {
            // Docker not available or permission denied
        }

        try {
            const statsOutput = await this._execSafe(
                'docker stats --no-stream --format "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}"',
                '',
                15000
            );

            if (statsOutput) {
                containers.stats = statsOutput.split('\n').filter(l => l).map(line => {
                    const [name, cpu, mem, net] = line.split('|');
                    return { name, cpu, memory: mem, network: net };
                });
            }
        } catch {
            // Stats not available
        }

        return containers;
    }

    async _getDiskMetrics() {
        try {
            const output = await this._exec('df -B1 / | tail -1');
            const parts = output.split(/\s+/);
            const total = parseInt(parts[1]) || 0;
            const used = parseInt(parts[2]) || 0;

            return {
                total: this._formatBytes(total),
                used: this._formatBytes(used),
                available: this._formatBytes(parseInt(parts[3]) || 0),
                usagePercent: total > 0 ? ((used / total) * 100).toFixed(1) : '0'
            };
        } catch (err) {
            return { total: '0 B', used: '0 B', available: '0 B', usagePercent: '0', error: err.message };
        }
    }

    async _getNetworkMetrics() {
        const result = { status: 'unknown', latency: '-1ms', interfaces: [], dns: false };

        try {
            const start = Date.now();
            await this._exec('ping -c 1 -W 2 8.8.8.8', 5000);
            result.latency = `${Date.now() - start}ms`;
            result.status = 'healthy';
        } catch {
            result.status = 'unreachable';
        }

        try {
            const netOutput = await this._execSafe("ip -o addr show | awk '{print $2, $4}'");
            if (netOutput) {
                result.interfaces = netOutput.split('\n').map(line => {
                    const [iface, cidr] = line.split(' ');
                    return { interface: iface, address: cidr };
                });
            }
        } catch {}

        try {
            await this._exec('nslookup google.com', 5000);
            result.dns = true;
        } catch {
            result.dns = false;
        }

        return result;
    }

    _generateRecommendations(report) {
        const recs = [];
        const { system, containers, disk, network } = report;

        const cpuUsage = parseFloat(system.cpu.usagePercent);
        if (cpuUsage > this.config.thresholds.cpuCritical) {
            recs.push({ type: 'cpu', severity: 'critical', message: `CPU usage at ${cpuUsage}%. Immediate scaling recommended.` });
        } else if (cpuUsage > this.config.thresholds.cpuWarning) {
            recs.push({ type: 'cpu', severity: 'warning', message: `CPU usage at ${cpuUsage}%. Consider scaling.` });
        }

        const memUsage = parseFloat(system.memory.usagePercent);
        if (memUsage > this.config.thresholds.memCritical) {
            recs.push({ type: 'memory', severity: 'critical', message: `Memory usage at ${memUsage}%. OOM risk.` });
        } else if (memUsage > this.config.thresholds.memWarning) {
            recs.push({ type: 'memory', severity: 'warning', message: `Memory usage at ${memUsage}%. Consider limits adjustment.` });
        }

        const diskUsage = parseFloat(disk.usagePercent);
        if (diskUsage > this.config.thresholds.diskCritical) {
            recs.push({ type: 'disk', severity: 'critical', message: `Disk usage at ${diskUsage}%. Cleanup required.` });
        } else if (diskUsage > this.config.thresholds.diskWarning) {
            recs.push({ type: 'disk', severity: 'warning', message: `Disk usage at ${diskUsage}%. Monitor closely.` });
        }

        if (containers.stopped > 0) {
            recs.push({ type: 'containers', severity: 'info', message: `${containers.stopped} container(s) stopped.` });
        }

        if (containers.unhealthy > 0) {
            recs.push({ type: 'containers', severity: 'warning', message: `${containers.unhealthy} unhealthy container(s) detected.` });
        }

        if (network.status !== 'healthy') {
            recs.push({ type: 'network', severity: 'critical', message: 'Network connectivity issues.' });
        }

        return recs;
    }

    _writeReport(report) {
        const filename = `health-${Date.now()}.json`;
        const filepath = path.join(this.config.logDir, filename);

        try {
            fs.writeFileSync(filepath, JSON.stringify(report, null, 2));
            // Keep only last 50 reports
            const files = fs.readdirSync(this.config.logDir)
                .filter(f => f.startsWith('health-'))
                .sort()
                .reverse();
            files.slice(50).forEach(f => {
                try { fs.unlinkSync(path.join(this.config.logDir, f)); } catch {}
            });
        } catch (err) {
            // Log directory not writable
        }
    }

    _formatBytes(bytes) {
        if (bytes === 0) return '0 B';
        const k = 1024;
        const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
        const i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
    }

    _formatUptime(seconds) {
        const days = Math.floor(seconds / 86400);
        const hours = Math.floor((seconds % 86400) / 3600);
        const mins = Math.floor((seconds % 3600) / 60);
        return `${days}d ${hours}h ${mins}m`;
    }

    async watch(callback, interval = this.config.pollInterval) {
        const check = async () => {
            try {
                const report = await this.checkHealth();
                callback(null, report);
            } catch (err) {
                callback(err, null);
            }
        };

        await check();
        setInterval(check, interval);
    }
}

// CLI entry point
async function main() {
    const args = process.argv.slice(2);
    const monitor = new ContainerMonitor();

    if (args.includes('--watch')) {
        console.log('Starting continuous monitoring...');
        monitor.watch((err, report) => {
            if (err) {
                console.error(`[${new Date().toISOString()}] Error:`, err.message);
                return;
            }
            const crits = report.recommendations.filter(r => r.severity === 'critical');
            if (crits.length > 0) {
                console.log(`[${report.timestamp}] CRITICAL: ${crits.map(r => r.message).join(', ')}`);
            } else {
                console.log(`[${report.timestamp}] OK - CPU: ${report.system.cpu.usagePercent}% | Mem: ${report.system.memory.usagePercent}% | Containers: ${report.containers.running}/${report.containers.total}`);
            }
        });
    } else if (args.includes('--health')) {
        try {
            const report = await monitor.checkHealth();
            const status = report.recommendations.length === 0 ? 'healthy' : 'needs-attention';
            console.log(`Status: ${status}`);
            console.log(`CPU: ${report.system.cpu.usagePercent}% | Memory: ${report.system.memory.usagePercent}% | Disk: ${report.disk.usagePercent}%`);
            console.log(`Containers: ${report.containers.running} running, ${report.containers.stopped} stopped`);
            process.exit(status === 'healthy' ? 0 : 1);
        } catch (err) {
            console.error('Health check failed:', err.message);
            process.exit(1);
        }
    } else {
        try {
            const report = await monitor.checkHealth();
            console.log('\n=== Container Health Report ===');
            console.log(JSON.stringify(report, null, 2));
        } catch (err) {
            console.error('Health check failed:', err.message);
            process.exit(1);
        }
    }
}

main();
