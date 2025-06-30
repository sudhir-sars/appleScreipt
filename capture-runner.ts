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

// ANSI color codes
const colors = {
  reset: '\x1b[0m',
  bright: '\x1b[1m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  red: '\x1b[31m',
  cyan: '\x1b[36m'
} as const;

type LogType = 'info' | 'success' | 'error' | 'warn' | 'step';

// Logger with timestamp
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

// Check if Swift executable exists
function checkExecutable(): void {
  log('Checking if Swift executable exists...', 'step');
  
  if (!existsSync(SWIFT_EXECUTABLE_PATH)) {
    log(`Swift executable not found at: ${SWIFT_EXECUTABLE_PATH}`, 'error');
    log('Please compile the Swift code first with:', 'info');
    log('bun run compile', 'info');
    process.exit(1);
  }
  
  log('Swift executable found!', 'success');
}

// Capture process manager class
class CaptureProcessManager {
  private testMode: boolean;
  private process: ChildProcess | null = null;
  private isRunning: boolean = false;

  constructor(testMode: boolean = false) {
    this.testMode = testMode;
  }

  start(): void {
    log(`Starting capture process in ${this.testMode ? 'TEST' : 'NORMAL'} mode...`, 'step');
    
    const args = this.testMode ? ['--testmode'] : [];
    
    this.process = spawn(SWIFT_EXECUTABLE_PATH, args, {
      stdio: ['pipe', 'pipe', 'pipe']
    });
    
    this.isRunning = true;
    log(`Swift process started with PID: ${this.process.pid}`, 'success');
    
    this.setupEventHandlers();
    this.setupIPC();
  }

  private setupEventHandlers(): void {
    if (!this.process) return;

    this.process.on('exit', (code, signal) => {
      this.isRunning = false;
      if (code === 0) {
        log('Swift process exited successfully', 'success');
      } else {
        log(`Swift process exited with code: ${code}, signal: ${signal}`, 'error');
      }
    });

    this.process.on('error', (error) => {
      log(`Failed to start Swift process: ${error.message}`, 'error');
      this.isRunning = false;
    });

    this.process.stderr?.on('data', (data: Buffer) => {
      log(`Swift Error: ${data.toString().trim()}`, 'error');
    });
  }

  private setupIPC(): void {
    if (!this.process?.stdout) return;

    this.process.stdout.on('data', (data: Buffer) => {
      try {
        const response = JSON.parse(data.toString()) as CaptureResponse;
        this.handleResponse(response);
      } catch (error) {
        log(`Swift Output: ${data.toString().trim()}`, 'info');
      }
    });
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
    if (!this.isRunning || !this.process?.stdin) {
      log('Cannot send command - process is not running', 'error');
      return;
    }

    log(`Sending command: ${command}`, 'step');
    this.process.stdin.write(command + '\n');
  }

  stop(): void {
    if (!this.isRunning) {
      log('Process is not running', 'warn');
      return;
    }

    log('Stopping capture process...', 'step');
    
    this.sendCommand('stop_stream');
    
    setTimeout(() => {
      if (this.isRunning && this.process) {
        log('Terminating process...', 'warn');
        this.process.kill('SIGTERM');
      }
    }, 2000);
  }
}

// Utility functions
const sleep = (ms: number): Promise<void> => 
  new Promise(resolve => setTimeout(resolve, ms));

// Demo workflow
async function runDemo(): Promise<void> {
  log(`${colors.bright}Starting Audio/Video Capture Demo${colors.reset}`, 'info');
  log(`Mode: ${TEST_MODE ? 'TEST (saving to disk)' : 'NORMAL (streaming only)'}`, 'info');
  log('=' + '='.repeat(50), 'info');

  const manager = new CaptureProcessManager(TEST_MODE);
  manager.start();

  await sleep(1000);

  const commands: CommandSequence[] = [
    { cmd: 'check_input_audio_access', wait: 2000, desc: 'Checking microphone permissions' },
    { cmd: 'check_screen_capture_access', wait: 2000, desc: 'Checking screen capture permissions' },
    { cmd: 'start_capture_default', wait: 5000, desc: 'Starting default capture (default mic + system audio)' },
    { cmd: 'pause_stream', wait: 3000, desc: 'Pausing all streams' },
    { cmd: 'stop_stream', wait: 2000, desc: 'Stopping all streams' },
    { cmd: 'start_capture_all', wait: 5000, desc: 'Starting full capture (all devices + all screens)' }
  ];

  for (const { cmd, wait, desc } of commands) {
    log(`\n${colors.bright}${desc}${colors.reset}`, 'info');
    manager.sendCommand(cmd);
    await sleep(wait);
  }

  log('\nCapturing for 10 seconds...', 'info');
  await sleep(10000);

  log('\nStopping capture demo...', 'step');
  manager.stop();

  await sleep(3000);
  
  log(`${colors.bright}Demo completed!${colors.reset}`, 'success');
  if (TEST_MODE) {
    log('Check the save directory for recorded files', 'info');
  }
}

// Interactive mode
async function runInteractive(): Promise<void> {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
  });

  log(`${colors.bright}Audio/Video Capture - Interactive Mode${colors.reset}`, 'info');
  log(`Mode: ${TEST_MODE ? 'TEST (saving to disk)' : 'NORMAL (streaming only)'}`, 'info');
  
  const manager = new CaptureProcessManager(TEST_MODE);
  manager.start();

  await sleep(1000);

  const showMenu = (): void => {
    console.log(`\n${colors.cyan}Available commands:${colors.reset}`);
    console.log('1. check_input_audio_access  - Check microphone permissions');
    console.log('2. check_screen_capture_access - Check screen capture permissions');
    console.log('3. start_capture_default     - Start default capture');
    console.log('4. start_capture_all         - Start capturing all devices');
    console.log('5. pause_stream              - Pause all streams');
    console.log('6. stop_stream               - Stop all streams');
    console.log('7. exit                      - Exit the program');
    console.log('');
  };

  showMenu();

  rl.on('line', (input: string) => {
    const commandMap: Record<string, string> = {
      '1': 'check_input_audio_access',
      '2': 'check_screen_capture_access',
      '3': 'start_capture_default',
      '4': 'start_capture_all',
      '5': 'pause_stream',
      '6': 'stop_stream',
      '7': 'exit'
    };

    const command = commandMap[input] || input;

    if (command === 'exit') {
      log('Exiting...', 'info');
      manager.stop();
      setTimeout(() => {
        rl.close();
        process.exit(0);
      }, 2000);
    } else if (command in commandMap || Object.values(commandMap).includes(command)) {
      manager.sendCommand(command);
    } else {
      log('Invalid command', 'error');
    }

    setTimeout(showMenu, 1000);
  });

  rl.on('close', () => {
    manager.stop();
    process.exit(0);
  });
}

// Main execution
async function main(): Promise<void> {
  checkExecutable();

  if (process.argv.includes('--demo')) {
    await runDemo();
    process.exit(0);
  } else {
    await runInteractive();
  }
}

// Handle process termination
process.on('SIGINT', () => {
  log('\nReceived SIGINT, cleaning up...', 'warn');
  process.exit(0);
});

process.on('SIGTERM', () => {
  log('\nReceived SIGTERM, cleaning up...', 'warn');
  process.exit(0);
});

// Start the application
main().catch(error => {
  log(`Fatal error: ${error.message}`, 'error');
  process.exit(1);
});