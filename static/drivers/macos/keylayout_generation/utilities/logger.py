import logging

from colorama import Fore, Style, init

# --- Colorama init ---
init(autoreset=True)


# --- Custom log levels: SUCCESS and LAUNCH ---
SUCCESS_LEVEL = 25
LAUNCH_LEVEL = 24
logging.addLevelName(SUCCESS_LEVEL, "SUCCESS")
logging.addLevelName(LAUNCH_LEVEL, "LAUNCH")


def success(self, message, *args, **kwargs):
    """Log a message with level SUCCESS on this logger."""
    if self.isEnabledFor(SUCCESS_LEVEL):
        self._log(SUCCESS_LEVEL, message, args, **kwargs)


def launch(self, message, *args, **kwargs):
    """Log a message with level LAUNCH on this logger."""
    if self.isEnabledFor(LAUNCH_LEVEL):
        self._log(LAUNCH_LEVEL, message, args, **kwargs)


logging.Logger.success = success
logging.Logger.launch = launch


# --- Formatter with emoji and color ---
class EmojiColorFormatter(logging.Formatter):
    """Custom formatter to add emojis and colors to log levels."""

    ORANGE = "\033[38;5;208m"
    LEVEL_COLORS = {
        logging.CRITICAL: Fore.RED,
        logging.ERROR: Fore.RED,
        logging.WARNING: ORANGE,
        SUCCESS_LEVEL: Fore.GREEN,
        LAUNCH_LEVEL: Fore.BLUE,
        logging.INFO: "",
        logging.DEBUG: "",
    }
    # Pre-formatted level strings, all 12 chars (emoji + level + colon + spaces)
    LEVEL_STRINGS = {
        logging.CRITICAL: "‼️  CRIT.    ",
        logging.ERROR: "❌ ERROR     ",
        logging.WARNING: "⚠️  WARNING  ",
        SUCCESS_LEVEL: "✅ SUCCESS  ",
        LAUNCH_LEVEL: "➡️  LAUNCH   ",
        logging.INFO: "INFO        ",
        logging.DEBUG: "DEBUG       ",
    }

    def format(self, record):
        color = self.LEVEL_COLORS.get(record.levelno, "")
        record.levelcustom = self.LEVEL_STRINGS.get(
            record.levelno, f"{record.levelname}: "
        )
        record.msg = color + str(record.msg) + Style.RESET_ALL
        return super().format(record)


# --- Logger configuration ---
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelcustom)s%(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("ergopti")
for handler in logging.getLogger().handlers:
    handler.setFormatter(
        EmojiColorFormatter(
            "%(asctime)s %(levelcustom)s%(message)s", datefmt="%H:%M:%S"
        )
    )


# --- Error counting handler ---
class ErrorCountingHandler(logging.Handler):
    """Logging handler that counts ERROR level messages."""

    def __init__(self):
        super().__init__()
        self.error_count = 0

    def emit(self, record):
        if record.levelno == logging.ERROR:
            self.error_count += 1

    def reset(self):
        self.error_count = 0

    def get_count(self):
        return self.error_count


_error_counter = ErrorCountingHandler()
logger.addHandler(_error_counter)


# --- Public API for error counting ---
def get_error_count():
    """Get the current count of ERROR level messages."""
    return _error_counter.get_count()


def reset_error_count():
    """Reset the error count."""
    _error_counter.reset()
