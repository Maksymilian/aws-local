// Minimal structured JSON logger: one line per entry, cheap to search in CloudWatch.
const LEVELS = { DEBUG: 10, INFO: 20, WARN: 30, ERROR: 40 };
const threshold = LEVELS[process.env.LOG_LEVEL] ?? LEVELS.INFO;

function log(level, msg, data) {
  if (LEVELS[level] < threshold) return;
  console.log(JSON.stringify({ level, msg, env: process.env.APP_ENV, ...data }));
}

export const logger = {
  debug: (m, d) => log("DEBUG", m, d),
  info: (m, d) => log("INFO", m, d),
  warn: (m, d) => log("WARN", m, d),
  error: (m, d) => log("ERROR", m, d),
};
