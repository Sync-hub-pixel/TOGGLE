import bcrypt from 'bcryptjs';
import { createInterface } from 'node:readline';

const input = process.stdin;
const output = process.stdout;
let password = '';

if (input.isTTY && typeof input.setRawMode === 'function') {
  input.setRawMode(true);
}
input.setEncoding('utf8');
input.resume();
output.write('Enter the SYNC sign-in password (input is hidden): ');

input.on('data', async (chunk) => {
  for (const character of chunk) {
    if (character === '\u0003') {
      output.write('\nCancelled.\n');
      process.exit(1);
    }
    if (character === '\r' || character === '\n') {
      input.pause();
      if (input.isTTY && typeof input.setRawMode === 'function') {
        input.setRawMode(false);
      }
      output.write('\n');

      if (password.length < 12) {
        output.write('Choose a password with at least 12 characters.\n');
        process.exitCode = 1;
        return;
      }

      output.write(`${await bcrypt.hash(password, 12)}\n`);
      return;
    }
    if (character === '\u007f' || character === '\b') {
      password = password.slice(0, -1);
    } else {
      password += character;
    }
  }
});

input.on('error', (error) => {
  output.write(`\nCould not read the password: ${error.message}\n`);
  process.exitCode = 1;
});
