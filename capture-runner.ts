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

// Capture process manager class
class CaptureProcessManager {
  private testMode: boolean;
  private process: ChildProcess | null = null;
  private isRunning: boolean = false;

  constructor(testMode: boolean = false) {
    this.testMode = testMode;
  }

  start(): void {
    const args = this.testMode ? ['--testmode'] : [];
    
    this.process = spawn(SWIFT_EXECUTABLE_PATH, args, {
      stdio: ['pipe', 'pipe', 'pipe']
    });
    
    this.isRunning = true;
    this.setupEventHandlers();
    this.setupIPC();
  }

  private setupEventHandlers(): void {
    if (!this.process) return;

    this.process.on('exit', (code) => {
      this.isRunning = false;
    });

    this.process.on('error', () => {
      this.isRunning = false;
    });
  }

  private setupIPC(): void {
    if (!this.process?.stdout) return;

    this.process.stdout.on('data', (data: Buffer) => {
      try {
        const response = JSON.parse(data.toString()) as CaptureResponse;
        this.handleResponse(response);
      } catch { }
    });
  }

  private handleResponse(response: CaptureResponse): void {
    if (response.type === 'success') {
      if (response.data) {
        if (response.data.metadata) {
          // Handle metadata
        }
        
        if (response.data.streams) {
          // Handle streams
        }
      }
    }
  }

  sendCommand(command: string): void {
    if (!this.isRunning || !this.process?.stdin) {
      return;
    }
    this.process.stdin.write(command + '\n');
  }

  stop(): void {
    if (!this.isRunning) {
      return;
    }
    
    this.sendCommand('stop_stream');
    
    setTimeout(() => {
      if (this.isRunning && this.process) {
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
  const manager = new CaptureProcessManager(TEST_MODE);
  manager.start();

  await sleep(1000);

  const commands: CommandSequence[] = [
    { cmd: 'check_input_audio_access', wait: 2000, desc: 'Checking microphone permissions' },
    { cmd: 'check_screen_capture_access', wait: 2000, desc: 'Checking screen capture permissions' },
    { cmd: 'start_capture_default', wait: 5000, desc: 'Starting default capture' },
    { cmd: 'pause_stream', wait: 3000, desc: 'Pausing all streams' },
    { cmd: 'stop_stream', wait: 2000, desc: 'Stopping all streams' },
    { cmd: 'start_capture_all', wait: 5000, desc: 'Starting full capture' }
  ];

  for (const { cmd, wait } of commands) {
    manager.sendCommand(cmd);
    await sleep(wait);
  }

  await sleep(10000);
  manager.stop();
  await sleep(3000);
}

// Interactive mode
async function runInteractive(): Promise<void> {
  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
  });

  const manager = new CaptureProcessManager(TEST_MODE);
  manager.start();

  await sleep(1000);

  const showMenu = (): void => {
    console.log('\nAvailable commands:');
    console.log('1. check_input_audio_access');
    console.log('2. check_screen_capture_access');
    console.log('3. start_capture_default');
    console.log('4. start_capture_all');
    console.log('5. pause_stream');
    console.log('6. stop_stream');
    console.log('7. exit');
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
      manager.stop();
      setTimeout(() => {
        rl.close();
        process.exit(0);
      }, 2000);
    } else if (command in commandMap || Object.values(commandMap).includes(command)) {
      manager.sendCommand(command);
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
  if (!existsSync(SWIFT_EXECUTABLE_PATH)) {
    process.exit(1);
  }

  if (process.argv.includes('--demo')) {
    await runDemo();
    process.exit(0);
  } else {
    await runInteractive();
  }
}

// Handle process termination
process.on('SIGINT', () => {
  process.exit(0);
});

process.on('SIGTERM', () => {
  process.exit(0);
});

// Start the application
main().catch(() => {
  process.exit(1);
});