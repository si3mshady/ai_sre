import os
import re
import time
import chromadb
from fastapi import FastAPI, Query
from llama_index.core import VectorStoreIndex, SimpleDirectoryReader, StorageContext, Settings, Document
from llama_index.vector_stores.chroma import ChromaVectorStore
from llama_index.embeddings.huggingface import HuggingFaceEmbedding
from llama_index.llms.ollama import Ollama

app = FastAPI(title="Ghost Kitchen RAG Service V2")

# --- CONFIGURATION ---
Settings.llm = Ollama(
    model="llama3:latest", 
    base_url=os.getenv("OLLAMA_HOST", "http://ollama.kitchen-sre.svc.cluster.local:11434"), 
    request_timeout=360.0
)
Settings.embed_model = HuggingFaceEmbedding(model_name="BAAI/bge-base-en-v1.5")

def parse_runbook_with_metadata(file_path):
    """Custom parser to extract metadata for targeted RAG."""
    with open(file_path, 'r') as f:
        content = f.read()
    
    # Split by the horizontal rule used in the md file
    chunks = content.split("---")
    documents = []
    
    for chunk in chunks:
        metadata = {}
        # Extract metadata fields using regex
        metric_match = re.search(r"METRIC_NAME:\s*(.*)", chunk)
        station_match = re.search(r"STATION:\s*(.*)", chunk)
        
        if metric_match:
            metadata["metric"] = metric_match.group(1).strip()
        if station_match:
            metadata["station"] = station_match.group(1).strip()
        
        if chunk.strip():
            documents.append(Document(text=chunk.strip(), metadata=metadata))
    return documents

def get_index():
    db_host = os.getenv("CHROMA_HOST", "chroma")
    remote_db = chromadb.HttpClient(host=db_host, port=8000)
    chroma_collection = remote_db.get_or_create_collection("ghost_kitchen_slo_v2")
    vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
    storage_context = StorageContext.from_defaults(vector_store=vector_store)
    
    # Load and Parse
    documents = parse_runbook_with_metadata("/app/data/slo_runbook.md")
    return VectorStoreIndex.from_documents(documents, storage_context=storage_context)

# Global index
index = get_index()

@app.get("/diagnose")
async def diagnose(metric: str, value: float, station: str = "global"):
    start_time = time.perf_counter()
    
    # Metadata filtering logic
    filters = {"station": station}
    query_engine = index.as_query_engine(
        vector_store_kwargs={"where": filters}
    )
    
    prompt = f"The {metric} for station {station} is {value}. What is the exact SLO rule and K8s action?"
    response = query_engine.query(prompt)
    
    end_time = time.perf_counter()
    latency_ms = (end_time - start_time) * 1000

    raw_meta = response.metadata.get(list(response.metadata.keys())[0], {})
    
    return {
        "reasoning": str(response),
        "metadata_used": filters,
        "metrics": {
            "total_tokens": raw_meta.get("prompt_eval_count", 0) + raw_meta.get("eval_count", 0),
            "latency_ms": round(latency_ms, 2)
        }
    }

@app.post("/refresh")
async def refresh_index():
    global index
    index = get_index()
    return {"status": "Index Reloaded with Metadata Support"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
