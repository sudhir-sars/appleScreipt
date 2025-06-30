import { spawn, type ChildProcess } from 'child_process';
import { existsSync } from 'fs';
import * as readline from 'readline';

// Types
interface StreamInfo {
  id: string;
  name: string;
  deviceId?: string;
  isDefault: boolean;
  type: string;
  status: string;
  filePath?: string;
}

interface VideoStreamInfo {
  id: string;
  name: string;
  type: string;
  isPrimary: boolean;
  status: string;
  filePaths?: {
    combined?: string;
    video?: string;
    audio?: string;
  };
}

interface CaptureResponse {
  type: 'success' | 'error';
  operation: string;
  timestamp: string;
  success: boolean;
  message: string;
  error?: {
    code: string;
    message: string;
    details: string;
  };
  data?: {
    streams?: {
      audio: StreamInfo[];
      video: VideoStreamInfo[];
    };
    metadata?: {
      totalStreams: number;
      activeStreams: number;
      testMode: boolean;
      saveDirectory?: string;
      permissions: {
        microphone: string;
        screenCapture: string;
      };
    };
  };
}

interface CommandSequence {
  cmd: string;
  wait: number;
  desc: string;
}

// Configuration
const SWIFT_EXECUTABLE_PATH = './CaptureProcess';
const TEST_MODE = process.argv.includes('--test');
const DEBUG_MODE = process.argv.includes('--debug');

// ANSI color codes - Fixed missing magenta color
const colors = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  red: '\x1b[31m',
  cyan: '\x1b[36m',
  magenta: '\x1b[35m'  // Added missing magenta color
} as const;

type LogType = 'info' | 'success' | 'error' | 'warn' | 'step';

// Enhanced logger with debug support
function log(message: string, type: LogType = 'info'): void {
  const timestamp = new Date().toISOString();
  const typeColors: Record<LogType, string> = {
    info: colors.blue,
    success: colors.green,
    error: colors.red,
    warn: colors.yellow,
    step: colors.cyan
  };
  
  console.log(`${typeColors[type]}[${timestamp}] ${message}${colors.reset}`);
}

function debug(message: string): void {
  if (DEBUG_MODE) {
    console.log(`${colors.magenta}[DEBUG] ${message}${colors.reset}`);
  }
}

// Enhanced executable check
function checkExecutable(): void {
  log('Checking if Swift executable exists...', 'step');
  
  const fullPath = SWIFT_EXECUTABLE_PATH;
  debug(`Looking for executable at: ${fullPath}`);
  
  if (!existsSync(fullPath)) {
    log(`Swift executable not found at: ${fullPath}`, 'error');
    log('Current directory: ' + process.cwd(), 'error');
    log('Directory contents:', 'error');
    
    // List directory contents to help debug
    try {
      const fs = require('fs');
      const files = fs.readdirSync('.');
      files.forEach((file: string) => {
        console.log(`  - ${file}`);
      });
    } catch (e) {
      console.log('  Could not list directory contents');
    }
    
    log('\nPlease compile the Swift code first with:', 'info');
    log('bun run build', 'info');
    log('or', 'info');
    log('./build.sh', 'info');
    process.exit(1);
  }
  
  // Check if it's executable
  try {
    const fs = require('fs');
    const stats = fs.statSync(fullPath);
    const isExecutable = (stats.mode & parseInt('0111', 8)) !== 0;
    
    if (!isExecutable) {
      log('File exists but is not executable', 'warn');
      log('Making it executable...', 'info');
      require('child_process').execSync(`chmod +x ${fullPath}`);
      log('Made executable', 'success');
    }
  } catch (e) {
    debug(`Error checking executable permissions: ${e}`);
  }
  
  log('Swift executable found!', 'success');
}

// Enhanced process manager with better error handling
class CaptureProcessManager {
  private testMode: boolean;
  private process: ChildProcess | null = null;
  private isRunning: boolean = false;
  private startupTimeout: NodeJS.Timeout | null = null;

  constructor(testMode: boolean = false) {
    this.testMode = testMode;
  }

  start(): void {
    log(`Starting capture process in ${this.testMode ? 'TEST' : 'NORMAL'} mode...`, 'step');
    
    const args = this.testMode ? ['--testmode'] : [];
    debug(`Spawn command: ${SWIFT_EXECUTABLE_PATH} ${args.join(' ')}`);
    
    try {
      this.process = spawn(SWIFT_EXECUTABLE_PATH, args, {
        stdio: ['pipe', 'pipe', 'pipe'],
        env: { ...process.env }
      });
      
      // Set startup timeout
      this.startupTimeout = setTimeout(() => {
        if (!this.isRunning) {
          log('Swift process failed to start within 5 seconds', 'error');
          this.cleanup();
        }
      }, 5000);
      
      if (this.process.pid) {
        debug(`Swift process spawned with PID: ${this.process.pid}`);
        this.isRunning = true;
        log(`Swift process started with PID: ${this.process.pid}`, 'success');
        
        this.setupEventHandlers();
        this.setupIPC();
      } else {
        throw new Error('Failed to get process PID');
      }
    } catch (error: any) {
      log(`Failed to spawn Swift process: ${error.message}`, 'error');
      log('Make sure the Swift executable exists and is compiled', 'error');
      this.isRunning = false;
      process.exit(1);
    }
  }

