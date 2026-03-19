import os
import time
import chromadb
from fastapi import FastAPI
from llama_index.core import VectorStoreIndex, SimpleDirectoryReader, StorageContext, Settings
from llama_index.vector_stores.chroma import ChromaVectorStore
from llama_index.embeddings.huggingface import HuggingFaceEmbedding
from llama_index.llms.ollama import Ollama

app = FastAPI(title="Ghost Kitchen RAG Service")

# --- CONFIGURATION ---
Settings.llm = Ollama(
    model="llama3:latest", 
    base_url=os.getenv("OLLAMA_HOST", "http://ollama.kitchen-sre.svc.cluster.local:11434"), 
    request_timeout=360.0
)
Settings.embed_model = HuggingFaceEmbedding(model_name="BAAI/bge-base-en-v1.5")

def get_index():
    db_host = os.getenv("CHROMA_HOST", "chroma") # Matches K8s Service Name
    remote_db = chromadb.HttpClient(host=db_host, port=8000)
    chroma_collection = remote_db.get_or_create_collection("ghost_kitchen_slo")
    vector_store = ChromaVectorStore(chroma_collection=chroma_collection)
    storage_context = StorageContext.from_defaults(vector_store=vector_store)
    
    # Load runbook from the mounted volume
    documents = SimpleDirectoryReader("/app/data").load_data()
    return VectorStoreIndex.from_documents(documents, storage_context=storage_context)

# Global index
index = get_index()

@app.get("/diagnose")
async def diagnose(metric: str, value: float):
    start_time = time.perf_counter()
    query_engine = index.as_query_engine()
    
    prompt = f"The {metric} is {value}. What is the exact SLO rule and required action from the runbook?"
    response = query_engine.query(prompt)
    
    end_time = time.perf_counter()
    latency_ms = (end_time - start_time) * 1000

    # Extract Token Factory Metrics
    raw_meta = response.metadata.get(list(response.metadata.keys())[0], {})
    prompt_tokens = raw_meta.get("prompt_eval_count", 0)
    completion_tokens = raw_meta.get("eval_count", 0)
    
    return {
        "reasoning": str(response),
        "metrics": {
            "total_tokens": prompt_tokens + completion_tokens,
            "latency_ms": round(latency_ms, 2),
            "tokens_per_sec": round(completion_tokens / (latency_ms / 1000), 2) if latency_ms > 0 else 0
        }
    }

@app.post("/refresh")
async def refresh_index():
    global index
    index = get_index()
    return {"status": "Index Reloaded"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
