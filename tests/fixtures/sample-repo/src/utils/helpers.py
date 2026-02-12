"""Utility helper functions."""


def format_output(message):
    """Format a message for display."""
    return f"[OUTPUT] {message}"


def validate_input(value):
    """Validate that input is non-empty."""
    if not value or not value.strip():
        raise ValueError("Input must not be empty")
    return True


def parse_config(filepath):
    """Parse a simple key=value config file."""
    config = {}
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            config[key.strip()] = value.strip()
    return config