  private setupEventHandlers(): void {
    if (!this.process) return;

    this.process.on('spawn', () => {
      debug('Process spawn event fired');
      if (this.startupTimeout) {
        clearTimeout(this.startupTimeout);
        this.startupTimeout = null;
      }
    });

    this.process.on('error', (error) => {
      log(`Process error: ${error.message}`, 'error');
      if (error.message.includes('ENOENT')) {
        log('The Swift executable was not found', 'error');
        log('Please run: bun run build', 'error');
      } else if (error.message.includes('EACCES')) {
        log('Permission denied. The file might not be executable', 'error');
        log('Please run: chmod +x ' + SWIFT_EXECUTABLE_PATH, 'error');
      }
      this.cleanup();
    });

    this.process.on('exit', (code, signal) => {
      this.isRunning = false;
      debug(`Process exited with code: ${code}, signal: ${signal}`);
      
      if (code === 0) {
        log('Swift process exited successfully', 'success');
      } else if (code === null && signal) {
        log(`Swift process terminated by signal: ${signal}`, 'warn');
      } else {
        log(`Swift process exited with code: ${code}`, 'error');
      }
      
      this.cleanup();
    });

    this.process.stderr?.on('data', (data: Buffer) => {
      const error = data.toString().trim();
      if (error) {
        log(`Swift Error: ${error}`, 'error');
        debug(`Full stderr: ${error}`);
      }
    });

    // Add stdout data handler for non-JSON output
    this.process.stdout?.on('data', (data: Buffer) => {
      const output = data.toString();
      debug(`Raw stdout: ${output}`);
      
      // Try to parse as JSON first
      try {
        const lines = output.trim().split('\n');
        for (const line of lines) {
          if (line.trim()) {
            try {
              const response = JSON.parse(line) as CaptureResponse;
              this.handleResponse(response);
            } catch {
              // Not JSON, just log it
              if (!line.includes('{') && !line.includes('}')) {
                log(`Swift: ${line}`, 'info');
              }
            }
          }
        }
      } catch (error) {
        debug(`Failed to parse output: ${error}`);
      }
    });
  }

  private setupIPC(): void {
    // Already handled in setupEventHandlers
    debug('IPC setup complete');
  }

  private handleResponse(response: CaptureResponse): void {
    log(`Received response: ${response.operation || 'unknown'}`, 'step');
    
    if (response.type === 'success') {
      log(`✓ ${response.message}`, 'success');
      
      if (response.data) {
        if (response.data.metadata) {
          log(`  Total streams: ${response.data.metadata.totalStreams}`, 'info');
          log(`  Active streams: ${response.data.metadata.activeStreams}`, 'info');
          if (response.data.metadata.saveDirectory) {
            log(`  Save directory: ${response.data.metadata.saveDirectory}`, 'info');
          }
        }
        
        if (response.data.streams) {
          const { audio, video } = response.data.streams;
          if (audio && audio.length > 0) {
            log(`  Audio streams: ${audio.length}`, 'info');
            audio.forEach(stream => {
              log(`    - ${stream.name} (${stream.type})${stream.isDefault ? ' [DEFAULT]' : ''}`, 'info');
            });
          }
          if (video && video.length > 0) {
            log(`  Video streams: ${video.length}`, 'info');
            video.forEach(stream => {
              log(`    - ${stream.name} (${stream.type})${stream.isPrimary ? ' [PRIMARY]' : ''}`, 'info');
            });
          }
        }
      }
    } else if (response.type === 'error') {
      log(`✗ Error: ${response.message}`, 'error');
      if (response.error) {
        log(`  Code: ${response.error.code}`, 'error');
        log(`  Details: ${response.error.details}`, 'error');
      }
    }
  }

  sendCommand(command: string): void {
    if (!this.process) {
      log('Process object is null', 'error');
      return;
    }

    if (!this.isRunning) {
      log('Process is not running', 'error');
      debug(`Process state: running=${this.isRunning}, pid=${this.process.pid}`);
      return;
    }

    if (!this.process.stdin) {
      log('Process stdin is not available', 'error');
      return;
    }

    try {
      log(`Sending command: ${command}`, 'step');
      debug(`Writing to stdin: '${command}\\n'`);
      
      const success = this.process.stdin.write(command + '\n', (error) => {
        if (error) {
          log(`Failed to write command: ${error.message}`, 'error');
        } else {
          debug('Command written successfully');
        }
      });
      
      if (!success) {
        debug('Write returned false, stream might be full');
      }
    } catch (error: any) {
      log(`Exception sending command: ${error.message}`, 'error');
    }
  }

