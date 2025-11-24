#!/bin/bash

# ui-dev.sh: Script to run the UI in development mode for the Football Game project

# Set environment variables if needed
export NODE_ENV=development

# Navigate to the UI directory (adjust path if needed)
cd "$(dirname "$0")/../ui" || { echo "UI directory not found."; exit 1; }

# Install dependencies if node_modules does not exist
if [ ! -d "node_modules" ]; then
    echo "Installing UI dependencies..."
    npm install
fi

# Start the UI development server
echo "Starting UI development server..."
npm run dev

# End of script
