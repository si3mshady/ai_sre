# Use a lightweight Python base
FROM python:3.10-slim

# Set working directory
WORKDIR /app

# Install system dependencies for building certain python packages if needed
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install LlamaIndex and specific integrations [cite: 16, 36, 179]
RUN pip install --no-cache-dir \
    fastapi \
    uvicorn \
    chromadb \
    llama-index \
    llama-index-vector-stores-chroma \
    llama-index-embeddings-huggingface \
    llama-index-llms-ollama

# Copy the application code
COPY main.py .

# Create the data directory (will be overridden by the volume mount)
RUN mkdir -p /app/data

# Expose FastAPI port
EXPOSE 8080

# Run the server
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