  private cleanup(): void {
    if (this.startupTimeout) {
      clearTimeout(this.startupTimeout);
      this.startupTimeout = null;
    }
    this.isRunning = false;
  }

  stop(): void {
    if (!this.isRunning) {
      log('Process is not running', 'warn');
      return;
    }

    log('Stopping capture process...', 'step');
    
    // First try to stop streams gracefully
    this.sendCommand('stop_stream');
    
    // Give it time to clean up
    setTimeout(() => {
      if (this.isRunning && this.process) {
        log('Terminating process...', 'warn');
        this.process.kill('SIGTERM');
      }
    }, 2000);
  }

  isProcessRunning(): boolean {
    return this.isRunning;
  }
}

// Added missing utility functions
function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Demo mode functionality
async function runDemo(manager: CaptureProcessManager): Promise<void> {
  log('Running demonstration mode...', 'step');
  
  const demoSequence: CommandSequence[] = [
    { cmd: 'list_streams', wait: 2000, desc: 'Listing available streams' },
    { cmd: 'start_stream', wait: 5000, desc: 'Starting capture' },
    { cmd: 'status', wait: 2000, desc: 'Checking status' },
    { cmd: 'stop_stream', wait: 2000, desc: 'Stopping capture' }
  ];

  for (const step of demoSequence) {
    log(step.desc, 'step');
    manager.sendCommand(step.cmd);
    await sleep(step.wait);
  }

  log('Demo completed', 'success');
}

// Interactive mode functionality
async function runInteractive(manager: CaptureProcessManager): Promise<void> {
  log('Starting interactive mode...', 'step');
  log('Available commands:', 'info');
  log('  list_streams - List available audio/video streams', 'info');
  log('  start_stream - Start capturing', 'info');
  log('  stop_stream - Stop capturing', 'info');
  log('  status - Check current status', 'info');
  log('  exit - Exit the application', 'info');
  log('', 'info');

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
    prompt: `${colors.cyan}capture> ${colors.reset}`
  });

  rl.prompt();

  rl.on('line', (input: string) => {
    const command = input.trim().toLowerCase();
    
    if (command === 'exit' || command === 'quit') {
      log('Exiting interactive mode...', 'step');
      manager.stop();
      rl.close();
      return;
    }
    
    if (command === 'help') {
      log('Available commands:', 'info');
      log('  list_streams - List available audio/video streams', 'info');
      log('  start_stream - Start capturing', 'info');
      log('  stop_stream - Stop capturing', 'info');
      log('  status - Check current status', 'info');
      log('  exit - Exit the application', 'info');
    } else if (command) {
      manager.sendCommand(command);
    }
    
    rl.prompt();
  });

  rl.on('close', () => {
    log('Interactive mode closed', 'info');
    manager.stop();
    process.exit(0);
  });

  // Handle Ctrl+C gracefully
  process.on('SIGINT', () => {
    log('\nReceived SIGINT, shutting down gracefully...', 'warn');
    manager.stop();
    rl.close();
    process.exit(0);
  });
}

// Main function
async function main(): Promise<void> {
  log('Starting Capture Process Manager', 'step');
  
  // Add debug info at startup
  if (DEBUG_MODE) {
    console.log(`${colors.magenta}=== DEBUG MODE ENABLED ===${colors.reset}`);
    console.log(`Working directory: ${process.cwd()}`);
    console.log(`Node version: ${process.version}`);
    console.log(`Platform: ${process.platform}`);
    console.log(`Arguments: ${process.argv.join(' ')}`);
    console.log('');
  }

  // Check if executable exists
  checkExecutable();

  // Create and start the capture process manager
  const manager = new CaptureProcessManager(TEST_MODE);
  
  // Handle process termination gracefully
  process.on('SIGTERM', () => {
    log('Received SIGTERM, shutting down...', 'warn');
    manager.stop();
    process.exit(0);
  });

  process.on('SIGINT', () => {
    log('Received SIGINT, shutting down...', 'warn');
    manager.stop();
    process.exit(0);
  });

  // Start the process
  manager.start();

  // Wait a bit for the process to start
  await sleep(1000);

  // Check if we should run in demo mode
  if (process.argv.includes('--demo')) {
    await runDemo(manager);
    manager.stop();
  } else {
    // Run in interactive mode
    await runInteractive(manager);
  }
}

// Start the application
main().catch(error => {
  log(`Fatal error: ${error.message}`, 'error');
  if (DEBUG_MODE && error.stack) {
    console.error(error.stack);
  }
  process.exit(1);
});