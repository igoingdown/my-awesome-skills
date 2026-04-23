#!/bin/bash
# Install dependencies for volcengine-balance-check skill

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venv"

echo "========================================"
echo "Installing volcengine-balance-check dependencies"
echo "========================================"

# Check Python 3
if ! command -v python3 &> /dev/null; then
    echo "❌ Error: Python 3 is not installed"
    echo "Please install Python 3 first:"
    echo "  brew install python3"
    exit 1
fi

echo "✅ Python 3 found: $(python3 --version)"

# Create virtual environment
echo ""
echo "Creating virtual environment..."
python3 -m venv "$VENV_DIR"

# Activate virtual environment
source "$VENV_DIR/bin/activate"

# Install dependencies
echo ""
echo "Installing volcengine SDK..."
pip install volcengine

echo ""
echo "========================================"
echo "✅ Installation complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo "1. Copy .env.example to .env:"
echo "   cp $SCRIPT_DIR/.env.example $SCRIPT_DIR/.env"
echo "2. Edit .env and fill in your credentials"
echo "3. Test the script:"
echo "   source $VENV_DIR/bin/activate"
echo "   python $SCRIPT_DIR/volcengine_balance_check.py"
echo ""
