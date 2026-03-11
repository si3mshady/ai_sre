#!/bin/bash

# 1. Ensure Ollama is running on the host
if ! pgrep -x "ollama" > /dev/null
then
    echo "Ollama is not running. Starting Ollama serve..."
    ollama serve &
    sleep 5
fi

# 2. Pull the specific model you need for the AI Agent
echo "Downloading Llama 3.2 (3B) to host machine..."
ollama pull llama3.2:3b

# 3. Verify the download
echo "Verifying local models..."
ollama list | grep "llama3.2:3b"

if [ $? -eq 0 ]; then
    echo "Success! Model is now stored locally on your host."
    echo "Default path is typically ~/.ollama/models"
else
    echo "Download failed. Please check your internet connection."
fi
