"""Main entry point for the sample application."""

from src.utils.helpers import format_output, validate_input
import os
import sys


class Application:
    """Main application class."""

    def __init__(self, name):
        self.name = name
        self.running = False

    def start(self):
        """Start the application."""
        validate_input(self.name)
        self.running = True
        return format_output(f"Started {self.name}")

    def stop(self):
        """Stop the application."""
        self.running = False
        return format_output(f"Stopped {self.name}")


def main():
    """CLI entry point."""
    app = Application("sample")
    print(app.start())


if __name__ == "__main__":
    main()
